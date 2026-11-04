#ifndef BB_CPU_FP_H
#define BB_CPU_FP_H
#include "cpu_internal.h"
#include <fenv.h>
#include <float.h>
#include <math.h>
#include <stdlib.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

enum { BB_FP_ADD, BB_FP_SUB, BB_FP_MUL, BB_FP_DIV, BB_FP_MIN, BB_FP_MAX };
typedef enum { BB_FP_F32, BB_FP_F64, BB_FP_I32, BB_FP_I64 } BbFpFormat;

/* x86 controls input DAZ and output FTZ separately; ARM's native flush mode combines them. */
static inline float bb_fp_input32(float value, uint32_t mxcsr) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    if ((mxcsr & 0x40) && !(bits & 0x7f800000)) bits &= 0x80000000;
    memcpy(&value, &bits, sizeof(bits));
    return value;
}

static inline double bb_fp_input64(double value, uint32_t mxcsr) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    if ((mxcsr & 0x40) && !(bits & UINT64_C(0x7ff0000000000000))) bits &= UINT64_C(0x8000000000000000);
    memcpy(&value, &bits, sizeof(bits));
    return value;
}

static inline int bb_fp_nan32(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return (bits & 0x7fffffff) > 0x7f800000;
}

static inline int bb_fp_nan64(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return (bits & UINT64_C(0x7fffffffffffffff)) > UINT64_C(0x7ff0000000000000);
}

static inline float bb_fp_result32(float value, float x, float y, uint32_t mxcsr) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    if (bb_fp_nan32(x)) {
        memcpy(&bits, &x, sizeof(bits));
        bits |= 0x00400000;
    } else if (bb_fp_nan32(y)) {
        memcpy(&bits, &y, sizeof(bits));
        bits |= 0x00400000;
    } else if (bb_fp_nan32(value)) bits = 0xffc00000;
    if ((mxcsr & 0x8000) && !(bits & 0x7f800000)) bits &= 0x80000000;
    memcpy(&value, &bits, sizeof(bits));
    return value;
}

static inline double bb_fp_result64(double value, double x, double y, uint32_t mxcsr) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    if (bb_fp_nan64(x)) {
        memcpy(&bits, &x, sizeof(bits));
        bits |= UINT64_C(0x0008000000000000);
    } else if (bb_fp_nan64(y)) {
        memcpy(&bits, &y, sizeof(bits));
        bits |= UINT64_C(0x0008000000000000);
    } else if (bb_fp_nan64(value)) bits = UINT64_C(0xfff8000000000000);
    if ((mxcsr & 0x8000) && !(bits & UINT64_C(0x7ff0000000000000))) bits &= UINT64_C(0x8000000000000000);
    memcpy(&value, &bits, sizeof(bits));
    return value;
}

/* x86 detects tininess after rounding to full precision: with FTZ, a result that reaches the
 * smallest normal only through subnormal rounding still flushes. ARM rounds at subnormal precision,
 * so redo such results with x (and the addend) scaled by 256, which keeps them normal. The scale
 * cannot overflow: a result this small rules out operands near the top of the range. */
#define BB_FP_FLUSH_TINY(result, scaled, minimum)                                     \
    do {                                                                             \
        if ((mxcsr & 0x8000) && fabs((double)(result)) == (minimum) &&               \
            fabs((double)(scaled)) < (minimum) * 256)                                \
            (result) = copysign(0.0, (result));                                      \
    } while (0)

/* MXCSR status flags are not modeled: the game only reads MXCSR to toggle FTZ and never tests
 * them. LDMXCSR stops on unmasked exceptions. */
