#include "furl.h"
#include "bwt.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#endif

#define FURL_MAGIC 0x314D4346u /* "FCM1" little-endian */
#define NMAPS 7
#define MAX_LEVEL 9

enum {
    BLK_RAW = 1u << 0,
    BLK_BWT = 1u << 1,
    BLK_E8 = 1u << 2,
    BLK_DELTA = 1u << 3,
    BLK_MTF = 1u << 4,
    BLK_PPM = 1u << 5,
    /* Move-to-front bytes coded as zero-runs plus an order-0 model.
       Older blocks leave this clear and stay on PPM or LZ. */
    BLK_ZRLE = 1u << 6
};

static uint32_t crc32_tab[256];
static int crc32_ready;
static int16_t g_stretch[4096];
static uint16_t g_squash[4096];
static int tables_ready;
static float neglog_tab[256];

static int call_progress(const FurlOptions *opt, uint64_t done, uint64_t total);

static void wr32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void wr64(uint8_t *p, uint64_t v) {
    wr32(p, (uint32_t)v);
    wr32(p + 4, (uint32_t)(v >> 32));
}

static uint64_t rd64(const uint8_t *p) {
    return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
}

static void init_crc(void) {
#if defined(__APPLE__)
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) {
                c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
            }
            crc32_tab[i] = c;
        }
        crc32_ready = 1;
    });
#else
    if (crc32_ready) {
        return;
    }
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) {
            c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
        }
        crc32_tab[i] = c;
    }
    crc32_ready = 1;
#endif
}

static uint32_t crc32(const uint8_t *p, size_t n) {
    init_crc();
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) {
        c = crc32_tab[(c ^ p[i]) & 255] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFFu;
}

static void fill_tables(void) {
    for (int i = 0; i < 4096; i++) {
        double p = (i + 0.5) / 4096.0;
        double t = log(p / (1.0 - p));
        int v = (int)floor(t * 256.0 + 0.5);
        if (v > 2047) {
            v = 2047;
        }
        if (v < -2047) {
            v = -2047;
        }
        g_stretch[i] = (int16_t)v;
    }
    for (int d = -2048; d < 2048; d++) {
        double p = 1.0 / (1.0 + exp(-d / 256.0));
        int v = (int)floor(p * 4096.0 + 0.5);
        if (v < 1) {
            v = 1;
        }
        if (v > 4095) {
            v = 4095;
        }
        g_squash[d + 2048] = (uint16_t)v;
    }
    for (int i = 0; i < 256; i++) {
        double p = ((double)i + 0.5) / 256.0;
        neglog_tab[i] = (float)(-log2(p));
    }
    tables_ready = 1;
}

static void init_tables(void) {
#if defined(__APPLE__)
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fill_tables();
    });
#else
    if (tables_ready) {
        return;
    }
    fill_tables();
#endif
}

static uint32_t hmix(uint32_t x) {
    x *= 0x9E3779B1u;
    x ^= x >> 16;
    x *= 0x85EBCA6Bu;
    x ^= x >> 13;
    return x;
}

static int clamp_level(int level) {
    if (level <= 0) {
        return 7;
    }
    if (level > MAX_LEVEL) {
        return MAX_LEVEL;
    }
    return level;
}

#define FURL_MAX_MATCH 4169u /* 2 + 72 + 4095 */

static uint32_t block_size_for(int level) {
    /* One block for typical documents so the match window covers the whole file.
       Level 9 is 64 MiB, matching 7-Zip ultra's dictionary class. */
    static const uint32_t sizes[10] = {
        0,
        1u << 20, /* 1: 1 MiB */
        1u << 21,
        1u << 22,
        1u << 23,
        1u << 24, /* 5: 16 MiB */
        1u << 25,
        1u << 25, /* 7: 32 MiB */
        1u << 26,
        1u << 26  /* 9: 64 MiB */
    };
    return sizes[clamp_level(level)];
}

static int use_bwt_for(int level) {
    (void)level;
    return 0;
}

typedef struct {
    int encoding;
    int level;
    uint32_t x1, x2, x;
    uint8_t *out;
    size_t out_len, out_cap;
    const uint8_t *in;
    size_t in_len, in_pos;

    uint16_t *map[NMAPS];
    uint32_t mask[NMAPS];
    int32_t w[NMAPS];
    int32_t st[NMAPS];
    int p12[NMAPS];

    uint16_t *apm;
    uint32_t apm_mask;
    uint32_t apm_idx;

    uint8_t *hist;
    uint32_t hist_mask;
    uint32_t *ht;
    uint32_t *chain;
    uint32_t ht_mask;
    uint32_t pos, mlen, hist_pos;
    int chain_limit;

    uint32_t c1, c2, c3, c4, word, run;
    uint8_t pred_byte;
    int bit_index;
    uint16_t flag[512];
    uint16_t lenm[1024];
    uint16_t distm[1024];
    uint32_t last_dist;
    uint32_t prev_flags;
    uint32_t reps[4];
    FurlParseStats *tally;
    /* Bits the literal mixer has been spending per byte. Match selection
       compares a match token against this many literals. */
    double lit_cost;
} CM;

static int emit(CM *s, uint8_t b) {
    if (s->out_len >= s->out_cap) {
        if (s->out_cap > SIZE_MAX / 2) {
            return -1;
        }
        size_t nc = s->out_cap ? s->out_cap * 2 : 8192;
        uint8_t *p = (uint8_t *)realloc(s->out, nc);
        if (!p) {
            return -1;
        }
        s->out = p;
        s->out_cap = nc;
    }
    s->out[s->out_len++] = b;
    return 0;
}

static uint8_t readb(CM *s) {
    if (s->in_pos < s->in_len) {
        return s->in[s->in_pos++];
    }
    return 0;
}

static int enc_bit(CM *s, int bit, uint32_t p) {
    if (s->tally) {
        uint32_t prob = bit ? p : (65536u - p);
        if (prob < 1) {
            prob = 1;
        }
        if (prob > 65535) {
            prob = 65535;
        }
        s->tally->predicted_bits += (double)neglog_tab[prob >> 8];
    }
    uint32_t xmid = s->x1 + (uint32_t)(((uint64_t)(s->x2 - s->x1) * p) >> 16);
    if (bit) {
        s->x2 = xmid;
    } else {
        s->x1 = xmid + 1;
    }
    while (((s->x1 ^ s->x2) & 0xFF000000u) == 0) {
        if (emit(s, (uint8_t)(s->x2 >> 24))) {
            return -1;
        }
        s->x1 <<= 8;
        s->x2 = (s->x2 << 8) | 0xFFu;
    }
    return 0;
}

static int dec_bit(CM *s, uint32_t p) {
    uint32_t xmid = s->x1 + (uint32_t)(((uint64_t)(s->x2 - s->x1) * p) >> 16);
    int bit = s->x <= xmid;
    if (bit) {
        s->x2 = xmid;
    } else {
        s->x1 = xmid + 1;
    }
    while (((s->x1 ^ s->x2) & 0xFF000000u) == 0) {
        s->x1 <<= 8;
        s->x2 = (s->x2 << 8) | 0xFFu;
        s->x = (s->x << 8) | readb(s);
    }
    return bit;
}

static int enc_flush(CM *s) {
    for (int i = 0; i < 4; i++) {
        if (emit(s, (uint8_t)(s->x1 >> 24))) {
            return -1;
        }
        s->x1 <<= 8;
    }
    return 0;
}

static uint16_t *alloc_map(uint32_t bits) {
    size_t n = (size_t)1u << bits;
    uint16_t *m = (uint16_t *)calloc(n, sizeof(uint16_t));
    return m;
}

static void cm_free(CM *s) {
    for (int i = 0; i < NMAPS; i++) {
        free(s->map[i]);
        s->map[i] = NULL;
    }
    free(s->apm);
    free(s->hist);
    free(s->ht);
    free(s->chain);
    s->apm = NULL;
    s->hist = NULL;
    s->ht = NULL;
    s->chain = NULL;
}

static int cm_init(CM *s, int encoding, int level, const uint8_t *in, size_t in_len) {
    memset(s, 0, sizeof(*s));
    init_tables();
    s->encoding = encoding;
    s->level = clamp_level(level);
    s->x1 = 0;
    s->x2 = 0xFFFFFFFFu;
    s->in = in;
    s->in_len = in_len;
    if (!encoding) {
        s->x = 0;
        for (int i = 0; i < 4; i++) {
            s->x = (s->x << 8) | readb(s);
        }
    }

    int mb = 17 + s->level; /* 18..26 */
    if (mb > 22) {
        mb = 22;
    }
    int bits[NMAPS] = {12, 16, mb, mb, mb, 16, mb};
    for (int i = 0; i < NMAPS; i++) {
        s->map[i] = alloc_map((uint32_t)bits[i]);
        if (!s->map[i]) {
            cm_free(s);
            return FURL_ERR_NOMEM;
        }
        s->mask[i] = ((uint32_t)1u << bits[i]) - 1u;
        s->w[i] = 192;
    }

    s->apm = alloc_map(15);
    if (!s->apm) {
        cm_free(s);
        return FURL_ERR_NOMEM;
    }
    s->apm_mask = (1u << 15) - 1u;
    for (uint32_t i = 0; i <= s->apm_mask; i++) {
        s->apm[i] = 2048;
    }

    uint32_t wbits = (s->level <= 3) ? 22u : (s->level <= 6) ? 23u : (s->level <= 8) ? 24u : 25u;
    s->hist = (uint8_t *)calloc((size_t)1u << wbits, 1);
    s->hist_mask = ((uint32_t)1u << wbits) - 1u;
    /* LZ owns matching. The old CM hash-chain window (tens to hundreds of
       MiB) was allocated every block and then immediately disabled. */
    s->ht = NULL;
    s->chain = NULL;
    s->ht_mask = 0;
    s->chain_limit = 0;
    if (!s->hist) {
        cm_free(s);
        return FURL_ERR_NOMEM;
    }
    s->run = 1;
    s->lit_cost = 8.0;
    return FURL_OK;
}

/* Range coder only. The zero-run model does not use the mixer tables. */
static void cm_range_init(CM *s, int encoding, const uint8_t *in, size_t in_len) {
    memset(s, 0, sizeof(*s));
    s->encoding = encoding;
    s->x1 = 0;
    s->x2 = 0xFFFFFFFFu;
    s->in = in;
    s->in_len = in_len;
    if (!encoding) {
        for (int i = 0; i < 4; i++) {
            s->x = (s->x << 8) | readb(s);
        }
    }
}

static int mix_predict(CM *s, uint32_t ctxs[NMAPS]) {
    int32_t sum = 0;
    for (int i = 0; i < NMAPS; i++) {
        uint16_t st = s->map[i][ctxs[i] & s->mask[i]];
        int n0 = st & 255;
        int n1 = st >> 8;
        int p12 = ((n1 + 1) << 12) / (n0 + n1 + 2);
        if (p12 < 1) {
            p12 = 1;
        }
        if (p12 > 4095) {
            p12 = 4095;
        }
        s->p12[i] = p12;
        s->st[i] = g_stretch[p12];
        sum += (s->w[i] * s->st[i]) >> 8;
    }
    if (sum < -2047) {
        sum = -2047;
    }
    if (sum > 2047) {
        sum = 2047;
    }
    int p = g_squash[sum + 2048];
    if (s->mlen >= 2) {
        int pb = (s->pred_byte >> (7 - s->bit_index)) & 1;
        int conf = s->mlen > 80 ? 80 : (int)s->mlen;
        int pmatch = pb ? 4095 - (48 / (conf / 2 + 1)) : (48 / (conf / 2 + 1));
        int wmatch = conf * 80;
        p = (int)(((int64_t)p * 128 + (int64_t)pmatch * wmatch) / (128 + wmatch));
    }
    s->apm_idx = ((s->c1 << 7) ^ ((uint32_t)s->bit_index << 12) ^ ((uint32_t)p >> 4)) & s->apm_mask;
    int ap = s->apm[s->apm_idx];
    p = (int)(((int64_t)p * 7 + ap) >> 3);
    if (p < 1) {
        p = 1;
    }
    if (p > 4095) {
        p = 4095;
    }
    return p;
}

static void mix_update(CM *s, uint32_t ctxs[NMAPS], int bit, int p12) {
    int err = (bit ? 4095 : 0) - p12;
    for (int i = 0; i < NMAPS; i++) {
        int32_t d = (err * s->st[i]) >> 11;
        s->w[i] += d;
        if (s->w[i] > 4096) {
            s->w[i] = 4096;
        }
        if (s->w[i] < -64) {
            s->w[i] = -64;
        }

        uint32_t idx = ctxs[i] & s->mask[i];
        uint16_t st = s->map[i][idx];
        int n0 = st & 255;
        int n1 = st >> 8;
        if (bit) {
            if (n1 < 255) {
                n1++;
            } else {
                n0 = (n0 + 1) >> 1;
                n1 = (n1 + 1) >> 1;
            }
        } else {
            if (n0 < 255) {
                n0++;
            } else {
                n0 = (n0 + 1) >> 1;
                n1 = (n1 + 1) >> 1;
            }
        }
        int cap = (i >= 2) ? 96 : 192;
        if (n0 + n1 > cap) {
            n0 = (n0 + 1) >> 1;
            n1 = (n1 + 1) >> 1;
        }
        s->map[i][idx] = (uint16_t)(n0 | (n1 << 8));
    }

    int ap = s->apm[s->apm_idx];
    ap += ((bit ? 4095 : 1) - ap) >> 4;
    if (ap < 1) {
        ap = 1;
    }
    if (ap > 4095) {
        ap = 4095;
    }
    s->apm[s->apm_idx] = (uint16_t)ap;
}

