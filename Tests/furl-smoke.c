#include "furl.h"
#include "bwt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail = 0;

static void expect(int cond, const char *msg) {
    if (!cond) {
        fprintf(stderr, "FAIL %s\n", msg);
        fail++;
    } else {
        printf("ok  %s\n", msg);
    }
}

static void roundtrip(const char *name, const uint8_t *in, size_t n, int level) {
    uint8_t *comp = NULL;
    size_t clen = 0;
    FurlOptions opt = {.level = level, .progress = NULL, .user = NULL};
    int rc = furl_compress(in, n, &comp, &clen, &opt);
    if (rc != FURL_OK) {
        fprintf(stderr, "FAIL %s compress rc=%d (%s)\n", name, rc, furl_error(rc));
        fail++;
        furl_free(comp);
        return;
    }
    uint8_t *plain = NULL;
    size_t plen = 0;
    rc = furl_decompress(comp, clen, &plain, &plen, &opt);
    if (rc != FURL_OK) {
        fprintf(stderr, "FAIL %s decompress rc=%d (%s) clen=%zu n=%zu\n", name, rc, furl_error(rc), clen, n);
        fail++;
        furl_free(comp);
        furl_free(plain);
        return;
    }
    int match = plen == n && (n == 0 || memcmp(plain, in, n) == 0);
    if (!match) {
        fprintf(stderr, "FAIL %s mismatch plen=%zu n=%zu clen=%zu\n", name, plen, n, clen);
        fail++;
    } else {
        printf("ok  %s n=%zu -> %zu (level %d)\n", name, n, clen, level);
    }
    furl_free(comp);
    furl_free(plain);
}

int main(void) {
    uint8_t banana[] = "banana";
    uint8_t bwt[6];
    uint32_t primary = 0;
    expect(furl_bwt(banana, 6, bwt, &primary) == 0, "bwt banana");
    expect(primary == 3, "banana primary 3");
    uint8_t back[6];
    expect(furl_unbwt(bwt, 6, primary, back) == 0, "unbwt banana");
    expect(memcmp(back, banana, 6) == 0, "banana roundtrip");

    uint8_t zeros[4096];
    memset(zeros, 0, sizeof(zeros));
    uint8_t zbwt[4096];
    expect(furl_bwt(zeros, 4096, zbwt, &primary) == 0, "bwt zeros");
    uint8_t zback[4096];
    expect(furl_unbwt(zbwt, 4096, primary, zback) == 0 && memcmp(zback, zeros, 4096) == 0, "zeros bwt roundtrip");

    roundtrip("empty", NULL, 0, 1);
    uint8_t one[] = {0x42};
    roundtrip("one", one, 1, 1);
    roundtrip("one-l5", one, 1, 5);
    roundtrip("banana-l1", banana, 6, 1);
    roundtrip("banana-l7", banana, 6, 7);
    roundtrip("zeros-l1", zeros, 4096, 1);
    roundtrip("zeros-l6", zeros, 4096, 6);

    uint8_t text[8000];
    const char *snip = "The quick brown fox jumps over the lazy dog. ";
    size_t sl = strlen(snip);
    for (int i = 0; i < 8000; i++) {
        text[i] = (uint8_t)snip[i % sl];
    }
    {
        uint8_t tbwt[8000], tback[8000];
        uint32_t tp = 0;
        expect(furl_bwt(text, 8000, tbwt, &tp) == 0, "bwt fox");
        expect(furl_unbwt(tbwt, 8000, tp, tback) == 0 && memcmp(tback, text, 8000) == 0, "fox bwt roundtrip");
        roundtrip("fox-bwt-as-data-l1", tbwt, 8000, 1);
    }
    roundtrip("fox-l1", text, 8000, 1);
    roundtrip("fox-l5", text, 8000, 5);
    roundtrip("fox-l6", text, 8000, 6);
    roundtrip("fox-l7", text, 8000, 7);
    roundtrip("fox-l9", text, 8000, 9);

    uint8_t rnd[2000];
    for (int i = 0; i < 2000; i++) {
        rnd[i] = (uint8_t)(i * 17 + 31);
    }
    roundtrip("pseudo-l1", rnd, 2000, 1);
    roundtrip("pseudo-l7", rnd, 2000, 7);

    printf(fail ? "\n%d FAILED\n" : "\nall passed\n", fail);
    return fail ? 1 : 0;
}
