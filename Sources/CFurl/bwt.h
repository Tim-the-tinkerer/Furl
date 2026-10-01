#pragma once

#include <stdint.h>

int furl_bwt(const uint8_t *in, uint32_t n, uint8_t *out, uint32_t *primary);
int furl_unbwt(const uint8_t *in, uint32_t n, uint32_t primary, uint8_t *out);