static int code_byte(CM *s, uint8_t *byte) {
    uint32_t y = 1;
    uint8_t c = s->encoding ? *byte : 0;
    double spent = 0;
    /* Context hashes do not depend on the bits of this byte — hoist them. */
    uint32_t base[NMAPS];
    uint32_t run = s->run > 31 ? 31 : s->run;
    base[0] = run << 8;
    base[1] = s->c1 << 8;
    base[2] = hmix(s->c1 | (s->c2 << 8)) * 32u;
    base[3] = hmix(s->c1 | (s->c2 << 8) | (s->c3 << 16) | (s->c4 << 24)) * 32u;
    {
        uint32_t h = s->c1 + s->c2 * 3u + s->c3 * 5u + s->c4 * 7u;
        if (s->pos > 4) {
            h = hmix(h ^ s->hist[(s->pos - 5) & s->hist_mask]);
        }
        if (s->pos > 5) {
            h = hmix(h ^ ((uint32_t)s->hist[(s->pos - 6) & s->hist_mask] << 8));
        }
        base[4] = hmix(h) * 32u;
    }
    base[5] = 0;
    base[6] = hmix(s->word) * 16u;
    for (int i = 7; i >= 0; i--) {
        s->bit_index = 7 - i;
        uint32_t ctxs[NMAPS];
        ctxs[0] = base[0] | y;
        ctxs[1] = base[1] | y;
        ctxs[2] = base[2] + y;
        ctxs[3] = base[3] + y;
        ctxs[4] = base[4] + y;
        if (s->mlen >= 2) {
            uint32_t pb = (uint32_t)((s->pred_byte >> (7 - s->bit_index)) & 1);
            uint32_t ml = s->mlen > 63 ? 63 : s->mlen;
            ctxs[5] = (ml << 9) | (pb << 8) | y;
        } else {
            ctxs[5] = (1u << 8) | y;
        }
        ctxs[6] = base[6] + y;
        int p12 = mix_predict(s, ctxs);
        uint32_t p16 = (uint32_t)p12 << 4;
        if (p16 < 1) {
            p16 = 1;
        }
        if (p16 > 65535) {
            p16 = 65535;
        }
        int bit;
        if (s->encoding) {
            bit = (c >> i) & 1;
            uint32_t prob = bit ? p16 : (65536u - p16);
            if (prob < 1) {
                prob = 1;
            }
            if (prob > 65535) {
                prob = 65535;
            }
            spent += (double)neglog_tab[prob >> 8];
            if (enc_bit(s, bit, p16)) {
                return FURL_ERR_NOMEM;
            }
        } else {
            bit = dec_bit(s, p16);
            c = (uint8_t)((c << 1) | bit);
        }
        mix_update(s, ctxs, bit, p12);
        y = (y << 1) | (uint32_t)bit;
    }
    if (!s->encoding) {
        *byte = c;
    }
    if (s->encoding) {
        s->lit_cost += (spent - s->lit_cost) * 0.08;
    }

    uint8_t actual = s->encoding ? *byte : c;
    if (s->mlen >= 2) {
        if (actual == s->pred_byte) {
            s->mlen++;
            s->hist_pos = (s->hist_pos + 1) & s->hist_mask;
        } else {
            s->mlen = 0;
        }
    }
    s->hist[s->pos & s->hist_mask] = actual;

    uint32_t h = 0;
    uint32_t prev = 0;
    if (s->chain_limit > 0 && s->ht && s->chain) {
        h = hmix((uint32_t)actual | (s->c1 << 8) | (s->c2 << 16) | (s->c3 << 24)) & s->ht_mask;
        prev = s->ht[h];
        s->chain[s->pos & s->hist_mask] = prev;
        s->ht[h] = s->pos + 1;
    }
    if (s->chain_limit > 0 && s->mlen < 3) {
        uint32_t best_k = 0, best_hp = 0;
        uint32_t cursor = prev;
        uint32_t max_dist = s->hist_mask;
        uint32_t limit = 65536;
        for (int steps = 0; steps < s->chain_limit && cursor; steps++) {
            uint32_t hp = cursor - 1;
            if (hp >= s->pos || (s->pos - hp) > max_dist) {
                break;
            }
            uint32_t k = 0;
            uint32_t maxk = s->pos - hp;
            if (maxk > limit) {
                maxk = limit;
            }
            while (k < maxk && s->hist[(s->pos - k) & s->hist_mask] == s->hist[(hp - k) & s->hist_mask]) {
                k++;
            }
            if (k > best_k) {
                best_k = k;
                best_hp = hp;
            }
            uint32_t next = s->chain[hp & s->hist_mask];
            if (next == cursor) {
                break;
            }
            cursor = next;
        }
        if (best_k >= 3) {
            s->mlen = best_k;
            s->hist_pos = best_hp;
        }
    }
    if (s->mlen >= 2) {
        s->pred_byte = s->hist[(s->hist_pos + 1) & s->hist_mask];
    }

    if (actual == (uint8_t)s->c1) {
        if (s->run < 0xFFFF) {
            s->run++;
        }
    } else {
        s->run = 1;
    }
    s->c4 = s->c3;
    s->c3 = s->c2;
    s->c2 = s->c1;
    s->c1 = actual;
    if ((actual >= 'A' && actual <= 'Z') || (actual >= 'a' && actual <= 'z')) {
        s->word = s->word * 29u + (actual & 31u);
    } else {
        s->word = 0;
    }
    s->pos++;
    return FURL_OK;
}

static void e8_fwd(uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i + 5 <= n; i++) {
        if (b[i] == 0xE8 || b[i] == 0xE9) {
            uint32_t rel = (uint32_t)b[i + 1] | ((uint32_t)b[i + 2] << 8) |
                           ((uint32_t)b[i + 3] << 16) | ((uint32_t)b[i + 4] << 24);
            uint32_t absv = rel + i;
            b[i + 1] = (uint8_t)absv;
            b[i + 2] = (uint8_t)(absv >> 8);
            b[i + 3] = (uint8_t)(absv >> 16);
            b[i + 4] = (uint8_t)(absv >> 24);
            i += 4;
        }
    }
}

static void e8_inv(uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i + 5 <= n; i++) {
        if (b[i] == 0xE8 || b[i] == 0xE9) {
            uint32_t absv = (uint32_t)b[i + 1] | ((uint32_t)b[i + 2] << 8) |
                            ((uint32_t)b[i + 3] << 16) | ((uint32_t)b[i + 4] << 24);
            uint32_t rel = absv - i;
            b[i + 1] = (uint8_t)rel;
            b[i + 2] = (uint8_t)(rel >> 8);
            b[i + 3] = (uint8_t)(rel >> 16);
            b[i + 4] = (uint8_t)(rel >> 24);
            i += 4;
        }
    }
}

static void mtf_fwd(uint8_t *b, uint32_t n) {
    uint8_t list[256];
    for (int i = 0; i < 256; i++) {
        list[i] = (uint8_t)i;
    }
    for (uint32_t i = 0; i < n; i++) {
        uint8_t v = b[i];
        int k = 0;
        while (list[k] != v) {
            k++;
        }
        b[i] = (uint8_t)k;
        while (k > 0) {
            list[k] = list[k - 1];
            k--;
        }
        list[0] = v;
    }
}

static void mtf_inv(uint8_t *b, uint32_t n) {
    uint8_t list[256];
    for (int i = 0; i < 256; i++) {
        list[i] = (uint8_t)i;
    }
    for (uint32_t i = 0; i < n; i++) {
        int k = b[i];
        uint8_t v = list[k];
        b[i] = v;
        while (k > 0) {
            list[k] = list[k - 1];
            k--;
        }
        list[0] = v;
    }
}

static void delta_fwd(uint8_t *b, uint32_t n, int w) {
    for (uint32_t i = n; i-- > (uint32_t)w;) {
        b[i] = (uint8_t)(b[i] - b[i - (uint32_t)w]);
    }
}

static void delta_inv(uint8_t *b, uint32_t n, int w) {
    for (uint32_t i = (uint32_t)w; i < n; i++) {
        b[i] = (uint8_t)(b[i] + b[i - (uint32_t)w]);
    }
}

static int text_window(const uint8_t *b, uint32_t n) {
    uint32_t hi = 0, bad = 0;
    if (n == 0) {
        return 0;
    }
    for (uint32_t i = 0; i < n; i++) {
        uint8_t c = b[i];
        if (c == 0) {
            return 0;
        }
        if (c < 32 && c != 9 && c != 10 && c != 13) {
            bad++;
        } else if (c >= 128) {
            hi++;
        }
    }
    if (bad * 50 > n) {
        return 0; /* >2% C0 controls */
    }
    if (hi * 5 > n * 2) {
        return 0; /* >40% high bytes — likely binary, not UTF-8 prose */
    }
    return 1;
}

/* Whole-block probe. The first 4 KiB of a solid archive is often XML/HTML
   even when later files are JPEG/fonts; sampling only the head picked PPM
   for mixed folders and then failed with FURL_ERR_DATA. */
static int looks_text(const uint8_t *b, uint32_t n) {
    if (n == 0) {
        return 0;
    }
    uint32_t win = n < 4096 ? n : 4096;
    if (!text_window(b, win)) {
        return 0;
    }
    if (n > win && !text_window(b + n - win, win)) {
        return 0;
    }
    if (n > win * 2) {
        uint32_t mid = n / 2;
        uint32_t off = mid > win / 2 ? mid - win / 2 : 0;
        if (!text_window(b + off, win)) {
            return 0;
        }
    }
    uint32_t stride = 128u * 1024u;
    for (uint32_t off = stride; off + 1024 < n; off += stride) {
        uint32_t w = n - off < 1024 ? n - off : 1024;
        if (!text_window(b + off, w)) {
            return 0;
        }
    }
    return 1;
}

static int count_e8(const uint8_t *b, uint32_t n) {
    uint32_t lim = n < 65536 ? n : 65536;
    int c = 0;
    for (uint32_t i = 0; i + 5 <= lim; i++) {
        if (b[i] == 0xE8 || b[i] == 0xE9) {
            c++;
        }
    }
    return c;
}

static double sample_entropy(const uint8_t *b, uint32_t n) {
    uint32_t lim = n < 8192 ? n : 8192;
    uint32_t hist[256];
    memset(hist, 0, sizeof(hist));
    for (uint32_t i = 0; i < lim; i++) {
        hist[b[i]]++;
    }
    double e = 0, N = (double)lim;
    for (int i = 0; i < 256; i++) {
        if (hist[i]) {
            double p = hist[i] / N;
            e -= p * log(p);
        }
    }
    return e;
}

static int choose_delta(const uint8_t *b, uint32_t n) {
    if (n < 64 || looks_text(b, n)) {
        return 0;
    }
    uint8_t tmp[8192];
    uint32_t lim = n < 8192 ? n : 8192;
    memcpy(tmp, b, lim);
    double e0 = sample_entropy(tmp, lim);
    int best = 0;
    double best_e = e0 * 0.97;
    int widths[] = {2, 4};
    for (int i = 0; i < 2; i++) {
        int w = widths[i];
        memcpy(tmp, b, lim);
        delta_fwd(tmp, lim, w);
        double e = sample_entropy(tmp, lim);
        if (e < best_e) {
            best_e = e;
            best = w;
        }
    }
    return best;
}

/* Content-typed variable blocks. 7-Zip wins on mixed folders when one 64 MiB
   LZ block holds HTML, PCM, and JPEG together: PPM never runs, and already-
   packed media never stores. Granules are 4 KiB; short TEXT/RAW runs fold
   back into LZ so we do not shatter a binary that has a few hot granules. */
#define FURL_GRAN 4096u
#define FURL_MIN_TEXT (32u * 1024u)
#define FURL_MIN_RAW (48u * 1024u)

enum { CLS_LZ = 0, CLS_TEXT = 1, CLS_RAW = 2, CLS_BWT = 3 };

typedef struct {
    size_t off;
    uint32_t n;
    uint8_t cls;
} FurlSeg;

static int packed_magic(const uint8_t *b, uint32_t n) {
    if (n < 4) {
        return 0;
    }
    /* SOI must be followed by a marker. FF D8 FF 00 is byte-stuffing, not a header. */
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF && b[3] != 0x00 && b[3] != 0xFF) {
        return 1; /* JPEG */
    }
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
        return 1; /* PNG */
    }
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
        return 1; /* GIF */
    }
    /* 1F 8B alone collides inside uncompressed bytes. Require DEFLATE and clear reserved flags. */
    if (b[0] == 0x1F && b[1] == 0x8B && b[2] == 0x08 && (b[3] & 0xE0) == 0) {
        return 1; /* gzip */
    }
    if (b[0] == 0x50 && b[1] == 0x4B &&
        ((b[2] == 0x03 && b[3] == 0x04) ||
         (b[2] == 0x05 && b[3] == 0x06) ||
         (b[2] == 0x07 && b[3] == 0x08))) {
        return 1; /* zip local, end of central directory, or split */
    }
    if (b[0] == 0xFD && b[1] == 0x37 && b[2] == 0x7A && b[3] == 0x58) {
        return 1; /* xz */
    }
    if (b[0] == 0x28 && b[1] == 0xB5 && b[2] == 0x2F && b[3] == 0xFD) {
        return 1; /* zstd */
    }
    if (b[0] == 'i' && b[1] == 'c' && b[2] == 'n' && b[3] == 's') {
        return 1; /* Apple icns */
    }
    if (n >= 12 && b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F' &&
        b[8] == 'W' && b[9] == 'E' && b[10] == 'B' && b[11] == 'P') {
        return 1;
    }
    if (n >= 8 && memcmp(b + 4, "ftyp", 4) == 0) {
        return 1; /* MP4 / MOV */
    }
    if (b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) {
        return 1; /* Matroska / WebM */
    }
    return 0;
}

static double byte_entropy_bits(const uint8_t *b, uint32_t n) {
    if (n == 0) {
        return 0;
    }
    uint32_t hist[256];
    memset(hist, 0, sizeof(hist));
    for (uint32_t i = 0; i < n; i++) {
        hist[b[i]]++;
    }
    double e = 0, N = (double)n, ln2 = log(2.0);
    for (int i = 0; i < 256; i++) {
        if (hist[i]) {
            double p = hist[i] / N;
            e -= p * log(p);
        }
    }
    return e / ln2;
}

static int classify_window(const uint8_t *b, uint32_t n) {
    if (n == 0) {
        return CLS_LZ;
    }
    if (packed_magic(b, n)) {
        return CLS_RAW;
    }
    double bits = byte_entropy_bits(b, n);
    if (text_window(b, n) && bits < 6.85) {
        return CLS_TEXT;
    }
    return CLS_LZ;
}

static uint32_t cut_take(size_t off, size_t hard, uint32_t max_block,
                         const uint64_t *file_ends, uint32_t nfiles) {
    uint32_t take = (uint32_t)(hard - off);
    if (!file_ends || nfiles == 0 || take <= max_block / 2) {
        return take;
    }
    size_t min_cut = off + (size_t)max_block / 2;
    size_t cut = hard;
    int found = 0;
    for (uint32_t f = 0; f < nfiles; f++) {
        uint64_t e = file_ends[f];
        if (e > min_cut && e <= (uint64_t)hard && e > (uint64_t)off) {
            cut = (size_t)e;
            found = 1;
        }
    }
    if (found && cut > off && cut <= hard) {
        return (uint32_t)(cut - off);
    }
    return take;
}

