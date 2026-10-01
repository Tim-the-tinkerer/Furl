#include "bwt.h"

#include <stdlib.h>
#include <string.h>

static void radix_pass(const int32_t *src, int32_t *dst, const int32_t *key,
                       int32_t n, int32_t *cnt, int32_t sigma) {
    memset(cnt, 0, (size_t)sigma * sizeof(int32_t));
    for (int32_t i = 0; i < n; i++) {
        cnt[key[src[i]]]++;
    }
    int32_t sum = 0;
    for (int32_t i = 0; i < sigma; i++) {
        int32_t c = cnt[i];
        cnt[i] = sum;
        sum += c;
    }
    for (int32_t i = 0; i < n; i++) {
        dst[cnt[key[src[i]]]++] = src[i];
    }
}

int furl_bwt(const uint8_t *in, uint32_t n, uint8_t *out, uint32_t *primary) {
    if (n == 0) {
        *primary = 0;
        return 0;
    }
    if (n == 1) {
        out[0] = in[0];
        *primary = 0;
        return 0;
    }

    int32_t N = (int32_t)n;
    int32_t sigma0 = N + 2 > 258 ? N + 2 : 258;
    int32_t *sa = (int32_t *)malloc((size_t)N * sizeof(int32_t));
    int32_t *rank = (int32_t *)malloc((size_t)N * sizeof(int32_t));
    int32_t *tmp = (int32_t *)malloc((size_t)N * sizeof(int32_t));
    int32_t *k2 = (int32_t *)malloc((size_t)N * sizeof(int32_t));
    int32_t *cnt = (int32_t *)malloc((size_t)sigma0 * sizeof(int32_t));
    if (!sa || !rank || !tmp || !k2 || !cnt) {
        free(sa);
        free(rank);
        free(tmp);
        free(k2);
        free(cnt);
        return -1;
    }

    for (int32_t i = 0; i < N; i++) {
        sa[i] = i;
        rank[i] = (int32_t)in[i] + 1;
    }

    int32_t sigma = 257;
    radix_pass(sa, tmp, rank, N, cnt, sigma);
    memcpy(sa, tmp, (size_t)N * sizeof(int32_t));

    tmp[sa[0]] = 1;
    int32_t classes = 1;
    for (int32_t i = 1; i < N; i++) {
        if (rank[sa[i]] != rank[sa[i - 1]]) {
            classes++;
        }
        tmp[sa[i]] = classes;
    }
    memcpy(rank, tmp, (size_t)N * sizeof(int32_t));
    sigma = classes + 1;

    /* Cyclic rotations, not suffixes: wrap indices so inverse BWT is valid. */
    for (int32_t k = 1; k < N && classes < N; k *= 2) {
        for (int32_t i = 0; i < N; i++) {
            k2[i] = rank[(i + k) % N];
        }
        radix_pass(sa, tmp, k2, N, cnt, sigma);
        radix_pass(tmp, sa, rank, N, cnt, sigma);

        tmp[sa[0]] = 1;
        classes = 1;
        for (int32_t i = 1; i < N; i++) {
            int32_t a = sa[i - 1];
            int32_t b = sa[i];
            int32_t a2 = rank[(a + k) % N];
            int32_t b2 = rank[(b + k) % N];
            if (rank[a] != rank[b] || a2 != b2) {
                classes++;
            }
            tmp[b] = classes;
        }
        memcpy(rank, tmp, (size_t)N * sizeof(int32_t));
        sigma = classes + 1;
    }

    *primary = 0;
    for (int32_t i = 0; i < N; i++) {
        int32_t p = sa[i];
        if (p == 0) {
            *primary = (uint32_t)i;
        }
        out[i] = in[(p + N - 1) % N];
    }

    free(sa);
    free(rank);
    free(tmp);
    free(k2);
    free(cnt);
    return 0;
}

int furl_unbwt(const uint8_t *in, uint32_t n, uint32_t primary, uint8_t *out) {
    if (n == 0) {
        return 0;
    }
    if (n == 1) {
        out[0] = in[0];
        return 0;
    }
    if (primary >= n) {
        return -1;
    }

    uint32_t C[256];
    memset(C, 0, sizeof(C));
    for (uint32_t i = 0; i < n; i++) {
        C[in[i]]++;
    }
    uint32_t sum = 0;
    for (int c = 0; c < 256; c++) {
        uint32_t t = C[c];
        C[c] = sum;
        sum += t;
    }

    uint32_t *lf = (uint32_t *)malloc((size_t)n * sizeof(uint32_t));
    if (!lf) {
        return -1;
    }
    uint32_t next[256];
    memcpy(next, C, sizeof(next));
    for (uint32_t i = 0; i < n; i++) {
        lf[i] = next[in[i]]++;
    }

    uint32_t i = primary;
    for (uint32_t k = n; k-- > 0;) {
        out[k] = in[i];
        i = lf[i];
    }
    free(lf);
    return 0;
}
