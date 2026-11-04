/* The runtime interface of recompiled game code (docs/RECOMPILATION.md): what the C written by
 * tools/recomp/bbrecomp.c includes, and what the program (the game, tools/recomp/replay.c) gives it.
 *
 * A recompiled function takes the guest CPU state at the function's entry (its return address on
 * top of the guest stack) and returns with cpu->rip at the address it returned to, as the guest
 * code does. Guest registers live in locals inside; the CPU flags are computed lazily (RcFlags):
 * clang drops what no instruction reads. */
#ifndef BB_RECOMP_RC_H
#define BB_RECOMP_RC_H
#include "../cpu/cpu_internal.h"
#include "../cpu/fp.h"

#ifdef __cplusplus
extern "C" {
#endif

#define BB_RECOMP_API_VERSION 4u
#define BB_RECOMP_INIT "bb_recomp_init"

typedef struct {
    uint32_t version;
    uint64_t image_base;
    /* Runs the guest instruction at cpu->rip (the interpreter); returns the next rip. */
    uint64_t (*step)(BbCpu *cpu);
    /* A call of guest `target` returning to `next` (nothing pushed yet); cpu->rip is `next` after. */
    void (*call)(BbCpu *cpu, uint64_t target, uint64_t next);
    /* A tail call of cpu->rip (the function's return address on top of the stack); cpu->rip is
     * where it returned to after. */
    void (*tail)(BbCpu *cpu);
    /* The rest of the function from cpu->rip in the translator (its return address at entry_rsp);
     * cpu->rip is where it returned to after. */
    void (*bail)(BbCpu *cpu, uint64_t entry_rsp);
    /* Code generated with BB_RECOMP_TRACE=1 calls this before each instruction (its image
     * offset, the guest registers): tools/recomp/replay.c --lockstep. NULL elsewhere. */
    void (*trace)(uint64_t offset, const uint64_t r[16], const BbCpu *cpu);
} RcApi;

#ifndef BB_CPU_TRACE_H
typedef void (*RcFn)(BbCpu *cpu);
#endif
/* A recompiled function: its image offset and size, and the hash of the code it was generated
 * from (bbcpu_recomp_hash): a function the game's patches changed is left to the translator.
 * `direct`: the slot the library's own calls of it go through, NULL until the program sets it to
 * `fn` (the functions it runs); empty, they go through RcApi.call. */
typedef struct { uint64_t offset, size, hash; RcFn fn; RcFn *direct; } RcFunction;
/* The library's entry point: keeps `api`, returns its functions. */
typedef const RcFunction *(*RcInit)(const RcApi *api, size_t *count);

/* ---- for generated code ---- */

/* Host SSE arithmetic: generated FP instructions use the plain host helpers
 * (fp.h, bb_fp_*_host) while (c->mxcsr & rc_fp_mask) == 0, that is while the guest rounds to
 * nearest without DAZ (0x6040; the game sets only FTZ, which host mode does not apply). The library's init sets the mask; SS_FP_EXACT=1 makes it ~0, keeping every operation
 * on the exact path for bisecting and comparisons with the original. */
extern __attribute__((visibility("hidden"))) uint32_t rc_fp_mask;
static inline int rc_fp_exact(void) {
    const char *value = getenv("SS_FP_EXACT");
    return value && value[0] == '1';
}

/* Host math replacements: a game math routine the generator recognizes by
 * address and byte hash gets a guarded host entry. SS_FP_EXACT=1 or SS_HOST_MATH_OFF=all turns
 * every one off, SS_HOST_MATH_OFF=0xb5380,... the listed ones; the lifted original then runs. */
static inline int rc_env_lists(const char *name, uint64_t rva) {
    const char *list = getenv(name);
    if (!list) return 0;
    if (!strcmp(list, "all")) return 1;
    for (const char *at = list; *at;) {
        char *end;
        const unsigned long long value = strtoull(at, &end, 16);
        if (end == at) break;
        if (value == rva) return 1;
        at = *end == ',' ? end + 1 : end;
    }
    return 0;
}
static inline int rc_host_math(uint64_t rva) { return !rc_fp_exact() && !rc_env_lists("SS_HOST_MATH_OFF", rva); }

/* E5 fast kernels: a second, guarded version of a selected function (vector registers in
 * locals, host FP only); SS_FP_EXACT=1 or SS_FAST_OFF=all|0x32f7b0,... run the normal one. */
static inline int rc_fast(uint64_t rva) { return !rc_fp_exact() && !rc_env_lists("SS_FAST_OFF", rva); }

/* Generated-code hooks: vector registers live in the context; a fast kernel redefines these to
 * locals with explicit write-back/reload, and RC_FP_HOST to always take the host FP path. */
#define RC_V c->v
#define VSPILL
#define VRELOAD
#define RC_FP_HOST if (!(c->mxcsr & fp_mask))

/* Lazy flags: the last flag-setting operation and its operands, or FK_CPU (in cpu->flags). */
enum { FK_CPU, FK_ADD, FK_SUB, FK_LOGIC, FK_INC, FK_DEC };
static inline uint64_t rc_mask(int size) { return size >= 8 ? ~UINT64_C(0) : (UINT64_C(1) << (size * 8)) - 1; }

/* RFLAGS from the lazy state (as the interpreter computes them). */
static inline uint64_t rc_flags(int kind, uint64_t a, uint64_t b, uint64_t r, int size, int saved_cf,
                                uint64_t cpu_flags) {
    if (kind == FK_CPU) return cpu_flags;
    const uint64_t m = rc_mask(size), sign = UINT64_C(1) << (size * 8 - 1);
    a &= m; b &= m; r &= m;
    uint64_t f = cpu_flags & ~(uint64_t)F_ARITH;
    int cf = 0, of = 0, af = 0;
    switch (kind) {
    case FK_ADD: cf = r < a; of = ((a ^ r) & (b ^ r) & sign) != 0; af = ((a ^ b ^ r) & 0x10) != 0; break;
    case FK_SUB: cf = a < b; of = ((a ^ b) & (a ^ r) & sign) != 0; af = ((a ^ b ^ r) & 0x10) != 0; break;
    case FK_INC: cf = saved_cf; of = r == sign; af = ((a ^ 1 ^ r) & 0x10) != 0; break;
    case FK_DEC: cf = saved_cf; of = r == sign - 1; af = ((a ^ 1 ^ r) & 0x10) != 0; break;
    default: break; /* FK_LOGIC: CF, OF, AF clear */
    }
    if (cf) f |= F_CF;
    if (of) f |= F_OF;
    if (af) f |= F_AF;
    if (!r) f |= F_ZF;
    if (r & sign) f |= F_SF;
    if (!__builtin_parity((unsigned)(r & 0xff))) f |= F_PF;
    return f;
}

/* Condition code cc (0 o, 1 no, 2 b, 3 nb, 4 z, ... 15 nle) of the lazy state. */
static inline int rc_cond(int cc, int kind, uint64_t a, uint64_t b, uint64_t r, int size, int saved_cf,
                          uint64_t cpu_flags) {
    const uint64_t f = rc_flags(kind, a, b, r, size, saved_cf, cpu_flags);
    const int cf = !!(f & F_CF), zf = !!(f & F_ZF), sf = !!(f & F_SF), of = !!(f & F_OF), pf = !!(f & F_PF);
    int v;
    switch (cc >> 1) {
    case 0: v = of; break;
    case 1: v = cf; break;
    case 2: v = zf; break;
    case 3: v = cf || zf; break;
    case 4: v = sf; break;
    case 5: v = pf; break;
    case 6: v = sf != of; break;
    default: v = zf || sf != of; break;
    }
    return (cc & 1) ? !v : v;
}

/* Guest memory: x86 ordering between threads (bb_load/bb_store: acquire/release). The stack too:
 * other threads read and write structures on it (the game's jobs report into their creator's
 * stack), so plain accesses there let the compiler reorder or merge what another thread sees. */
static inline uint64_t rc_ld(uint64_t address, int size) { return bb_load(address, size); }
static inline void rc_st(uint64_t address, int size, uint64_t value) { bb_store(address, size, value); }
static inline uint64_t rc_lds(uint64_t address, int size) { return bb_load(address, size); }
static inline void rc_sts(uint64_t address, int size, uint64_t value) { bb_store(address, size, value); }

/* One atomic compare-and-exchange (lock prefixes; the interpreter's atomic_cas): *seen gets the
 * value the operation found. x86 locked instructions are full barriers, but on arm64 a failed CAS
 * only acquires and plain (vector, unaligned) stores before it may pass it: explicit barriers, as
 * bbcpu_step_insn. */
static inline int rc_cas(uint64_t address, int size, uint64_t expected, uint64_t desired, uint64_t *seen) {
    int ok;
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    switch (size) {
    case 1: { uint8_t e = (uint8_t)expected; ok = __atomic_compare_exchange_n((uint8_t *)address, &e, (uint8_t)desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); *seen = e; break; }
    case 2: { uint16_t e = (uint16_t)expected; ok = __atomic_compare_exchange_n((uint16_t *)address, &e, (uint16_t)desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); *seen = e; break; }
    case 4: { uint32_t e = (uint32_t)expected; ok = __atomic_compare_exchange_n((uint32_t *)address, &e, (uint32_t)desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); *seen = e; break; }
    default: { uint64_t e = expected; ok = __atomic_compare_exchange_n((uint64_t *)address, &e, desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); *seen = e; break; }
    }
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    return ok;
}

/* SZP of a result into flags f (the interpreter's set_szp). */
static inline uint64_t rc_szp(uint64_t f, uint64_t r, int size) {
    r &= rc_mask(size);
    f &= ~(uint64_t)(F_ZF | F_SF | F_PF);
    if (!r) f |= F_ZF;
    if (r & (UINT64_C(1) << (size * 8 - 1))) f |= F_SF;
    if (!__builtin_parity((unsigned)(r & 0xff))) f |= F_PF;
    return f;
}

/* Flags after adc (sub = 0) or sbb (sub = 1) of a and b with carry giving r (the interpreter's). */
static inline uint64_t rc_carry_flags(uint64_t f, int sub, uint64_t a, uint64_t b, uint64_t carry, uint64_t r, int size) {
    const uint64_t m = rc_mask(size), sign = UINT64_C(1) << (size * 8 - 1);
    a &= m; b &= m; r &= m;
    f &= ~(uint64_t)F_ARITH;
    if (sub ? (carry ? a <= b : a < b) : (carry ? r <= a : r < a)) f |= F_CF;
    if (sub ? ((a ^ b) & (a ^ r) & sign) : ((a ^ r) & (b ^ r) & sign)) f |= F_OF;
    if ((a ^ b ^ r) & 0x10) f |= F_AF;
    return rc_szp(f, r, size);
}

/* Flags after shl/shr/sar of `a` by `count` (masked, non-zero) giving `r` (the interpreter's). */
static inline uint64_t rc_shift_flags(uint64_t f, int kind, uint64_t a, unsigned count, uint64_t r, int size) {
    const int bits = size * 8;
    const uint64_t sign = UINT64_C(1) << (bits - 1);
    int cf;
    f &= ~(uint64_t)(F_CF | F_OF);
    if (kind == 0) { /* shl */
        cf = count <= (unsigned)bits && ((a >> (bits - count)) & 1);
        if (((r & sign) != 0) != cf) f |= F_OF;
    } else if (kind == 1) { /* shr */
        cf = (int)((a >> (count - 1)) & 1);
        if (a & sign) f |= F_OF;
    } else { /* sar: a sign-extended */
        cf = (int)(((int64_t)a >> (count - 1)) & 1);
    }
    if (cf) f |= F_CF;
    return rc_szp(f, r, size);
}

/* Vector operands (the interpreter's vread/vwrite): memory loads and stores with x86 ordering;
 * a register destination gets `bytes`, VEX forms zeros above them. */
static inline BbVec rc_vld(uint64_t address, int size) {
    BbVec v;
    memset(&v, 0, sizeof(v));
    memcpy(v.b, (const void *)address, (size_t)size);
    bb_fence_load();
    return v;
}
static inline void rc_vst(uint64_t address, int size, BbVec v) {
    bb_fence_store();
    memcpy((void *)address, v.b, (size_t)size);
}
static inline void rc_vset(BbVec *d, BbVec v, int bytes, int vex) {
    memcpy(d->b, v.b, (size_t)bytes);
    if (vex && bytes < 32) memset(d->b + bytes, 0, (size_t)(32 - bytes));
}
static inline BbVec rc_vgpr(uint64_t value) {
    BbVec v;
    memset(&v, 0, sizeof(v));
    v.q[0] = value;
    return v;
}

typedef struct { uint64_t address, count; int found; } RcScan;
/* Keep the ordered scan's pointer out of the surrounding function's register pressure. */
static __attribute__((noinline, unused)) RcScan rc_scan64(uint64_t address, uint64_t count, uint64_t value) {
    do {
        if (rc_ld(address, 8) == value) return (RcScan){address, count, 1};
        address += 8;
    } while (--count);
    return (RcScan){address, count, 0};
}

/* cmpps predicates (the interpreter's fcompare). */
static inline int rc_fcompare(double a, double b, int predicate) {
    const int unordered = a != a || b != b;
    int r;
    switch (predicate & 7) {
    case 0: r = !unordered && a == b; break;
    case 1: r = !unordered && a < b; break;
    case 2: r = !unordered && a <= b; break;
    case 3: r = unordered; break;
    case 4: r = unordered || a != b; break;
    case 5: r = unordered || !(a < b); break;
    case 6: r = unordered || !(a <= b); break;
    default: r = !unordered; break;
    }
    if (predicate & 8) {
        switch (predicate & 7) {
        case 0: r = unordered || a == b; break;
        case 1: r = unordered || !(a >= b); break;
        case 2: r = unordered || !(a > b); break;
        case 3: r = 0; break;
        case 4: r = !unordered && a != b; break;
        case 5: r = !unordered && a >= b; break;
        case 6: r = !unordered && a > b; break;
        default: r = 1; break;
        }
    }
    return r;
}

/* comiss/ucomiss flags (the interpreter's comis). */
static inline uint64_t rc_comis(uint64_t f, double a, double b) {
    f &= ~(uint64_t)F_ARITH;
    if (a != a || b != b) f |= F_ZF | F_PF | F_CF;
    else if (a < b) f |= F_CF;
    else if (a == b) f |= F_ZF;
    return f;
}

#ifdef __cplusplus
}
#endif
#endif