static int plan_segments(const uint8_t *in, size_t n, uint32_t max_block,
                         const uint64_t *file_ends, uint32_t nfiles,
                         const FurlOptions *opt, FurlSeg **out, uint32_t *nout) {
    if (n == 0) {
        *out = NULL;
        *nout = 0;
        return FURL_OK;
    }
    uint32_t ng = (uint32_t)((n + (size_t)FURL_GRAN - 1) / FURL_GRAN);
    uint8_t *g = (uint8_t *)malloc(ng);
    if (!g) {
        return FURL_ERR_NOMEM;
    }
    for (uint32_t i = 0; i < ng; i++) {
        size_t off = (size_t)i * FURL_GRAN;
        if ((i & 255u) == 0) {
            int pr = call_progress(opt, (uint64_t)off, (uint64_t)n);
            if (pr != FURL_OK) {
                free(g);
                return pr;
            }
        }
        uint32_t w = (uint32_t)((n - off) > FURL_GRAN ? FURL_GRAN : (n - off));
        g[i] = (uint8_t)classify_window(in + off, w);
        if (i > 0 && g[i - 1] == CLS_RAW && g[i] != CLS_RAW) {
            double bits = byte_entropy_bits(in + off, w);
            if (bits >= 7.30) {
                g[i] = CLS_RAW; /* packed body after a magic/header granule */
            }
        }
    }
    uint32_t i = 0;
    while (i < ng) {
        uint8_t cls = g[i];
        uint32_t j = i + 1;
        while (j < ng && g[j] == cls) {
            j++;
        }
        size_t off = (size_t)i * FURL_GRAN;
        uint32_t bytes = (uint32_t)((n - off) > (size_t)(j - i) * FURL_GRAN ? (size_t)(j - i) * FURL_GRAN : (n - off));
        if ((cls == CLS_TEXT && bytes < FURL_MIN_TEXT) || (cls == CLS_RAW && bytes < FURL_MIN_RAW)) {
            for (uint32_t k = i; k < j; k++) {
                g[k] = CLS_LZ;
            }
        }
        i = j;
    }
    uint32_t cap = ng + (uint32_t)(n / max_block) + 8;
    FurlSeg *segs = (FurlSeg *)malloc((size_t)cap * sizeof(FurlSeg));
    if (!segs) {
        free(g);
        return FURL_ERR_NOMEM;
    }
    uint32_t ns = 0;
    i = 0;
    while (i < ng) {
        uint8_t cls = g[i];
        uint32_t j = i + 1;
        while (j < ng && g[j] == cls) {
            j++;
        }
        size_t off = (size_t)i * FURL_GRAN;
        size_t end = (j == ng) ? n : (size_t)j * FURL_GRAN;
        if (end > n) {
            end = n;
        }
        while (off < end) {
            size_t hard = off + max_block;
            if (hard > end) {
                hard = end;
            }
            uint32_t take = cut_take(off, hard, max_block, file_ends, nfiles);
            if (ns >= cap) {
                cap *= 2;
                FurlSeg *nb = (FurlSeg *)realloc(segs, (size_t)cap * sizeof(FurlSeg));
                if (!nb) {
                    free(g);
                    free(segs);
                    return FURL_ERR_NOMEM;
                }
                segs = nb;
            }
            segs[ns].off = off;
            segs[ns].n = take;
            segs[ns].cls = cls;
            ns++;
            off += take;
        }
        i = j;
    }
    free(g);
    *out = segs;
    *nout = ns;
    return FURL_OK;
}

static int code_adapt(CM *s, uint16_t *cell, int *bit) {
    int n0 = (*cell) & 255;
    int n1 = (*cell) >> 8;
    int p12 = ((n1 + 1) << 12) / (n0 + n1 + 2);
    if (p12 < 1) {
        p12 = 1;
    }
    if (p12 > 4095) {
        p12 = 4095;
    }
    uint32_t p16 = (uint32_t)p12 << 4;
    if (s->encoding) {
        if (enc_bit(s, *bit, p16)) {
            return FURL_ERR_NOMEM;
        }
    } else {
        *bit = dec_bit(s, p16);
    }
    if (*bit) {
        if (n1 < 255) {
            n1++;
        } else {
            n0 = (n0 + 1) >> 1;
            n1 = (n1 + 1) >> 1;
        }
    } else {
        if (n0 < 255) {
            n0++;
        } else {
            n0 = (n0 + 1) >> 1;
            n1 = (n1 + 1) >> 1;
        }
    }
    if (n0 + n1 > 192) {
        n0 = (n0 + 1) >> 1;
        n1 = (n1 + 1) >> 1;
    }
    *cell = (uint16_t)(n0 | (n1 << 8));
    return FURL_OK;
}

static int code_bits(CM *s, uint16_t *map, uint32_t map_mask, uint32_t ctx, uint32_t *value, int nbits) {
    uint32_t v = 0;
    if (s->encoding) {
        v = *value;
    }
    for (int i = 0; i < nbits; i++) {
        int b = s->encoding ? (int)((v >> i) & 1) : 0;
        uint16_t *cell = &map[(ctx + (uint32_t)(i * 17)) & map_mask];
        int rc = code_adapt(s, cell, &b);
        if (rc != FURL_OK) {
            return rc;
        }
        if (!s->encoding) {
            v |= (uint32_t)b << i;
        }
    }
    if (!s->encoding) {
        *value = v;
    }
    return FURL_OK;
}

static void cm_see(CM *s, uint8_t actual) {
    s->hist[s->pos & s->hist_mask] = actual;
    if (actual == (uint8_t)s->c1) {
        if (s->run < 0xFFFF) {
            s->run++;
        }
    } else {
        s->run = 1;
    }
    s->c4 = s->c3;
    s->c3 = s->c2;
    s->c2 = s->c1;
    s->c1 = actual;
    if ((actual >= 'A' && actual <= 'Z') || (actual >= 'a' && actual <= 'z')) {
        s->word = s->word * 29u + (actual & 31u);
    } else {
        s->word = 0;
    }
    s->pos++;
}

static int code_length(CM *s, uint32_t *len) {
    /* *len is match length >= 2 */
    uint32_t extra = s->encoding ? *len - 2 : 0;
    int shortl = s->encoding ? extra < 8 : 0;
    uint32_t ctx = (s->c1 ^ (s->prev_flags << 8)) & 511;
    int rc = code_adapt(s, &s->lenm[ctx], &shortl);
    if (rc != FURL_OK) {
        return rc;
    }
    if (shortl) {
        rc = code_bits(s, s->lenm, 1023, 64 + (s->c1 & 7), &extra, 3);
        if (rc != FURL_OK) {
            return rc;
        }
        if (!s->encoding) {
            *len = extra + 2;
        }
        return FURL_OK;
    }
    int med = s->encoding ? extra < 72 : 0;
    rc = code_adapt(s, &s->lenm[512 + (ctx & 255)], &med);
    if (rc != FURL_OK) {
        return rc;
    }
    if (med) {
        uint32_t v = s->encoding ? extra - 8 : 0;
        rc = code_bits(s, s->lenm, 1023, 128, &v, 6);
        if (rc != FURL_OK) {
            return rc;
        }
        if (!s->encoding) {
            *len = v + 8 + 2;
        }
        return FURL_OK;
    }
    uint32_t v = s->encoding ? extra - 72 : 0;
    if (s->encoding && v > 4095) {
        v = 4095;
    }
    rc = code_bits(s, s->lenm, 1023, 256, &v, 12);
    if (rc != FURL_OK) {
        return rc;
    }
    if (!s->encoding) {
        *len = v + 72 + 2;
    }
    return FURL_OK;
}

static int ilog2u(uint32_t x) {
    int n = 0;
    while (x >>= 1) {
        n++;
    }
    return n;
}

static void reps_push(CM *s, uint32_t dist) {
    if (s->reps[0] == dist) {
        return;
    }
    s->reps[3] = s->reps[2];
    s->reps[2] = s->reps[1];
    s->reps[1] = s->reps[0];
    s->reps[0] = dist;
    s->last_dist = dist;
}

static int code_dist(CM *s, uint32_t *dist) {
    int is_rep = 0;
    uint32_t rep_idx = 0;
    if (s->encoding) {
        for (uint32_t i = 0; i < 4; i++) {
            if (s->reps[i] != 0 && s->reps[i] == *dist) {
                is_rep = 1;
                rep_idx = i;
                break;
            }
        }
    }
    int rc = code_adapt(s, &s->distm[(s->prev_flags ^ s->c1) & 255], &is_rep);
    if (rc != FURL_OK) {
        return rc;
    }
    if (is_rep) {
        rc = code_bits(s, s->distm, 1023, 48, &rep_idx, 2);
        if (rc != FURL_OK) {
            return rc;
        }
        if (!s->encoding) {
            if (rep_idx > 3 || s->reps[rep_idx] == 0) {
                return FURL_ERR_DATA;
            }
            *dist = s->reps[rep_idx];
        }
        reps_push(s, *dist);
        return FURL_OK;
    }

    uint32_t slot = 0, extra = 0;
    if (s->encoding) {
        if (*dist == 0) {
            return FURL_ERR_DATA;
        }
        slot = (uint32_t)ilog2u(*dist);
        extra = *dist - (1u << slot);
    }
    rc = code_bits(s, s->distm, 1023, 80 + (s->c1 & 15), &slot, 5);
    if (rc != FURL_OK) {
        return rc;
    }
    /* 5-bit slot: 0..31 → distances up to 2^31. Blocks are 64 MiB at
       density 9, so matches beyond 16 MiB (old cap of 24) must be legal. */
    if (slot > 31) {
        return FURL_ERR_DATA;
    }
    if (slot > 0) {
        rc = code_bits(s, s->distm, 1023, 200 + slot, &extra, (int)slot);
        if (rc != FURL_OK) {
            return rc;
        }
    }
    if (!s->encoding) {
        *dist = (1u << slot) + extra;
    }
    reps_push(s, *dist);
    return FURL_OK;
}

static uint32_t lz_hash3(const uint8_t *in, uint32_t pos) {
    return hmix((uint32_t)in[pos] | ((uint32_t)in[pos + 1] << 8) | ((uint32_t)in[pos + 2] << 16));
}

static uint32_t lz_hash4(const uint8_t *in, uint32_t pos) {
    return hmix((uint32_t)in[pos] | ((uint32_t)in[pos + 1] << 8) | ((uint32_t)in[pos + 2] << 16) | ((uint32_t)in[pos + 3] << 24));
}

static uint32_t min_len_for_dist(uint32_t dist) {
    if (dist <= 256) {
        return 2;
    }
    if (dist <= 4096) {
        return 3;
    }
    if (dist <= 65536) {
        return 4;
    }
    if (dist <= 1048576) {
        return 5;
    }
    return 6;
}

#define FURL_NICE 64u

static uint64_t load64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return v;
}

static uint32_t match_len(const uint8_t *a, const uint8_t *b, uint32_t maxk) {
    uint32_t k = 0;
    while (k + 8 <= maxk && load64(a + k) == load64(b + k)) {
        k += 8;
    }
    if (k + 8 <= maxk) {
        uint64_t x = load64(a + k) ^ load64(b + k);
        k += (uint32_t)(__builtin_ctzll(x) >> 3);
        if (k > maxk) {
            k = maxk;
        }
        return k;
    }
    while (k < maxk && a[k] == b[k]) {
        k++;
    }
    return k;
}

static void lz_walk(const uint8_t *in, uint32_t pos, uint32_t cursor, const uint32_t *chain,
                   int limit, uint32_t maxk, uint32_t maxdist, uint32_t nice_len,
                   uint64_t *seen, uint32_t *best, uint32_t *best_d) {
    uint32_t nice = nice_len ? nice_len : FURL_NICE;
    if (nice > maxk) {
        nice = maxk;
    }
    uint16_t want2 = 0;
    if (maxk >= 2) {
        memcpy(&want2, in + pos, 2);
    }
    for (int i = 0; i < limit && cursor; i++) {
        if (seen) {
            (*seen)++;
        }
        uint32_t hp = cursor - 1;
        if (hp >= pos) {
            break;
        }
        uint32_t dist = pos - hp;
        if (dist > maxdist) {
            break;
        }
        if (maxk >= 2) {
            uint16_t got2;
            memcpy(&got2, in + hp, 2);
            if (got2 != want2) {
                uint32_t next = chain[hp];
                if (next == cursor) {
                    break;
                }
                cursor = next;
                continue;
            }
        }
        uint32_t minl = min_len_for_dist(dist);
        uint32_t k = match_len(in + pos, in + hp, maxk);
        if (k >= minl) {
            uint32_t extra = 0;
            if (*best && *best_d) {
                if (dist > *best_d * 16u) {
                    extra = 2;
                } else if (dist > *best_d * 4u) {
                    extra = 1;
                }
            }
            if (*best == 0 || k > *best + extra || (k == *best && dist < *best_d)) {
                *best = k;
                *best_d = dist;
            }
        }
        if (k == maxk || *best >= nice) {
            break;
        }
        uint32_t next = chain[hp];
        if (next == cursor) {
            break;
        }
        cursor = next;
    }
}

static void lz_insert(const uint8_t *in, uint32_t pos, uint32_t n, uint32_t *ht3, uint32_t *ht4,
                      uint32_t *chain3, uint32_t *chain4, uint32_t hmask) {
    if (pos + 3 <= n) {
        uint32_t h = lz_hash3(in, pos) & hmask;
        chain3[pos] = ht3[h];
        ht3[h] = pos + 1;
    }
    if (pos + 4 <= n && ht4 && chain4) {
        uint32_t h = lz_hash4(in, pos) & hmask;
        chain4[pos] = ht4[h];
        ht4[h] = pos + 1;
    }
}

static int lz_keep_insert(uint32_t pos, uint32_t start, uint32_t end) {
    uint32_t len = end - start;
    if (len <= 64) {
        return 1;
    }
    uint32_t i = pos - start;
    return i < 8 || pos + 2 >= end || (i & 1) == 0;
}

static int rep_index(const uint32_t *reps, uint32_t dist) {
    if (!reps || dist == 0) {
        return -1;
    }
    for (int i = 0; i < 4; i++) {
        if (reps[i] == dist) {
            return i;
        }
    }
    return -1;
}

static void lz_find(const uint8_t *raw, uint32_t pos, uint32_t n,
                   const uint32_t *ht2, const uint32_t *ht3, const uint32_t *ht4,
                   const uint32_t *chain2, const uint32_t *chain3, const uint32_t *chain4,
                   uint32_t hmask, int limit2, int limit3, int limit4,
                   const uint32_t *reps, uint32_t nice_len, uint64_t *seen,
                   uint32_t *best_ml, uint32_t *best_dist) {
    uint32_t dist = 0, ml = 0;
    uint32_t maxk = n - pos;
    if (maxk > FURL_MAX_MATCH) {
        maxk = FURL_MAX_MATCH;
    }
    if (maxk < 2) {
        *best_ml = 0;
        *best_dist = 0;
        return;
    }
    uint32_t nice = nice_len ? nice_len : FURL_NICE;
    if (reps) {
        for (int ri = 0; ri < 4; ri++) {
            if (seen) {
                (*seen)++;
            }
            uint32_t d = reps[ri];
            if (d == 0 || d > pos) {
                continue;
            }
            uint32_t hp = pos - d;
            uint32_t k = match_len(raw + pos, raw + hp, maxk);
            uint32_t minl = (ri == 0) ? 2 : min_len_for_dist(d);
            if (k >= minl && (k > ml || (k == ml && d < dist))) {
                ml = k;
                dist = d;
            }
            if (ml == maxk || ml >= nice) {
                break;
            }
        }
    }
    uint32_t hlen = 0, hdist = 0;
    if (ml < nice) {
        if (pos + 4 <= n && limit4 > 0) {
            lz_walk(raw, pos, ht4[lz_hash4(raw, pos) & hmask], chain4, limit4, maxk, 0xFFFFFFFFu, nice, seen, &hlen, &hdist);
        }
        if (pos + 3 <= n && limit3 > 0 && hlen < nice && hlen < maxk) {
            lz_walk(raw, pos, ht3[lz_hash3(raw, pos) & hmask], chain3, limit3, maxk, 0xFFFFFFFFu, nice, seen, &hlen, &hdist);
        }
        if (pos + 2 <= n && limit2 > 0 && hlen < 8) {
            uint32_t h2 = (uint32_t)raw[pos] | ((uint32_t)raw[pos + 1] << 8);
            lz_walk(raw, pos, ht2[h2], chain2, limit2, maxk, 8192, nice, seen, &hlen, &hdist);
        }
    }
    if (hlen >= 2 && (ml < 2 || hlen > ml + (dist > 0 && dist <= 256 ? 1 : 0))) {
        ml = hlen;
        dist = hdist;
    }
    if (ml > FURL_MAX_MATCH) {
        ml = FURL_MAX_MATCH;
    }
    *best_ml = ml;
    *best_dist = dist;
}

