/* R1.04: results near the smallest normal under every MXCSR rounding/FTZ/DAZ mode. Built for x86_64
 * it streams random operands steered toward FLT_MIN/DBL_MIN with the reference MUL, DIV, FMA and
 * CVTSD2SS results; built for arm64 it recomputes them with fp.h and compares.
 * Usage: tiny_check-x86 | tiny_check */
#include <float.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef __x86_64__
#include <immintrin.h>
#else
#include "../src/cpu/fp.h"
#endif

enum { CASES = 1 << 18 };

typedef struct {
    uint32_t mxcsr;
    float f[4]; /* x, y, z, dividend */
    double d[5]; /* the same, then a CVTSD2SS source */
    float out_f[4];
    double out_d[3];
} Case;

#ifdef __x86_64__
static uint64_t state = 0x9e3779b97f4a7c15u;
static uint64_t next(void) {
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    return state;
}
static double unit(void) { return (double)(next() >> 11) * 0x1p-53; }

static float nudge32(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    bits += (uint32_t)(next() % 5) - 2;
    memcpy(&value, &bits, sizeof(bits));
    return value;
}
static double nudge64(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    bits += next() % 5 - 2;
    memcpy(&value, &bits, sizeof(bits));
    return value;
}

static void make(Case *c, unsigned n) {
    c->mxcsr = 0x1f80 | (n & 3) << 13;
    if (n & 4) c->mxcsr |= 0x8000;
    if (n & 8) c->mxcsr |= 0x40;
    const double sign = next() & 1 ? -1 : 1, target = 1 + (unit() - 0.5) * 0x1p-20;
    const double x = (1 + unit()) * (next() & 1 ? 1 : 0x1p-20), addend = (unit() - 0.5) * 8;
    c->f[0] = nudge32((float)(sign * x));
    c->f[2] = nudge32((float)(addend * FLT_MIN));
    c->f[1] = nudge32((float)((target - addend) * FLT_MIN / x));
    c->d[0] = nudge64(sign * x);
    c->d[2] = nudge64(addend * DBL_MIN);
    c->d[1] = nudge64((target - addend) * DBL_MIN / x);
    if (n & 16) { c->f[1] = nudge32((float)(target * FLT_MIN / x)); c->d[1] = nudge64(target * DBL_MIN / x); }
    c->f[3] = nudge32((float)(sign * target * FLT_MIN * x));
    c->d[3] = nudge64(sign * target * DBL_MIN * x);
    c->d[4] = nudge64(sign * target * FLT_MIN);
}

static void reference(Case *c) {
    _mm_setcsr(c->mxcsr);
    const __m128 x = _mm_set_ss(c->f[0]), y = _mm_set_ss(c->f[1]), z = _mm_set_ss(c->f[2]);
    const __m128d a = _mm_set_sd(c->d[0]), b = _mm_set_sd(c->d[1]), e = _mm_set_sd(c->d[2]);
    c->out_f[0] = _mm_cvtss_f32(_mm_mul_ss(x, y));
    c->out_f[1] = _mm_cvtss_f32(_mm_div_ss(_mm_set_ss(c->f[3]), x));
    c->out_f[2] = _mm_cvtss_f32(_mm_fmadd_ss(x, y, z));
    c->out_f[3] = _mm_cvtss_f32(_mm_cvtsd_ss(_mm_setzero_ps(), _mm_set_sd(c->d[4])));
    c->out_d[0] = _mm_cvtsd_f64(_mm_mul_sd(a, b));
    c->out_d[1] = _mm_cvtsd_f64(_mm_div_sd(_mm_set_sd(c->d[3]), a));
    c->out_d[2] = _mm_cvtsd_f64(_mm_fmadd_sd(a, b, e));
    _mm_setcsr(0x1f80);
}
#endif

int main(void) {
#ifndef __x86_64__
    unsigned long checked = 0, failed = 0;
#endif
    for (unsigned n = 0; n < CASES; ++n) {
        Case c;
#ifdef __x86_64__
        memset(&c, 0, sizeof(c));
        make(&c, n);
        reference(&c);
        fwrite(&c, sizeof(c), 1, stdout);
#else
        if (fread(&c, sizeof(c), 1, stdin) != 1) {
            puts("reference stream ended early");
            return 2;
        }
        BbVec x = {0}, y = {0}, z = {0}, p = {0}, a = {0}, b = {0}, e = {0}, q = {0}, wide = {0};
        x.f[0] = c.f[0]; y.f[0] = c.f[1]; z.f[0] = c.f[2]; p.f[0] = c.f[3];
        a.fd[0] = c.d[0]; b.fd[0] = c.d[1]; e.fd[0] = c.d[2]; q.fd[0] = c.d[3]; wide.fd[0] = c.d[4];
        const uint32_t m = c.mxcsr;
        const float actual_f[4] = {
            bb_fp_binary(x, y, BB_FP_MUL, 0, 1, m).f[0],
            bb_fp_binary(p, x, BB_FP_DIV, 0, 1, m).f[0],
            bb_fp_fma(z, x, y, 231, 0, 0, 0, 1, m).f[0],
            bb_fp_convert((BbVec){0}, wide, BB_FP_F64, BB_FP_F32, 1, 0, m).f[0],
        };
        const double actual_d[3] = {
            bb_fp_binary(a, b, BB_FP_MUL, 1, 1, m).fd[0],
            bb_fp_binary(q, a, BB_FP_DIV, 1, 1, m).fd[0],
            bb_fp_fma(a, e, b, 132, 0, 0, 1, 1, m).fd[0],
        };
        for (int k = 0; k < 7; ++k) {
            uint64_t want = 0, got = 0;
            if (k < 4) { memcpy(&want, &c.out_f[k], 4); memcpy(&got, &actual_f[k], 4); }
            else { memcpy(&want, &c.out_d[k - 4], 8); memcpy(&got, &actual_d[k - 4], 8); }
            ++checked;
            if (want != got && failed++ < 10)
                printf("FAIL case=%u op=%d mxcsr=%#x expected=%#llx actual=%#llx\n", n, k, m,
                       (unsigned long long)want, (unsigned long long)got);
        }
#endif
    }
#ifndef __x86_64__
    printf("TINY checked=%lu failed=%lu\n", checked, failed);
    return failed != 0;
#endif
    return 0;
}