#if defined(__aarch64__)
typedef struct { uint64_t control, status; } BbFpEnv;
static inline BbFpEnv bb_fp_enter(uint32_t mxcsr) {
    BbFpEnv saved;
    // ARM swaps the upward/downward encodings; leave native flushing and traps disabled.
    const uint64_t rounding = (uint64_t)(((mxcsr >> 13) & 1) << 1 | ((mxcsr >> 14) & 1)) << 22;
    __asm__ volatile("mrs %0, fpcr\n\tmrs %1, fpsr" : "=r"(saved.control), "=r"(saved.status) : : "memory");
    if (saved.control != rounding)
        __asm__ volatile("msr fpcr, %0" : : "r"(rounding) : "memory");
    // Guest status flags are unmodeled; retain FPSR until restoring the host environment.
    return saved;
}
static inline void bb_fp_leave(BbFpEnv saved) {
    BbFpEnv current;
    __asm__ volatile("mrs %0, fpcr\n\tmrs %1, fpsr" : "=r"(current.control), "=r"(current.status) : : "memory");
    if (current.control != saved.control)
        __asm__ volatile("msr fpcr, %0" : : "r"(saved.control) : "memory");
    if (current.status != saved.status)
        __asm__ volatile("msr fpsr, %0" : : "r"(saved.status) : "memory");
}
#else
typedef fenv_t BbFpEnv;
static inline BbFpEnv bb_fp_enter(uint32_t mxcsr) {
    fenv_t saved;
    fegetenv(&saved);
    fesetenv(FE_DFL_ENV);
    const int rounding[] = {FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO};
    fesetround(rounding[(mxcsr >> 13) & 3]);
    return saved;
}
static inline void bb_fp_leave(BbFpEnv saved) { fesetenv(&saved); }
#endif

#if defined(__aarch64__)
static inline int bb_fp_regular32(uint32x4_t bits, uint32_t minimum) {
    const uint32x4_t magnitude = vandq_u32(bits, vdupq_n_u32(0x7fffffff));
    const uint32x4_t normal = vandq_u32(vcgeq_u32(magnitude, vdupq_n_u32(minimum)),
                                      vcltq_u32(magnitude, vdupq_n_u32(0x7f800000)));
    return vminvq_u32(vorrq_u32(normal, vceqq_u32(magnitude, vdupq_n_u32(0)))) != 0;
}
#endif

/* Generated callers may share the guest environment across instructions, restoring it before
 * every runtime boundary. Other callers use the environment-preserving wrappers. */
static inline __attribute__((always_inline)) BbVec bb_fp_binary_in_env(BbVec a, BbVec b, int kind, int dbl, int lanes, uint32_t mxcsr) {
#pragma STDC FENV_ACCESS ON
    BbVec r = a;
    int processed = 0;
#if defined(__aarch64__)
    if (!dbl && lanes >= 4 && kind <= BB_FP_DIV) {
        int regular = 1;
        for (int i = 0; i < lanes; i += 4) {
            const float32x4_t x = vld1q_f32(a.f + i), y = vld1q_f32(b.f + i);
            if (!bb_fp_regular32(vreinterpretq_u32_f32(x), 0x00800000) ||
                !bb_fp_regular32(vreinterpretq_u32_f32(y), 0x00800000)) { regular = 0; break; }
            float32x4_t value;
            switch (kind) {
            case BB_FP_ADD: value = vaddq_f32(x, y); break;
            case BB_FP_SUB: value = vsubq_f32(x, y); break;
            case BB_FP_MUL: value = vmulq_f32(x, y); break;
            case BB_FP_DIV: value = vdivq_f32(x, y); break;
            default: abort();
            }
            // The smallest normal can require x86's after-rounding FTZ correction.
            if (!bb_fp_regular32(vreinterpretq_u32_f32(value), 0x00800001)) { regular = 0; break; }
            vst1q_f32(r.f + i, value);
        }
        if (regular) processed = lanes;
    }
#endif
    for (int i = processed; i < lanes; ++i) {
        if (dbl) {
            const double x = bb_fp_input64(a.fd[i], mxcsr), y = bb_fp_input64(b.fd[i], mxcsr);
            switch (kind) {
            case BB_FP_ADD: r.fd[i] = x + y; break;
            case BB_FP_SUB: r.fd[i] = x - y; break;
            case BB_FP_MUL: r.fd[i] = x * y; break;
            case BB_FP_DIV: r.fd[i] = x / y; break;
            case BB_FP_MIN: r.fd[i] = x < y ? x : y; break;
            case BB_FP_MAX: r.fd[i] = x > y ? x : y; break;
            default: abort();
            }
            if (kind == BB_FP_MUL) BB_FP_FLUSH_TINY(r.fd[i], x * 256 * y, DBL_MIN);
            if (kind == BB_FP_DIV) BB_FP_FLUSH_TINY(r.fd[i], x * 256 / y, DBL_MIN);
            if (kind <= BB_FP_DIV) r.fd[i] = bb_fp_result64(r.fd[i], x, y, mxcsr);
        } else {
            const float x = bb_fp_input32(a.f[i], mxcsr), y = bb_fp_input32(b.f[i], mxcsr);
            switch (kind) {
            case BB_FP_ADD: r.f[i] = x + y; break;
            case BB_FP_SUB: r.f[i] = x - y; break;
            case BB_FP_MUL: r.f[i] = x * y; break;
            case BB_FP_DIV: r.f[i] = x / y; break;
            case BB_FP_MIN: r.f[i] = x < y ? x : y; break;
            case BB_FP_MAX: r.f[i] = x > y ? x : y; break;
            default: abort();
            }
            if (kind == BB_FP_MUL) BB_FP_FLUSH_TINY(r.f[i], x * 256 * y, FLT_MIN);
            if (kind == BB_FP_DIV) BB_FP_FLUSH_TINY(r.f[i], x * 256 / y, FLT_MIN);
            if (kind <= BB_FP_DIV) r.f[i] = bb_fp_result32(r.f[i], x, y, mxcsr);
        }
    }
    return r;
}

