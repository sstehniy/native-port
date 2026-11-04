/* tests/fuzz_recomp.c (arm64): differential fuzzing of the recompiler's C (tools/recomp/bbrecomp.c)
 * against the interpreter, one instruction at a time, as tests/fuzz_jit.c does for the JIT.
 * Input: instructions (hex bytes per line: tools/cpu/encodings.c) and the library bbrecomp
 * --snippets made of them (a function per line it translates natively). Each runs from random
 * register, flag, vector and memory states through bbcpu_step_insn and through its generated
 * function; registers, the flags x86 defines for it, vector registers and memory must match.
 * Usage: fuzz_recomp FILE LIB [trials] [max reports] [X86_ORACLE]. The optional oracle replaces
 * the interpreter reference, and also checks forms using interpreter fallbacks. */
#include <Zydis/Zydis.h>
#include <inttypes.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include "../src/cpu/bbcpu.h"
#include "../src/cpu/cpu_internal.h"
#include "../src/cpu/trace.h"
#include "../src/recomp/rc.h"
#include <dlfcn.h>
#include <sys/wait.h>
#include "x86_oracle.h"

uint64_t bb_image_base; /* platform.c in the game: fault reports */

void *runtime_low_map(size_t size, int prot) {
    void *p = mmap(NULL, size, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}

#define CODE_AT UINT64_C(0x30000000000)
#define SCRATCH_AT UINT64_C(0x31000000000)
enum { SCRATCH = 1 << 16, RIP_SIZE = 1 << 15 };
/* Memory for a rip-relative operand: 32 KiB at its target page (rip_at), random like the scratch. */
static uint8_t *rip_mem;
/* Where the instruction under test runs: CODE_AT, or a few bytes past it so that a rip-relative
 * atomic reaches a naturally aligned target, as it does at its real address (arm64 faults on
 * atomics that cross 16 bytes). The generated code reads it as rc->image_base. */
static uint64_t code_at = CODE_AT;
static uint64_t rip_at;
static int uses_rip;
static int oracle_mode;
static uint64_t branch_target;
static sigjmp_buf snippet_done;

static int map_rip_target(uint64_t target) {
    const uint64_t page = target & ~UINT64_C(0x3fff);
    const uint64_t code_end = UINT64_C(0x30000000000) + 0x4000, scratch_end = UINT64_C(0x31000000000) + SCRATCH;
    if (page < code_end && page + RIP_SIZE > UINT64_C(0x30000000000)) return 0;
    if (page < scratch_end && page + RIP_SIZE > UINT64_C(0x31000000000)) return 0;
    if (target + 32 > page + RIP_SIZE) return 0;
    if (rip_mem && rip_at == page) return 1;
    if (rip_mem) munmap(rip_mem, RIP_SIZE);
    rip_mem = mmap((void *)page, RIP_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    if (rip_mem == MAP_FAILED) { rip_mem = NULL; return 0; }
    rip_at = page;
    return 1;
}

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

static uint64_t interesting(void) {
    static const uint64_t v[] = {0, 1, 2, 7, 8, 31, 32, 63, 64, 0x7f, 0x80, 0xff, 0x100, 0x7fff, 0x8000,
                                 0xffff, 0x7fffffff, 0x80000000, 0xffffffff, 0x100000000ull,
                                 0x7fffffffffffffffull, 0x8000000000000000ull, ~0ull, ~0ull - 1};
    switch (rnd() % 4) {
    case 0: return v[rnd() % (sizeof(v) / sizeof(*v))];
    case 1: return rnd() & 0xff;
    case 2: return rnd() & 0xffffffff;
    default: return rnd();
    }
}
static uint32_t random_float_bits(void) {
    static const uint32_t v[] = {0, 0x80000000, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000,
                                 0x7fc00000, 0xffc00000, 0x7f800001, 0x00000001, 0x00800000,
                                 0x4f000000, 0xcf000000, 0x5f000000, 0x3f000000};
    switch (rnd() % 3) {
    case 0: return v[rnd() % (sizeof(v) / sizeof(*v))];
    case 1: { float f = (float)((int64_t)(rnd() % 2000001) - 1000000) / 64.0f; uint32_t u; memcpy(&u, &f, 4); return u; }
    default: return (uint32_t)rnd();
    }
}
static uint64_t random_double_bits(void) {
    switch (rnd() % 3) {
    case 0: { double d = (double)((int64_t)(rnd() % 2000001) - 1000000) / 64.0; uint64_t u; memcpy(&u, &d, 8); return u; }
    case 1: { static const uint64_t v[] = {0, 0x8000000000000000ull, 0x3ff0000000000000ull, 0x7ff0000000000000ull,
                                           0x7ff8000000000000ull, 0x41e0000000000000ull, 0xc3e0000000000000ull, 1};
              return v[rnd() % 8]; }
    default: return rnd();
    }
}

static int reg_index(ZydisRegister r) {
    if (r == ZYDIS_REGISTER_NONE) return -1;
    const ZydisRegister l = ZydisRegisterGetLargestEnclosing(ZYDIS_MACHINE_MODE_LONG_64, r);
    if (l >= ZYDIS_REGISTER_RAX && l <= ZYDIS_REGISTER_R15) return (int)(l - ZYDIS_REGISTER_RAX);
    return -2;
}

static sigjmp_buf crash_jump;
static volatile sig_atomic_t guarded;
static void on_crash(int sig) {
    if (guarded) siglongjmp(crash_jump, sig);
    signal(sig, SIG_DFL);
    raise(sig);
}

typedef struct {
    ZydisDecodedInstruction zi;
    ZydisDecodedOperand zo[ZYDIS_MAX_OPERAND_COUNT];
    uint32_t defined_flags;
} Insn;

/* Places operands in synthetic memory; native probes keep invalid absolute addresses as fault cases.
 * Returns 0 when memory operands have conflicting register constraints. */
static int place_memory(const Insn *x, BbCpu *cpu) {
    int seen_base = -1;
    for (int i = 0; i < x->zi.operand_count_visible; ++i) {
        const ZydisDecodedOperand *o = &x->zo[i];
        if (o->type != ZYDIS_OPERAND_TYPE_MEMORY || o->mem.type == ZYDIS_MEMOP_TYPE_AGEN) continue;
        if (o->mem.base == ZYDIS_REGISTER_RIP) {
            const int64_t disp = o->mem.disp.has_displacement ? o->mem.disp.value : 0;
            if (!map_rip_target(code_at + x->zi.length + (uint64_t)disp)) return 0;
            uses_rip = 1;
            continue;
        }
        const int base = reg_index(o->mem.base), index = reg_index(o->mem.index);
        if (base == -2 || index == -2) return 0;
        if (oracle_mode && o->mem.segment == ZYDIS_REGISTER_GS && base < 0 && index < 0 &&
            o->mem.disp.value >= 0 && o->mem.disp.value + o->size / 8 <= 128) {
            cpu->gs_base = SCRATCH_AT + 0x1000;
            continue;
        }
        if (o->mem.segment == ZYDIS_REGISTER_FS || o->mem.segment == ZYDIS_REGISTER_GS)
            cpu->fs_base = cpu->gs_base = 0;
        const int64_t disp = o->mem.disp.has_displacement ? o->mem.disp.value : 0;
        const uint64_t scale = o->mem.scale ? o->mem.scale : 1;
        uint64_t target = SCRATCH_AT + 0x2000 + rnd() % 0x6000;
        if (oracle_mode) target &= ~UINT64_C(31);
        /* Atomics are naturally aligned in real code (split locks are rare and slow on x86 too). */
        const int atomic = (x->zi.attributes & ZYDIS_ATTRIB_HAS_LOCK) || x->zi.mnemonic == ZYDIS_MNEMONIC_XCHG ||
                           x->zi.mnemonic == ZYDIS_MNEMONIC_CMPXCHG || x->zi.mnemonic == ZYDIS_MNEMONIC_XADD;
        if (atomic && o->size >= 16) target &= ~(uint64_t)(o->size / 8 - 1);
        if (base >= 0 && seen_base >= 0 && base != seen_base) return 0;
        if (oracle_mode && base == RSP && index >= 0 && index != RSP) {
            target -= (target - (uint64_t)disp - cpu->r[RSP]) % scale;
            cpu->r[index] = (target - (uint64_t)disp - cpu->r[RSP]) / scale;
        } else if (oracle_mode && base == RSP && index < 0 &&
                   (target - (uint64_t)disp < SCRATCH_AT + 0x100 ||
                    target - (uint64_t)disp > SCRATCH_AT + SCRATCH - 0x100)) {
            const uint64_t address = cpu->r[RSP] + (uint64_t)disp;
            if (address < SCRATCH_AT || address + 32 > SCRATCH_AT + SCRATCH) {
                if (!map_rip_target(address)) return 0;
                uses_rip = 1;
            }
        } else if (base >= 0 && base == index) {
            target -= (target - (uint64_t)disp) % (scale + 1);
            cpu->r[base] = (target - (uint64_t)disp) / (scale + 1);
        } else if (base >= 0) {
            if (index >= 0) cpu->r[index] = rnd() % 64;
            cpu->r[base] = target - (uint64_t)disp - (index >= 0 ? cpu->r[index] * scale : 0);
        } else if (index >= 0) {
            target -= (target - (uint64_t)disp) % scale;
            cpu->r[index] = (target - (uint64_t)disp) / scale;
        } else {
            if (!oracle_mode) return 0;
            /* Absolute null/noncanonical candidates must be observed faulting, not skipped. */
        }
        seen_base = base;
    }
    /* The stack must stay in the scratch area (push/pop, call). */
    if (cpu->r[RSP] < SCRATCH_AT + 0x100 || cpu->r[RSP] > SCRATCH_AT + SCRATCH - 0x100) return 0;
    return 1;
}

static void random_state(BbCpu *cpu, uint8_t *scratch) {
    for (int i = 0; i < 16; ++i) cpu->r[i] = interesting();
    cpu->r[RSP] = SCRATCH_AT + 0x8000 + (rnd() % 0x100) * 8;
    cpu->flags = 2 | (rnd() & 0x8d5);
    for (int i = 0; i < 16; ++i) {
        const int kind = (int)(rnd() % 3);
        for (int k = 0; k < 8; ++k) cpu->v[i].d[k] = kind == 0 ? random_float_bits() : (uint32_t)rnd();
        if (kind == 2) for (int k = 0; k < 4; ++k) cpu->v[i].q[k] = random_double_bits();
    }
    for (int i = 0; i < SCRATCH; i += 8) { uint64_t v = rnd(); memcpy(scratch + i, &v, 8); }
}

static void oracle_pack_inputs(const Insn *x, const BbInsn *in, BbCpu *cpu, int trial) {
    const int m = in->mnemonic;
    const int dwords = m == ZYDIS_MNEMONIC_PACKSSDW || m == ZYDIS_MNEMONIC_VPACKSSDW;
    if (!dwords && m != ZYDIS_MNEMONIC_PACKSSWB && m != ZYDIS_MNEMONIC_VPACKSSWB &&
        m != ZYDIS_MNEMONIC_PACKUSWB && m != ZYDIS_MNEMONIC_VPACKUSWB) return;
    if (trial >= 64) return;
    static const int32_t edges[] = {INT32_MIN, -32769, -32768, -32767, -129, -128, -127,
        -1, 0, 1, 126, 127, 128, 254, 255, 256, 32766, 32767, 32768, INT32_MAX};
    for (int i = 0; i < x->zi.operand_count_visible; ++i) {
        const BbOp *op = &in->op[i];
        if (!(x->zo[i].actions & ZYDIS_OPERAND_ACTION_MASK_READ)) continue;
        uint8_t *target;
        if (op->type == OP_REG && op->kind == RK_VEC) target = cpu->v[op->reg].b;
        else if (op->type == OP_MEM) target = (uint8_t *)bbcpu_addr(cpu, in, op);
        else continue;
        const int bytes = dwords ? 4 : 2;
        for (int lane = 0; lane < op->size / bytes; ++lane) {
            int32_t value = edges[(trial + i + lane) % (sizeof edges / sizeof *edges)];
            if (dwords) memcpy(target + lane * bytes, &value, bytes);
            else { const int16_t word = (int16_t)value; memcpy(target + lane * bytes, &word, bytes); }
        }
    }
}

static void oracle_fp_inputs(const Insn *x, const BbInsn *in, BbCpu *cpu, int trial) {
    static const uint32_t pairs32[][2] = {
        {0x3f800000, 0x33800000}, {0x00800000, 0x3f000000}, {0x007fffff, 0x00000001},
        {0x00800000, 0x40400000}, {0x7fc12345, 0xff812345}, {0x7f812345, 0xffc34567},
        {0x7f800000, 0}, {0x80000000, 0}, {0, 1}, {0x7f7fffff, 0x40000000},
        /* Tiny before rounding, smallest normal after: FTZ still flushes on x86. */
        {0x3f7fffff, 0x00800000}, {0x00800000, 0x3f800001}
    };
    static const uint64_t pairs64[][2] = {
        {UINT64_C(0x3ff0000000000000), UINT64_C(0x3ca0000000000000)},
        {UINT64_C(0x0010000000000000), UINT64_C(0x3fe0000000000000)},
        {UINT64_C(0x000fffffffffffff), 1}, {UINT64_C(0x0010000000000000), UINT64_C(0x4008000000000000)},
        {UINT64_C(0x7ff8123456789abc), UINT64_C(0xfff0123456789abc)},
        {UINT64_C(0x7ff0123456789abc), UINT64_C(0xfff83456789abcde)},
        {UINT64_C(0x7ff0000000000000), 0}, {UINT64_C(0x8000000000000000), 0},
        {0, 1}, {UINT64_C(0x7fefffffffffffff), UINT64_C(0x4000000000000000)},
        {UINT64_C(0x3fefffffffffffff), UINT64_C(0x0010000000000000)},
        {UINT64_C(0x0010000000000000), UINT64_C(0x3ff0000000000001)}
    };
    static const uint32_t convert32[][2] = {
        {0x3f000000, 0xbf000000},
        {0x3fc00000, 0xbfc00000},
        {0x4effffff, 0x4f000000},
        {0xcf000000, 0xcf000001},
        {0x00000001, 0x80000001},
        {0x00800000, 0x007fffff},
        {0x7f800000, 0xff800000},
        {0x7fc12345, 0xff812345},
        {0x7f7fffff, 0xff7fffff},
        {0x5effffff, 0x5f000000},
        {0xdf000000, 0xdf000001},
        {0x3f800001, 0xbf800001},
        {0x00000000, 0x80000000},
        {0x00800001, 0x80800001},
    };
    static const uint64_t convert64[][2] = {
        {UINT64_C(0x3fe0000000000000), UINT64_C(0xbfe0000000000000)},
        {UINT64_C(0x3ff8000000000000), UINT64_C(0xbff8000000000000)},
        {UINT64_C(0x41dffffffff00000), UINT64_C(0xc1e0000000180000)},
        {UINT64_C(0x41dfffffffe00000), UINT64_C(0xc1e0000000100000)},
        {UINT64_C(0x0000000000000001), UINT64_C(0x8000000000000001)},
        {UINT64_C(0x3690000000000000), UINT64_C(0x3690000000000001)},
        {UINT64_C(0x7ff0000000000000), UINT64_C(0xfff0000000000000)},
        {UINT64_C(0x7ff8123456789abc), UINT64_C(0xfff0123456789abc)},
        {UINT64_C(0x43dfffffffffffff), UINT64_C(0x43e0000000000000)},
        {UINT64_C(0x3ff0000010000000), UINT64_C(0xbff0000010000000)},
        {UINT64_C(0xc3e0000000000000), UINT64_C(0xc3e0000000000001)},
        {UINT64_C(0x7fefffffffffffff), UINT64_C(0xffefffffffffffff)},
        {UINT64_C(0x0010000000000000), UINT64_C(0x000fffffffffffff)},
        {UINT64_C(0x380fffffffffffff), UINT64_C(0xb80ffffff0000000)},
    };
    static const uint32_t integer32[][2] = {
        {0x00000000, 0x00000001},
        {0xffffffff, 0x00000002},
        {0x01000001, 0xfeffffff},
        {0x01000003, 0xfefffffd},
        {0x7fffffff, 0x80000000},
        {0x00ffffff, 0xff000001},
        {0x7fffff81, 0x8000007f},
        {0x7ffffd79, 0x80000287},
        {0x00000003, 0xfffffffd},
        {0x55555555, 0xaaaaaaab},
        {0x40000000, 0xc0000000},
        {0x40000001, 0xbfffffff},
        {0x01234567, 0xfedcba99},
        {0x80000001, 0x7ffffffe},
    };
    static const uint64_t integer64[][2] = {
        {UINT64_C(0x0000000000000000), UINT64_C(0x0000000000000001)},
        {UINT64_C(0xffffffffffffffff), UINT64_C(0x0000000000000002)},
        {UINT64_C(0x0000000001000001), UINT64_C(0xfffffffffeffffff)},
        {UINT64_C(0x0020000000000001), UINT64_C(0xffdfffffffffffff)},
        {UINT64_C(0x7fffffffffffffff), UINT64_C(0x8000000000000000)},
        {UINT64_C(0x001fffffffffffff), UINT64_C(0xffe0000000000001)},
        {UINT64_C(0x0020000000000003), UINT64_C(0xffdffffffffffffd)},
        {UINT64_C(0x4000000000000001), UINT64_C(0xbfffffffffffffff)},
        {UINT64_C(0x0000000000000003), UINT64_C(0xfffffffffffffffd)},
        {UINT64_C(0x5555555555555555), UINT64_C(0xaaaaaaaaaaaaaaab)},
        {UINT64_C(0x0040000000000001), UINT64_C(0xffbfffffffffffff)},
        {UINT64_C(0x3fffffffffffffff), UINT64_C(0xc000000000000001)},
        {UINT64_C(0x0123456789abcdef), UINT64_C(0xfedcba9876543211)},
        {UINT64_C(0x8000000000000001), UINT64_C(0x7ffffffffffffffe)},
    };
    /* Source-order triples: fused rounding, NaN priority, invalid products, signed zeros,
     * DAZ/FTZ underflow and overflow. Each is rotated across the three FMA operands. */
    static const uint32_t fused32[][3] = {
        {0x3f800001, 0x3f7ffffe, 0xbf800000}, {0x7fc11111, 0x7f822222, 0xffc33333},
        {0x3f800000, 0x7f812345, 0xffc54321}, {0x7f800000, 0x00000000, 0x7fc12345},
        {0x7f800000, 0x00000000, 0x3f800000}, {0x3f800000, 0xbf800000, 0x3f800000},
        {0x00800000, 0x3f000000, 0x00000001}, {0x7f7fffff, 0x40000000, 0xff7fffff},
        {0x3f800000, 0x3f800000, 0x007fffff}, {0x7f800000, 0xff800000, 0x3f800000},
        {0x80000000, 0x80000000, 0x80000000}, {0x3fffffff, 0x3fffffff, 0xc0800000},
        {0x1f800001, 0x1f800001, 0x80000000},
    };
    static const uint64_t fused64[][3] = {
        {UINT64_C(0x3ff0000000000001), UINT64_C(0x3feffffffffffffe), UINT64_C(0xbff0000000000000)},
        {UINT64_C(0x7ff8111111111111), UINT64_C(0x7ff0222222222222), UINT64_C(0xfff8333333333333)},
        {UINT64_C(0x3ff0000000000000), UINT64_C(0x7ff0123456789abc), UINT64_C(0xfff8987654321abc)},
        {UINT64_C(0x7ff0000000000000), 0, UINT64_C(0x7ff8123456789abc)},
        {UINT64_C(0x7ff0000000000000), 0, UINT64_C(0x3ff0000000000000)},
        {UINT64_C(0x3ff0000000000000), UINT64_C(0xbff0000000000000), UINT64_C(0x3ff0000000000000)},
        {UINT64_C(0x0010000000000000), UINT64_C(0x3fe0000000000000), 1},
        {UINT64_C(0x7fefffffffffffff), UINT64_C(0x4000000000000000), UINT64_C(0xffefffffffffffff)},
        {UINT64_C(0x3ff0000000000000), UINT64_C(0x3ff0000000000000), UINT64_C(0x000fffffffffffff)},
        {UINT64_C(0x7ff0000000000000), UINT64_C(0xfff0000000000000), UINT64_C(0x3ff0000000000000)},
        {UINT64_C(0x8000000000000000), UINT64_C(0x8000000000000000), UINT64_C(0x8000000000000000)},
        {UINT64_C(0x3fffffffffffffff), UINT64_C(0x3fffffffffffffff), UINT64_C(0xc010000000000000)},
        {UINT64_C(0x1ff0000000000001), UINT64_C(0x1ff0000000000001), UINT64_C(0x8000000000000000)},
    };
    const char *name = ZydisMnemonicGetString(x->zi.mnemonic);
    const char *base = name[0] == 'v' ? name + 1 : name;
    const int conversion = !strncmp(base, "cvt", 3);
    const int rounding = !strncmp(base, "round", 5);
    const int boundaries = conversion || rounding;
    const int fused = !strncmp(base, "fm", 2) || !strncmp(base, "fnm", 3);
    unsigned pair = (unsigned)trial / (boundaries ? 32 : 16);
    unsigned pairs = boundaries ? sizeof(convert32) / sizeof(*convert32) : sizeof(pairs32) / sizeof(*pairs32);
    if (fused) {
        pair = (unsigned)trial / 48;
        pairs = sizeof(fused32) / sizeof(*fused32);
    }
    if (pair >= pairs) return;
    unsigned source = 0;
    for (int i = 0; i < x->zi.operand_count_visible && i < in->count; ++i) {
        const ZydisDecodedOperand *op = &x->zo[i];
        if (!(op->actions & ZYDIS_OPERAND_ACTION_MASK_READ) || op->size > 256) continue;
        ZydisElementType element = op->element_type;
        /* Zydis labels legacy ROUNDSS/ROUNDSD data operands as integers. */
        if (rounding && op->type != ZYDIS_OPERAND_TYPE_IMMEDIATE) {
            element = ZYDIS_ELEMENT_TYPE_FLOAT32;
            if (base[strlen(base) - 1] == 'd') element = ZYDIS_ELEMENT_TYPE_FLOAT64;
        }
        const int integer = conversion && element == ZYDIS_ELEMENT_TYPE_INT;
        if (!integer && element != ZYDIS_ELEMENT_TYPE_FLOAT32 && element != ZYDIS_ELEMENT_TYPE_FLOAT64) continue;
        uint8_t *target;
        if (op->type == ZYDIS_OPERAND_TYPE_REGISTER) {
            const ZydisRegisterClass cls = ZydisRegisterGetClass(op->reg.value);
            const int reg = ZydisRegisterGetId(op->reg.value);
            if (reg < 0 || reg >= 16) continue;
            if (integer && (cls == ZYDIS_REGCLASS_GPR32 || cls == ZYDIS_REGCLASS_GPR64)) target = (uint8_t *)&cpu->r[reg];
            else if (cls == ZYDIS_REGCLASS_XMM || cls == ZYDIS_REGCLASS_YMM) target = cpu->v[reg].b;
            else continue;
        } else if (op->type == ZYDIS_OPERAND_TYPE_MEMORY) {
            const uint64_t at = bbcpu_addr(cpu, in, &in->op[i]);
            const unsigned size = op->size / 8;
            const int in_scratch = at >= SCRATCH_AT && at <= SCRATCH_AT + SCRATCH - size;
            const int in_rip = uses_rip && at >= rip_at && at <= rip_at + RIP_SIZE - size;
            if (!in_scratch && !in_rip) continue;
            target = (uint8_t *)at;
        } else continue;
        const int bytes = op->element_size == 64 ? 8 : 4;
        for (unsigned lane = 0; lane < op->size / (unsigned)(bytes * 8); ++lane) {
            unsigned choice = boundaries ? (source + lane + (unsigned)trial / 16) % 2 : source % 2;
            if (fused) choice = (source + lane + (unsigned)trial / 16) % 3;
            if (bytes == 8) {
                const uint64_t *values;
                if (fused) values = fused64[pair];
                else if (boundaries) values = integer ? integer64[pair] : convert64[pair];
                else values = pairs64[pair];
                memcpy(target + lane * 8, &values[choice], 8);
            } else {
                const uint32_t *values;
                if (fused) values = fused32[pair];
                else if (boundaries) values = integer ? integer32[pair] : convert32[pair];
                else values = pairs32[pair];
                memcpy(target + lane * 4, &values[choice], 4);
            }
        }
        ++source;
    }
}

/* FUZZ_FP_TOLERANCE=d18 accepts the documented D18 host-FP differences in vector lanes of the
 * destination's element width: two NaNs with different encodings, and a denormal or the
 * smallest normal against a zero (FTZ/DAZ not applied). Accepted lanes are counted and printed; everything else compares
 * bit-exactly. */
static int tolerance_width;
static uint64_t tolerated_nan, tolerated_flush;

static int tolerated_lane(uint64_t x, uint64_t y, int width) {
    const int mantissa_bits = width == 8 ? 52 : 23;
    const uint64_t sign = UINT64_C(1) << (width * 8 - 1), mantissa = (UINT64_C(1) << mantissa_bits) - 1;
    const uint64_t exponent = (sign - 1) & ~mantissa;
    const int x_nan = (x & exponent) == exponent && (x & mantissa), y_nan = (y & exponent) == exponent && (y & mantissa);
    if (x_nan && y_nan) { ++tolerated_nan; return 1; }
    const int x_tiny = !(x & exponent), y_tiny = !(y & exponent);
    if (x_tiny && y_tiny && (!(x & mantissa) || !(y & mantissa))) { ++tolerated_flush; return 1; }
    /* x86 detects tininess before rounding, ARM after: FTZ gives zero where the host rounds up
     * to the smallest normal. */
    const uint64_t smallest = mantissa + 1;
    if (((x & ~sign) == smallest && !(y & ~sign)) || ((y & ~sign) == smallest && !(x & ~sign))) { ++tolerated_flush; return 1; }
    return 0;
}

static int vector_equal(const BbVec *a, const BbVec *b) {
    if (!memcmp(a, b, 32)) return 1;
    if (!tolerance_width) return 0;
    for (int i = 0; i < 32; i += tolerance_width) {
        uint64_t x = 0, y = 0;
        memcpy(&x, (const uint8_t *)a + i, (size_t)tolerance_width);
        memcpy(&y, (const uint8_t *)b + i, (size_t)tolerance_width);
        if (x != y && !tolerated_lane(x, y, tolerance_width)) return 0;
    }
    return 1;
}

static int compare(const BbCpu *a, const BbCpu *b, const uint8_t *ma, const uint8_t *mb, uint32_t flag_mask,
                   char *out, size_t size) {
    size_t n = 0;
    for (int i = 0; i < 16 && n < size - 200; ++i)
        if (a->r[i] != b->r[i])
            n += (size_t)snprintf(out + n, size - n, " r%d: reference %#" PRIx64 " recomp %#" PRIx64 ";", i, a->r[i], b->r[i]);
    if (n < size - 200 && ((a->flags ^ b->flags) & flag_mask))
        n += (size_t)snprintf(out + n, size - n, " flags: reference %#" PRIx64 " recomp %#" PRIx64 " (mask %#x);",
                              a->flags & flag_mask, b->flags & flag_mask, flag_mask);
    for (int i = 0; i < 16 && n < size - 200; ++i)
        if (!vector_equal(&a->v[i], &b->v[i]))
            n += (size_t)snprintf(out + n, size - n, " ymm%d: reference %016" PRIx64 "%016" PRIx64 "%016" PRIx64 "%016" PRIx64
                                  " recomp %016" PRIx64 "%016" PRIx64 "%016" PRIx64 "%016" PRIx64 ";", i,
                                  a->v[i].q[3], a->v[i].q[2], a->v[i].q[1], a->v[i].q[0],
                                  b->v[i].q[3], b->v[i].q[2], b->v[i].q[1], b->v[i].q[0]);
    for (int i = 0; i < SCRATCH && n < size - 100; ++i)
        if (ma[i] != mb[i]) {
            n += (size_t)snprintf(out + n, size - n, " mem[+%#x]: reference %02x recomp %02x;", i, ma[i], mb[i]);
            break;
        }
    return n != 0;
}

static void oracle_dividend(BbCpu *cpu, const BbInsn *in) {
    const BbOp *op = &in->op[0];
    const uint64_t mask = bb_mask(op->size);
    const int signed_divide = in->mnemonic == ZYDIS_MNEMONIC_IDIV;
    if (op->type == OP_REG) {
        uint64_t value = interesting() & mask;
        if (!value) value = 1;
        cpu->r[RAX] = value;
        cpu->r[RDX] = 0;
        if (signed_divide && (value & (UINT64_C(1) << (op->size * 8 - 1)))) cpu->r[RDX] = mask;
        if (op->size == 1 && signed_divide) cpu->r[RAX] = (uint16_t)(int16_t)(int8_t)value;
        if (op->reg == RAX && !op->high8) return;
        /* High-half divisors also exercise division-overflow outcomes. */
        if (op->reg == RAX) { cpu->r[RAX] = 0x101; return; }
        uint64_t divisor = interesting() & mask;
        if (!divisor || (signed_divide && divisor == mask)) divisor = 7;
        cpu->r[op->reg] = divisor;
        return;
    }
    const uint64_t address = bbcpu_addr(cpu, in, op);
    int uses_rax = op->base == RAX || op->index == RAX;
    int uses_rdx = op->base == RDX || op->index == RDX;
    uint64_t divisor = interesting() & mask;
    if (!divisor || (signed_divide && divisor == mask)) divisor = 7;
    if (!uses_rax) {
        const uint64_t value = interesting() & mask;
        cpu->r[RAX] = value;
        if (op->size == 1 && signed_divide) cpu->r[RAX] = (uint16_t)(int16_t)(int8_t)value;
    }
    uint64_t high = 0;
    if (signed_divide && (cpu->r[RAX] & (UINT64_C(1) << (op->size * 8 - 1)))) high = mask;
    if (!signed_divide) high = rnd() % divisor;
    if (!uses_rdx) cpu->r[RDX] = high;
    memcpy((void *)address, &divisor, op->size);
}

static void snippet_tail(BbCpu *cpu) { (void)cpu; }
static void snippet_bail(BbCpu *cpu, uint64_t rsp) { (void)cpu; (void)rsp; }
static void snippet_call(BbCpu *cpu, uint64_t target, uint64_t next) {
    cpu->r[RSP] -= 8;
    memcpy((void *)cpu->r[RSP], &next, 8);
    cpu->rip = target;
    siglongjmp(snippet_done, 1);
}
static int oracle_in = -1, oracle_out = -1;
static pid_t oracle_pid;
static const char *oracle_path;
static void start_oracle(const char *path) {
    oracle_path = path;
    signal(SIGPIPE, SIG_IGN);
    int input[2], output[2];
    if (pipe(input) || pipe(output)) { perror("pipe"); exit(2); }
    oracle_pid = fork();
    if (oracle_pid < 0) { perror("fork"); exit(2); }
    if (!oracle_pid) {
        dup2(input[0], STDIN_FILENO);
        dup2(output[1], STDOUT_FILENO);
        close(input[0]); close(input[1]); close(output[0]); close(output[1]);
        setenv("ROSETTA_ADVERTISE_AVX", "1", 1);
        execl(path, path, NULL);
        _exit(2);
    }
    close(input[0]); close(output[1]);
    oracle_in = input[1]; oracle_out = output[0];
    uint64_t hello[2];
    if (!oracle_io(oracle_out, hello, sizeof(hello), 0) || hello[0] != UINT64_C(0x5838364f5241434c) ||
        hello[1] != sizeof(X86Oracle)) { fprintf(stderr, "oracle handshake failed\n"); exit(2); }
}

/* A fallback may deliberately _exit on an unsupported instruction. Keep the sweep alive. */
static int isolated_step(BbCpu *cpu, const BbInsn *instruction, uint8_t *scratch, int input_fd) {
    int output[2];
    if (pipe(output)) { perror("pipe"); exit(2); }
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); exit(2); }
    if (!pid) {
        close(output[0]);
        /* bbcpu_fatal flushes all streams; do not let it rewind the parent's buffered input. */
        close(input_fd);
        const int signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE};
        for (unsigned i = 0; i < sizeof(signals) / sizeof(*signals); ++i) signal(signals[i], SIG_DFL);
        cpu->rip = bbcpu_step_insn(cpu, instruction);
        int ok = oracle_io(output[1], cpu, sizeof(*cpu), 1) &&
                 oracle_io(output[1], scratch, SCRATCH, 1) &&
                 (!uses_rip || oracle_io(output[1], rip_mem, RIP_SIZE, 1));
        _exit(ok ? 0 : 2);
    }
    close(output[1]);
    int ok = oracle_io(output[0], cpu, sizeof(*cpu), 0) &&
             oracle_io(output[0], scratch, SCRATCH, 0) &&
             (!uses_rip || oracle_io(output[0], rip_mem, RIP_SIZE, 0));
    close(output[0]);
    int status;
    if (waitpid(pid, &status, 0) != pid) { perror("waitpid"); exit(2); }
    if (WIFSIGNALED(status)) return WTERMSIG(status);
    if (!ok || WEXITSTATUS(status)) return 256 + WEXITSTATUS(status);
    return 0;
}

