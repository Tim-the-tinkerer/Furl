#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Density 9 parse counters. The caller zeros this; compress adds into it.
   Predicted bits are -log2(p) for every bit the LZ arithmetic coder emits,
   including literal context-mixing. Coded bits are the LZ arithmetic bytes,
   times 8. Histograms count accepted matches. Rejected matches were legal
   but priced above the same bytes as literals. */
typedef struct FurlParseStats {
    uint64_t literals;
    uint64_t matches;
    uint64_t literal_bytes;
    uint64_t match_bytes;
    uint64_t longest_match;
    uint64_t rep_hits;
    uint64_t candidates;
    double predicted_bits;
    uint64_t coded_bits;
    uint64_t raw_bytes;
    uint64_t ppm_bytes;
    uint64_t lz_bytes;
    uint64_t long_bytes;
    uint32_t e8_blocks;
    uint32_t delta_blocks;
    uint64_t len_2_3;
    uint64_t len_4_7;
    uint64_t len_8_15;
    uint64_t len_16_31;
    uint64_t len_32_63;
    uint64_t len_64;
    uint64_t dist_256;
    uint64_t dist_4k;
    uint64_t dist_64k;
    uint64_t dist_1m;
    uint64_t dist_16m;
    uint64_t dist_far;
    uint64_t rep0;
    uint64_t rep1;
    uint64_t rep2;
    uint64_t rep3;
    uint64_t short_nonrep;
    uint64_t short_nonrep_bytes;
    uint64_t rejected_matches;
    uint64_t rejected_bytes;
} FurlParseStats;

typedef struct FurlOptions {
    int level; /* 1 (fast) … 9 (smallest). 0 means 7. */
    int (*progress)(void *user, uint64_t done, uint64_t total);
    void *user;
    /* Optional exclusive end offsets of each file in the solid stream.
       When set, long LZ runs split on a file boundary near the block cap
       so similar copies are not cut in half. */
    const uint64_t *file_ends;
    uint32_t nfiles;
    FurlParseStats *stats;
} FurlOptions;

enum {
    FURL_OK = 0,
    FURL_ERR_ARG = 1,
    FURL_ERR_NOMEM = 2,
    FURL_ERR_DATA = 3,
    FURL_ERR_CANCEL = 4
};

int furl_compress(const uint8_t *in, size_t in_len,
                  uint8_t **out, size_t *out_len,
                  const FurlOptions *opt);

int furl_decompress(const uint8_t *in, size_t in_len,
                    uint8_t **out, size_t *out_len,
                    const FurlOptions *opt);

void furl_free(void *p);
const char *furl_version(void);
const char *furl_error(int code);

#ifdef __cplusplus
}
#endif