static inline BbVec bb_fp_binary(BbVec a, BbVec b, int kind, int dbl, int lanes, uint32_t mxcsr) {
#pragma STDC FENV_ACCESS ON
    const BbFpEnv saved = bb_fp_enter(mxcsr);
    const BbVec result = bb_fp_binary_in_env(a, b, kind, dbl, lanes, mxcsr);
    bb_fp_leave(saved);
    return result;
}

static inline BbVec bb_fp_sqrt(BbVec r, BbVec s, int dbl, int lanes, uint32_t mxcsr) {
#pragma STDC FENV_ACCESS ON
    const BbFpEnv saved = bb_fp_enter(mxcsr);
    for (int i = 0; i < lanes; ++i) {
        if (dbl) {
            const double x = bb_fp_input64(s.fd[i], mxcsr);
            r.fd[i] = bb_fp_result64(sqrt(x), x, x, mxcsr);
        } else {
            const float x = bb_fp_input32(s.f[i], mxcsr);
            r.f[i] = bb_fp_result32(sqrtf(x), x, x, mxcsr);
        }
    }
    bb_fp_leave(saved);
    return r;
}

static inline __attribute__((always_inline)) BbVec bb_fp_convert_in_env(BbVec r, BbVec s, BbFpFormat from, BbFpFormat to,
                                  int lanes, int truncate, uint32_t mxcsr) {
#pragma STDC FENV_ACCESS ON
    for (int i = 0; i < lanes; ++i) {
        if (from == BB_FP_I32 || from == BB_FP_I64) {
            if (to == BB_FP_F32) {
                if (from == BB_FP_I32) r.f[i] = (float)s.sd[i];
                else r.f[i] = (float)s.sq[i];
            } else {
                if (from == BB_FP_I32) r.fd[i] = (double)s.sd[i];
                else r.fd[i] = (double)s.sq[i];
            }
            continue;
        }
        const double x = from == BB_FP_F64 ? bb_fp_input64(s.fd[i], mxcsr) : bb_fp_input32(s.f[i], mxcsr);
        if (to == BB_FP_I32 || to == BB_FP_I64) {
            const double rounded = truncate ? trunc(x) : nearbyint(x);
            /* Round before checking range; an out-of-range C cast is undefined. */
            if (to == BB_FP_I32) {
                r.sd[i] = INT32_MIN;
                if (rounded >= -0x1p31 && rounded < 0x1p31) r.sd[i] = (int32_t)rounded;
            } else {
                r.sq[i] = INT64_MIN;
                if (rounded >= -0x1p63 && rounded < 0x1p63) r.sq[i] = (int64_t)rounded;
            }
        } else if (to == BB_FP_F32) {
            float value = (float)x;
            BB_FP_FLUSH_TINY(value, (float)(x * 256), FLT_MIN);
            r.f[i] = bb_fp_result32(value, value, value, mxcsr);
        } else {
            r.fd[i] = bb_fp_result64(x, x, x, mxcsr);
        }
    }
    return r;
}

