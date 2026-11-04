#include "../src/cpu/fp.h"
#include <assert.h>
#include <stdio.h>

static void check_environment(const fenv_t *before) {
    fenv_t after = {0};
    assert(fegetenv(&after) == 0);
    assert(memcmp(before, &after, sizeof(after)) == 0);
}

int main(void) {
    fenv_t original;
    assert(fegetenv(&original) == 0);
    unsigned checks = 0;
    BbVec approx_in = {0}, approx_want[2];
    approx_in.d[0] = 0x3f800000; approx_in.d[1] = 0x3f9fffff; approx_in.d[2] = 0x7f7fffff; approx_in.d[3] = 0x40490fdb;
    for (int root = 0; root < 2; ++root) approx_want[root] = bb_fp_approx((BbVec){0}, approx_in, root, 4);
    for (int flush = 0; flush < 2; ++flush) {
        const fenv_t *environment = FE_DFL_ENV;
        if (flush) environment = FE_DFL_DISABLE_DENORMS_ENV;
        assert(fesetenv(environment) == 0 && fesetround(FE_DOWNWARD) == 0);
        assert(feraiseexcept(FE_INEXACT | FE_DIVBYZERO) == 0);
        for (unsigned mode = 0; mode < 16; ++mode) {
            uint32_t mxcsr = 0x1f80 | (mode & 3) << 13;
            if (mode & 4) mxcsr |= 0x8000;
            if (mode & 8) mxcsr |= 0x40;
            for (int kind = BB_FP_ADD; kind <= BB_FP_MAX + 1; ++kind) {
                for (int dbl = 0; dbl < 2; ++dbl) {
                    BbVec a = {0}, b = {0};
                    if (dbl) {
                        a.q[0] = UINT64_C(0x7ff0000000000001);
                        b.q[0] = UINT64_C(0x3ff0000000000000);
                        a.q[1] = UINT64_C(0x0010000000000000);
                        b.q[1] = UINT64_C(0x3fe0000000000000);
                    } else {
                        a.d[0] = 0x7f800001; b.d[0] = 0x3f800000;
                        a.d[1] = 0x00800000; b.d[1] = 0x3f000000;
                        a.d[2] = 0x3f800000; b.d[2] = 0x33800000;
                        a.d[3] = 0x7f7fffff; b.d[3] = 0x40000000;
                    }
                    fenv_t before = {0};
                    assert(fegetenv(&before) == 0);
                    const int lanes = dbl ? 2 : 4;
                    volatile BbVec result;
                    if (kind <= BB_FP_MAX) result = bb_fp_binary(a, b, kind, dbl, lanes, mxcsr);
                    else result = bb_fp_sqrt(a, a, dbl, lanes, mxcsr);
                    check_environment(&before);
                    (void)result;
                    ++checks;
                }
            }
            for (BbFpFormat from = BB_FP_F32; from <= BB_FP_I64; ++from) {
                for (BbFpFormat to = BB_FP_F32; to <= BB_FP_I64; ++to) {
                    if (from == to || (from >= BB_FP_I32 && to >= BB_FP_I32)) continue;
                    const int variants = from <= BB_FP_F64 && to >= BB_FP_I32 ? 2 : 1;
                    for (int truncate = 0; truncate < variants; ++truncate) {
                        BbVec s = {0};
                        if (from == BB_FP_F32) {
                            s.d[0] = 0x7f800001; s.d[1] = 1;
                            s.d[2] = 0x3fc00000; s.d[3] = 0x7f7fffff;
                        } else if (from == BB_FP_F64) {
                            s.q[0] = UINT64_C(0x7ff0000000000001);
                            s.q[1] = UINT64_C(0x3690000000000001);
                        } else if (from == BB_FP_I32) {
                            s.sd[0] = INT32_MAX; s.sd[1] = INT32_MIN;
                            s.sd[2] = 16777217; s.sd[3] = -16777217;
                        } else {
                            s.sq[0] = INT64_MAX; s.sq[1] = INT64_MIN;
                        }
                        const int wide = from == BB_FP_F64 || from == BB_FP_I64 || to == BB_FP_F64 || to == BB_FP_I64;
                        const int lanes = wide ? 2 : 4;
                        fenv_t before = {0};
                        assert(fegetenv(&before) == 0);
                        volatile BbVec result = bb_fp_convert((BbVec){0}, s, from, to, lanes, truncate, mxcsr);
                        check_environment(&before);
                        (void)result;
                        ++checks;
                    }
                }
            }
            for (int dbl = 0; dbl < 2; ++dbl) {
                BbVec s = {0};
                if (dbl) {
                    s.q[0] = UINT64_C(0x3fe0000000000000);
                    s.q[1] = UINT64_C(0xbff8000000000000);
                    s.q[2] = 1;
                    s.q[3] = UINT64_C(0x7ff0000000000001);
                } else {
                    s.d[0] = 0x3f000000; s.d[1] = 0xbfc00000;
                    s.d[2] = 1; s.d[3] = 0x7f800001;
                    s.d[4] = 0x80000000; s.d[5] = 0x7f7fffff;
                    s.d[6] = 0xff800000; s.d[7] = 0x7fc12345;
                }
                for (int imm = 0; imm < 16; ++imm) {
                    fenv_t before = {0};
                    assert(fegetenv(&before) == 0);
                    const int lanes = dbl ? 4 : 8;
                    volatile BbVec result = bb_fp_round((BbVec){0}, s, dbl, lanes, imm, mxcsr);
                    check_environment(&before);
                    (void)result;
                    ++checks;
                }
            }
            for (int dbl = 0; dbl < 2; ++dbl) {
                BbVec a = {0}, b = {0}, c = {0};
                if (dbl) {
                    a.q[0] = UINT64_C(0x3ff0000000000001); b.q[0] = UINT64_C(0x3feffffffffffffe);
                    c.q[0] = UINT64_C(0xbff0000000000000); a.q[1] = UINT64_C(0x7ff0000000000000);
                } else {
                    a.d[0] = 0x3f800001; b.d[0] = 0x3f7ffffe; c.d[0] = 0xbf800000;
                    a.d[1] = 0x7f800000; a.d[2] = 0x00800000; b.d[2] = 0x3f000000; c.d[2] = 1;
                    a.d[3] = 0x7f7fffff; b.d[3] = 0x40000000; c.d[3] = 0x7f7fffff;
                }
                for (int form = 0; form < 3; ++form) {
                    fenv_t before = {0};
                    assert(fegetenv(&before) == 0);
                    const int order[] = {132, 213, 231};
                    volatile BbVec result = bb_fp_fma(a, b, c, order[form], form & 1, form != 1, dbl, dbl ? 2 : 4, mxcsr);
                    check_environment(&before);
                    (void)result;
                    ++checks;
                }
            }
            for (int lanes = 4; lanes <= 8; lanes += 4) {
                BbVec a = {0}, b = {0}, c = {0};
                for (int i = 0; i < lanes; ++i) {
                    a.f[i] = b.f[i] = 1.0f;
                    c.f[i] = 0x1p-24f;
                }
                const int order[] = {132, 213, 231};
                for (int form = 0; form < 3; ++form) {
                    fenv_t before = {0};
                    assert(fegetenv(&before) == 0);
                    volatile BbVec result = bb_fp_fma(a, b, c, order[form], form & 1, form != 1, 0, lanes, mxcsr);
                    check_environment(&before);
                    (void)result;
                    ++checks;
                }
            }
            /* Approximations ignore MXCSR but must not depend on host rounding or leak inexact flags,
             * so check with host flags both cleared and already raised. */
            for (int raised = 0; raised < 2; ++raised) {
                assert(feclearexcept(FE_ALL_EXCEPT) == 0);
                if (raised) assert(feraiseexcept(FE_INEXACT | FE_DIVBYZERO) == 0);
                for (int root = 0; root < 2; ++root) {
                    fenv_t before = {0};
                    assert(fegetenv(&before) == 0);
                    const BbVec result = bb_fp_approx((BbVec){0}, approx_in, root, 4);
                    check_environment(&before);
                    assert(memcmp(&result, &approx_want[root], sizeof(result)) == 0);
                    ++checks;
                }
            }
        }
    }
    assert(fesetenv(&original) == 0);
    printf("FP environment preserved across %u calls\n", checks);
    return 0;
}