#define PPM_ORDER 5
#define PPM_BITS 18
#define PPM_NSYM 12

typedef struct {
    uint32_t tag;
    uint16_t esc;
    uint8_t n;
    uint8_t sym[PPM_NSYM];
    uint8_t freq[PPM_NSYM];
} PPMNode;

/* Sequential test: encode whether the current item is chosen, with p = freq/rem. */
static int rc_pick(CM *s, uint32_t freq, uint32_t rem, int *chosen) {
    if (rem == 0 || freq == 0) {
        return FURL_ERR_DATA;
    }
    uint32_t p = (uint32_t)(((uint64_t)freq << 16) / rem);
    if (p < 1) {
        p = 1;
    }
    if (p > 65535) {
        p = 65535;
    }
    if (s->encoding) {
        if (enc_bit(s, *chosen, p)) {
            return FURL_ERR_NOMEM;
        }
    } else {
        *chosen = dec_bit(s, p);
    }
    return FURL_OK;
}

static uint32_t ppm_hash(const uint8_t *hist, uint32_t pos, int order, uint32_t mask) {
    uint32_t h = 2166136261u;
    for (int i = 0; i < order; i++) {
        uint8_t b = (pos > (uint32_t)i) ? hist[(pos - 1 - (uint32_t)i) & mask] : 0;
        h ^= b;
        h *= 16777619u;
    }
    h ^= (uint32_t)order * 0x9E3779B1u;
    return h;
}

static int ppm_node_find(PPMNode *n, uint8_t b) {
    for (int i = 0; i < n->n; i++) {
        if (n->sym[i] == b) {
            return i;
        }
    }
    return -1;
}

static void ppm_node_update(PPMNode *n, uint8_t b) {
    int i = ppm_node_find(n, b);
    if (i >= 0) {
        if (n->freq[i] < 250) {
            n->freq[i]++;
        }
        while (i > 0 && n->freq[i] > n->freq[i - 1]) {
            uint8_t ts = n->sym[i];
            uint8_t tf = n->freq[i];
            n->sym[i] = n->sym[i - 1];
            n->freq[i] = n->freq[i - 1];
            n->sym[i - 1] = ts;
            n->freq[i - 1] = tf;
            i--;
        }
        return;
    }
    if (n->n < PPM_NSYM) {
        n->sym[n->n] = b;
        n->freq[n->n] = 1;
        n->n++;
    } else {
        if (n->freq[PPM_NSYM - 1] > 1) {
            n->freq[PPM_NSYM - 1]--;
        } else {
            n->sym[PPM_NSYM - 1] = b;
            n->freq[PPM_NSYM - 1] = 1;
        }
    }
    if (n->esc < 250) {
        n->esc++;
    }
}

static int ppm_code_byte(CM *s, PPMNode *nodes, uint32_t nctx, uint8_t *hist, uint32_t hmask, uint32_t pos, uint8_t *byte) {
    uint32_t excluded[8];
    PPMNode *touched[PPM_ORDER + 2];
    int nt = 0;
    memset(excluded, 0, sizeof(excluded));
    int have_excl = 0;
    for (int order = PPM_ORDER; order >= 0; order--) {
        uint32_t tag = ppm_hash(hist, pos, order, hmask);
        PPMNode *n = (order == 0) ? &nodes[nctx] : &nodes[tag & (nctx - 1)];
        if (order == 0) {
            n->tag = tag;
        } else if (n->tag != tag) {
            n->tag = tag;
            n->n = 0;
            n->esc = 1;
        }
        uint32_t esc_freq = (uint32_t)n->esc + 1;
        uint32_t tot = esc_freq;
        for (int i = 0; i < n->n; i++) {
            uint8_t sy = n->sym[i];
            if (have_excl && (excluded[sy >> 5] & (1u << (sy & 31)))) {
                continue;
            }
            tot += (uint32_t)n->freq[i] + 1;
        }
        uint32_t rem = tot;
        int hit = s->encoding ? 0 : 0;
        if (s->encoding) {
            uint8_t b = *byte;
            int is_esc = 1;
            for (int i = 0; i < n->n; i++) {
                if (!(have_excl && (excluded[n->sym[i] >> 5] & (1u << (n->sym[i] & 31)))) && n->sym[i] == b) {
                    is_esc = 0;
                    break;
                }
            }
            if (rc_pick(s, esc_freq, rem, &is_esc)) {
                return FURL_ERR_NOMEM;
            }
            rem -= esc_freq;
            if (!is_esc) {
                for (int i = 0; i < n->n; i++) {
                    uint8_t sy = n->sym[i];
                    if (have_excl && (excluded[sy >> 5] & (1u << (sy & 31)))) {
                        continue;
                    }
                    uint32_t f = (uint32_t)n->freq[i] + 1;
                    int ch = (sy == b);
                    if (rc_pick(s, f, rem, &ch)) {
                        return FURL_ERR_NOMEM;
                    }
                    if (ch) {
                        ppm_node_update(n, b);
                        for (int t = 0; t < nt; t++) {
                            ppm_node_update(touched[t], b);
                        }
                        return FURL_OK;
                    }
                    rem -= f;
                }
                return FURL_ERR_DATA;
            }
            touched[nt++] = n;
        } else {
            int is_esc = 0;
            if (rc_pick(s, esc_freq, rem, &is_esc)) {
                return FURL_ERR_DATA;
            }
            rem -= esc_freq;
            if (!is_esc) {
                for (int i = 0; i < n->n; i++) {
                    uint8_t sy = n->sym[i];
                    if (have_excl && (excluded[sy >> 5] & (1u << (sy & 31)))) {
                        continue;
                    }
                    uint32_t f = (uint32_t)n->freq[i] + 1;
                    int ch = 0;
                    if (rc_pick(s, f, rem, &ch)) {
                        return FURL_ERR_DATA;
                    }
                    if (ch) {
                        *byte = sy;
                        ppm_node_update(n, sy);
                        for (int t = 0; t < nt; t++) {
                            ppm_node_update(touched[t], sy);
                        }
                        return FURL_OK;
                    }
                    rem -= f;
                }
                return FURL_ERR_DATA;
            }
            touched[nt++] = n;
        }
        (void)hit;
        for (int i = 0; i < n->n; i++) {
            excluded[n->sym[i] >> 5] |= 1u << (n->sym[i] & 31);
        }
        have_excl = 1;
    }
    uint32_t rem = 0;
    for (int b = 0; b < 256; b++) {
        if (!(have_excl && (excluded[b >> 5] & (1u << (b & 31))))) {
            rem++;
        }
    }
    if (rem == 0) {
        /* Every byte value was excluded — treat as raw 8-bit. */
        rem = 256;
        have_excl = 0;
        memset(excluded, 0, sizeof(excluded));
    }
    for (int i = 0; i < 256; i++) {
        if (have_excl && (excluded[i >> 5] & (1u << (i & 31)))) {
            continue;
        }
        int ch = s->encoding ? (*byte == (uint8_t)i) : 0;
        if (rc_pick(s, 1, rem, &ch)) {
            return s->encoding ? FURL_ERR_NOMEM : FURL_ERR_DATA;
        }
        if (ch) {
            if (!s->encoding) {
                *byte = (uint8_t)i;
            }
            for (int t = 0; t < nt; t++) {
                ppm_node_update(touched[t], (uint8_t)i);
            }
            return FURL_OK;
        }
        rem--;
    }
    return FURL_ERR_DATA;
}

static int poll_due(uint32_t pos, uint32_t *next, const FurlOptions *opt, uint64_t base, uint64_t total) {
    if (pos < *next) {
        return FURL_OK;
    }
    *next = pos > UINT32_MAX - 4096u ? UINT32_MAX : pos + 4096u;
    return call_progress(opt, base + (uint64_t)pos, total);
}

static int ppm_block(CM *s, uint8_t *raw, uint32_t n, const FurlOptions *opt, uint64_t base, uint64_t total) {
    uint32_t nctx = 1u << PPM_BITS;
    PPMNode *nodes = (PPMNode *)calloc((size_t)nctx + 1, sizeof(PPMNode));
    if (!nodes) {
        return FURL_ERR_NOMEM;
    }
    nodes[nctx].esc = 1;
    /* order-0: dense via the leftover node, start empty so it learns */
    uint8_t *hist = s->hist;
    uint32_t hmask = s->hist_mask;
    uint32_t next_poll = 0;
    for (uint32_t i = 0; i < n; i++) {
        int pr = poll_due(i, &next_poll, opt, base, total);
        if (pr != FURL_OK) {
            free(nodes);
            return pr;
        }
        uint8_t b = s->encoding ? raw[i] : 0;
        int rc = ppm_code_byte(s, nodes, nctx, hist, hmask, i, &b);
        if (rc != FURL_OK) {
            free(nodes);
            return rc;
        }
        if (!s->encoding) {
            raw[i] = b;
        }
        hist[i & hmask] = b;
    }
    free(nodes);
    return FURL_OK;
}

static double price_bit(uint16_t cell, int bit) {
    int n0 = cell & 255;
    int n1 = cell >> 8;
    int p12 = ((n1 + 1) << 12) / (n0 + n1 + 2);
    if (p12 < 1) {
        p12 = 1;
    }
    if (p12 > 4095) {
        p12 = 4095;
    }
    uint32_t p16 = (uint32_t)p12 << 4;
    uint32_t prob = bit ? p16 : (65536u - p16);
    if (prob < 1) {
        prob = 1;
    }
    if (prob > 65535) {
        prob = 65535;
    }
    return (double)neglog_tab[prob >> 8];
}

static double price_nbits(const uint16_t *map, uint32_t map_mask, uint32_t ctx, uint32_t value, int nbits) {
    double cost = 0;
    for (int i = 0; i < nbits; i++) {
        int b = (int)((value >> i) & 1u);
        cost += price_bit(map[(ctx + (uint32_t)(i * 17)) & map_mask], b);
    }
    return cost;
}

/* Prices use the flag context before the match bit, then the length and
   distance contexts after that bit has been shifted in. Cells are not updated. */
static double price_length_at(const CM *s, uint32_t ml, uint32_t prev_flags, uint32_t c1) {
    uint32_t extra = ml - 2;
    uint32_t ctx = (c1 ^ (prev_flags << 8)) & 511u;
    int shortl = extra < 8;
    double cost = price_bit(s->lenm[ctx], shortl);
    if (shortl) {
        return cost + price_nbits(s->lenm, 1023, 64 + (c1 & 7), extra, 3);
    }
    int med = extra < 72;
    cost += price_bit(s->lenm[512 + (ctx & 255)], med);
    if (med) {
        return cost + price_nbits(s->lenm, 1023, 128, extra - 8, 6);
    }
    uint32_t v = extra - 72;
    if (v > 4095) {
        v = 4095;
    }
    return cost + price_nbits(s->lenm, 1023, 256, v, 12);
}

static double price_dist_at(const CM *s, uint32_t dist, uint32_t prev_flags, uint32_t c1) {
    int idx = rep_index(s->reps, dist);
    int is_rep = idx >= 0;
    double cost = price_bit(s->distm[(prev_flags ^ c1) & 255], is_rep);
    if (is_rep) {
        return cost + price_nbits(s->distm, 1023, 48, (uint32_t)idx, 2);
    }
    uint32_t slot = (uint32_t)ilog2u(dist);
    uint32_t extra = dist - (1u << slot);
    cost += price_nbits(s->distm, 1023, 80 + (c1 & 15), slot, 5);
    if (slot > 0) {
        cost += price_nbits(s->distm, 1023, 200 + slot, extra, (int)slot);
    }
    return cost;
}

static double price_match_at(const CM *s, uint32_t ml, uint32_t dist, uint32_t prev_flags, uint32_t c1) {
    uint32_t fctx = (prev_flags | ((c1 & 0xF0) << 4)) & 511u;
    uint32_t flags_after = ((prev_flags << 1) | 1u) & 255u;
    return price_bit(s->flag[fctx], 1) + price_length_at(s, ml, flags_after, c1) + price_dist_at(s, dist, flags_after, c1);
}

static double lit_unit_at(const CM *s, uint32_t prev_flags, uint32_t c1) {
    double byte = s->lit_cost > 0.5 ? s->lit_cost : 8.0;
    uint32_t fctx = (prev_flags | ((c1 & 0xF0) << 4)) & 511u;
    return price_bit(s->flag[fctx], 0) + byte;
}

static double span_cost(double match_price, uint32_t ml, uint32_t horizon, double unit) {
    double cost = match_price;
    if (horizon > ml) {
        cost += (double)(horizon - ml) * unit;
    }
    return cost;
}

static int collect_reps(const uint8_t *raw, uint32_t pos, uint32_t n, const uint32_t *reps, uint64_t *seen,
                        uint32_t *mls, uint32_t *dists) {
    int nout = 0;
    if (!reps || pos >= n) {
        return 0;
    }
    uint32_t maxk = n - pos;
    if (maxk > FURL_MAX_MATCH) {
        maxk = FURL_MAX_MATCH;
    }
    if (maxk < 2) {
        return 0;
    }
    for (int ri = 0; ri < 4; ri++) {
        uint32_t d = reps[ri];
        if (d == 0 || d > pos) {
            continue;
        }
        int dup = 0;
        for (int j = 0; j < ri; j++) {
            if (reps[j] == d) {
                dup = 1;
                break;
            }
        }
        if (dup) {
            continue;
        }
        if (seen) {
            (*seen)++;
        }
        uint32_t k = match_len(raw + pos, raw + pos - d, maxk);
        uint32_t minl = (ri == 0) ? 2u : min_len_for_dist(d);
        if (k >= minl && k >= 2) {
            mls[nout] = k;
            dists[nout] = d;
            nout++;
        }
    }
    return nout;
}

/* Keep every candidate that costs less than literals. Among those, prefer the
   cheaper span out to the longest survivor. A repeat wins a near tie. */
static void pick_match(CM *s, uint32_t prev_flags, uint32_t c1, uint32_t chain_ml, uint32_t chain_dist,
                       const uint32_t *rml, const uint32_t *rdist, int nrep, int record_reject,
                       uint32_t *out_ml, uint32_t *out_dist, double *out_price) {
    uint32_t cml[5];
    uint32_t cdist[5];
    int nc = 0;
    if (chain_ml >= 2 && rep_index(s->reps, chain_dist) < 0) {
        cml[nc] = chain_ml;
        cdist[nc] = chain_dist;
        nc++;
    }
    for (int i = 0; i < nrep && nc < 5; i++) {
        cml[nc] = rml[i];
        cdist[nc] = rdist[i];
        nc++;
    }
    double unit = lit_unit_at(s, prev_flags, c1);
    double prices[5];
    int keep[5];
    uint32_t horizon = 0;
    for (int i = 0; i < nc; i++) {
        prices[i] = price_match_at(s, cml[i], cdist[i], prev_flags, c1);
        keep[i] = prices[i] < unit * (double)cml[i];
        if (!keep[i] && record_reject && s->tally) {
            s->tally->rejected_matches++;
            s->tally->rejected_bytes += cml[i];
        }
        if (keep[i] && cml[i] > horizon) {
            horizon = cml[i];
        }
    }
    int have = 0;
    double best = 0;
    uint32_t bml = 0, bd = 0;
    for (int i = 0; i < nc; i++) {
        if (!keep[i]) {
            continue;
        }
        double cost = span_cost(prices[i], cml[i], horizon, unit);
        int rep = rep_index(s->reps, cdist[i]) >= 0;
        int better = !have || cost + 0.05 < best;
        if (!better && have && cost <= best + 0.05 && rep && rep_index(s->reps, bd) < 0) {
            better = 1;
        }
        if (better) {
            have = 1;
            best = cost;
            bml = cml[i];
            bd = cdist[i];
            *out_price = prices[i];
        }
    }
    *out_ml = bml;
    *out_dist = bd;
}