static inline BbVec bb_fp_convert(BbVec r, BbVec s, BbFpFormat from, BbFpFormat to,
                                  int lanes, int truncate, uint32_t mxcsr) {
#pragma STDC FENV_ACCESS ON
    const BbFpEnv saved = bb_fp_enter(mxcsr);
    const BbVec result = bb_fp_convert_in_env(r, s, from, to, lanes, truncate, mxcsr);
    bb_fp_leave(saved);
    return result;
}

static inline BbVec bb_fp_round(BbVec r, BbVec s, int dbl, int lanes, int imm, uint32_t mxcsr) {
#pragma STDC FENV_ACCESS ON
    uint32_t control = mxcsr;
    if (!(imm & 4)) control = (mxcsr & ~UINT32_C(0x6000)) | (uint32_t)(imm & 3) << 13;
    const BbFpEnv saved = bb_fp_enter(control);
    for (int i = 0; i < lanes; ++i) {
        if (dbl) {
            const double x = bb_fp_input64(s.fd[i], mxcsr);
            r.fd[i] = bb_fp_result64(nearbyint(x), x, x, mxcsr);
        } else {
            const float x = bb_fp_input32(s.f[i], mxcsr);
            r.f[i] = bb_fp_result32(nearbyintf(x), x, x, mxcsr);
        }
    }
    bb_fp_leave(saved);
    return r;
}

/* FMA in x86 operand order: d is the destination/first source. form is 132, 213 or 231. */
/* VFM*: Rosetta negates the first multiplicand and the addend before the fused operation, so a
 * negated NaN changes sign, then takes the first NaN of x, y, z in that order (not operand order). */
static inline BbVec bb_fp_fma_in_env(BbVec d, BbVec s2, BbVec s3, int form, int negate_product,
                              int negate_addend, int dbl, int lanes, uint32_t mxcsr) {
#pragma STDC FENV_ACCESS ON
    int processed = 0;
#if defined(__aarch64__)
    if (!dbl && lanes >= 4) {
        const BbVec *x = &s2, *y = &s3, *z = &d;
        if (form == 132) { x = &d; y = &s3; z = &s2; }
        else if (form == 213) { x = &s2; y = &d; z = &s3; }
        BbVec result = d;
        int regular = 1;
        for (int i = 0; i < lanes; i += 4) {
            float32x4_t a = vld1q_f32(x->f + i), b = vld1q_f32(y->f + i), c = vld1q_f32(z->f + i);
            if (!bb_fp_regular32(vreinterpretq_u32_f32(a), 0x00800000) ||
                !bb_fp_regular32(vreinterpretq_u32_f32(b), 0x00800000) ||
                !bb_fp_regular32(vreinterpretq_u32_f32(c), 0x00800000)) { regular = 0; break; }
            if (negate_product) a = vnegq_f32(a);
            if (negate_addend) c = vnegq_f32(c);
            const float32x4_t value = vfmaq_f32(c, a, b);
            if (!bb_fp_regular32(vreinterpretq_u32_f32(value), 0x00800001)) { regular = 0; break; }
            vst1q_f32(result.f + i, value);
        }
        if (regular) { d = result; processed = lanes; }
    }
#endif
    for (int i = processed; i < lanes; ++i) {
        if (dbl) {
            const double o[3] = {bb_fp_input64(d.fd[i], mxcsr), bb_fp_input64(s2.fd[i], mxcsr),
                                 bb_fp_input64(s3.fd[i], mxcsr)};
            double x = o[1], y = o[2], z = o[0];
            if (form == 132) { x = o[0]; y = o[2]; z = o[1]; }
            else if (form == 213) { x = o[1]; y = o[0]; z = o[2]; }
            if (negate_product) x = -x;
            if (negate_addend) z = -z;
            double nan = 0;
            if (bb_fp_nan64(x)) nan = x;
            else if (bb_fp_nan64(y)) nan = y;
            else if (bb_fp_nan64(z)) nan = z;
            double value = fma(x, y, z);
            BB_FP_FLUSH_TINY(value, fma(x * 256, y, z * 256), DBL_MIN);
            d.fd[i] = bb_fp_result64(value, nan, nan, mxcsr);
        } else {
            const float o[3] = {bb_fp_input32(d.f[i], mxcsr), bb_fp_input32(s2.f[i], mxcsr),
                                bb_fp_input32(s3.f[i], mxcsr)};
            float x = o[1], y = o[2], z = o[0];
            if (form == 132) { x = o[0]; y = o[2]; z = o[1]; }
            else if (form == 213) { x = o[1]; y = o[0]; z = o[2]; }
            if (negate_product) x = -x;
            if (negate_addend) z = -z;
            float nan = 0;
            if (bb_fp_nan32(x)) nan = x;
            else if (bb_fp_nan32(y)) nan = y;
            else if (bb_fp_nan32(z)) nan = z;
            float value = fmaf(x, y, z);
            BB_FP_FLUSH_TINY(value, fmaf(x * 256, y, z * 256), FLT_MIN);
            d.f[i] = bb_fp_result32(value, nan, nan, mxcsr);
        }
    }
    return d;
}