static unsigned native_step(BbCpu *cpu, uint8_t *scratch, const uint8_t *bytes, int length, int single_step, int x87) {
    X86Oracle packet = {.cpu = *cpu, .rip_page = uses_rip ? rip_at : 0, .length = (uint32_t)length, .branch_target = branch_target, .single_step = (uint32_t)single_step, .x87 = (uint32_t)x87};
    memcpy(packet.code, bytes, (size_t)length);
    if (!oracle_io(oracle_in, &packet, sizeof(packet), 1) ||
        !oracle_io(oracle_in, scratch, SCRATCH, 1) ||
        (uses_rip && !oracle_io(oracle_in, rip_mem, RIP_SIZE, 1)) ||
        !oracle_io(oracle_out, &packet, sizeof(packet), 0) ||
        !oracle_io(oracle_out, scratch, SCRATCH, 0) ||
        (uses_rip && !oracle_io(oracle_out, rip_mem, RIP_SIZE, 0))) {
        close(oracle_in); close(oracle_out);
        int status;
        if (waitpid(oracle_pid, &status, 0) != oracle_pid) { perror("waitpid"); exit(2); }
        unsigned failure = 256;
        if (WIFSIGNALED(status)) failure = (unsigned)WTERMSIG(status);
        else failure += (unsigned)WEXITSTATUS(status);
        printf("ORACLE-RESTART rip=%#" PRIx64 " status=%u\n", cpu->rip, failure);
        start_oracle(oracle_path);
        return failure;
    }
    *cpu = packet.cpu;
    return packet.signal;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: fuzz_recomp FILE LIB [trials] [max reports]\n"); return 2; }
    const int trials = argc > 3 ? atoi(argv[3]) : 200, max_reports = argc > 4 ? atoi(argv[4]) : 50;
    const int oracle = argc > 5;
    oracle_mode = oracle;
    if (oracle) start_oracle(argv[5]);
    setvbuf(stdout, NULL, _IOLBF, 0);
    static RcApi api;
    api = (RcApi){.version = BB_RECOMP_API_VERSION, .image_base = CODE_AT};
    if (oracle) { api.call = snippet_call; api.tail = snippet_tail; api.bail = snippet_bail; }
    void *library = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    const RcInit init = library ? (RcInit)dlsym(library, BB_RECOMP_INIT) : NULL;
    if (!init) { fprintf(stderr, "%s: %s\n", argv[2], dlerror()); return 2; }
    size_t snippet_count = 0;
    const RcFunction *snippets = init(&api, &snippet_count);
    static BbCpu warm;
    bbcpu_run(&warm, 0); /* the interpreter's tables are made on its first run */
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 2; }
    uint8_t *code = mmap((void *)CODE_AT, 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    uint8_t *scratch = mmap((void *)SCRATCH_AT, SCRATCH, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    uint8_t *mem_jit = malloc(SCRATCH), *mem_start = malloc(SCRATCH);
    uint8_t *rip_jit = malloc(RIP_SIZE), *rip_start = malloc(RIP_SIZE);
    if (code == MAP_FAILED || scratch == MAP_FAILED || !mem_jit || !mem_start) { perror("mmap"); return 2; }
    bbcpu_add_guest_code(CODE_AT, 0x4000);
    signal(SIGSEGV, on_crash);
    signal(SIGBUS, on_crash);
    signal(SIGILL, on_crash);
    signal(SIGTRAP, on_crash);
    signal(SIGABRT, on_crash);
    signal(SIGFPE, on_crash);
    ZydisDecoder decoder;
    ZydisDecoderInit(&decoder, ZYDIS_MACHINE_MODE_LONG_64, ZYDIS_STACK_WIDTH_64);
    ZydisFormatter formatter;
    ZydisFormatterInit(&formatter, ZYDIS_FORMATTER_STYLE_ATT);
    BbCpu *ci = calloc(1, sizeof(BbCpu)), *cj = calloc(1, sizeof(BbCpu)), *c0 = calloc(1, sizeof(BbCpu));
    char line[128];
    int tested = 0, skipped = 0, failed = 0, crashed = 0, reports = 0, native = 0;
    uint64_t cases = 0, generated_cases = 0, fallback_cases = 0;
    uint64_t cmpxchg_checks = 0, cmpxchg_quirks = 0, cmpxchg_successes = 0, cmpxchg_writeback_quirks = 0;
    uint64_t line_number = 0;
    size_t next_snippet = 0;
    while (fgets(line, sizeof(line), f)) {
        ++line_number;
        /* Only the lines bbrecomp translated natively (the table is in line order). */
        while (next_snippet < snippet_count && snippets[next_snippet].offset < line_number) ++next_snippet;
        RcFn generated = NULL;
        if (next_snippet < snippet_count && snippets[next_snippet].offset == line_number)
            generated = snippets[next_snippet].fn;
        if (!oracle && !generated) continue;
        uint8_t bytes[16];
        int len = 0;
        for (const char *p = line; p[0] && p[1] && p[0] != '\n' && len < 15; p += 2) {
            unsigned v;
            if (sscanf(p, "%2x", &v) != 1) break;
            bytes[len++] = (uint8_t)v;
        }
        Insn x;
        if (!len || !ZYAN_SUCCESS(ZydisDecoderDecodeFull(&decoder, bytes, (ZyanUSize)len, &x.zi, x.zo))) continue;
        char text[96];
        ZydisFormatterFormatInstruction(&formatter, &x.zi, x.zo, x.zi.operand_count_visible, text, sizeof(text), CODE_AT, NULL);
        const ZydisMnemonic mn = x.zi.mnemonic;
        static const char *tolerance = (const char *)1;
        if (tolerance == (const char *)1) tolerance = getenv("FUZZ_FP_TOLERANCE");
        tolerance_width = 0;
        if (tolerance && !strcmp(tolerance, "d18") && x.zo[0].type == ZYDIS_OPERAND_TYPE_REGISTER &&
            (x.zo[0].element_size == 32 || x.zo[0].element_size == 64) &&
            x.zo[0].reg.value >= ZYDIS_REGISTER_XMM0 && x.zo[0].reg.value <= ZYDIS_REGISTER_YMM15)
            tolerance_width = x.zo[0].element_size / 8;
        if (oracle) printf("FORM line=%" PRIu64 " %s %s\n", line_number, generated ? "C" : "fallback", text);
        int excluded = mn == ZYDIS_MNEMONIC_INT3 || mn == ZYDIS_MNEMONIC_UD2 ||
            mn == ZYDIS_MNEMONIC_HLT || mn == ZYDIS_MNEMONIC_SYSCALL || mn == ZYDIS_MNEMONIC_INT ||
            mn == ZYDIS_MNEMONIC_IRETD || mn == ZYDIS_MNEMONIC_POPFQ || mn == ZYDIS_MNEMONIC_PUSHFQ;
        if (!oracle) excluded |= x.zi.meta.branch_type != ZYDIS_BRANCH_TYPE_NONE || mn == ZYDIS_MNEMONIC_RET ||
            ((mn == ZYDIS_MNEMONIC_DIV || mn == ZYDIS_MNEMONIC_IDIV) && x.zo[0].size < 32) ||
            mn == ZYDIS_MNEMONIC_RDTSC || mn == ZYDIS_MNEMONIC_RDTSCP || mn == ZYDIS_MNEMONIC_CPUID ||
            mn == ZYDIS_MNEMONIC_LEAVE || mn == ZYDIS_MNEMONIC_XGETBV;
        if (oracle) excluded = 0;
        if (excluded) {
            ++skipped;
            if (oracle) printf("SKIP line=%" PRIu64 " %s (%s) trap/privileged/TF-sensitive form\n", line_number, text, strtok(line, "\n"));
            continue;
        }
        x.defined_flags = 0x8d5;
        if (oracle) x.defined_flags |= F_DF;
        if (x.zi.cpu_flags) x.defined_flags &= ~(uint32_t)x.zi.cpu_flags->undefined;
        /* Shifts by cl: CF is undefined past the operand width; the count may also be 0. */
        if ((x.zi.mnemonic == ZYDIS_MNEMONIC_SHL || x.zi.mnemonic == ZYDIS_MNEMONIC_SHR || x.zi.mnemonic == ZYDIS_MNEMONIC_SAR) &&
            x.zo[1].type == ZYDIS_OPERAND_TYPE_REGISTER && x.zo[0].size < 32)
            x.defined_flags &= ~1u;
        uint64_t shift = 0;
        for (int i = 0; i < x.zi.operand_count_visible; ++i) {
            const ZydisDecodedOperand *o = &x.zo[i];
            const int atomic = (x.zi.attributes & ZYDIS_ATTRIB_HAS_LOCK) || mn == ZYDIS_MNEMONIC_XCHG ||
                               mn == ZYDIS_MNEMONIC_CMPXCHG || mn == ZYDIS_MNEMONIC_XADD;
            if ((atomic || oracle) && o->type == ZYDIS_OPERAND_TYPE_MEMORY && o->mem.base == ZYDIS_REGISTER_RIP && o->size >= 16) {
                const uint64_t align = oracle ? 32 : o->size / 8, target = (uint64_t)len + (uint64_t)o->mem.disp.value;
                shift = (align - target % align) % align;
            }
        }
        code_at = CODE_AT + shift;
        api.image_base = code_at;
        /* The instruction, then a jump to `stop` (block end). */
        memset(code, 0x90, 128);
        uint8_t *at = code + shift;
        memcpy(at, bytes, (size_t)len);
        at[len] = 0xe9;
        const int32_t rel = 0x40;
        memcpy(at + len + 1, &rel, 4);
        /* At stop (never run): pushfq, so the JIT's flag liveness keeps every flag of the
         * instruction (it looks at the code a block continues to). */
        at[len + 5 + 0x40] = 0x9c;
        bbcpu_invalidate(CODE_AT, 128);
        const BbBlock *block = bbcpu_block(code_at);

        int bad = 0, placed = 1, cmpxchg_note = 0, cmpxchg_writeback_note = 0;
        /* FUZZ_MXCSR pins every oracle trial's MXCSR (hex), e.g. 0x1f80 to classify the D18
         * host-FP path without the rounding/FTZ/DAZ trials that it deliberately ignores. */
        static const char *fixed_mxcsr = (const char *)1;
        if (fixed_mxcsr == (const char *)1) fixed_mxcsr = getenv("FUZZ_MXCSR");
        for (int t = 0; t < trials && !bad; ++t) {
            memset(ci, 0, offsetof(BbCpu, jf_flags));
            random_state(ci, scratch);
            ci->rip = code_at;
            if (oracle) ci->flags |= 0x200;
            ci->mxcsr = 0x1f80;
            if (oracle) ci->mxcsr |= (uint32_t)(t % 4) << 13 | (uint32_t)((t / 4) % 2) << 15 | (uint32_t)((t / 8) % 2) << 6;
            if (oracle && fixed_mxcsr) ci->mxcsr = (uint32_t)strtoul(fixed_mxcsr, NULL, 16);
            ci->fcw = 0x37f;
            if (oracle && x.zi.meta.isa_set == ZYDIS_ISA_SET_X87) {
                static const double values[] = {2.25, -3.5, 0.0, -0.0, 1.0, -1.0, 0x1p-1022, 0x1p1023};
                ci->st[0] = values[t % (sizeof(values) / sizeof(*values))];
            }
            ci->stack_top = SCRATCH_AT + SCRATCH;
            uses_rip = 0;
            if (oracle && x.zi.meta.category == ZYDIS_CATEGORY_STRINGOP) {
                ci->r[RSI] = SCRATCH_AT + 0x2000;
                ci->r[RDI] = SCRATCH_AT + 0x4000;
                ci->r[RCX] = (uint64_t)t % 33;
            } else if (!place_memory(&x, ci)) { placed = 0; break; }
            if (uses_rip) {
                for (int i = 0; i < RIP_SIZE; i += 8) { uint64_t v = rnd(); memcpy(rip_mem + i, &v, 8); }
            }
            branch_target = 0;
            if (oracle && (mn == ZYDIS_MNEMONIC_CALL || mn == ZYDIS_MNEMONIC_JMP)) {
                const BbOp *op = &block->insn[0].op[0];
                branch_target = code_at + 0x100;
                if (op->type == OP_IMM) branch_target = code_at + (uint64_t)op->disp;
                else bbcpu_write(ci, &block->insn[0], op, branch_target);
            }
            if (oracle && mn == ZYDIS_MNEMONIC_RET) {
                branch_target = code_at + 0x100;
                memcpy((void *)ci->r[RSP], &branch_target, 8);
            }
            if (oracle && mn == ZYDIS_MNEMONIC_CPUID) { ci->r[RAX] = (uint64_t)t % 16; ci->r[RCX] = 0; }
            if (oracle && mn == ZYDIS_MNEMONIC_XGETBV) ci->r[RCX] = 0;
            if (oracle && mn == ZYDIS_MNEMONIC_LEAVE) ci->r[RBP] = SCRATCH_AT + 0x5000;
            if (oracle && mn == ZYDIS_MNEMONIC_POPFQ) {
                uint64_t flags = 0x202 | (rnd() & 0xcd5);
                memcpy((void *)ci->r[RSP], &flags, 8);
            }
            if (oracle && (mn == ZYDIS_MNEMONIC_INT || mn == ZYDIS_MNEMONIC_SYSCALL)) ci->r[RAX] = UINT32_MAX;
            if (oracle && mn == ZYDIS_MNEMONIC_XLAT) ci->r[RBX] = SCRATCH_AT + 0x2000;
            if (oracle && (mn == ZYDIS_MNEMONIC_DIV || mn == ZYDIS_MNEMONIC_IDIV)) oracle_dividend(ci, &block->insn[0]);
            if (!oracle && (mn == ZYDIS_MNEMONIC_DIV || mn == ZYDIS_MNEMONIC_IDIV)) {
                /* No #DE (the interpreter stops the process): a nonzero divisor, rdx the extension of
                 * rax, or (unsigned, sometimes) below the divisor: the quotient fits. */
                const int bytes = x.zo[0].size / 8, sgn = mn == ZYDIS_MNEMONIC_IDIV;
                const uint64_t mask = bytes == 8 ? ~UINT64_C(0) : (UINT64_C(1) << (bytes * 8)) - 1;
                uint64_t d = interesting() & mask;
                if (!d || (sgn && d == mask)) d = 7;
                const BbOp *op = &block->insn[0].op[0];
                if (op->type == OP_REG) {
                    if (op->reg == RAX || op->reg == RDX) { placed = 0; break; }
                    ci->r[op->reg] = (ci->r[op->reg] & ~mask) | d;
                } else {
                    if (op->base == RAX || op->base == RDX || op->index == RAX || op->index == RDX) { placed = 0; break; }
                    const uint64_t at = bbcpu_addr(ci, &block->insn[0], op);
                    if (at < SCRATCH_AT || at + 8 > SCRATCH_AT + SCRATCH) { placed = 0; break; }
                    memcpy((void *)at, &d, (size_t)bytes);
                }
                const uint64_t ax = ci->r[RAX] & mask;
                uint64_t dx;
                if (sgn) dx = ((ax >> (bytes * 8 - 1)) & 1) ? mask : 0;
                else dx = rnd() % 4 ? 0 : (rnd() % d) & mask;
                if (sgn && bytes == 8 && ax == UINT64_C(0x8000000000000000) && d == mask) ci->r[RAX] = 1;
                if (oracle && bytes == 1) {
                    uint16_t ax8 = (uint8_t)ci->r[RAX];
                    if (sgn) ax8 = (uint16_t)(int16_t)(int8_t)ax8;
                    ci->r[RAX] = (ci->r[RAX] & ~UINT64_C(0xffff)) | ax8;
                }
                if (bytes == 4) { ci->r[RDX] = (ci->r[RDX] & ~mask) | dx; }
                else ci->r[RDX] = dx;
            }
            if (oracle && x.zo[0].type == ZYDIS_OPERAND_TYPE_MEMORY &&
                (mn == ZYDIS_MNEMONIC_BT || mn == ZYDIS_MNEMONIC_BTS || mn == ZYDIS_MNEMONIC_BTR || mn == ZYDIS_MNEMONIC_BTC) &&
                x.zo[1].type == ZYDIS_OPERAND_TYPE_REGISTER) {
                int index = reg_index(x.zo[1].reg.value);
                if (index >= 0) ci->r[index] %= x.zo[0].size;
            }
            if (oracle && (mn == ZYDIS_MNEMONIC_LDMXCSR || mn == ZYDIS_MNEMONIC_VLDMXCSR)) {
                uint64_t address = bbcpu_addr(ci, &block->insn[0], &block->insn[0].op[0]);
                memcpy((void *)address, &ci->mxcsr, 4);
            }
            if (oracle && mn == ZYDIS_MNEMONIC_CMPXCHG && block->insn[0].op[0].type == OP_MEM) {
                const BbOp *dst = &block->insn[0].op[0];
                const uint64_t expected = ci->r[RAX] & bb_mask(dst->size);
                uint64_t old = expected;
                if (t & 1) {
                    old = interesting() & bb_mask(dst->size);
                    if (old == expected) old ^= 1;
                }
                bbcpu_write(ci, &block->insn[0], dst, old);
            }
            if (oracle) {
                oracle_fp_inputs(&x, &block->insn[0], ci, t);
                oracle_pack_inputs(&x, &block->insn[0], ci, t);
            }
            if (uses_rip) memcpy(rip_start, rip_mem, RIP_SIZE);
            ci->rip = code_at;
            memcpy(mem_start, scratch, SCRATCH);
            memcpy(c0, ci, sizeof(*c0));
            memcpy(cj, ci, sizeof(*cj));
            const char *volatile stage = generated ? "generated code" : "interpreter fallback";
            volatile unsigned native_signal = 0;
            if (t == 0) ++native;
            ++cases;
            if (generated) ++generated_cases;
            else ++fallback_cases;
            guarded = 1;
            int sig = sigsetjmp(crash_jump, 1);
            if (!sig) {
                if (oracle) {
                    uint64_t cmpxchg_old = 0;
                    if (mn == ZYDIS_MNEMONIC_CMPXCHG)
                        cmpxchg_old = bbcpu_read(c0, &block->insn[0], &block->insn[0].op[0]);
                    native_signal = native_step(ci, scratch, bytes, len, x.zi.meta.branch_type != ZYDIS_BRANCH_TYPE_NONE, x.zi.meta.isa_set == ZYDIS_ISA_SET_X87);
                    memcpy(mem_jit, scratch, SCRATCH);
                    if (ci->gs_base) memcpy(mem_start + ci->gs_base - SCRATCH_AT, scratch + ci->gs_base - SCRATCH_AT, 128);
                    memcpy(scratch, mem_start, SCRATCH);
                    if (uses_rip) { memcpy(rip_jit, rip_mem, RIP_SIZE); memcpy(rip_mem, rip_start, RIP_SIZE); }
                    if (!native_signal && mn == ZYDIS_MNEMONIC_CMPXCHG) {
                        /* Rosetta's CMPXCHG flags are wrong; Intel specifies CMP accumulator,old-destination flags. */
                        static const uint8_t cmp[9][3] = {
                            [1] = {0x38, 0xd0}, [2] = {0x66, 0x39, 0xd0},
                            [4] = {0x39, 0xd0}, [8] = {0x48, 0x39, 0xd0}
                        };
                        const int size = block->insn[0].op[0].size;
                        const int cmp_length = size == 2 || size == 8 ? 3 : 2;
                        BbCpu comparison = *c0;
                        comparison.r[RDX] = cmpxchg_old;
                        native_signal = native_step(&comparison, scratch, cmp[size], cmp_length, 0, 0);
                        if (!native_signal) {
                            ++cmpxchg_checks;
                            if (comparison.flags & F_ZF) ++cmpxchg_successes;
                            if ((ci->flags ^ comparison.flags) & F_ARITH) {
                                ++cmpxchg_quirks;
                                if (!cmpxchg_note++) printf("REFERENCE_CMPXCHG line=%" PRIu64 " captured=%#" PRIx64 " x86_cmp=%#" PRIx64 "\n",
                                                           line_number, ci->flags & F_ARITH, comparison.flags & F_ARITH);
                            }
                            ci->flags = (ci->flags & ~(uint64_t)F_ARITH) | (comparison.flags & F_ARITH);
                            const BbOp *dst = &block->insn[0].op[0];
                            int untouched = -1;
                            if (size == 4) {
                                if (comparison.flags & F_ZF) {
                                    if (dst->type != OP_REG || dst->reg != RAX) untouched = RAX;
                                } else if (dst->type == OP_REG) untouched = dst->reg;
                            }
                            if (untouched >= 0) {
                                /* A conditional write that did not happen must preserve the full register. */
                                const uint64_t captured = ci->r[untouched];
                                ci->r[untouched] = (captured & UINT32_MAX) | (c0->r[untouched] & ~UINT64_C(0xffffffff));
                                if (captured != ci->r[untouched]) {
                                    ++cmpxchg_writeback_quirks;
                                    if (!cmpxchg_writeback_note++) printf("REFERENCE_CMPXCHG_WRITEBACK line=%" PRIu64 " r%d captured=%#" PRIx64 " conditional=%#" PRIx64 "\n",
                                                                        line_number, untouched, captured, ci->r[untouched]);
                                }
                            }
                        }
                    }
                }
                if (generated) {
                    if (!oracle || !sigsetjmp(snippet_done, 1)) generated(cj);
                } else sig = isolated_step(cj, &block->insn[0], scratch, fileno(f));
                if (!oracle) {
                    memcpy(mem_jit, scratch, SCRATCH);
                    memcpy(scratch, mem_start, SCRATCH);
                    if (uses_rip) { memcpy(rip_jit, rip_mem, RIP_SIZE); memcpy(rip_mem, rip_start, RIP_SIZE); }
                    stage = "interpreter";
                    bbcpu_step_insn(ci, &block->insn[0]);
                }
            }
            guarded = 0;
            if (sig || native_signal) {
                ++crashed;
                if (reports++ < max_reports) printf("CRASH line=%" PRIu64 " %s %-40s (%s) implementation=%d x86=%u stage=%s\n",
                    line_number, generated ? "C" : "fallback", text, line[0] ? strtok(line, "\n") : "", sig, native_signal, stage);
                bad = 1;
                break;
            }
            if (!oracle) ci->rip = code_at + (uint64_t)len;
            char diff[1024];
            int differs = compare(ci, cj, oracle ? mem_jit : scratch, oracle ? scratch : mem_jit, x.defined_flags, diff, sizeof(diff));
            if (uses_rip && memcmp(rip_mem, rip_jit, RIP_SIZE)) {
                strncat(diff, " rip-relative memory differs;", sizeof(diff) - strlen(diff) - 1);
                differs = 1;
            }
            if (oracle && x.zi.meta.isa_set == ZYDIS_ISA_SET_X87 &&
                (ci->top != cj->top || memcmp(ci->st, cj->st, sizeof(ci->st)) || ci->fcw != cj->fcw)) {
                strncat(diff, " x87 stack/control differs;", sizeof(diff) - strlen(diff) - 1);
                differs = 1;
            }
            if (oracle && ci->rip != cj->rip) {
                size_t n = strlen(diff);
                snprintf(diff + n, sizeof(diff) - n, " rip: x86 %#" PRIx64 " actual %#" PRIx64 ";", ci->rip, cj->rip);
                differs = 1;
            }
            if (oracle && ((ci->mxcsr ^ cj->mxcsr) & 0xffc0)) {
                size_t n = strlen(diff);
                snprintf(diff + n, sizeof(diff) - n, " mxcsr controls: x86 %#x actual %#x;", ci->mxcsr, cj->mxcsr);
                differs = 1;
            }
            if (differs) {
                bad = 1;
                ++failed;
                if (reports++ < max_reports) {
                    printf("FAIL line=%" PRIu64 " %s %-40s (%s) trial %d:%s\n", line_number, generated ? "C" : "fallback", text, strtok(line, "\n"), t, diff);
                    printf("     in:");
                    for (int i = 0; i < 16; ++i) printf(" r%d=%#" PRIx64, i, c0->r[i]);
                    printf(" flags=%#" PRIx64 " mxcsr=%#x\n", c0->flags, c0->mxcsr);
                }
            }
        }
        if (!placed) {
            ++skipped;
            if (oracle) printf("SKIP line=%" PRIu64 " %s (%s) memory/division setup\n", line_number, text, strtok(line, "\n"));
            continue;
        }
        ++tested;
        if (oracle && line_number % 100 == 0) printf("PROGRESS line=%" PRIu64 " tested=%d failed=%d crashed=%d skipped=%d\n",
                                                    line_number, tested, failed, crashed, skipped);
    }
    if (oracle && tolerated_nan + tolerated_flush)
        printf("TOLERATED nan=%" PRIu64 " flush=%" PRIu64 "\n", tolerated_nan, tolerated_flush);
    if (oracle) printf("CASES total=%" PRIu64 " generated=%" PRIu64 " fallback=%" PRIu64 "\n", cases, generated_cases, fallback_cases);
    if (cmpxchg_checks) printf("CMPXCHG_FLAGS checked=%" PRIu64 " rosetta_differences=%" PRIu64 " success=%" PRIu64 " failure=%" PRIu64 " writeback_differences=%" PRIu64 "\n",
                               cmpxchg_checks, cmpxchg_quirks, cmpxchg_successes, cmpxchg_checks - cmpxchg_successes, cmpxchg_writeback_quirks);
    printf("%d instructions tested, %d failed, %d crashed, %d skipped\n", tested, failed, crashed, skipped);
    if (oracle) {
        close(oracle_in); close(oracle_out);
        int status;
        if (waitpid(oracle_pid, &status, 0) != oracle_pid || status) return 2;
    }
    (void)native;
    return failed || crashed || (oracle && skipped);
}