/* Density 9 search budget. Shift 0 is the normal chain limit. A few
   kilobytes of full-depth search that gain under ~0.06 match bytes per
   candidate step the shift up, which shortens the chains. Repeat distances
   are still priced in full. A probe restores shift 0 when a long match was
   only visible deeper in the chain. */
typedef struct {
    int shift;
    int low;
    int shallow_windows;
    uint32_t win_pos;
    uint32_t probe_pos;
    uint64_t win_bytes;
    uint64_t win_cand;
} ChainBudget;

static void budget_limits(int shift, int base4, int base3, int *l2, int *l3, int *l4) {
    if (shift <= 0) {
        *l2 = 16;
        *l3 = base3;
        *l4 = base4;
        return;
    }
    if (shift > 3) {
        shift = 3;
    }
    *l4 = base4 >> shift;
    *l3 = base3 >> shift;
    *l2 = 16 >> shift;
    if (*l4 < 16) {
        *l4 = 16;
    }
    if (*l3 < 8) {
        *l3 = 8;
    }
    if (*l2 < 4) {
        *l2 = 4;
    }
}

static void budget_roll(ChainBudget *b, uint32_t pos, uint64_t cand) {
    uint64_t dc = cand >= b->win_cand ? cand - b->win_cand : 0;
    if (b->shift == 0) {
        double prod = dc > 0 ? (double)b->win_bytes / (double)dc : 0.0;
        if (dc >= 32 && prod < 0.06) {
            b->low++;
            if (b->low >= 2) {
                b->shift = 2;
                b->shallow_windows = 0;
                b->probe_pos = pos + 4096u;
            }
        } else {
            b->low = 0;
        }
    } else {
        b->shallow_windows++;
        if (b->shallow_windows >= 4 && b->shift < 3) {
            b->shift++;
            b->shallow_windows = 0;
        }
    }
    b->win_pos = pos;
    b->win_cand = cand;
    b->win_bytes = 0;
}

static void lz_find_budget(const uint8_t *raw, uint32_t pos, uint32_t n,
                           const uint32_t *ht2, const uint32_t *ht3, const uint32_t *ht4,
                           const uint32_t *chain2, const uint32_t *chain3, const uint32_t *chain4,
                           uint32_t hmask, int base3, int base4, uint32_t nice, uint64_t *seen,
                           ChainBudget *bud, uint32_t *out_ml, uint32_t *out_dist) {
    int l2, l3, l4;
    budget_limits(bud->shift, base4, base3, &l2, &l3, &l4);
    uint32_t sml = 0, sd = 0;
    lz_find(raw, pos, n, ht2, ht3, ht4, chain2, chain3, chain4, hmask,
            l2, l3, l4, NULL, nice, seen, &sml, &sd);
    int probe = pos >= bud->probe_pos;
    if (probe) {
        bud->probe_pos = pos + 4096u;
    }
    int deeper = bud->shift;
    if (sml < FURL_NICE && (probe || sml >= 16)) {
        deeper = 0;
    } else if (sml >= 8 && sml < 16 && bud->shift > 1) {
        deeper = bud->shift - 1;
    }
    if (deeper < bud->shift) {
        int d2, d3, d4;
        budget_limits(deeper, base4, base3, &d2, &d3, &d4);
        uint32_t fml = 0, fd = 0;
        lz_find(raw, pos, n, ht2, ht3, ht4, chain2, chain3, chain4, hmask,
                d2, d3, d4, NULL, nice, seen, &fml, &fd);
        if (deeper == 0 && fml >= 64 && fml >= sml + 16) {
            bud->shift = 0;
            bud->low = 0;
            bud->shallow_windows = 0;
        }
        if (fml > sml || (fml == sml && fml >= 2 && fd < sd)) {
            sml = fml;
            sd = fd;
        }
    }
    *out_ml = sml;
    *out_dist = sd;
}

static void note_match(FurlParseStats *t, uint32_t ml, uint32_t dist, int repi) {
    if (!t) {
        return;
    }
    t->matches++;
    t->match_bytes += ml;
    if ((uint64_t)ml > t->longest_match) {
        t->longest_match = ml;
    }
    if (repi >= 0) {
        t->rep_hits++;
        if (repi == 0) {
            t->rep0++;
        } else if (repi == 1) {
            t->rep1++;
        } else if (repi == 2) {
            t->rep2++;
        } else {
            t->rep3++;
        }
    } else if (ml <= 7) {
        t->short_nonrep++;
        t->short_nonrep_bytes += ml;
    }
    if (ml <= 3) {
        t->len_2_3++;
    } else if (ml <= 7) {
        t->len_4_7++;
    } else if (ml <= 15) {
        t->len_8_15++;
    } else if (ml <= 31) {
        t->len_16_31++;
    } else if (ml <= 63) {
        t->len_32_63++;
    } else {
        t->len_64++;
    }
    if (dist <= 256) {
        t->dist_256++;
    } else if (dist <= 4096) {
        t->dist_4k++;
    } else if (dist <= 65536) {
        t->dist_64k++;
    } else if (dist <= 1048576u) {
        t->dist_1m++;
    } else if (dist <= 16777216u) {
        t->dist_16m++;
    } else {
        t->dist_far++;
    }
}

static int compress_block(CM *s, const uint8_t *raw, uint32_t n, int ppm,
                          const FurlOptions *opt, uint64_t base, uint64_t total,
                          FurlParseStats *tally) {
    if (ppm && n >= 8) {
        return ppm_block(s, (uint8_t *)raw, n, opt, base, total);
    }
    if (n < 8) {
        for (uint32_t i = 0; i < n; i++) {
            uint8_t b = raw[i];
            int rc = code_byte(s, &b);
            if (rc != FURL_OK) {
                return rc;
            }
        }
        return FURL_OK;
    }

    uint32_t hbits = 18 + (uint32_t)(s->level / 2);
    if (s->level >= 9) {
        hbits = 23;
    }
    if (hbits > 23) {
        hbits = 23;
    }
    uint32_t hmask = (1u << hbits) - 1u;
    uint32_t *ht3 = (uint32_t *)calloc((size_t)1u << hbits, sizeof(uint32_t));
    uint32_t *ht4 = (uint32_t *)calloc((size_t)1u << hbits, sizeof(uint32_t));
    uint32_t *ht2 = (uint32_t *)calloc(65536, sizeof(uint32_t));
    uint32_t *chain3 = (uint32_t *)malloc((size_t)n * sizeof(uint32_t));
    uint32_t *chain4 = (uint32_t *)malloc((size_t)n * sizeof(uint32_t));
    uint32_t *chain2 = (uint32_t *)malloc((size_t)n * sizeof(uint32_t));
    if (!ht3 || !ht4 || !ht2 || !chain3 || !chain4 || !chain2) {
        free(ht3);
        free(ht4);
        free(ht2);
        free(chain3);
        free(chain4);
        free(chain2);
        return FURL_ERR_NOMEM;
    }
    int limit4 = 16 << (s->level / 3);
    int limit3 = 8 << (s->level / 3);
    if (limit4 > 256) {
        limit4 = 256;
    }
    if (limit3 > 96) {
        limit3 = 96;
    }
    s->chain_limit = 0; /* disable CM match model; LZ owns matching */
    s->tally = (s->level >= 9) ? tally : NULL;
    uint32_t nice = FURL_NICE;
    uint64_t cand = 0;
    uint64_t *seen = s->level >= 9 ? &cand : NULL;
    ChainBudget bud = {0, 0, 0, 0, 4096u, 0, 0};

    uint32_t pos = 0;
    uint32_t next_poll = 0;
    while (pos < n) {
        int pr = poll_due(pos, &next_poll, opt, base, total);
        if (pr != FURL_OK) {
            free(ht3);
            free(ht4);
            free(ht2);
            free(chain3);
            free(chain4);
            free(chain2);
            return pr;
        }
        if (s->level >= 9 && pos >= bud.win_pos + 2048u) {
            budget_roll(&bud, pos, cand);
        }
        uint32_t chain_ml = 0, chain_dist = 0;
        if (s->level < 9 || bud.shift == 0) {
            lz_find(raw, pos, n, ht2, ht3, ht4, chain2, chain3, chain4, hmask,
                    16, limit3, limit4, NULL, nice, seen, &chain_ml, &chain_dist);
        } else {
            lz_find_budget(raw, pos, n, ht2, ht3, ht4, chain2, chain3, chain4, hmask,
                           limit3, limit4, nice, seen, &bud, &chain_ml, &chain_dist);
        }
        uint32_t rml[4], rd[4];
        int nrep = collect_reps(raw, pos, n, s->reps, seen, rml, rd);
        uint32_t dist = 0, ml = 0;
        double mprice = 0;
        pick_match(s, s->prev_flags, s->c1, chain_ml, chain_dist, rml, rd, nrep, 1, &ml, &dist, &mprice);
        if (ml >= 2 && ml < 48 && pos + 3 <= n) {
            uint32_t chain_ml1 = 0, chain_d1 = 0;
            if (s->level < 9 || bud.shift == 0) {
                lz_find(raw, pos + 1, n, ht2, ht3, ht4, chain2, chain3, chain4, hmask,
                        0, limit3 / 2 + 8, (pos + 5 <= n) ? limit4 / 2 + 8 : 0, NULL, nice, seen, &chain_ml1, &chain_d1);
            } else {
                int l2, l3, l4;
                budget_limits(bud.shift, limit4, limit3, &l2, &l3, &l4);
                (void)l2;
                int lazy4 = (pos + 5 <= n) ? l4 / 2 + 2 : 0;
                lz_find(raw, pos + 1, n, ht2, ht3, ht4, chain2, chain3, chain4, hmask,
                        0, l3 / 2 + 2, lazy4, NULL, nice, seen, &chain_ml1, &chain_d1);
                if (chain_ml1 >= 16 && chain_ml1 < FURL_NICE) {
                    uint32_t fml = 0, fd = 0;
                    lz_find(raw, pos + 1, n, ht2, ht3, ht4, chain2, chain3, chain4, hmask,
                            0, limit3 / 2 + 8, (pos + 5 <= n) ? limit4 / 2 + 8 : 0, NULL, nice, seen, &fml, &fd);
                    if (fml > chain_ml1 || (fml == chain_ml1 && fml >= 2 && fd < chain_d1)) {
                        chain_ml1 = fml;
                        chain_d1 = fd;
                    }
                }
            }
            uint32_t rml1[4], rd1[4];
            int nrep1 = collect_reps(raw, pos + 1, n, s->reps, seen, rml1, rd1);
            uint32_t ml1 = 0, d1 = 0;
            double p1 = 0;
            uint32_t flags1 = (s->prev_flags << 1) & 255u;
            pick_match(s, flags1, raw[pos], chain_ml1, chain_d1, rml1, rd1, nrep1, 0, &ml1, &d1, &p1);
            if (ml1 >= 2) {
                double unit = lit_unit_at(s, s->prev_flags, s->c1);
                uint32_t horizon = ml > ml1 + 1 ? ml : ml1 + 1;
                double cost_here = span_cost(mprice, ml, horizon, unit);
                double cost_lazy = unit + span_cost(p1, ml1, horizon - 1, unit);
                if (cost_lazy < cost_here) {
                    ml = 0;
                }
            }
            (void)d1;
        }
        uint32_t fctx = (s->prev_flags | ((s->c1 & 0xF0) << 4)) & 511;
        int is_match = ml >= 2;
        int rc = code_adapt(s, &s->flag[fctx], &is_match);
        if (rc != FURL_OK) {
            free(ht3);
            free(ht4);
            free(ht2);
            free(chain3);
            free(chain4);
            free(chain2);
            return rc;
        }
        s->prev_flags = ((s->prev_flags << 1) | (uint32_t)is_match) & 255;
        if (is_match) {
            int repi = rep_index(s->reps, dist);
            rc = code_length(s, &ml);
            if (rc == FURL_OK) {
                rc = code_dist(s, &dist);
            }
            if (rc != FURL_OK || dist == 0 || dist > pos || pos + ml > n) {
                free(ht3);
                free(ht4);
                free(ht2);
                free(chain3);
                free(chain4);
                free(chain2);
                return rc != FURL_OK ? rc : FURL_ERR_DATA;
            }
            uint32_t end = pos + ml;
            uint32_t match_dist = dist;
            uint32_t start = pos;
            while (pos < end) {
                if (lz_keep_insert(pos, start, end)) {
                    lz_insert(raw, pos, n, ht3, ht4, chain3, chain4, hmask);
                    if (pos + 2 <= n) {
                        uint32_t h2 = (uint32_t)raw[pos] | ((uint32_t)raw[pos + 1] << 8);
                        chain2[pos] = ht2[h2];
                        ht2[h2] = pos + 1;
                    }
                }
                cm_see(s, raw[pos]);
                pos++;
            }
            if (pos < n && match_dist > 0 && match_dist <= pos) {
                s->pred_byte = raw[pos - match_dist];
                s->hist_pos = (pos - match_dist) & s->hist_mask;
                s->mlen = 8;
            }
            if (s->level >= 9) {
                bud.win_bytes += ml;
            }
            note_match(s->tally, ml, dist, repi);
        } else {
            uint8_t b = raw[pos];
            rc = code_byte(s, &b);
            if (rc != FURL_OK) {
                free(ht3);
                free(ht4);
                free(ht2);
                free(chain3);
                free(chain4);
                free(chain2);
                return rc;
            }
            lz_insert(raw, pos, n, ht3, ht4, chain3, chain4, hmask);
            if (pos + 2 <= n) {
                uint32_t h2 = (uint32_t)raw[pos] | ((uint32_t)raw[pos + 1] << 8);
                chain2[pos] = ht2[h2];
                ht2[h2] = pos + 1;
            }
            if (s->tally) {
                s->tally->literals++;
                s->tally->literal_bytes++;
            }
            pos++;
        }
    }
    if (s->tally) {
        s->tally->candidates += cand;
    }
    free(ht3);
    free(ht4);
    free(ht2);
    free(chain3);
    free(chain4);
    free(chain2);
    return FURL_OK;
}

