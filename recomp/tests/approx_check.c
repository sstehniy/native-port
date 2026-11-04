/* R1.04: RCPPS/RSQRTPS results depend only on sign, exponent and the top 12 mantissa bits (plus
 * the payload for NaN). Built for x86_64 it streams the reference results for every such class,
 * two low-bit fillers and two MXCSR settings; built for arm64 it compares them with bb_fp_approx32.
 * Usage: approx_check-x86 | approx_check */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef __x86_64__
#include <immintrin.h>
#else
#include "../src/cpu/fp.h"
#endif

static const uint32_t modes[] = {0x1f80, 0xffc0};
static const uint32_t fillers[] = {0, 0x7ff};

int main(void) {
#ifndef __x86_64__
    unsigned long checked = 0, failed = 0;
#endif
    for (unsigned m = 0; m < 2; ++m) {
        for (unsigned l = 0; l < 2; ++l) {
            for (uint32_t high = 0; high < (UINT32_C(1) << 21); high += 4) {
                uint32_t in[4], rcp[4], rsqrt[4];
                for (int k = 0; k < 4; ++k) in[k] = (high + (uint32_t)k) << 11 | fillers[l];
#ifdef __x86_64__
                _mm_setcsr(modes[m]);
                __m128 x;
                memcpy(&x, in, sizeof(in));
                const __m128 r = _mm_rcp_ps(x), s = _mm_rsqrt_ps(x);
                _mm_setcsr(0x1f80);
                memcpy(rcp, &r, sizeof(rcp));
                memcpy(rsqrt, &s, sizeof(rsqrt));
                fwrite(rcp, sizeof(rcp), 1, stdout);
                fwrite(rsqrt, sizeof(rsqrt), 1, stdout);
#else
                if (fread(rcp, sizeof(rcp), 1, stdin) != 1 || fread(rsqrt, sizeof(rsqrt), 1, stdin) != 1) {
                    puts("reference stream ended early");
                    return 2;
                }
                for (int k = 0; k < 4; ++k) {
                    float value;
                    memcpy(&value, &in[k], sizeof(value));
                    const float actual[2] = {bb_fp_approx32(value, 0), bb_fp_approx32(value, 1)};
                    const uint32_t expected[2] = {rcp[k], rsqrt[k]};
                    for (int root = 0; root < 2; ++root) {
                        uint32_t bits;
                        memcpy(&bits, &actual[root], sizeof(bits));
                        ++checked;
                        if (bits != expected[root] && failed++ < 10)
                            printf("FAIL %s input=%#x mxcsr=%#x expected=%#x actual=%#x\n", root ? "rsqrt" : "rcp",
                                   in[k], modes[m], expected[root], bits);
                    }
                }
#endif
            }
        }
    }
#ifndef __x86_64__
    printf("APPROX checked=%lu failed=%lu\n", checked, failed);
    return failed != 0;
#endif
    return 0;
}