static inline BbVec bb_fp_fma(BbVec d, BbVec s2, BbVec s3, int form, int negate_product, int negate_addend, int dbl, int lanes, uint32_t mxcsr) {
#pragma STDC FENV_ACCESS ON
    const BbFpEnv saved = bb_fp_enter(mxcsr);
    const BbVec result = bb_fp_fma_in_env(d, s2, s3, form, negate_product, negate_addend, dbl, lanes, mxcsr);
    bb_fp_leave(saved);
    return result;
}

/* RCPPS/RSQRTPS as the Rosetta reference computes them: the reciprocal (root) of the midpoint
 * of the input's top-12-bit mantissa interval, rounded to 12 bits, with denormal inputs read as
 * zero and denormal results flushed. MXCSR has no effect. */
static inline float bb_fp_approx32(float value, int root) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    const uint32_t sign = bits & 0x80000000, exponent = bits >> 23 & 0xff;
    if (exponent == 0xff && (bits & 0x7fffff)) bits |= 0x00400000;
    else if (exponent && root && sign) bits = 0xffc00000;
    else if (exponent == 0xff) bits = sign;
    else if (!exponent) bits = sign | 0x7f800000;
    else {
        const int scale = (int)exponent - 127;
        double middle = 1 + ((bits >> 11 & 0xfff) + 0.5) / 4096;
        double result;
        if (root) {
            if (scale & 1) middle *= 2;
            result = ldexp(floor(8192 / sqrt(middle) + 0.5) / 8192, -(scale >> 1));
        } else {
            result = ldexp(floor(8192 / middle + 0.5) / 8192, -scale);
        }
        if (result < 0x1p-126) result = 0;
        const float rounded = (float)result;
        memcpy(&bits, &rounded, sizeof(bits));
        bits |= sign;
    }
    memcpy(&value, &bits, sizeof(bits));
    return value;
}

static inline BbVec bb_fp_approx(BbVec r, BbVec s, int root, int lanes) {
    const BbFpEnv saved = bb_fp_enter(0x1f80);
    for (int i = 0; i < lanes; ++i) r.f[i] = bb_fp_approx32(s.f[i], root);
    bb_fp_leave(saved);
    return r;
}

/* Host SSE arithmetic: plain host operations in the host's
 * default environment (round to nearest, no flushing). Generated code uses these only while the
 * guest rounds to nearest without DAZ; otherwise, and with SS_FP_EXACT=1, it uses the exact helpers above.
 * NaN encodings and operand priority follow the host and FTZ/DAZ are not applied; RCP/RSQRT
 * keep the reference 12-bit approximation. Integer-visible
 * semantics stay: MIN/MAX operand selection and the integer indefinite for invalid conversions. */