static int decompress_block(CM *s, uint8_t *raw, uint32_t n, int ppm,
                            const FurlOptions *opt, uint64_t base, uint64_t total) {
    if (ppm && n >= 8) {
        return ppm_block(s, raw, n, opt, base, total);
    }
    if (n < 8) {
        for (uint32_t i = 0; i < n; i++) {
            uint8_t b = 0;
            int rc = code_byte(s, &b);
            if (rc != FURL_OK) {
                return rc;
            }
            raw[i] = b;
        }
        return FURL_OK;
    }
    s->chain_limit = 0;

    uint32_t pos = 0;
    uint32_t next_poll = 0;
    while (pos < n) {
        int pr = poll_due(pos, &next_poll, opt, base, total);
        if (pr != FURL_OK) {
            return pr;
        }
        uint32_t fctx = (s->prev_flags | ((s->c1 & 0xF0) << 4)) & 511;
        int is_match = 0;
        int rc = code_adapt(s, &s->flag[fctx], &is_match);
        if (rc != FURL_OK) {
            return rc;
        }
        s->prev_flags = ((s->prev_flags << 1) | (uint32_t)is_match) & 255;
        if (is_match) {
            uint32_t ml = 0, dist = 0;
            rc = code_length(s, &ml);
            if (rc == FURL_OK) {
                rc = code_dist(s, &dist);
            }
            if (rc != FURL_OK) {
                return rc;
            }
            if (ml < 2 || dist == 0 || dist > pos || pos + ml > n) {
                return FURL_ERR_DATA;
            }
            uint32_t match_dist = dist;
            for (uint32_t i = 0; i < ml; i++) {
                uint8_t b = raw[pos - dist];
                raw[pos] = b;
                cm_see(s, b);
                pos++;
            }
            if (pos < n && match_dist > 0 && match_dist <= pos) {
                s->pred_byte = raw[pos - match_dist];
                s->hist_pos = (pos - match_dist) & s->hist_mask;
                s->mlen = 8;
            }
        } else {
            uint8_t b = 0;
            rc = code_byte(s, &b);
            if (rc != FURL_OK) {
                return rc;
            }
            raw[pos] = b;
            pos++;
        }
    }
    return FURL_OK;
}

static int call_progress(const FurlOptions *opt, uint64_t done, uint64_t total) {
    if (opt && opt->progress) {
        if (opt->progress(opt->user, done, total) == 0) {
            return FURL_ERR_CANCEL;
        }
    }
    return FURL_OK;
}

typedef struct {
    const uint8_t *src;
    uint32_t n;
    uint8_t cls;
    int level;
    uint32_t flags;
    uint32_t primary;
    uint8_t *out;
    uint32_t out_n;
    int rc;
    const FurlOptions *opt;
    uint64_t base;
    uint64_t total;
    FurlParseStats stats;
} SegJob;

static void stats_add(FurlParseStats *dst, const FurlParseStats *src) {
    dst->literals += src->literals;
    dst->matches += src->matches;
    dst->literal_bytes += src->literal_bytes;
    dst->match_bytes += src->match_bytes;
    if (src->longest_match > dst->longest_match) {
        dst->longest_match = src->longest_match;
    }
    dst->rep_hits += src->rep_hits;
    dst->candidates += src->candidates;
    dst->predicted_bits += src->predicted_bits;
    dst->coded_bits += src->coded_bits;
    dst->raw_bytes += src->raw_bytes;
    dst->ppm_bytes += src->ppm_bytes;
    dst->lz_bytes += src->lz_bytes;
    dst->long_bytes += src->long_bytes;
    dst->e8_blocks += src->e8_blocks;
    dst->delta_blocks += src->delta_blocks;
    dst->len_2_3 += src->len_2_3;
    dst->len_4_7 += src->len_4_7;
    dst->len_8_15 += src->len_8_15;
    dst->len_16_31 += src->len_16_31;
    dst->len_32_63 += src->len_32_63;
    dst->len_64 += src->len_64;
    dst->dist_256 += src->dist_256;
    dst->dist_4k += src->dist_4k;
    dst->dist_64k += src->dist_64k;
    dst->dist_1m += src->dist_1m;
    dst->dist_16m += src->dist_16m;
    dst->dist_far += src->dist_far;
    dst->rep0 += src->rep0;
    dst->rep1 += src->rep1;
    dst->rep2 += src->rep2;
    dst->rep3 += src->rep3;
    dst->short_nonrep += src->short_nonrep;
    dst->short_nonrep_bytes += src->short_nonrep_bytes;
    dst->rejected_matches += src->rejected_matches;
    dst->rejected_bytes += src->rejected_bytes;
}

/* Cheap sample of a large block. Level is capped so the probe does not
   rebuild a density-9 hash table. The coded size includes the store fallback
   the real encoder uses when a trial expands. */
static int trial_coded(const uint8_t *src, uint32_t n, int level, int ppm, int delta, int do_e8, uint32_t *out_size) {
    uint8_t *work = (uint8_t *)malloc(n);
    if (!work) {
        return FURL_ERR_NOMEM;
    }
    memcpy(work, src, n);
    if (!ppm && delta > 0) {
        delta_fwd(work, n, delta);
    }
    if (!ppm && do_e8) {
        e8_fwd(work, n);
    }
    CM cm;
    int rc = cm_init(&cm, 1, level, NULL, 0);
    if (rc != FURL_OK) {
        free(work);
        return rc;
    }
    uint8_t *p = (uint8_t *)malloc((size_t)n + 256);
    if (!p) {
        cm_free(&cm);
        free(work);
        return FURL_ERR_NOMEM;
    }
    cm.out = p;
    cm.out_cap = (size_t)n + 256;
    rc = compress_block(&cm, work, n, ppm && n >= 8, NULL, 0, 0, NULL);
    if (rc == FURL_OK) {
        rc = enc_flush(&cm) ? FURL_ERR_NOMEM : FURL_OK;
    }
    free(work);
    if (rc != FURL_OK) {
        cm_free(&cm);
        free(cm.out);
        return rc;
    }
    if (cm.out_len > (size_t)n + 64) {
        *out_size = n;
    } else {
        *out_size = (uint32_t)cm.out_len;
    }
    cm_free(&cm);
    free(cm.out);
    return FURL_OK;
}

/* After move-to-front, zeros come in long runs and the other ranks are a
   small alphabet. A run of z zeros is the bzip2 bit loop (RUNA=0, RUNB=1):
   zPend = z-1; emit zPend's low bit, then (zPend-2)/2, until zPend < 2.
   A nonzero rank r is symbol r+1. The symbol count is stored in front of
   the arithmetic bytes so a trailing run has a known length. */
#define ZR_ALPH 257
#define ZR_RESCALE 16384u

typedef struct {
    uint32_t fw[ZR_ALPH + 1];
    uint32_t tot;
} ZRModel;

static void zr_add(ZRModel *m, int sym, uint32_t d) {
    m->tot += d;
    uint32_t i = (uint32_t)sym + 1u;
    while (i <= ZR_ALPH) {
        m->fw[i] += d;
        i += i & -i;
    }
}

static uint32_t zr_sum(const ZRModel *m, uint32_t n) {
    uint32_t s = 0;
    while (n) {
        s += m->fw[n];
        n &= n - 1u;
    }
    return s;
}

static void zr_init(ZRModel *m) {
    memset(m, 0, sizeof(*m));
    for (int i = 0; i < ZR_ALPH; i++) {
        zr_add(m, i, 1);
    }
}

static void zr_rescale(ZRModel *m) {
    uint32_t f[ZR_ALPH];
    uint32_t prev = 0;
    for (int i = 0; i < ZR_ALPH; i++) {
        uint32_t c = zr_sum(m, (uint32_t)i + 1u);
        f[i] = c - prev;
        prev = c;
    }
    memset(m, 0, sizeof(*m));
    for (int i = 0; i < ZR_ALPH; i++) {
        uint32_t v = (f[i] + 1u) >> 1;
        if (v < 1u) {
            v = 1u;
        }
        zr_add(m, i, v);
    }
}

static int zr_enc_sym(CM *s, ZRModel *m, int sym) {
    int lo = 0;
    int hi = ZR_ALPH;
    while (hi - lo > 1) {
        int mid = (lo + hi) >> 1;
        uint32_t left = zr_sum(m, (uint32_t)mid) - zr_sum(m, (uint32_t)lo);
        uint32_t right = zr_sum(m, (uint32_t)hi) - zr_sum(m, (uint32_t)mid);
        uint32_t tot = left + right;
        if (tot == 0) {
            return -1;
        }
        uint32_t p = (uint32_t)(((uint64_t)left << 16) / tot);
        if (p < 1u) {
            p = 1u;
        }
        if (p > 65535u) {
            p = 65535u;
        }
        int bit = sym < mid;
        if (enc_bit(s, bit, p)) {
            return -1;
        }
        if (bit) {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    zr_add(m, sym, 1);
    if (m->tot >= ZR_RESCALE) {
        zr_rescale(m);
    }
    return 0;
}

static int zr_dec_sym(CM *s, ZRModel *m) {
    int lo = 0;
    int hi = ZR_ALPH;
    while (hi - lo > 1) {
        int mid = (lo + hi) >> 1;
        uint32_t left = zr_sum(m, (uint32_t)mid) - zr_sum(m, (uint32_t)lo);
        uint32_t right = zr_sum(m, (uint32_t)hi) - zr_sum(m, (uint32_t)mid);
        uint32_t tot = left + right;
        if (tot == 0) {
            return -1;
        }
        uint32_t p = (uint32_t)(((uint64_t)left << 16) / tot);
        if (p < 1u) {
            p = 1u;
        }
        if (p > 65535u) {
            p = 65535u;
        }
        int bit = dec_bit(s, p);
        if (bit) {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    zr_add(m, lo, 1);
    if (m->tot >= ZR_RESCALE) {
        zr_rescale(m);
    }
    return lo;
}

static int zrle_encode(const uint8_t *mtf, uint32_t n, uint8_t **out, uint32_t *out_n,
                       const FurlOptions *opt, uint64_t base, uint64_t total) {
    *out = NULL;
    *out_n = 0;
    CM cm;
    cm_range_init(&cm, 1, NULL, 0);
    size_t guess = (size_t)n / 4u + 256u;
    cm.out = (uint8_t *)malloc(guess);
    if (!cm.out) {
        return FURL_ERR_NOMEM;
    }
    cm.out_cap = guess;
    ZRModel model;
    zr_init(&model);
    uint32_t nsym = 0;
    uint32_t i = 0;
    uint32_t next_poll = 0;
    while (i < n) {
        int pr = poll_due(i, &next_poll, opt, base, total);
        if (pr != FURL_OK) {
            free(cm.out);
            return pr;
        }
        if (mtf[i] == 0) {
            uint32_t z = 0;
            while (i < n && mtf[i] == 0) {
                z++;
                i++;
            }
            uint32_t zpend = z - 1u;
            for (;;) {
                int sym = (zpend & 1u) ? 1 : 0;
                if (zr_enc_sym(&cm, &model, sym)) {
                    free(cm.out);
                    return FURL_ERR_NOMEM;
                }
                nsym++;
                if (zpend < 2u) {
                    break;
                }
                zpend = (zpend - 2u) / 2u;
            }
        } else {
            if (zr_enc_sym(&cm, &model, (int)mtf[i] + 1)) {
                free(cm.out);
                return FURL_ERR_NOMEM;
            }
            nsym++;
            i++;
        }
    }
    if (enc_flush(&cm)) {
        free(cm.out);
        return FURL_ERR_NOMEM;
    }
    if (cm.out_len > UINT32_MAX - 4u) {
        free(cm.out);
        return FURL_ERR_NOMEM;
    }
    uint8_t *p = (uint8_t *)realloc(cm.out, cm.out_len + 4u);
    if (!p) {
        free(cm.out);
        return FURL_ERR_NOMEM;
    }
    memmove(p + 4, p, cm.out_len);
    wr32(p, nsym);
    *out = p;
    *out_n = (uint32_t)cm.out_len + 4u;
    return FURL_OK;
}

static int zrle_decode(CM *s, uint8_t *mtf, uint32_t n, uint32_t nsym,
                       const FurlOptions *opt, uint64_t base, uint64_t total) {
    if (nsym > n) {
        return FURL_ERR_DATA;
    }
    ZRModel model;
    zr_init(&model);
    uint32_t pos = 0;
    int have = 0;
    uint32_t zpend = 0;
    uint32_t add = 1;
    for (uint32_t k = 0; k < nsym; k++) {
        if ((k & 4095u) == 0) {
            int pr = call_progress(opt, base + (uint64_t)pos, total);
            if (pr != FURL_OK) {
                return pr;
            }
        }
        int sym = zr_dec_sym(s, &model);
        if (sym < 0 || sym >= ZR_ALPH) {
            return FURL_ERR_DATA;
        }
        if (sym <= 1) {
            if (!have) {
                zpend = (uint32_t)sym;
                add = 2;
                have = 1;
            } else {
                if (add > n) {
                    return FURL_ERR_DATA;
                }
                uint64_t nz = (uint64_t)zpend + ((uint64_t)sym + 1ull) * (uint64_t)add;
                if (nz > n) {
                    return FURL_ERR_DATA;
                }
                zpend = (uint32_t)nz;
                if (add > 0x7FFFFFFFu) {
                    return FURL_ERR_DATA;
                }
                add *= 2u;
            }
        } else {
            if (have) {
                uint32_t z = zpend + 1u;
                if ((uint64_t)pos + z > n) {
                    return FURL_ERR_DATA;
                }
                memset(mtf + pos, 0, z);
                pos += z;
                have = 0;
            }
            if (pos >= n) {
                return FURL_ERR_DATA;
            }
            mtf[pos++] = (uint8_t)(sym - 1);
        }
    }
    if (have) {
        uint32_t z = zpend + 1u;
        if ((uint64_t)pos + z > n) {
            return FURL_ERR_DATA;
        }
        memset(mtf + pos, 0, z);
        pos += z;
    }
    if (pos != n) {
        return FURL_ERR_DATA;
    }
    return FURL_OK;
}

/* The trial is the coder the block will use: Burrows-Wheeler, move-to-front,
   zero-runs, order-0. Level is unused; the model does not grow with density. */
static int trial_bwt_ppm(const uint8_t *src, uint32_t n, int level, uint32_t *out_size) {
    (void)level;
    uint8_t *sorted = (uint8_t *)malloc(n);
    uint8_t *work = (uint8_t *)malloc(n);
    if (!sorted || !work) {
        free(sorted);
        free(work);
        return FURL_ERR_NOMEM;
    }
    uint32_t primary = 0;
    if (furl_bwt(src, n, sorted, &primary) != 0) {
        free(sorted);
        free(work);
        *out_size = n;
        return FURL_OK;
    }
    memcpy(work, sorted, n);
    free(sorted);
    mtf_fwd(work, n);
    uint8_t *coded = NULL;
    uint32_t cn = 0;
    int rc = zrle_encode(work, n, &coded, &cn, NULL, 0, 0);
    free(work);
    if (rc != FURL_OK) {
        free(coded);
        return rc;
    }
    if (cn > n + 64u) {
        *out_size = n;
    } else {
        *out_size = cn;
    }
    free(coded);
    return FURL_OK;
}

static int clearly_smaller(uint32_t smaller, uint32_t larger, unsigned pct) {
    return (uint64_t)smaller * 100ull < (uint64_t)larger * (uint64_t)pct;
}

static int trial_slice(const uint8_t *b, uint32_t n, int index, const uint8_t **ptr, uint32_t *len) {
    const uint32_t span = 32u * 1024u;
    if (n < span * 2u) {
        if (index > 0) {
            return 0;
        }
        *ptr = b;
        *len = n < 64u * 1024u ? n : 64u * 1024u;
        return 1;
    }
    if (index > 2) {
        return 0;
    }
    uint32_t off = 0;
    if (index == 1) {
        off = n / 2u - span / 2u;
    } else if (index == 2) {
        off = n - span;
    }
    *ptr = b + off;
    *len = span;
    return 1;
}

/* Back off a heuristic when every sample says another existing strategy is
   clearly cheaper. A sample never promotes a block to stored bytes: that
   still happens only after the real encode expands. */
static void revise_strategy(const uint8_t *b, uint32_t n, int level, int *use_ppm, int *delta, int *do_e8) {
    if (n < 128u * 1024u) {
        return;
    }
    int trial_level = level > 4 ? 4 : level;
    if (trial_level < 1) {
        trial_level = 1;
    }
    int saw = 0;
    int lz_beats_ppm = *use_ppm ? 1 : 0;
    int plain_beats_filter = (!*use_ppm && (*delta || *do_e8)) ? 1 : 0;
    int ppm_beats_lz = (!*use_ppm) ? 1 : 0;
    for (int i = 0; i < 3; i++) {
        const uint8_t *slice = NULL;
        uint32_t sl = 0;
        if (!trial_slice(b, n, i, &slice, &sl)) {
            break;
        }
        uint32_t plain = 0, current = 0, ppm = 0;
        if (trial_coded(slice, sl, trial_level, 0, 0, 0, &plain) != FURL_OK) {
            return;
        }
        if (*use_ppm) {
            if (trial_coded(slice, sl, trial_level, 1, 0, 0, &current) != FURL_OK) {
                current = sl;
            }
            if (!clearly_smaller(plain, current, 85)) {
                lz_beats_ppm = 0;
            }
        } else {
            if (trial_coded(slice, sl, trial_level, 0, *delta, *do_e8, &current) != FURL_OK) {
                return;
            }
            if (*delta || *do_e8) {
                if (!clearly_smaller(plain, current, 96)) {
                    plain_beats_filter = 0;
                }
            }
            if (ppm_beats_lz && text_window(slice, sl)) {
                if (trial_coded(slice, sl, trial_level, 1, 0, 0, &ppm) != FURL_OK) {
                    ppm_beats_lz = 0;
                } else if (!clearly_smaller(ppm, plain, 92)) {
                    ppm_beats_lz = 0;
                }
            } else {
                ppm_beats_lz = 0;
            }
        }
        saw++;
    }
    if (saw == 0) {
        return;
    }
    if (*use_ppm && lz_beats_ppm) {
        *use_ppm = 0;
        *delta = 0;
        *do_e8 = 0;
        return;
    }
    if (ppm_beats_lz && looks_text(b, n)) {
        *use_ppm = 1;
        *delta = 0;
        *do_e8 = 0;
        return;
    }
    if (plain_beats_filter) {
        *delta = 0;
        *do_e8 = 0;
    }
}

/* A packed run is worth parsing when some 256-byte string occurs twice.
   Samples are taken where the hash says so, not on a fixed stride: two
   copies of a file almost never sit a multiple of the stride apart.
   A shared header is shorter than this and stays stored. */
static int raw_has_long_copy(const uint8_t *b, uint32_t n) {
    const uint32_t need = 256u;
    if (n < need * 2u) {
        return 0;
    }
    enum { SAMPLE = 64, SLOTS = 1 << 20 };
    uint32_t *ht = (uint32_t *)calloc(SLOTS, sizeof(uint32_t));
    if (!ht) {
        /* Keep the parse. Storing here would hide a later copy of the same bytes. */
        return 1;
    }
    int found = 0;
    for (uint32_t i = 0; i + need <= n; i++) {
        uint64_t v = load64(b + i);
        uint32_t h = (uint32_t)(v ^ (v >> 32)) * 0x9E3779B1u;
        if (h & (SAMPLE - 1u)) {
            continue;
        }
        uint32_t slot = (h >> 6) & (SLOTS - 1u);
        uint32_t prev = ht[slot];
        if (prev) {
            uint32_t hp = prev - 1u;
            if (hp < i && load64(b + hp) == v && match_len(b + i, b + hp, need) >= need) {
                found = 1;
                break;
            }
        }
        ht[slot] = i + 1u;
    }
    free(ht);
    return found;
}

static int encode_segment(SegJob *j) {
    j->flags = 0;
    j->primary = 0;
    j->out = NULL;
    j->out_n = 0;
    j->rc = FURL_OK;
    int pr = call_progress(j->opt, j->base, j->total);
    if (pr != FURL_OK) {
        j->rc = pr;
        return pr;
    }
    uint32_t n = j->n;
    int from_raw = 0;
    if (j->cls == CLS_RAW && !raw_has_long_copy(j->src, n)) {
        j->flags = BLK_RAW;
        j->out_n = n;
        j->stats.raw_bytes += n;
        return FURL_OK;
    }
    if (j->cls == CLS_RAW) {
        j->cls = CLS_LZ;
        from_raw = 1;
    }

    uint8_t *work = (uint8_t *)malloc(n);
    if (!work) {
        j->rc = FURL_ERR_NOMEM;
        return j->rc;
    }
    memcpy(work, j->src, n);
    uint32_t flags = 0;
    uint32_t primary = 0;
    uint8_t *bwt = NULL;
    int want_bwt = (j->cls == CLS_BWT && n >= 256);
    int use_ppm = ((j->cls == CLS_TEXT || want_bwt) && n >= 8);
    int delta = 0;
    int do_e8 = 0;
    if (!use_ppm && j->cls == CLS_LZ) {
        delta = choose_delta(work, n);
        if (!looks_text(work, n) && count_e8(work, n) >= 24) {
            do_e8 = 1;
        }
    }
    if (!want_bwt) {
        revise_strategy(j->src, n, j->level, &use_ppm, &delta, &do_e8);
    }
    if (!use_ppm && delta) {
        delta_fwd(work, n, delta);
        flags |= BLK_DELTA | ((uint32_t)delta << 8);
    }
    if (!use_ppm && do_e8) {
        e8_fwd(work, n);
        flags |= BLK_E8;
    }
    const uint8_t *payload = work;
    uint32_t payload_n = n;
    int bwt_ok = 0;
    if ((want_bwt || (use_bwt_for(j->level) && use_ppm)) && n >= 256) {
        bwt = (uint8_t *)malloc(n);
        if (bwt && furl_bwt(work, n, bwt, &primary) == 0) {
            mtf_fwd(bwt, n);
            flags |= BLK_BWT | BLK_MTF | BLK_ZRLE;
            uint8_t *coded = NULL;
            uint32_t cn = 0;
            int zrc = zrle_encode(bwt, n, &coded, &cn, j->opt, j->base, j->total);
            free(work);
            free(bwt);
            if (zrc != FURL_OK) {
                free(coded);
                j->rc = zrc;
                return zrc;
            }
            /* Same slack as the other coders. A block that grows is stored. */
            if (cn > n + 64u) {
                free(coded);
                memset(&j->stats, 0, sizeof(j->stats));
                j->stats.raw_bytes = n;
                j->flags = BLK_RAW;
                j->primary = 0;
                j->out = NULL;
                j->out_n = n;
                j->rc = FURL_OK;
                return FURL_OK;
            }
            j->stats.ppm_bytes += n;
            j->flags = flags;
            j->primary = primary;
            j->out = coded;
            j->out_n = cn;
            j->rc = FURL_OK;
            return FURL_OK;
        }
        free(bwt);
        bwt = NULL;
    }
    if (!bwt_ok && use_ppm) {
        flags |= BLK_PPM;
    }

    CM cm;
    int rc = cm_init(&cm, 1, j->level, NULL, 0);
    if (rc != FURL_OK) {
        free(work);
        free(bwt);
        j->rc = rc;
        return rc;
    }
    {
        size_t guess = (size_t)n + 256;
        uint8_t *p = (uint8_t *)malloc(guess);
        if (p) {
            cm.out = p;
            cm.out_cap = guess;
        }
    }
    use_ppm = (flags & BLK_PPM) != 0;
    FurlParseStats *tally = j->level >= 9 ? &j->stats : NULL;
    rc = compress_block(&cm, payload, payload_n, use_ppm, j->opt, j->base, j->total, use_ppm ? NULL : tally);
    if (rc == FURL_OK) {
        rc = enc_flush(&cm) ? FURL_ERR_NOMEM : FURL_OK;
    }
    if (rc != FURL_OK && rc != FURL_ERR_CANCEL && use_ppm) {
        cm_free(&cm);
        free(cm.out);
        flags &= ~(uint32_t)BLK_PPM;
        use_ppm = 0;
        rc = cm_init(&cm, 1, j->level, NULL, 0);
        if (rc == FURL_OK) {
            rc = compress_block(&cm, payload, payload_n, 0, j->opt, j->base, j->total, tally);
            if (rc == FURL_OK) {
                rc = enc_flush(&cm) ? FURL_ERR_NOMEM : FURL_OK;
            }
        }
    }
    free(work);
    free(bwt);
    if (rc != FURL_OK) {
        cm_free(&cm);
        free(cm.out);
        j->rc = rc;
        return rc;
    }
    /* A packed run was going to be stored. Keep the parse only when it
       is actually smaller. Other blocks still allow a few bytes of slack. */
    uint32_t slack = from_raw ? 0u : 64u;
    if (cm.out_len > (size_t)n + slack) {
        cm_free(&cm);
        free(cm.out);
        memset(&j->stats, 0, sizeof(j->stats));
        j->stats.raw_bytes = n;
        j->flags = BLK_RAW;
        j->primary = 0;
        j->out = NULL;
        j->out_n = n;
        j->rc = FURL_OK;
        return FURL_OK;
    }
    if (flags & BLK_PPM) {
        j->stats.ppm_bytes += n;
    } else {
        j->stats.lz_bytes += n;
        if (j->level >= 9) {
            j->stats.coded_bits += (uint64_t)cm.out_len * 8ull;
        }
    }
    if (flags & BLK_E8) {
        j->stats.e8_blocks++;
    }
    if (flags & BLK_DELTA) {
        j->stats.delta_blocks++;
    }
    j->flags = flags;
    j->primary = primary;
    j->out = cm.out;
    j->out_n = (uint32_t)cm.out_len;
    cm.out = NULL;
    cm_free(&cm);
    j->rc = FURL_OK;
    return FURL_OK;
}

static int emit_stored(uint8_t **buf, size_t *cap, size_t *len, uint32_t n, uint32_t flags,
                       uint32_t primary, const uint8_t *payload, uint32_t payload_n) {
    size_t need = *len + 16 + payload_n;
    if (need > *cap) {
        size_t nc = *cap * 2;
        while (nc < need) {
            nc *= 2;
        }
        uint8_t *nb = (uint8_t *)realloc(*buf, nc);
        if (!nb) {
            return FURL_ERR_NOMEM;
        }
        *buf = nb;
        *cap = nc;
    }
    wr32(*buf + *len + 0, n);
    wr32(*buf + *len + 4, flags);
    wr32(*buf + *len + 8, primary);
    wr32(*buf + *len + 12, payload_n);
    memcpy(*buf + *len + 16, payload, payload_n);
    *len += 16 + payload_n;
    return FURL_OK;
}

/* A run at the start or end of a large LZ block that is already near 8 bits
   per byte, and that has almost no matches, can be stored. An island in the
   middle stays in the block: storing it would split the block, and a match
   could no longer cross it. A copy that reaches the rest of the block keeps
   the run on LZ, so the first copy of a repeated payload is not stored away
   from the second. */
static uint32_t window_match_bytes(const uint8_t *b, uint32_t n, uint32_t from, uint32_t to,
                                   uint32_t *ht, uint32_t slots) {
    uint32_t covered = 0;
    uint32_t i = from;
    while (i + 4 <= to && i + 4 <= n) {
        uint32_t v4 = (uint32_t)b[i] | ((uint32_t)b[i + 1] << 8) | ((uint32_t)b[i + 2] << 16) |
                      ((uint32_t)b[i + 3] << 24);
        uint32_t slot = (v4 * 0x9E3779B1u) & (slots - 1u);
        uint32_t prev = ht[slot];
        uint32_t step = 1;
        if (prev) {
            uint32_t hp = prev - 1u;
            if (hp < i && memcmp(b + hp, b + i, 4) == 0) {
                uint32_t maxk = n - i;
                if (maxk > 4096u) {
                    maxk = 4096u;
                }
                uint32_t k = match_len(b + i, b + hp, maxk);
                if (k >= 4u) {
                    uint32_t add = k;
                    if (i + add > to) {
                        add = to - i;
                    }
                    covered += add;
                    step = k;
                }
            }
        }
        ht[slot] = i + 1u;
        if (step > 1u) {
            uint32_t end = i + step;
            if (end > to) {
                end = to;
            }
            for (uint32_t j = i + 4; j + 4 <= end; j += 4) {
                uint32_t u = (uint32_t)b[j] | ((uint32_t)b[j + 1] << 8) | ((uint32_t)b[j + 2] << 16) |
                             ((uint32_t)b[j + 3] << 24);
                ht[(u * 0x9E3779B1u) & (slots - 1u)] = j + 1u;
            }
        }
        i += step;
    }
    return covered;
}

static int region_echoes(const uint8_t *b, uint32_t n, uint32_t off, uint32_t len) {
    /* 32 bytes is a real copy. Sampled probes miss a copy that short,
       and that copy is often what makes the stretch worth parsing. */
    const uint32_t need = 32u;
    if (len < need || n < need * 2u) {
        return 0;
    }
    enum { SLOTS = 1 << 22 };
    uint32_t *ht = (uint32_t *)calloc(SLOTS, sizeof(uint32_t));
    if (!ht) {
        return 1;
    }
    int echoed = 0;
    uint32_t end = off + len;
    for (uint32_t i = 0; i + need <= n; i++) {
        uint64_t v = load64(b + i);
        uint32_t slot = ((uint32_t)(v ^ (v >> 32)) * 0x9E3779B1u) & (SLOTS - 1u);
        uint32_t prev = ht[slot];
        if (prev) {
            uint32_t hp = prev - 1u;
            if (hp < i && load64(b + hp) == v && match_len(b + i, b + hp, need) >= need) {
                int in1 = hp >= off && hp < end;
                int in2 = i >= off && i < end;
                if (in1 != in2) {
                    echoed = 1;
                    break;
                }
            }
        }
        ht[slot] = i + 1u;
    }
    free(ht);
    return echoed;
}

static int carve_incompressible(const uint8_t *in, FurlSeg **psegs, uint32_t *pn) {
    FurlSeg *segs = *psegs;
    uint32_t ns = *pn;
    if (!segs || ns == 0) {
        return FURL_OK;
    }
    const uint32_t win = 64u * 1024u;
    const uint32_t slots = 1u << 20;
    uint32_t extra = 0;
    for (uint32_t i = 0; i < ns; i++) {
        if (segs[i].cls == CLS_LZ && segs[i].n >= 256u * 1024u) {
            extra += segs[i].n / win + 2u;
        }
    }
    if (extra == 0) {
        return FURL_OK;
    }
    size_t cap = (size_t)ns + (size_t)extra;
    FurlSeg *out = (FurlSeg *)malloc(cap * sizeof(FurlSeg));
    uint32_t *ht = (uint32_t *)malloc((size_t)slots * sizeof(uint32_t));
    if (!out || !ht) {
        free(out);
        free(ht);
        return FURL_OK; /* keep the original plan */
    }
    uint32_t no = 0;
    for (uint32_t s = 0; s < ns; s++) {
        if (segs[s].cls != CLS_LZ || segs[s].n < 256u * 1024u) {
            if (no >= cap) {
                free(ht);
                free(out);
                return FURL_OK; /* keep the original plan */
            }
            out[no++] = segs[s];
            continue;
        }
        const uint8_t *b = in + segs[s].off;
        uint32_t n = segs[s].n;
        uint32_t nw = (n + win - 1u) / win;
        uint8_t *mark = (uint8_t *)calloc(nw, 1);
        if (!mark) {
            if (no >= cap) {
                free(ht);
                free(out);
                return FURL_OK; /* keep the original plan */
            }
            out[no++] = segs[s];
            continue;
        }
        memset(ht, 0, (size_t)slots * sizeof(uint32_t));
        uint32_t pos = 0;
        for (uint32_t w = 0; w < nw; w++) {
            uint32_t wlen = win;
            if (pos + wlen > n) {
                wlen = n - pos;
            }
            if (wlen < 32u * 1024u) {
                mark[w] = w > 0 ? mark[w - 1] : 0;
            } else {
                uint32_t covered = window_match_bytes(b, n, pos, pos + wlen, ht, slots);
                double e = byte_entropy_bits(b + pos, wlen);
                if (covered * 50u < wlen && e >= 7.80) {
                    mark[w] = 1;
                }
            }
            pos += wlen;
        }
        pos = 0;
        for (uint32_t w = 0; w < nw;) {
            uint32_t w2 = w;
            uint32_t end = pos;
            uint8_t dead = mark[w];
            while (w2 < nw && mark[w2] == dead) {
                uint32_t wlen = win;
                if (end + wlen > n) {
                    wlen = n - end;
                }
                end += wlen;
                w2++;
            }
            uint32_t len = end - pos;
            /* Only an edge. An interior store would split this block in two. */
            int at_edge = (pos == 0u) || (end == n);
            int use_raw = dead && at_edge && len >= FURL_MIN_RAW && !region_echoes(b, n, pos, len);
            size_t abs = segs[s].off + pos;
            /* Only join pieces of this segment. Joining across the block
               cap would rebuild a block larger than the matcher allows. */
            if (!use_raw && no > 0 && out[no - 1].cls == CLS_LZ && out[no - 1].off >= segs[s].off &&
                out[no - 1].off + out[no - 1].n == abs) {
                out[no - 1].n += len;
            } else {
                if (no >= cap) {
                    free(mark);
                    free(ht);
                    free(out);
                    return FURL_OK; /* keep the original plan */
                }
                out[no].off = abs;
                out[no].n = len;
                out[no].cls = use_raw ? (uint8_t)CLS_RAW : (uint8_t)CLS_LZ;
                no++;
            }
            pos = end;
            w = w2;
        }
        free(mark);
    }
    free(ht);
    free(segs);
    *psegs = out;
    *pn = no;
    return FURL_OK;
}

#define FURL_BWT_CHUNK (1u << 20)
#define FURL_BWT_TRY (256u * 1024u)
#define FURL_BWT_SAMPLE (128u * 1024u)

static int bwt_beats_ppm(const uint8_t *b, uint32_t n, int level) {
    if (n < 32u * 1024u) {
        return 0;
    }
    uint32_t sl = n < FURL_BWT_SAMPLE ? n : FURL_BWT_SAMPLE;
    uint32_t off = n > sl ? (n - sl) / 2u : 0u;
    int trial_level = level > 4 ? 4 : level;
    if (trial_level < 1) {
        trial_level = 1;
    }
    uint32_t ppm = 0, bw = 0;
    if (trial_coded(b + off, sl, trial_level, 1, 0, 0, &ppm) != FURL_OK) {
        return 0;
    }
    if (trial_bwt_ppm(b + off, sl, trial_level, &bw) != FURL_OK) {
        return 0;
    }
    return clearly_smaller(bw, ppm, 85);
}

/* Cut a long text run into 1 MiB pieces and keep the Burrows-Wheeler coder
   only on pieces where a sample is clearly smaller than order-5 PPM.
   Pieces that stay on PPM are joined back together, so prose keeps one model. */
static int split_record_text(const uint8_t *in, FurlSeg **psegs, uint32_t *pn, int level, const FurlOptions *opt, uint64_t total) {
    FurlSeg *segs = *psegs;
    uint32_t n = *pn;
    int any = 0;
    uint32_t cap = n + 8u;
    for (uint32_t i = 0; i < n; i++) {
        if (segs[i].cls == CLS_TEXT && segs[i].n >= FURL_BWT_TRY) {
            any = 1;
            uint32_t extra = segs[i].n / FURL_BWT_CHUNK + 2u;
            if (cap > UINT32_MAX - extra) {
                return FURL_OK;
            }
            cap += extra;
        }
    }
    if (!any) {
        return FURL_OK;
    }
    FurlSeg *out = (FurlSeg *)malloc((size_t)cap * sizeof(FurlSeg));
    if (!out) {
        return FURL_OK;
    }
    uint32_t no = 0;
    for (uint32_t s = 0; s < n; s++) {
        if (segs[s].cls != CLS_TEXT || segs[s].n < FURL_BWT_TRY) {
            if (no >= cap) {
                free(out);
                return FURL_OK;
            }
            out[no++] = segs[s];
            continue;
        }
        uint32_t pos = 0;
        int fresh = 1;
        while (pos < segs[s].n) {
            int pr = call_progress(opt, (uint64_t)segs[s].off + pos, total);
            if (pr != FURL_OK) {
                free(out);
                return pr;
            }
            uint32_t take = segs[s].n - pos;
            if (take > FURL_BWT_CHUNK) {
                take = FURL_BWT_CHUNK;
            }
            int use_bwt = bwt_beats_ppm(in + segs[s].off + pos, take, level);
            if (!use_bwt && !fresh && no > 0 && out[no - 1].cls == CLS_TEXT) {
                out[no - 1].n += take;
            } else {
                if (no >= cap) {
                    free(out);
                    return FURL_OK;
                }
                out[no].off = segs[s].off + pos;
                out[no].n = take;
                out[no].cls = use_bwt ? (uint8_t)CLS_BWT : (uint8_t)CLS_TEXT;
                no++;
            }
            fresh = 0;
            pos += take;
        }
    }
    free(segs);
    *psegs = out;
    *pn = no;
    return FURL_OK;
}

int furl_compress(const uint8_t *in, size_t in_len, uint8_t **out, size_t *out_len, const FurlOptions *opt) {
    if (!out || !out_len || (in_len && !in)) {
        return FURL_ERR_ARG;
    }
    if (in_len > (8ull << 30)) {
        return FURL_ERR_ARG;
    }
    *out = NULL;
    *out_len = 0;
    int level = clamp_level(opt ? opt->level : 7);
    uint32_t bsz = block_size_for(level);

    FurlSeg *segs = NULL;
    uint32_t nblocks = 0;
    const uint64_t *file_ends = opt ? opt->file_ends : NULL;
    uint32_t nfiles = opt ? opt->nfiles : 0;
    int rc = plan_segments(in, in_len, bsz, file_ends, nfiles, opt, &segs, &nblocks);
    if (rc != FURL_OK) {
        return rc;
    }
    carve_incompressible(in, &segs, &nblocks);
    init_tables();
    rc = split_record_text(in, &segs, &nblocks, level, opt, (uint64_t)in_len);
    if (rc != FURL_OK) {
        free(segs);
        return rc;
    }

    uint8_t *buf = (uint8_t *)malloc(32);
    if (!buf) {
        free(segs);
        return FURL_ERR_NOMEM;
    }
    size_t cap = 32;
    size_t len = 32;
    memset(buf, 0, 32);
    wr32(buf + 0, FURL_MAGIC);
    buf[4] = (uint8_t)level;
    buf[5] = 1; /* has crc */
    wr64(buf + 8, (uint64_t)in_len);
    wr32(buf + 16, crc32(in, in_len));
    wr32(buf + 20, nblocks);

    init_tables();

    SegJob *jobs = NULL;
    if (nblocks) {
        jobs = (SegJob *)calloc(nblocks, sizeof(SegJob));
        if (!jobs) {
            free(buf);
            free(segs);
            return FURL_ERR_NOMEM;
        }
        for (uint32_t i = 0; i < nblocks; i++) {
            jobs[i].src = in + segs[i].off;
            jobs[i].n = segs[i].n;
            jobs[i].cls = segs[i].cls;
            jobs[i].level = level;
            jobs[i].opt = opt;
            jobs[i].base = (uint64_t)segs[i].off;
            jobs[i].total = (uint64_t)in_len;
        }
#if defined(__APPLE__)
        if (nblocks > 1) {
            /* Cap in-flight blocks so five 64 MiB jobs do not each keep a ~400 MiB window. */
            dispatch_semaphore_t slots = dispatch_semaphore_create(4);
            if (!slots) {
                for (uint32_t i = 0; i < nblocks; i++) {
                    encode_segment(&jobs[i]);
                }
            } else {
                dispatch_apply(nblocks, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
                    dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
                    encode_segment(&jobs[i]);
                    dispatch_semaphore_signal(slots);
                });
                dispatch_release(slots);
            }
        } else
#endif
        {
            for (uint32_t i = 0; i < nblocks; i++) {
                encode_segment(&jobs[i]);
            }
        }
    }

    if (opt && opt->stats && jobs) {
        int failed = 0;
        for (uint32_t i = 0; i < nblocks; i++) {
            if (jobs[i].rc != FURL_OK) {
                failed = 1;
                break;
            }
        }
        if (!failed) {
            for (uint32_t i = 0; i < nblocks; i++) {
                stats_add(opt->stats, &jobs[i].stats);
            }
        }
    }

    size_t done = 0;
    for (uint32_t bi = 0; bi < nblocks; bi++) {
        if (jobs[bi].rc != FURL_OK) {
            rc = jobs[bi].rc;
            for (uint32_t k = 0; k < nblocks; k++) {
                free(jobs[k].out);
            }
            free(jobs);
            free(buf);
            free(segs);
            return rc;
        }
        const uint8_t *payload = jobs[bi].out ? jobs[bi].out : jobs[bi].src;
        rc = emit_stored(&buf, &cap, &len, jobs[bi].n, jobs[bi].flags, jobs[bi].primary, payload, jobs[bi].out_n);
        if (rc != FURL_OK) {
            for (uint32_t k = 0; k < nblocks; k++) {
                free(jobs[k].out);
            }
            free(jobs);
            free(buf);
            free(segs);
            return rc;
        }
        done += jobs[bi].n;
        rc = call_progress(opt, (uint64_t)done, (uint64_t)in_len);
        if (rc != FURL_OK) {
            for (uint32_t k = 0; k < nblocks; k++) {
                free(jobs[k].out);
            }
            free(jobs);
            free(buf);
            free(segs);
            return rc;
        }
    }

    if (jobs) {
        for (uint32_t i = 0; i < nblocks; i++) {
            free(jobs[i].out);
        }
        free(jobs);
    }
    free(segs);
    *out = buf;
    *out_len = len;
    return FURL_OK;
}

int furl_decompress(const uint8_t *in, size_t in_len, uint8_t **out, size_t *out_len, const FurlOptions *opt) {
    if (!out || !out_len || !in || in_len < 32) {
        return FURL_ERR_ARG;
    }
    *out = NULL;
    *out_len = 0;
    if (rd32(in) != FURL_MAGIC) {
        return FURL_ERR_DATA;
    }
    int level = in[4];
    if (level < 1 || level > MAX_LEVEL) {
        return FURL_ERR_DATA;
    }
    uint64_t orig = rd64(in + 8);
    uint32_t expect_crc = rd32(in + 16);
    uint32_t nblocks = rd32(in + 20);
    if (orig > (8ULL << 30)) {
        return FURL_ERR_DATA;
    }
    if (orig == 0) {
        if (nblocks != 0) {
            return FURL_ERR_DATA;
        }
    } else if (nblocks == 0 || (uint64_t)nblocks > orig) {
        return FURL_ERR_DATA;
    }

    uint8_t *buf = NULL;
    if (orig) {
        buf = (uint8_t *)malloc((size_t)orig);
        if (!buf) {
            return FURL_ERR_NOMEM;
        }
    }

    size_t cursor = 32;
    size_t written = 0;
    for (uint32_t bi = 0; bi < nblocks; bi++) {
        if (cursor + 16 > in_len) {
            free(buf);
            return FURL_ERR_DATA;
        }
        uint32_t n = rd32(in + cursor);
        uint32_t flags = rd32(in + cursor + 4);
        uint32_t primary = rd32(in + cursor + 8);
        uint32_t csize = rd32(in + cursor + 12);
        cursor += 16;
        if (cursor + csize > in_len || written + n > orig) {
            free(buf);
            return FURL_ERR_DATA;
        }
        uint8_t *dst = buf + written;
        if (flags & BLK_RAW) {
            if (csize != n) {
                free(buf);
                return FURL_ERR_DATA;
            }
            memcpy(dst, in + cursor, n);
        } else {
            uint8_t *tmp = (uint8_t *)malloc(n);
            if (!tmp) {
                free(buf);
                return FURL_ERR_NOMEM;
            }
            CM cm;
            int rc;
            if (flags & BLK_ZRLE) {
                if (csize < 8u) {
                    free(tmp);
                    free(buf);
                    return FURL_ERR_DATA;
                }
                uint32_t nsym = rd32(in + cursor);
                cm_range_init(&cm, 0, in + cursor + 4, csize - 4u);
                rc = zrle_decode(&cm, tmp, n, nsym, opt, (uint64_t)written, orig);
            } else {
                rc = cm_init(&cm, 0, level, in + cursor, csize);
                if (rc != FURL_OK) {
                    free(tmp);
                    free(buf);
                    return rc;
                }
                rc = decompress_block(&cm, tmp, n, (flags & BLK_PPM) != 0, opt, (uint64_t)written, orig);
                cm_free(&cm);
            }
            if (rc != FURL_OK) {
                free(tmp);
                free(buf);
                return rc;
            }
            if (flags & BLK_MTF) {
                mtf_inv(tmp, n);
            }
            if (flags & BLK_BWT) {
                if (furl_unbwt(tmp, n, primary, dst) != 0) {
                    free(tmp);
                    free(buf);
                    return FURL_ERR_DATA;
                }
            } else {
                memcpy(dst, tmp, n);
            }
            free(tmp);
            if (flags & BLK_E8) {
                e8_inv(dst, n);
            }
            if (flags & BLK_DELTA) {
                int w = (int)((flags >> 8) & 0xFF);
                if (w > 0) {
                    delta_inv(dst, n, w);
                }
            }
        }
        cursor += csize;
        written += n;
        int prc = call_progress(opt, (uint64_t)written, orig);
        if (prc != FURL_OK) {
            free(buf);
            return prc;
        }
    }
    if (written != orig) {
        free(buf);
        return FURL_ERR_DATA;
    }
    if (cursor != in_len) {
        free(buf);
        return FURL_ERR_DATA;
    }
    if (expect_crc != crc32(buf, (size_t)orig)) {
        free(buf);
        return FURL_ERR_DATA;
    }
    *out = buf;
    *out_len = (size_t)orig;
    return FURL_OK;
}

void furl_free(void *p) {
    free(p);
}

const char *furl_version(void) {
    return "1.5.13";
}

const char *furl_error(int code) {
    switch (code) {
    case FURL_OK:
        return "ok";
    case FURL_ERR_ARG:
        return "bad argument";
    case FURL_ERR_NOMEM:
        return "out of memory";
    case FURL_ERR_DATA:
        return "corrupt or truncated data";
    case FURL_ERR_CANCEL:
        return "cancelled";
    default:
        return "unknown error";
    }
}