static inline __attribute__((always_inline)) BbVec bb_fp_binary_host(BbVec a, BbVec b, int kind, int dbl, int lanes) {
    BbVec r = a;
    for (int i = 0; i < lanes; ++i) {
        if (dbl) {
            const double x = a.fd[i], y = b.fd[i];
            switch (kind) {
            case BB_FP_ADD: r.fd[i] = x + y; break;
            case BB_FP_SUB: r.fd[i] = x - y; break;
            case BB_FP_MUL: r.fd[i] = x * y; break;
            case BB_FP_DIV: r.fd[i] = x / y; break;
            case BB_FP_MIN: r.fd[i] = x < y ? x : y; break;
            default: r.fd[i] = x > y ? x : y; break;
            }
        } else {
            const float x = a.f[i], y = b.f[i];
            switch (kind) {
            case BB_FP_ADD: r.f[i] = x + y; break;
            case BB_FP_SUB: r.f[i] = x - y; break;
            case BB_FP_MUL: r.f[i] = x * y; break;
            case BB_FP_DIV: r.f[i] = x / y; break;
            case BB_FP_MIN: r.f[i] = x < y ? x : y; break;
            default: r.f[i] = x > y ? x : y; break;
            }
        }
    }
    return r;
}

static inline __attribute__((always_inline)) BbVec bb_fp_sqrt_host(BbVec r, BbVec s, int dbl, int lanes) {
    for (int i = 0; i < lanes; ++i) {
        if (dbl) r.fd[i] = __builtin_sqrt(s.fd[i]);
        else r.f[i] = __builtin_sqrtf(s.f[i]);
    }
    return r;
}

static inline __attribute__((always_inline)) BbVec bb_fp_approx_host(BbVec r, BbVec s, int root, int lanes) {
    /* The host environment is the default one bb_fp_approx enters, so the 12-bit reference
     * approximation (denormal inputs read as zero) costs no FPCR access. */
    for (int i = 0; i < lanes; ++i) r.f[i] = bb_fp_approx32(s.f[i], root);
    return r;
}

static inline __attribute__((always_inline)) BbVec bb_fp_convert_host(BbVec r, BbVec s, BbFpFormat from, BbFpFormat to,
                                                                      int lanes, int truncate) {
    for (int i = 0; i < lanes; ++i) {
        if (from == BB_FP_I32 || from == BB_FP_I64) {
            const int64_t value = from == BB_FP_I32 ? (int64_t)s.sd[i] : s.sq[i];
            if (to == BB_FP_F32) r.f[i] = from == BB_FP_I32 ? (float)s.sd[i] : (float)value;
            else r.fd[i] = from == BB_FP_I32 ? (double)s.sd[i] : (double)value;
            continue;
        }
        const double x = from == BB_FP_F64 ? s.fd[i] : (double)s.f[i];
        if (to == BB_FP_I32 || to == BB_FP_I64) {
            const double rounded = truncate ? __builtin_trunc(x) : __builtin_rint(x);
            if (to == BB_FP_I32) r.sd[i] = rounded >= -0x1p31 && rounded < 0x1p31 ? (int32_t)rounded : INT32_MIN;
            else r.sq[i] = rounded >= -0x1p63 && rounded < 0x1p63 ? (int64_t)rounded : INT64_MIN;
        } else if (to == BB_FP_F32) {
            r.f[i] = (float)x;
        } else {
            r.fd[i] = x;
        }
    }
    return r;
}

static inline __attribute__((always_inline)) BbVec bb_fp_fma_host(BbVec d, BbVec s2, BbVec s3, int form, int negate_product,
                                                                  int negate_addend, int dbl, int lanes) {
    const BbVec *x = &s2, *y = &s3, *z = &d;
    if (form == 132) { x = &d; y = &s3; z = &s2; }
    else if (form == 213) { x = &s2; y = &d; z = &s3; }
    BbVec r = d;
    for (int i = 0; i < lanes; ++i) {
        if (dbl) {
            const double p = negate_product ? -x->fd[i] : x->fd[i], q = negate_addend ? -z->fd[i] : z->fd[i];
            r.fd[i] = __builtin_fma(p, y->fd[i], q);
        } else {
            const float p = negate_product ? -x->f[i] : x->f[i], q = negate_addend ? -z->f[i] : z->f[i];
            r.f[i] = __builtin_fmaf(p, y->f[i], q);
        }
    }
    return r;
}
#endif
