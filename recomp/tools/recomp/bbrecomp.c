/* tools/recomp/bbrecomp.c ELF FUNCTIONS_TSV OUT.c OFFSET...: the recompiler (docs/RECOMPILATION.md). Writes
 * one C function per game function (image offsets; sizes from tools/recomp/scan.c's functions.tsv)
 * against src/recomp/rc.h, in files OUT_<n>.c, and the library's table and entry point in OUT.c.
 * Build: tools/recomp/recomp.sh.
 *
 * Generated code keeps the guest registers in a local array and the flags lazily; every
 * instruction gets a label. Instructions the generator does not translate run in the interpreter
 * (rc->step) with the state spilled around them; a branch to an unknown place goes back to the
 * translator (rc->bail) or, out of the function, is a tail call (rc->tail). */
#include "../../src/cpu/trace.h"
#include <ctype.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#define M(name) ZYDIS_MNEMONIC_##name

void *runtime_low_map(size_t size, int prot) {
    void *p = mmap(NULL, size, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}
uint64_t bb_image_base;

/* ---- the image ---- */

typedef struct { unsigned char e_ident[16]; uint16_t e_type, e_machine; uint32_t e_version;
    uint64_t e_entry, e_phoff, e_shoff; uint32_t e_flags; uint16_t e_ehsize, e_phentsize, e_phnum,
    e_shentsize, e_shnum, e_shstrndx; } Elf64_Ehdr;
typedef struct { uint32_t p_type, p_flags; uint64_t p_offset, p_vaddr, p_paddr, p_filesz, p_memsz,
    p_align; } Elf64_Phdr;

static uint64_t base; /* where the image is mapped here */

static void map_image(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END);
    const long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *data = malloc((size_t)size);
    if (!data || fread(data, 1, (size_t)size, f) != (size_t)size) exit(1);
    fclose(f);
    const Elf64_Ehdr *eh = (const Elf64_Ehdr *)data;
    uint64_t end = 0;
    for (int i = 0; i < eh->e_phnum; ++i) {
        const Elf64_Phdr *ph = (const Elf64_Phdr *)(data + eh->e_phoff + (uint64_t)i * eh->e_phentsize);
        if (ph->p_type == 1 && ph->p_vaddr + ph->p_memsz > end) end = ph->p_vaddr + ph->p_memsz;
    }
    uint8_t *image = mmap(NULL, (end + 16383) & ~UINT64_C(16383), PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANON, -1, 0);
    if (image == MAP_FAILED) exit(1);
    base = (uint64_t)(uintptr_t)image;
    for (int i = 0; i < eh->e_phnum; ++i) {
        const Elf64_Phdr *ph = (const Elf64_Phdr *)(data + eh->e_phoff + (uint64_t)i * eh->e_phentsize);
        if (ph->p_type != 1) continue;
        memcpy(image + ph->p_vaddr, data + ph->p_offset, ph->p_filesz);
        if (ph->p_flags & 1) bbcpu_add_guest_code(base + ph->p_vaddr, ph->p_memsz);
    }
    free(data);
}

/* ---- functions ---- */

typedef struct { uint64_t offset, size; } Function;
static Function *functions;
static size_t function_count;

static uint64_t size_of(const char *tsv, uint64_t offset) {
    static uint64_t *starts, *sizes;
    static size_t count;
    if (!starts) {
        FILE *f = fopen(tsv, "r");
        if (!f) { perror(tsv); exit(1); }
        char line[256];
        size_t capacity = 0;
        while (fgets(line, sizeof(line), f)) {
            if (line[0] != '0') continue;
            if (count == capacity) {
                capacity = capacity ? capacity * 2 : 1 << 18;
                starts = realloc(starts, capacity * 8);
                sizes = realloc(sizes, capacity * 8);
            }
            char *end;
            starts[count] = strtoull(line, &end, 16);
            sizes[count++] = strtoull(end, NULL, 10);
        }
        fclose(f);
    }
    for (size_t lo = 0, hi = count; lo < hi;) { /* functions.tsv is sorted */
        const size_t mid = (lo + hi) / 2;
        if (starts[mid] == offset) return sizes[mid];
        if (starts[mid] < offset) lo = mid + 1; else hi = mid;
    }
    return 0;
}

/* ---- output ---- */

static FILE *out;
static void emit(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void emit(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(out, format, args);
    va_end(args);
}

/* Closes `out` where writing ended: a translation that gave up may have written past it. */
static void close_output(void) {
    fflush(out);
    ftruncate(fileno(out), ftell(out));
    fclose(out);
}

#define FP_END "if (fp_active) { bb_fp_leave(fp_saved); fp_active = 0; }"
#define FP_BEGIN "if (!fp_active) { fp_saved = bb_fp_enter(c->mxcsr); fp_active = 1; }"
/* E2 host SSE (D18): plain host arithmetic while the guest rounds to nearest; rc_fp_mask is ~0
 * with SS_FP_EXACT=1, which keeps every operation on the exact path. */
#define FP_HOST "RC_FP_HOST"
/* VSPILL/VRELOAD/RC_V: the vector registers (rc.h: in the context; E1 fast kernels: locals). */
#define SPILL FP_END " memcpy(c->r, r, sizeof(r)); VSPILL"
#define RELOAD "memcpy(r, c->r, sizeof(r)); VRELOAD"
#define COND "rc_cond(%d, fk, fa, fb, fr, fz, fcf, c->flags)"
#define FLAGS_OUT "c->flags = rc_flags(fk, fa, fb, fr, fz, fcf, c->flags); fk = FK_CPU;"

typedef struct { char s[1024]; } Str;
static Str str(const char *format, ...) __attribute__((format(printf, 1, 2)));
static Str str(const char *format, ...) {
    Str v;
    va_list args;
    va_start(args, format);
    vsnprintf(v.s, sizeof(v.s), format, args);
    va_end(args);
    return v;
}
static uint64_t mask(int size) { return size >= 8 ? ~UINT64_C(0) : (UINT64_C(1) << (size * 8)) - 1; }

/* The address of a memory operand (image offsets for rip-relative); 0: not translatable. */
static int address(uint64_t off, const BbInsn *in, const BbOp *op, Str *s, int *stack) {
    if (op->segment > 2) return 0;
    char text[200] = "";
    size_t n = 0;
    if (op->base == 0xfe) {
        n += (size_t)snprintf(text + n, sizeof(text) - n, "(B + 0x%" PRIx64 "ull)", off + in->length + (uint64_t)op->disp);
    } else {
        n += (size_t)snprintf(text + n, sizeof(text) - n, "(0x%" PRIx64 "ull", (uint64_t)op->disp);
        if (op->base != 0xff) n += (size_t)snprintf(text + n, sizeof(text) - n, " + r[%d]", op->base);
        if (op->index != 0xff) n += (size_t)snprintf(text + n, sizeof(text) - n, " + r[%d] * %d", op->index, op->scale);
        n += (size_t)snprintf(text + n, sizeof(text) - n, ")");
    }
    const int segment = in->mnemonic != M(LEA) ? op->segment : 0;
    *stack = !segment && op->base == RSP && op->index == 0xff;
    if (segment) *s = str("(%s + c->%s_base)", text, segment == 1 ? "fs" : "gs");
    else *s = str("%s", text);
    return 1;
}

static int gpr(const BbOp *op) { return op->type == OP_REG && op->kind == RK_GPR; }

/* An operand's value, zero-extended (immediates: sign-extended to `size`, then masked). */
static int read_op(uint64_t off, const BbInsn *in, const BbOp *op, int size, Str *v) {
    if (gpr(op)) {
        if (op->size == 1 && op->high8) *v = str("((r[%d] >> 8) & 0xff)", op->reg);
        else if (op->size == 8) *v = str("r[%d]", op->reg);
        else *v = str("(r[%d] & 0x%" PRIx64 "ull)", op->reg, mask(op->size));
        return 1;
    }
    if (op->type == OP_IMM) {
        *v = str("0x%" PRIx64 "ull", (uint64_t)op->disp & mask(size));
        return 1;
    }
    if (op->type == OP_MEM) {
        Str a;
        int stack;
        if (!address(off, in, op, &a, &stack)) return 0;
        *v = str("%s(%s, %d)", stack ? "rc_lds" : "rc_ld", a.s, op->size);
        return 1;
    }
    return 0;
}

/* A statement writing `v` to a register or memory operand. */
static int write_op(uint64_t off, const BbInsn *in, const BbOp *op, const char *v, Str *s) {
    if (gpr(op)) {
        const int x = op->reg;
        switch (op->size) {
        case 8: *s = str("r[%d] = (%s);", x, v); break;
        case 4: *s = str("r[%d] = (uint32_t)(%s);", x, v); break;
        case 2: *s = str("r[%d] = (r[%d] & ~0xffffull) | ((%s) & 0xffff);", x, x, v); break;
        default:
            if (op->high8) *s = str("r[%d] = (r[%d] & ~0xff00ull) | (((%s) & 0xff) << 8);", x, x, v);
            else *s = str("r[%d] = (r[%d] & ~0xffull) | ((%s) & 0xff);", x, x, v);
        }
        return 1;
    }
    if (op->type == OP_MEM) {
        Str a;
        int stack;
        if (!address(off, in, op, &a, &stack)) return 0;
        *s = str("%s(%s, %d, (%s));", stack ? "rc_sts" : "rc_st", a.s, op->size, v);
        return 1;
    }
    return 0;
}

static int cc_of(int m) {
    static const int jcc[16] = {M(JO), M(JNO), M(JB), M(JNB), M(JZ), M(JNZ), M(JBE), M(JNBE),
                                M(JS), M(JNS), M(JP), M(JNP), M(JL), M(JNL), M(JLE), M(JNLE)};
    static const int setcc[16] = {M(SETO), M(SETNO), M(SETB), M(SETNB), M(SETZ), M(SETNZ), M(SETBE),
                                  M(SETNBE), M(SETS), M(SETNS), M(SETP), M(SETNP), M(SETL), M(SETNL),
                                  M(SETLE), M(SETNLE)};
    static const int cmovcc[16] = {M(CMOVO), M(CMOVNO), M(CMOVB), M(CMOVNB), M(CMOVZ), M(CMOVNZ),
                                   M(CMOVBE), M(CMOVNBE), M(CMOVS), M(CMOVNS), M(CMOVP), M(CMOVNP),
                                   M(CMOVL), M(CMOVNL), M(CMOVLE), M(CMOVNLE)};
    for (int i = 0; i < 16; ++i) {
        if (jcc[i] == m) return i;
        if (setcc[i] == m) return 16 + i;
        if (cmovcc[i] == m) return 32 + i;
    }
    return -1;
}

typedef struct { uint64_t start, end; } Range;
static Range split_function;

/* The functions being recompiled, by offset: calls of them go through their direct-call slot
 * (d_<offset>, rc.h) when the program filled it. */
static uint64_t *recompiled;
/* Import stubs by name (imports.tsv): calls of them are labelled. */
typedef struct { uint64_t stub; char name[64]; } Import;
static Import *imports;
static size_t import_count;
static const char *import_name(uint64_t t) {
    for (size_t lo = 0, hi = import_count; lo < hi;) {
        const size_t mid = (lo + hi) / 2;
        if (imports[mid].stub == t) return imports[mid].name;
        if (imports[mid].stub < t) lo = mid + 1; else hi = mid;
    }
    return NULL;
}
static int by_offset(const void *a, const void *b);
static int is_recompiled(uint64_t t) {
    return recompiled && bsearch(&t, recompiled, function_count, sizeof(*recompiled), by_offset) != NULL;
}

/* Direct generated calls: a call or tail call of a recompiled function still tests its d_ slot,
 * which the runtime sets to exactly f_ or leaves NULL (hash mismatch, BB_RECOMP_OFF/ONLY,
 * BB_RECOMP_NODIRECT, replay), but then calls f_ directly: a direct branch the compiler can
 * see through. BB_GEN_DIRECT=0 emits the call through the slot. */
static int gen_direct = 1;
static const char *call_flags_out(uint64_t off, uint64_t callee);
static const char *ret_flags_out(void);
static const char *mxcsr_exit(void);
static const char *direct_declaration(uint64_t t) {
    static char text[96];
    if (!gen_direct) return "";
    snprintf(text, sizeof(text), "extern __attribute__((visibility(\"hidden\"))) void f_%" PRIx64 "(BbCpu *);", t);
    return text;
}

/* A jump to image offset `t`: a goto inside the function. Out of it: a tail call when the stack is
 * back at the entry (the return address on top), else code of this function elsewhere (a part the
 * compiler moved out, a shared block): the translator runs the rest, the function's return address
 * at entry_rsp (rc->bail). */
static void jump(Range f, uint64_t t) {
    if (t >= f.start && t < f.end) emit("goto L_%" PRIx64 ";", t);
    else if (t >= split_function.start && t < split_function.end)
        emit("{ " SPILL " " FLAGS_OUT " c->rip = B + 0x%" PRIx64 "ull; *resume = 1; return; }", t);
    else if (is_recompiled(t))
        emit("{ extern RcFn d_%" PRIx64 "; %s " SPILL " " FLAGS_OUT " c->rip = B + 0x%" PRIx64 "ull; if (r[RSP] == entry_rsp) { if (d_%" PRIx64 ") %s_%" PRIx64 "(c); else rc->tail(c); } else rc->bail(c, entry_rsp); return; }",
             t, direct_declaration(t), t, t, gen_direct ? "f" : "d", t);
    else emit("{ " SPILL " " FLAGS_OUT " c->rip = B + 0x%" PRIx64 "ull; if (r[RSP] == entry_rsp) rc->tail(c); else rc->bail(c, entry_rsp); return; }", t);
}

static int translate_vector(uint64_t off, const BbInsn *in);
static int translate_shift_mul(uint64_t off, const BbInsn *in);
static int translate_extra(uint64_t off, const BbInsn *in);
static int translate_atomic(uint64_t off, const BbInsn *in);

/* One instruction natively; 0: it goes to the interpreter. */
static int translate(Range f, uint64_t off, const BbInsn *in, uint64_t *stats) {
    const uint64_t next = off + in->length;
    const int m = in->mnemonic;
    const BbOp *d = &in->op[0], *s = &in->op[1];
    Str a, b, w;
    if (in->rep || in->repne) return 0;
    if (in->lock || m == M(XADD) || m == M(CMPXCHG)) return translate_atomic(off, in);
    const int cc = cc_of(m);
    if (cc >= 0 && cc < 16) { /* jcc */
        if (d->type != OP_IMM) return 0;
        emit("if (" COND ") ", cc);
        jump(f, off + (uint64_t)d->disp);
        emit("\n");
        return 1;
    }
    if (cc >= 16 && cc < 32) { /* setcc */
        if (!write_op(off, in, d, str(COND, cc - 16).s, &w)) return 0;
        emit("%s\n", w.s);
        return 1;
    }
    if (cc >= 32) { /* cmovcc */
        if (!gpr(d) || !read_op(off, in, s, d->size, &b) || !write_op(off, in, d, b.s, &w)) return 0;
        emit("if (" COND ") { %s }", cc - 32, w.s);
        if (d->size == 4) emit(" else { r[%d] = (uint32_t)r[%d]; }", d->reg, d->reg);
        emit("\n");
        return 1;
    }
    switch (m) {
    case M(NOP): case M(ENDBR64): case M(PAUSE): case M(PREFETCHNTA): case M(PREFETCHT0):
    case M(PREFETCHT1): case M(PREFETCHT2): case M(PREFETCHW):
        emit("/* %s */\n", ZydisMnemonicGetString((ZydisMnemonic)m));
        return 1;
    case M(MOV):
        if (d->type == OP_REG && d->kind != RK_GPR) return 0;
        if (s->type == OP_REG && s->kind != RK_GPR) return 0;
        if (!read_op(off, in, s, d->size, &b) || !write_op(off, in, d, b.s, &w)) return 0;
        emit("%s\n", w.s);
        return 1;
    case M(MOVZX):
        if (!gpr(d) || !read_op(off, in, s, s->size, &b) || !write_op(off, in, d, b.s, &w)) return 0;
        emit("%s\n", w.s);
        return 1;
    case M(MOVSX): case M(MOVSXD): {
        if (!gpr(d) || !read_op(off, in, s, s->size, &b)) return 0;
        static const char *const ext[9] = {0, "int8_t", "int16_t", 0, "int32_t", 0, 0, 0, "int64_t"};
        if (!ext[s->size]) return 0;
        const Str v = str("(uint64_t)(int64_t)(%s)(%s)", ext[s->size], b.s);
        if (!write_op(off, in, d, v.s, &w)) return 0;
        emit("%s\n", w.s);
        return 1;
    }
    case M(LEA): {
        int stack;
        if (!gpr(d) || s->type != OP_AGEN || !address(off, in, s, &a, &stack)) return 0;
        if (!write_op(off, in, d, str("%s & 0x%" PRIx64 "ull", a.s, mask(d->size)).s, &w)) return 0;
        emit("%s\n", w.s);
        return 1;
    }
    case M(ADD): case M(SUB): case M(CMP): case M(AND): case M(OR): case M(XOR): case M(TEST): {
        const int size = d->size;
        if (!(gpr(d) || d->type == OP_MEM)) return 0;
        if (!read_op(off, in, s, size, &b)) return 0;
        const int kind = m == M(ADD) ? 1 : (m == M(SUB) || m == M(CMP)) ? 2 : 3;
        const char *op = m == M(ADD) ? "+" : (m == M(SUB) || m == M(CMP)) ? "-" : (m == M(OR)) ? "|" : (m == M(XOR)) ? "^" : "&";
        emit("{ ");
        Str da;
        int stack = 0;
        if (d->type == OP_MEM) { /* read-modify-write: the address once */
            if (!address(off, in, d, &da, &stack)) return 0;
            emit("const uint64_t ea = %s; const uint64_t a = %s(ea, %d); ", da.s, stack ? "rc_lds" : "rc_ld", size);
        } else {
            if (!read_op(off, in, d, size, &a)) return 0;
            emit("const uint64_t a = %s; ", a.s);
        }
        emit("const uint64_t b = %s; const uint64_t v = (a %s b) & 0x%" PRIx64 "ull; ", b.s, op, mask(size));
        emit("fk = %s; fa = a; fb = b; fr = v; fz = %d; ", kind == 1 ? "FK_ADD" : kind == 2 ? "FK_SUB" : "FK_LOGIC", size);
        if (m != M(CMP) && m != M(TEST)) {
            if (d->type == OP_MEM) emit("%s(ea, %d, v);", stack ? "rc_sts" : "rc_st", size);
            else {
                if (!write_op(off, in, d, "v", &w)) return 0;
                emit("%s", w.s);
            }
        }
        emit(" }\n");
        return 1;
    }
    case M(INC): case M(DEC): case M(NEG): case M(NOT): {
        const int size = d->size;
        emit("{ ");
        Str da;
        int stack = 0;
        if (d->type == OP_MEM) {
            if (!address(off, in, d, &da, &stack)) return 0;
            emit("const uint64_t ea = %s; const uint64_t a = %s(ea, %d); ", da.s, stack ? "rc_lds" : "rc_ld", size);
        } else if (gpr(d)) {
            if (!read_op(off, in, d, size, &a)) return 0;
            emit("const uint64_t a = %s; ", a.s);
        } else {
            return 0;
        }
        const char *calc = m == M(INC) ? "a + 1" : m == M(DEC) ? "a - 1" : m == M(NEG) ? "0 - a" : "~a";
        emit("const uint64_t v = (%s) & 0x%" PRIx64 "ull; ", calc, mask(size));
        if (m == M(INC) || m == M(DEC)) emit("fcf = " COND "; fk = %s; fa = a; fb = 1; fr = v; fz = %d; ", 2, m == M(INC) ? "FK_INC" : "FK_DEC", size);
        if (m == M(NEG)) emit("fk = FK_SUB; fa = 0; fb = a; fr = v; fz = %d; ", size);
        if (d->type == OP_MEM) emit("%s(ea, %d, v);", stack ? "rc_sts" : "rc_st", size);
        else {
            if (!write_op(off, in, d, "v", &w)) return 0;
            emit("%s", w.s);
        }
        emit(" }\n");
        return 1;
    }
    case M(PUSH):
        if (d->size == 2) return 0;
        if (d->type == OP_REG && d->kind != RK_GPR) return 0;
        if (!read_op(off, in, d, 8, &b)) return 0;
        if (d->type == OP_IMM) b = str("0x%" PRIx64 "ull", (uint64_t)d->disp);
        emit("{ const uint64_t v = %s; r[RSP] -= 8; rc_sts(r[RSP], 8, v); }\n", b.s);
        return 1;
    case M(POP):
        if (!gpr(d) || d->size != 8) return 0;
        emit("{ const uint64_t v = rc_lds(r[RSP], 8); r[RSP] += 8; r[%d] = v; }\n", d->reg);
        return 1;
    case M(LEAVE):
        emit("r[RSP] = r[RBP]; r[RBP] = rc_lds(r[RSP], 8); r[RSP] += 8;\n");
        return 1;
    case M(JMP):
        if (d->type == OP_IMM) {
            jump(f, off + (uint64_t)d->disp);
            emit("\n");
            return 1;
        }
        if (!read_op(off, in, d, 8, &b)) return 0;
        emit("{ dn = %s; goto L_dispatch; }\n", b.s);
        ++stats[1];
        return 1;
    case M(CALL): {
        if (d->type == OP_IMM) {
            /* A recompiled callee directly, when the program filled its slot (the game: the ones it
             * runs; the replay leaves them empty and answers each call from the record). */
            const uint64_t t = off + (uint64_t)d->disp;
            if (is_recompiled(t)) {
                emit("{ extern RcFn d_%" PRIx64 "; %s " SPILL " %s if (d_%" PRIx64 ") { c->r[RSP] -= 8; rc_st(c->r[RSP], 8, B + 0x%" PRIx64
                     "ull); c->rip = B + 0x%" PRIx64 "ull; %s_%" PRIx64 "(c); } else rc->call(c, B + 0x%" PRIx64 "ull, B + 0x%" PRIx64
                     "ull); " RELOAD " fk = FK_CPU; if (c->rip != B + 0x%" PRIx64 "ull%s) { dn = c->rip; goto L_dispatch; } }\n",
                     t, direct_declaration(t), call_flags_out(off, t), t, next, t, gen_direct ? "f" : "d", t, t, next, next, mxcsr_exit());
                return 1;
            }
            b = str("B + 0x%" PRIx64 "ull", t);
            if (import_name(t)) emit("/* %s */ ", import_name(t));
        } else if (!read_op(off, in, d, 8, &b)) {
            return 0;
        }
        emit("{ const uint64_t t = %s; " SPILL " " FLAGS_OUT " rc->call(c, t, B + 0x%" PRIx64 "ull); " RELOAD " fk = FK_CPU; if (c->rip != B + 0x%" PRIx64 "ull%s) { dn = c->rip; goto L_dispatch; } }\n", b.s, next, next, mxcsr_exit());
        return 1;
    }
    case M(RET): {
        const uint64_t pop = 8 + (in->count && d->type == OP_IMM ? (uint64_t)d->disp : 0);
        emit("{ const uint64_t t = rc_lds(r[RSP], 8); r[RSP] += %" PRIu64 "; " SPILL " %s c->rip = t; return; }\n", pop, ret_flags_out());
        return 1;
    }
    default:
        return translate_shift_mul(off, in) || translate_extra(off, in) || translate_vector(off, in);
    }
}


/* ---- vector instructions (as src/cpu/interp_vec.c does them) ---- */

static int vreg(const BbOp *op) { return op->type == OP_REG && op->kind == RK_VEC; }
static int vwidth(const BbInsn *in) { return in->vex && in->vl ? in->vl : 16; }

/* A vector operand's value (a BbVec expression). */
static int vread(uint64_t off, const BbInsn *in, const BbOp *op, Str *v) {
    if (vreg(op)) { *v = str("RC_V[%d]", op->reg); return 1; }
    if (op->type == OP_MEM) {
        Str a;
        int stack;
        if (!address(off, in, op, &a, &stack)) return 0;
        *v = str("rc_vld(%s, %d)", a.s, op->size);
        return 1;
    }
    if (gpr(op)) {
        Str g;
        if (!read_op(off, in, op, 8, &g)) return 0;
        *v = str("rc_vgpr(%s)", g.s);
        return 1;
    }
    return 0;
}

/* A statement writing BbVec `v` (`bytes` of it to a register). */
static int vwrite(uint64_t off, const BbInsn *in, const BbOp *op, const char *v, int bytes, Str *s) {
    if (vreg(op)) { *s = str("rc_vset(&RC_V[%d], %s, %d, %d);", op->reg, v, bytes, in->vex ? 1 : 0); return 1; }
    if (op->type == OP_MEM) {
        Str a;
        int stack;
        if (!address(off, in, op, &a, &stack)) return 0;
        *s = str("rc_vst(%s, %d, %s);", a.s, op->size, v);
        return 1;
    }
    return 0;
}

typedef struct { const BbOp *dst, *s1, *s2, *imm; } VOps;
static VOps vops3(const BbInsn *in) {
    VOps o = {&in->op[0], NULL, NULL, NULL};
    if (in->vex && in->count >= 3 && in->op[2].type != OP_IMM) {
        o.s1 = &in->op[1]; o.s2 = &in->op[2];
        if (in->count >= 4 && in->op[3].type == OP_IMM) o.imm = &in->op[3];
    } else {
        o.s1 = &in->op[0]; o.s2 = &in->op[1];
        if (in->count >= 3 && in->op[2].type == OP_IMM) o.imm = &in->op[2];
    }
    return o;
}
static VOps vops1(const BbInsn *in) {
    VOps o = {&in->op[0], NULL, NULL, NULL};
    int last = in->count - 1;
    if (in->op[last].type == OP_IMM) { o.imm = &in->op[last]; --last; }
    o.s2 = &in->op[last];
    o.s1 = &in->op[0];
    return o;
}

/* Two sources, a lane loop, the destination: `body` sets rr from a and b (i: the lane). */
static int vbinary(uint64_t off, const BbInsn *in, int lanes, int bytes, int zero, const char *body) {
    const VOps o = vops3(in);
    Str a, b, w;
    if (!vread(off, in, o.s1, &a) || !vread(off, in, o.s2, &b) || !vwrite(off, in, o.dst, "rr", bytes, &w)) return 0;
    emit("{ const BbVec a = %s, b = %s; BbVec rr = a; %s for (int i = 0; i < %d; ++i) { %s } %s }\n", a.s, b.s,
         zero ? "memset(&rr, 0, sizeof(rr));" : "", lanes, body, w.s);
    return 1;
}

static int translate_vector(uint64_t off, const BbInsn *in) {
    const int m = in->mnemonic, w = vwidth(in);
    Str a, b, s;
    const char *name = ZydisMnemonicGetString((ZydisMnemonic)m);
    if (name && !strncmp(name, "vf", 2)) {
        name += 2;
        const int negate_product = *name == 'n';
        if (negate_product) ++name;
        int negate_addend;
        if (!strncmp(name, "madd", 4)) negate_addend = 0;
        else if (!strncmp(name, "msub", 4)) negate_addend = 1;
        else return 0;
        name += 4;
        if (strlen(name) != 5) return 0;
        const int form = atoi(name);
        if (form != 132 && form != 213 && form != 231) return 0;
        if ((name[3] != 'p' && name[3] != 's') || (name[4] != 's' && name[4] != 'd')) return 0;
        const int scalar = name[3] == 's', dbl = name[4] == 'd';
        const int lane_bytes = dbl ? 8 : 4;
        const int lanes = scalar ? 1 : w / lane_bytes;
        Str d;
        if (!vreg(&in->op[0]) || !vread(off, in, &in->op[0], &d) ||
            !vread(off, in, &in->op[1], &a) || !vread(off, in, &in->op[2], &b) ||
            !vwrite(off, in, &in->op[0], "rr", scalar ? 16 : w, &s)) return 0;
        emit("{ const BbVec d = %s, s2 = %s, s3 = %s; BbVec rr; " FP_HOST " rr = bb_fp_fma_host(d, s2, s3, %d, %d, %d, %d, %d); "
             "else { " FP_BEGIN " rr = bb_fp_fma_in_env(d, s2, s3, %d, %d, %d, %d, %d, c->mxcsr); } %s }\n",
             d.s, a.s, b.s, form, negate_product, negate_addend, dbl, lanes, form, negate_product, negate_addend, dbl, lanes, s.s);
        return 1;
    }
    switch (m) {
    case M(MOVAPS): case M(MOVUPS): case M(MOVAPD): case M(MOVUPD): case M(MOVDQA): case M(MOVDQU):
    case M(VMOVAPS): case M(VMOVUPS): case M(VMOVAPD): case M(VMOVUPD): case M(VMOVDQA): case M(VMOVDQU):
    case M(LDDQU): case M(VLDDQU):
        if (!vread(off, in, &in->op[1], &a) || !vwrite(off, in, &in->op[0], a.s, in->op[0].size, &s)) return 0;
        emit("%s\n", s.s);
        return 1;
    case M(MOVSS): case M(VMOVSS): case M(MOVSD): case M(VMOVSD): {
        if (m == M(MOVSD) && !(in->count && vreg(&in->op[0])) && !(in->count >= 2 && vreg(&in->op[1]))) return 0;
        const int bytes = (m == M(MOVSS) || m == M(VMOVSS)) ? 4 : 8;
        const BbOp *d = &in->op[0];
        if (d->type == OP_MEM) {
            Str ad;
            int stack;
            if (!vread(off, in, &in->op[in->count - 1], &a) || !address(off, in, d, &ad, &stack)) return 0;
            emit("rc_vst(%s, %d, %s);\n", ad.s, bytes, a.s);
            return 1;
        }
        if (!vreg(d)) return 0;
        if (in->count == 3) {
            if (!vread(off, in, &in->op[1], &a) || !vread(off, in, &in->op[2], &b)) return 0;
            emit("{ BbVec rr = %s; const BbVec b = %s; memcpy(rr.b, b.b, %d); rc_vset(&RC_V[%d], rr, 16, %d); }\n", a.s, b.s,
                 bytes, d->reg, in->vex ? 1 : 0);
            return 1;
        }
        const BbOp *src = &in->op[1];
        if (src->type == OP_MEM) {
            Str ad;
            int stack;
            if (!address(off, in, src, &ad, &stack)) return 0;
            if (in->vex) emit("rc_vset(&RC_V[%d], rc_vld(%s, %d), 16, 1);\n", d->reg, ad.s, bytes);
            else emit("{ const BbVec rr = rc_vld(%s, %d); memcpy(RC_V[%d].b, rr.b, 16); }\n", ad.s, bytes, d->reg);
            return 1;
        }
        if (!vreg(src)) return 0;
        emit("{ BbVec rr = RC_V[%d]; memcpy(rr.b, RC_V[%d].b, %d); rc_vset(&RC_V[%d], rr, 16, %d); }\n", d->reg,
             src->reg, bytes, d->reg, in->vex ? 1 : 0);
        return 1;
    }
    case M(ADDPS): case M(VADDPS): case M(SUBPS): case M(VSUBPS): case M(MULPS): case M(VMULPS):
    case M(DIVPS): case M(VDIVPS): case M(MINPS): case M(VMINPS): case M(MAXPS): case M(VMAXPS):
    case M(ADDSS): case M(VADDSS): case M(SUBSS): case M(VSUBSS): case M(MULSS): case M(VMULSS):
    case M(DIVSS): case M(VDIVSS): case M(MINSS): case M(VMINSS): case M(MAXSS): case M(VMAXSS):
    case M(ADDPD): case M(VADDPD): case M(SUBPD): case M(VSUBPD): case M(MULPD): case M(VMULPD):
    case M(DIVPD): case M(VDIVPD): case M(ADDSD): case M(VADDSD): case M(SUBSD): case M(VSUBSD):
    case M(MULSD): case M(VMULSD): case M(DIVSD): case M(VDIVSD): {
        const char *name = ZydisMnemonicGetString((ZydisMnemonic)m);
        const char *base = name[0] == 'v' ? name + 1 : name;
        const int dbl = base[strlen(base) - 1] == 'd', scalar = base[strlen(base) - 2] == 's';
        const int lane_bytes = dbl ? 8 : 4;
        const int lanes = scalar ? 1 : w / lane_bytes;
        const char *kind = "BB_FP_MAX";
        if (!strncmp(base, "add", 3)) kind = "BB_FP_ADD";
        else if (!strncmp(base, "sub", 3)) kind = "BB_FP_SUB";
        else if (!strncmp(base, "mul", 3)) kind = "BB_FP_MUL";
        else if (!strncmp(base, "div", 3)) kind = "BB_FP_DIV";
        else if (!strncmp(base, "min", 3)) kind = "BB_FP_MIN";
        const VOps o = vops3(in);
        int result_bytes = w;
        if (scalar) result_bytes = in->vex ? 16 : lane_bytes;
        if (!vread(off, in, o.s1, &a) || !vread(off, in, o.s2, &b) ||
            !vwrite(off, in, o.dst, "rr", result_bytes, &s)) return 0;
        emit("{ const BbVec a = %s, b = %s; BbVec rr; " FP_HOST " rr = bb_fp_binary_host(a, b, %s, %d, %d); "
             "else { " FP_BEGIN " rr = bb_fp_binary_in_env(a, b, %s, %d, %d, c->mxcsr); } %s }\n",
             a.s, b.s, kind, dbl, lanes, kind, dbl, lanes, s.s);
        return 1;
    }
    case M(ANDPS): case M(VANDPS): case M(ANDPD): case M(VANDPD): case M(PAND): case M(VPAND):
        return vbinary(off, in, 4, w, 0, "rr.q[i] = a.q[i] & b.q[i];");
    case M(ANDNPS): case M(VANDNPS): case M(ANDNPD): case M(VANDNPD): case M(PANDN): case M(VPANDN):
        return vbinary(off, in, 4, w, 0, "rr.q[i] = ~a.q[i] & b.q[i];");
    case M(ORPS): case M(VORPS): case M(ORPD): case M(VORPD): case M(POR): case M(VPOR):
        return vbinary(off, in, 4, w, 0, "rr.q[i] = a.q[i] | b.q[i];");
    case M(XORPS): case M(VXORPS): case M(XORPD): case M(VXORPD): case M(PXOR): case M(VPXOR):
        return vbinary(off, in, 4, w, 0, "rr.q[i] = a.q[i] ^ b.q[i];");
    case M(PADDD): case M(VPADDD): return vbinary(off, in, w / 4, w, 1, "rr.d[i] = a.d[i] + b.d[i];");
    case M(PSUBD): case M(VPSUBD): return vbinary(off, in, w / 4, w, 1, "rr.d[i] = a.d[i] - b.d[i];");
    case M(PADDQ): case M(VPADDQ): return vbinary(off, in, w / 8, w, 1, "rr.q[i] = a.q[i] + b.q[i];");
    case M(PSUBQ): case M(VPSUBQ): return vbinary(off, in, w / 8, w, 1, "rr.q[i] = a.q[i] - b.q[i];");
    case M(PCMPEQB): case M(VPCMPEQB): return vbinary(off, in, w, w, 1, "rr.b[i] = a.b[i] == b.b[i] ? 0xff : 0;");
    case M(PCMPEQD): case M(VPCMPEQD): return vbinary(off, in, w / 4, w, 1, "rr.d[i] = a.d[i] == b.d[i] ? ~0u : 0;");
    case M(PCMPEQQ): case M(VPCMPEQQ): return vbinary(off, in, w / 8, w, 1, "rr.q[i] = a.q[i] == b.q[i] ? ~0ull : 0;");
    case M(HADDPS): case M(VHADDPS): case M(HSUBPS): case M(VHSUBPS): {
        const char *op = (m == M(HADDPS) || m == M(VHADDPS)) ? "+" : "-";
        const Str body = str("const float *x = a.f + i * 4, *y = b.f + i * 4; rr.f[i * 4] = x[0] %s x[1]; "
                             "rr.f[i * 4 + 1] = x[2] %s x[3]; rr.f[i * 4 + 2] = y[0] %s y[1]; rr.f[i * 4 + 3] = y[2] %s y[3];",
                             op, op, op, op);
        return vbinary(off, in, w / 16, w, 1, body.s);
    }
    case M(CMPPS): case M(VCMPPS): case M(CMPPD): case M(VCMPPD): case M(CMPSS): case M(VCMPSS): case M(CMPSD): case M(VCMPSD): {
        const VOps o = vops3(in);
        if (!o.imm) return 0;
        const int predicate = (int)o.imm->disp & 31;
        const int dbl = m == M(CMPPD) || m == M(VCMPPD) || m == M(CMPSD) || m == M(VCMPSD);
        const int scalar = m == M(CMPSS) || m == M(VCMPSS) || m == M(CMPSD) || m == M(VCMPSD);
        const int lane_bytes = dbl ? 8 : 4;
        const int lanes = scalar ? 1 : w / lane_bytes;
        const Str body = dbl ? str("rr.q[i] = rc_fcompare(bb_fp_input64(a.fd[i], c->mxcsr), bb_fp_input64(b.fd[i], c->mxcsr), %d) ? ~0ull : 0;", predicate)
                             : str("rr.d[i] = rc_fcompare(bb_fp_input32(a.f[i], c->mxcsr), bb_fp_input32(b.f[i], c->mxcsr), %d) ? ~0u : 0;", predicate);
        return vbinary(off, in, lanes, scalar ? 16 : w, 0, body.s);
    }
    case M(COMISS): case M(VCOMISS): case M(UCOMISS): case M(VUCOMISS): case M(COMISD): case M(VCOMISD):
    case M(UCOMISD): case M(VUCOMISD): {
        const int dbl = m == M(COMISD) || m == M(VCOMISD) || m == M(UCOMISD) || m == M(VUCOMISD);
        if (!vread(off, in, &in->op[0], &a) || !vread(off, in, &in->op[1], &b)) return 0;
        emit("{ const BbVec a = %s, b = %s; c->flags = rc_comis(c->flags, bb_fp_input%d(a.%s[0], c->mxcsr), bb_fp_input%d(b.%s[0], c->mxcsr)); fk = FK_CPU; }\n",
             a.s, b.s, dbl ? 64 : 32, dbl ? "fd" : "f", dbl ? 64 : 32, dbl ? "fd" : "f");
        return 1;
    }
    case M(SHUFPS): case M(VSHUFPS): {
        const VOps o = vops3(in);
        if (!o.imm) return 0;
        const int imm = (int)o.imm->disp;
        const Str body = str("rr.d[i * 4] = a.d[i * 4 + %d]; rr.d[i * 4 + 1] = a.d[i * 4 + %d]; rr.d[i * 4 + 2] = b.d[i * 4 + %d]; "
                             "rr.d[i * 4 + 3] = b.d[i * 4 + %d];", imm & 3, (imm >> 2) & 3, (imm >> 4) & 3, (imm >> 6) & 3);
        return vbinary(off, in, w / 16, w, 1, body.s);
    }
    case M(PSHUFD): case M(VPSHUFD): case M(VPERMILPS): {
        if (m == M(VPERMILPS) && in->op[2].type != OP_IMM) return 0;
        const VOps o = vops1(in);
        if (!o.imm || !vread(off, in, o.s2, &a) || !vwrite(off, in, o.dst, "rr", w, &s)) return 0;
        const int imm = (int)o.imm->disp;
        emit("{ const BbVec a = %s; BbVec rr = a; for (int h = 0; h < %d; ++h) { rr.d[h * 4] = a.d[h * 4 + %d]; "
             "rr.d[h * 4 + 1] = a.d[h * 4 + %d]; rr.d[h * 4 + 2] = a.d[h * 4 + %d]; rr.d[h * 4 + 3] = a.d[h * 4 + %d]; } %s }\n",
             a.s, w / 16, imm & 3, (imm >> 2) & 3, (imm >> 4) & 3, (imm >> 6) & 3, s.s);
        return 1;
    }
    case M(MOVMSKPS): case M(VMOVMSKPS): case M(PMOVMSKB): case M(VPMOVMSKB): {
        if (!vread(off, in, &in->op[1], &a)) return 0;
        Str wr;
        if (!write_op(off, in, &in->op[0], "mask", &wr)) return 0;
        const int bytes = m == M(PMOVMSKB) || m == M(VPMOVMSKB);
        emit("{ const BbVec a = %s; uint64_t mask = 0; for (int i = 0; i < %d; ++i) mask |= (uint64_t)(a.%s[i] >> %d) << i; %s }\n",
             a.s, bytes ? w : w / 4, bytes ? "b" : "d", bytes ? 7 : 31, wr.s);
        return 1;
    }
    case M(MOVHLPS): case M(VMOVHLPS): case M(MOVLHPS): case M(VMOVLHPS): {
        const VOps o = vops3(in);
        if (!vread(off, in, o.s1, &a) || !vread(off, in, o.s2, &b) || !vwrite(off, in, o.dst, "rr", 16, &s)) return 0;
        emit("{ BbVec rr = %s; const BbVec b = %s; %s %s }\n", a.s, b.s,
             (m == M(MOVHLPS) || m == M(VMOVHLPS)) ? "rr.q[0] = b.q[1];" : "rr.q[1] = b.q[0];", s.s);
        return 1;
    }
    case M(MOVLPS): case M(VMOVLPS): case M(MOVLPD): case M(VMOVLPD):
    case M(MOVHPS): case M(VMOVHPS): case M(MOVHPD): case M(VMOVHPD): {
        const int high = m == M(MOVHPS) || m == M(VMOVHPS) || m == M(MOVHPD) || m == M(VMOVHPD);
        const BbOp *dst = &in->op[0];
        Str ad;
        int stack;
        if (dst->type == OP_MEM) {
            if (!vread(off, in, &in->op[1], &a) || !address(off, in, dst, &ad, &stack)) return 0;
            emit("{ const BbVec a = %s; %s(%s, 8, a.q[%d]); }\n", a.s, stack ? "rc_sts" : "rc_st", ad.s, high);
        } else {
            if (!vread(off, in, in->count == 3 ? &in->op[1] : dst, &a) ||
                !address(off, in, &in->op[in->count - 1], &ad, &stack) || !vwrite(off, in, dst, "rr", 16, &s)) return 0;
            emit("{ BbVec rr = %s; rr.q[%d] = %s(%s, 8); %s }\n", a.s, high, stack ? "rc_lds" : "rc_ld", ad.s, s.s);
        }
        return 1;
    }
    case M(CVTSS2SD): case M(VCVTSS2SD): case M(CVTSD2SS): case M(VCVTSD2SS): {
        const VOps o = vops3(in);
        const int widen = m == M(CVTSS2SD) || m == M(VCVTSS2SD);
        if (!vread(off, in, o.s1, &a) || !vread(off, in, o.s2, &b) || !vwrite(off, in, o.dst, "rr", 16, &s)) return 0;
        const char *from = widen ? "BB_FP_F32" : "BB_FP_F64", *to = widen ? "BB_FP_F64" : "BB_FP_F32";
        emit("{ const BbVec a = %s, b = %s; BbVec rr; " FP_HOST " rr = bb_fp_convert_host(a, b, %s, %s, 1, 0); "
             "else { " FP_BEGIN " rr = bb_fp_convert_in_env(a, b, %s, %s, 1, 0, c->mxcsr); } %s }\n",
             a.s, b.s, from, to, from, to, s.s);
        return 1;
    }
    case M(MOVD): case M(VMOVD): case M(MOVQ): case M(VMOVQ): {
        const BbOp *d = &in->op[0], *src = &in->op[1];
        const int bytes = (m == M(MOVD) || m == M(VMOVD)) ? 4 : 8;
        if (!vread(off, in, src, &a)) return 0;
        if (vreg(d)) {
            emit("{ BbVec rr; memset(&rr, 0, sizeof(rr)); const BbVec s = %s; memcpy(rr.b, s.b, %d); memcpy(RC_V[%d].b, rr.b, 16);%s }\n",
                 a.s, bytes, d->reg, in->vex ? str(" memset(RC_V[%d].b + 16, 0, 16);", d->reg).s : "");
            return 1;
        }
        if (d->type == OP_MEM) {
            Str ad;
            int stack;
            if (!address(off, in, d, &ad, &stack)) return 0;
            emit("rc_vst(%s, %d, %s);\n", ad.s, bytes, a.s);
            return 1;
        }
        Str wr;
        if (!write_op(off, in, d, bytes == 4 ? "s.d[0]" : "s.q[0]", &wr)) return 0;
        emit("{ const BbVec s = %s; %s }\n", a.s, wr.s);
        return 1;
    }
    case M(DPPS): case M(VDPPS): { /* the hardware's pairwise order: (p0 + p1) + (p2 + p3) */
        const VOps o = vops3(in);
        if (!o.imm) return 0;
        const int imm = (int)o.imm->disp & 0xff;
        const Str body = str("float p[4]; for (int k = 0; k < 4; ++k) p[k] = (%d & (0x10 << k)) ? a.f[i * 4 + k] * b.f[i * 4 + k] : 0.0f; "
                             "const float sum = (p[0] + p[1]) + (p[2] + p[3]); "
                             "for (int k = 0; k < 4; ++k) rr.f[i * 4 + k] = (%d & (1 << k)) ? sum : 0.0f;", imm, imm);
        return vbinary(off, in, w / 16, w, 1, body.s);
    }
    case M(INSERTPS): case M(VINSERTPS): {
        const VOps o = vops3(in);
        if (!o.imm || !vread(off, in, o.s1, &a) || !vread(off, in, o.s2, &b) || !vwrite(off, in, o.dst, "rr", 16, &s)) return 0;
        const int imm = (int)o.imm->disp & 0xff;
        emit("{ BbVec rr = %s; const BbVec b = %s; rr.d[%d] = b.d[%d];", a.s, b.s, (imm >> 4) & 3,
             o.s2->type == OP_MEM ? 0 : (imm >> 6) & 3);
        for (int i = 0; i < 4; ++i) if (imm & (1 << i)) emit(" rr.d[%d] = 0;", i);
        emit(" %s }\n", s.s);
        return 1;
    }
    case M(BLENDVPS): case M(VBLENDVPS): case M(BLENDVPD): case M(VBLENDVPD): case M(PBLENDVB): case M(VPBLENDVB): {
        Str mk;
        if (in->vex) {
            if (in->count < 4 || !vread(off, in, &in->op[1], &a) || !vread(off, in, &in->op[2], &b) ||
                !vread(off, in, &in->op[3], &mk)) return 0;
        } else {
            if (!vread(off, in, &in->op[0], &a) || !vread(off, in, &in->op[1], &b)) return 0;
            mk = str("RC_V[0]");
        }
        if (!vwrite(off, in, &in->op[0], "rr", w, &s)) return 0;
        const int es = (m == M(BLENDVPS) || m == M(VBLENDVPS)) ? 4 : (m == M(BLENDVPD) || m == M(VBLENDVPD)) ? 8 : 1;
        emit("{ BbVec rr = %s; const BbVec b = %s, mk = %s; for (int i = 0; i < %d; ++i) if (mk.b[i * %d + %d] & 0x80) "
             "memcpy(rr.b + i * %d, b.b + i * %d, %d); %s }\n", a.s, b.s, mk.s, w / es, es, es - 1, es, es, es, s.s);
        return 1;
    }
    case M(BLENDPS): case M(VBLENDPS): case M(BLENDPD): case M(VBLENDPD): case M(PBLENDW): case M(VPBLENDW): case M(VPBLENDD): {
        const VOps o = vops3(in);
        if (!o.imm || !vread(off, in, o.s1, &a) || !vread(off, in, o.s2, &b) || !vwrite(off, in, o.dst, "rr", w, &s)) return 0;
        const int imm = (int)o.imm->disp & 0xff;
        const int es = (m == M(BLENDPS) || m == M(VBLENDPS) || m == M(VPBLENDD)) ? 4 : (m == M(BLENDPD) || m == M(VBLENDPD)) ? 8 : 2;
        emit("{ BbVec rr = %s; const BbVec b = %s;", a.s, b.s);
        for (int i = 0; i < w / es; ++i)
            if (imm & (1 << (es == 2 ? (i & 7) : i))) emit(" memcpy(rr.b + %d, b.b + %d, %d);", i * es, i * es, es);
        emit(" %s }\n", s.s);
        return 1;
    }
    case M(SQRTPS): case M(VSQRTPS): case M(SQRTPD): case M(VSQRTPD):
    case M(SQRTSS): case M(VSQRTSS): case M(SQRTSD): case M(VSQRTSD): {
        const int scalar = m == M(SQRTSS) || m == M(VSQRTSS) || m == M(SQRTSD) || m == M(VSQRTSD);
        const int dbl = m == M(SQRTPD) || m == M(VSQRTPD) || m == M(SQRTSD) || m == M(VSQRTSD);
        const VOps o = scalar ? vops3(in) : vops1(in);
        if (o.imm || !vread(off, in, o.s2, &b) || !vwrite(off, in, o.dst, "rr", scalar ? 16 : w, &s)) return 0;
        a = str("(BbVec){0}");
        if (scalar && !vread(off, in, o.s1, &a)) return 0;
        const int lane_bytes = dbl ? 8 : 4;
        const int lanes = scalar ? 1 : w / lane_bytes;
        emit("{ const BbVec a = %s, b = %s; BbVec rr; " FP_HOST " rr = bb_fp_sqrt_host(a, b, %d, %d); "
             "else rr = bb_fp_sqrt(a, b, %d, %d, c->mxcsr); %s }\n", a.s, b.s, dbl, lanes, dbl, lanes, s.s);
        return 1;
    }
    case M(RSQRTPS): case M(VRSQRTPS): case M(RCPPS): case M(VRCPPS): {
        const VOps o = vops1(in);
        if (o.imm || !vread(off, in, o.s2, &a) || !vwrite(off, in, o.dst, "rr", w, &s)) return 0;
        const int root = m == M(RSQRTPS) || m == M(VRSQRTPS);
        emit("{ const BbVec a = %s; BbVec rr; " FP_HOST " rr = bb_fp_approx_host((BbVec){0}, a, %d, %d); "
             "else rr = bb_fp_approx((BbVec){0}, a, %d, %d); %s }\n", a.s, root, w / 4, root, w / 4, s.s);
        return 1;
    }
    case M(RSQRTSS): case M(VRSQRTSS): case M(RCPSS): case M(VRCPSS): {
        const VOps o = vops3(in);
        if (o.imm || !vread(off, in, o.s1, &a) || !vread(off, in, o.s2, &b) || !vwrite(off, in, o.dst, "rr", 16, &s)) return 0;
        const int root = m == M(RSQRTSS) || m == M(VRSQRTSS);
        emit("{ const BbVec a = %s, b = %s; BbVec rr; " FP_HOST " rr = bb_fp_approx_host(a, b, %d, 1); "
             "else rr = bb_fp_approx(a, b, %d, 1); %s }\n", a.s, b.s, root, root, s.s);
        return 1;
    }
    case M(CVTSI2SS): case M(VCVTSI2SS): case M(CVTSI2SD): case M(VCVTSI2SD): {
        const VOps o = vops3(in);
        Str g;
        if (o.imm || (o.s2->size != 4 && o.s2->size != 8) || !vread(off, in, o.s1, &a) || !read_op(off, in, o.s2, o.s2->size, &g) ||
            !vwrite(off, in, o.dst, "rr", 16, &s)) return 0;
        const char *from = o.s2->size == 8 ? "BB_FP_I64" : "BB_FP_I32";
        const char *to = (m == M(CVTSI2SS) || m == M(VCVTSI2SS)) ? "BB_FP_F32" : "BB_FP_F64";
        emit("{ const BbVec iv = rc_vgpr((uint64_t)(%s)), a = %s; BbVec rr; " FP_HOST " rr = bb_fp_convert_host(a, iv, %s, %s, 1, 0); "
             "else { " FP_BEGIN " rr = bb_fp_convert_in_env(a, iv, %s, %s, 1, 0, c->mxcsr); } %s }\n",
             g.s, a.s, from, to, from, to, s.s);
        return 1;
    }
    case M(CVTTSS2SI): case M(VCVTTSS2SI): case M(CVTSS2SI): case M(VCVTSS2SI): case M(CVTTSD2SI): case M(VCVTTSD2SI):
    case M(CVTSD2SI): case M(VCVTSD2SI): {
        const BbOp *d = &in->op[0];
        Str wr;
        if (!gpr(d) || (d->size != 4 && d->size != 8) || !vread(off, in, &in->op[1], &a)) return 0;
        const int truncate = m == M(CVTTSS2SI) || m == M(VCVTTSS2SI) || m == M(CVTTSD2SI) || m == M(VCVTTSD2SI);
        const int dbl = m == M(CVTTSD2SI) || m == M(VCVTTSD2SI) || m == M(CVTSD2SI) || m == M(VCVTSD2SI);
        if (!write_op(off, in, d, d->size == 8 ? "rr.q[0]" : "rr.d[0]", &wr)) return 0;
        const char *from = dbl ? "BB_FP_F64" : "BB_FP_F32", *to = d->size == 8 ? "BB_FP_I64" : "BB_FP_I32";
        emit("{ const BbVec a = %s; BbVec rr; " FP_HOST " rr = bb_fp_convert_host((BbVec){0}, a, %s, %s, 1, %d); "
             "else { " FP_BEGIN " rr = bb_fp_convert_in_env((BbVec){0}, a, %s, %s, 1, %d, c->mxcsr); } %s }\n",
             a.s, from, to, truncate, from, to, truncate, wr.s);
        return 1;
    }
    case M(CVTDQ2PS): case M(VCVTDQ2PS): case M(CVTPS2DQ): case M(VCVTPS2DQ): case M(CVTTPS2DQ): case M(VCVTTPS2DQ): {
        if (!vread(off, in, &in->op[1], &a) || !vwrite(off, in, &in->op[0], "rr", w, &s)) return 0;
        const int to_float = m == M(CVTDQ2PS) || m == M(VCVTDQ2PS);
        const int truncate = m == M(CVTTPS2DQ) || m == M(VCVTTPS2DQ);
        const char *from = to_float ? "BB_FP_I32" : "BB_FP_F32", *to = to_float ? "BB_FP_F32" : "BB_FP_I32";
        emit("{ const BbVec a = %s; BbVec rr; " FP_HOST " rr = bb_fp_convert_host((BbVec){0}, a, %s, %s, %d, %d); "
             "else { " FP_BEGIN " rr = bb_fp_convert_in_env((BbVec){0}, a, %s, %s, %d, %d, c->mxcsr); } %s }\n",
             a.s, from, to, w / 4, truncate, from, to, w / 4, truncate, s.s);
        return 1;
    }
    case M(VBROADCASTSS): case M(VBROADCASTSD): case M(VBROADCASTF128): case M(VPBROADCASTD): case M(VPBROADCASTQ):
    case M(VPBROADCASTB): case M(VPBROADCASTW): {
        if (!vread(off, in, &in->op[1], &a) || !vwrite(off, in, &in->op[0], "rr", w, &s)) return 0;
        const int es = (m == M(VBROADCASTSS) || m == M(VPBROADCASTD)) ? 4 : (m == M(VBROADCASTSD) || m == M(VPBROADCASTQ)) ? 8
                     : m == M(VPBROADCASTB) ? 1 : m == M(VPBROADCASTW) ? 2 : 16;
        emit("{ const BbVec x = %s; BbVec rr; memset(&rr, 0, sizeof(rr)); for (int i = 0; i < %d; i += %d) memcpy(rr.b + i, x.b, %d); %s }\n",
             a.s, w, es, es, s.s);
        return 1;
    }
    case M(UNPCKLPS): case M(VUNPCKLPS): case M(UNPCKHPS): case M(VUNPCKHPS):
        return vbinary(off, in, w / 16, w, 1, (m == M(UNPCKLPS) || m == M(VUNPCKLPS))
            ? "rr.d[i * 4] = a.d[i * 4]; rr.d[i * 4 + 1] = b.d[i * 4]; rr.d[i * 4 + 2] = a.d[i * 4 + 1]; rr.d[i * 4 + 3] = b.d[i * 4 + 1];"
            : "rr.d[i * 4] = a.d[i * 4 + 2]; rr.d[i * 4 + 1] = b.d[i * 4 + 2]; rr.d[i * 4 + 2] = a.d[i * 4 + 3]; rr.d[i * 4 + 3] = b.d[i * 4 + 3];");
    case M(UNPCKLPD): case M(VUNPCKLPD): case M(UNPCKHPD): case M(VUNPCKHPD):
        return vbinary(off, in, w / 16, w, 1, (m == M(UNPCKLPD) || m == M(VUNPCKLPD))
            ? "rr.q[i * 2] = a.q[i * 2]; rr.q[i * 2 + 1] = b.q[i * 2];" : "rr.q[i * 2] = a.q[i * 2 + 1]; rr.q[i * 2 + 1] = b.q[i * 2 + 1];");
    case M(PUNPCKLBW): case M(VPUNPCKLBW): case M(PUNPCKLWD): case M(VPUNPCKLWD):
    case M(PUNPCKLQDQ): case M(VPUNPCKLQDQ): {
        int es = 8;
        if (m == M(PUNPCKLBW) || m == M(VPUNPCKLBW)) es = 1;
        else if (m == M(PUNPCKLWD) || m == M(VPUNPCKLWD)) es = 2;
        const Str body = str("for (int j = 0; j < %d; ++j) { memcpy(rr.b + i * 16 + j * %d, a.b + i * 16 + j * %d, %d); "
                             "memcpy(rr.b + i * 16 + j * %d + %d, b.b + i * 16 + j * %d, %d); }",
                             8 / es, 2 * es, es, es, 2 * es, es, es, es);
        return vbinary(off, in, w / 16, w, 1, body.s);
    }
    case M(PACKSSDW): case M(VPACKSSDW): case M(PACKSSWB): case M(VPACKSSWB): case M(PACKUSWB): case M(VPACKUSWB): {
        const int dwords = m == M(PACKSSDW) || m == M(VPACKSSDW);
        const int unsign = m == M(PACKUSWB) || m == M(VPACKUSWB);
        int low = -128, high = 127;
        if (dwords) { low = -32768; high = 32767; }
        else if (unsign) { low = 0; high = 255; }
        const Str body = str("for (int j = 0; j < %d; ++j) { int32_t x = a.%s[i * %d + j], y = b.%s[i * %d + j]; "
                             "if (x < %d) x = %d; else if (x > %d) x = %d; "
                             "if (y < %d) y = %d; else if (y > %d) y = %d; "
                             "rr.%s[i * %d + j] = x; rr.%s[i * %d + %d + j] = y; }",
                             dwords ? 4 : 8, dwords ? "sd" : "sw", dwords ? 4 : 8, dwords ? "sd" : "sw", dwords ? 4 : 8,
                             low, low, high, high, low, low, high, high, dwords ? "sw" : "b", dwords ? 8 : 16,
                             dwords ? "sw" : "b", dwords ? 8 : 16, dwords ? 4 : 8);
        return vbinary(off, in, w / 16, w, 1, body.s);
    }
    case M(PSLLW): case M(VPSLLW): case M(PSLLD): case M(VPSLLD): case M(PSLLQ): case M(VPSLLQ): case M(PSRLW): case M(VPSRLW):
    case M(PSRLD): case M(VPSRLD): case M(PSRLQ): case M(VPSRLQ): case M(PSRAW): case M(VPSRAW): case M(PSRAD): case M(VPSRAD):
    case M(PSLLDQ): case M(VPSLLDQ): case M(PSRLDQ): case M(VPSRLDQ): {
        const BbOp *src = in->vex ? &in->op[1] : &in->op[0], *cnt = in->vex ? &in->op[2] : &in->op[1];
        Str n;
        if (!vread(off, in, src, &a) || !vwrite(off, in, &in->op[0], "rr", w, &s)) return 0;
        if (cnt->type == OP_IMM) n = str("%" PRIu64 "ull", (uint64_t)cnt->disp & 0xff);
        else if (!vread(off, in, cnt, &b)) return 0;
        else n = str("(%s).q[0]", b.s);
        const char *body;
        switch (m) {
        case M(PSLLW): case M(VPSLLW): body = "for (int i = 0; i < %d / 2; ++i) rr.w[i] = n > 15 ? 0 : (uint16_t)(x.w[i] << n);"; break;
        case M(PSLLD): case M(VPSLLD): body = "for (int i = 0; i < %d / 4; ++i) rr.d[i] = n > 31 ? 0 : x.d[i] << n;"; break;
        case M(PSLLQ): case M(VPSLLQ): body = "for (int i = 0; i < %d / 8; ++i) rr.q[i] = n > 63 ? 0 : x.q[i] << n;"; break;
        case M(PSRLW): case M(VPSRLW): body = "for (int i = 0; i < %d / 2; ++i) rr.w[i] = n > 15 ? 0 : (uint16_t)(x.w[i] >> n);"; break;
        case M(PSRLD): case M(VPSRLD): body = "for (int i = 0; i < %d / 4; ++i) rr.d[i] = n > 31 ? 0 : x.d[i] >> n;"; break;
        case M(PSRLQ): case M(VPSRLQ): body = "for (int i = 0; i < %d / 8; ++i) rr.q[i] = n > 63 ? 0 : x.q[i] >> n;"; break;
        case M(PSRAW): case M(VPSRAW): body = "for (int i = 0; i < %d / 2; ++i) rr.sw[i] = (int16_t)(x.sw[i] >> (n > 15 ? 15 : n));"; break;
        case M(PSRAD): case M(VPSRAD): body = "for (int i = 0; i < %d / 4; ++i) rr.sd[i] = x.sd[i] >> (n > 31 ? 31 : n);"; break;
        case M(PSLLDQ): case M(VPSLLDQ):
            body = "for (int h = 0; h < %d / 16; ++h) for (int i = 0; i < 16; ++i) rr.b[h * 16 + i] = (uint64_t)i >= n ? x.b[h * 16 + i - n] : 0;"; break;
        default:
            body = "for (int h = 0; h < %d / 16; ++h) for (int i = 0; i < 16; ++i) rr.b[h * 16 + i] = i + n < 16 ? x.b[h * 16 + i + n] : 0;"; break;
        }
        emit("{ const BbVec x = %s; const uint64_t n = %s; BbVec rr; memset(&rr, 0, sizeof(rr)); ", a.s, n.s);
        emit(body, w);
        emit(" %s }\n", s.s);
        return 1;
    }
    case M(EXTRACTPS): case M(VEXTRACTPS): case M(PEXTRD): case M(VPEXTRD): case M(PEXTRQ): case M(VPEXTRQ):
    case M(PEXTRW): case M(VPEXTRW): case M(PEXTRB): case M(VPEXTRB): {
        if (in->count < 3 || in->op[2].type != OP_IMM || !vread(off, in, &in->op[1], &a)) return 0;
        const int imm = (int)in->op[2].disp;
        const Str v = (m == M(PEXTRQ) || m == M(VPEXTRQ)) ? str("x.q[%d]", imm & 1) : (m == M(PEXTRW) || m == M(VPEXTRW)) ? str("x.w[%d]", imm & 7)
                    : (m == M(PEXTRB) || m == M(VPEXTRB)) ? str("x.b[%d]", imm & 15) : str("x.d[%d]", imm & 3);
        BbOp dst = in->op[0];
        if (dst.type == OP_REG && dst.size < 4) dst.size = 4;
        Str wr;
        if (!write_op(off, in, &dst, v.s, &wr)) return 0;
        emit("{ const BbVec x = %s; %s }\n", a.s, wr.s);
        return 1;
    }
    case M(PINSRD): case M(VPINSRD): case M(PINSRQ): case M(VPINSRQ): case M(PINSRW): case M(VPINSRW): case M(PINSRB): case M(VPINSRB): {
        const VOps o = vops3(in);
        Str g;
        if (!o.imm || !vread(off, in, o.s1, &a) || !read_op(off, in, o.s2, o.s2->size, &g) || !vwrite(off, in, o.dst, "rr", 16, &s)) return 0;
        const int imm = (int)o.imm->disp;
        const Str set = (m == M(PINSRQ) || m == M(VPINSRQ)) ? str("rr.q[%d] = v;", imm & 1)
                      : (m == M(PINSRW) || m == M(VPINSRW)) ? str("rr.w[%d] = (uint16_t)v;", imm & 7)
                      : (m == M(PINSRB) || m == M(VPINSRB)) ? str("rr.b[%d] = (uint8_t)v;", imm & 15) : str("rr.d[%d] = (uint32_t)v;", imm & 3);
        emit("{ BbVec rr = %s; const uint64_t v = %s; %s %s }\n", a.s, g.s, set.s, s.s);
        return 1;
    }
    case M(PALIGNR): case M(VPALIGNR): {
        const VOps o = vops3(in);
        if (!o.imm) return 0;
        const Str body = str("uint8_t cat[32]; memcpy(cat, b.b + i * 16, 16); memcpy(cat + 16, a.b + i * 16, 16); "
                             "for (int k = 0; k < 16; ++k) rr.b[i * 16 + k] = k + %d < 32 ? cat[k + %d] : 0;",
                             (int)o.imm->disp & 0xff, (int)o.imm->disp & 0xff);
        return vbinary(off, in, w / 16, w, 1, body.s);
    }
    default:
        return 0;
    }
}

/* Locked read-modify-writes (and xadd, cmpxchg): a compare-and-exchange loop, as the interpreter. */
static int translate_atomic(uint64_t off, const BbInsn *in) {
    const int m = in->mnemonic;
    const BbOp *d = &in->op[0], *src = &in->op[1];
    if (d->type != OP_MEM) return 0;
    const int size = d->size;
    if (size != 1 && size != 2 && size != 4 && size != 8) return 0;
    Str ad, b, w;
    int stack;
    if (!address(off, in, d, &ad, &stack)) return 0;
    const uint64_t mk = mask(size);
    switch (m) {
    case M(ADD): case M(SUB): case M(AND): case M(OR): case M(XOR): {
        const char *op = m == M(ADD) ? "+" : m == M(SUB) ? "-" : m == M(AND) ? "&" : m == M(OR) ? "|" : "^";
        if (!read_op(off, in, src, size, &b)) return 0;
        emit("{ const uint64_t ea = %s; const uint64_t b = %s; uint64_t a, seen; do a = rc_ld(ea, %d); "
             "while (!rc_cas(ea, %d, a, (a %s b) & 0x%" PRIx64 "ull, &seen)); const uint64_t v = (a %s b) & 0x%" PRIx64 "ull; "
             "fk = %s; fa = a; fb = b; fr = v; fz = %d; }\n", ad.s, b.s, size, size, op, mk, op, mk,
             m == M(ADD) ? "FK_ADD" : m == M(SUB) ? "FK_SUB" : "FK_LOGIC", size);
        return 1;
    }
    case M(INC): case M(DEC): {
        const char *op = m == M(INC) ? "+" : "-";
        emit("{ const uint64_t ea = %s; fcf = " COND "; uint64_t a, seen; do a = rc_ld(ea, %d); "
             "while (!rc_cas(ea, %d, a, (a %s 1) & 0x%" PRIx64 "ull, &seen)); const uint64_t v = (a %s 1) & 0x%" PRIx64 "ull; "
             "fk = %s; fa = a; fb = 1; fr = v; fz = %d; }\n", ad.s, 2, size, size, op, mk, op, mk,
             m == M(INC) ? "FK_INC" : "FK_DEC", size);
        return 1;
    }
    case M(XADD): {
        if (!gpr(src) || !read_op(off, in, src, size, &b) || !write_op(off, in, src, "a", &w)) return 0;
        emit("{ const uint64_t ea = %s; const uint64_t b = %s; uint64_t a, seen; do a = rc_ld(ea, %d); "
             "while (!rc_cas(ea, %d, a, (a + b) & 0x%" PRIx64 "ull, &seen)); fk = FK_ADD; fa = a; fb = b; "
             "fr = (a + b) & 0x%" PRIx64 "ull; fz = %d; %s }\n", ad.s, b.s, size, size, mk, mk, size, w.s);
        return 1;
    }
    case M(CMPXCHG): {
        const BbOp rax = {.type = OP_REG, .kind = RK_GPR, .reg = RAX, .size = (uint8_t)size};
        Str e;
        if (!gpr(src) || !read_op(off, in, src, size, &b) || !read_op(off, in, &rax, size, &e) ||
            !write_op(off, in, &rax, "seen", &w))
            return 0;
        emit("{ const uint64_t ea = %s; const uint64_t e = (%s) & 0x%" PRIx64 "ull; uint64_t seen; "
             "const int ok = rc_cas(ea, %d, e, %s, &seen); fk = FK_SUB; fa = e; fb = seen; fr = (e - seen) & 0x%" PRIx64 "ull; "
             "fz = %d; if (!ok) { %s } }\n", ad.s, e.s, mk, size, b.s, mk, size, w.s);
        return 1;
    }
    default:
        return 0;
    }
}

/* Sign extensions of rax; adc/sbb; bt/bts/btr/btc; shifts by cl. */
static int translate_extra(uint64_t off, const BbInsn *in) {
    const int m = in->mnemonic;
    const BbOp *d = &in->op[0], *src = &in->op[1];
    static const char *const sext[9] = {0, "int8_t", "int16_t", 0, "int32_t", 0, 0, 0, "int64_t"};
    Str a, b, w, ad;
    int stack = 0;
    switch (m) {
    case M(CBW): emit("r[RAX] = (r[RAX] & ~0xffffull) | ((uint64_t)(int16_t)(int8_t)r[RAX] & 0xffff);\n"); return 1;
    case M(CWDE): emit("r[RAX] = (uint32_t)(int32_t)(int16_t)r[RAX];\n"); return 1;
    case M(CDQE): emit("r[RAX] = (uint64_t)(int64_t)(int32_t)r[RAX];\n"); return 1;
    case M(CWD): emit("r[RDX] = (r[RDX] & ~0xffffull) | (((int16_t)r[RAX] < 0) ? 0xffff : 0);\n"); return 1;
    case M(CDQ): emit("r[RDX] = ((int32_t)r[RAX] < 0) ? 0xffffffffu : 0;\n"); return 1;
    case M(CQO): emit("r[RDX] = ((int64_t)r[RAX] < 0) ? ~0ull : 0;\n"); return 1;
    case M(ADC): case M(SBB): {
        const int size = d->size;
        if (!(gpr(d) || d->type == OP_MEM) || !read_op(off, in, src, size, &b)) return 0;
        emit("{ const uint64_t cy = " COND "; ", 2);
        if (d->type == OP_MEM) {
            if (!address(off, in, d, &ad, &stack)) return 0;
            emit("const uint64_t ea = %s; const uint64_t a = %s(ea, %d); ", ad.s, stack ? "rc_lds" : "rc_ld", size);
        } else {
            if (!read_op(off, in, d, size, &a)) return 0;
            emit("const uint64_t a = %s; ", a.s);
        }
        const char *op = m == M(ADC) ? "+" : "-";
        emit("const uint64_t b = %s; const uint64_t v = (a %s b %s cy) & 0x%" PRIx64 "ull; "
             "c->flags = rc_carry_flags(rc_flags(fk, fa, fb, fr, fz, fcf, c->flags), %d, a, b, cy, v, %d); fk = FK_CPU; ",
             b.s, op, op, mask(size), m == M(SBB), size);
        if (d->type == OP_MEM) emit("%s(ea, %d, v);", stack ? "rc_sts" : "rc_st", size);
        else {
            if (!write_op(off, in, d, "v", &w)) return 0;
            emit("%s", w.s);
        }
        emit(" }\n");
        return 1;
    }
    case M(BT): case M(BTS): case M(BTR): case M(BTC): {
        const int size = d->size, bits = size * 8;
        if (size < 2 || !read_op(off, in, src, size, &b)) return 0;
        const char *calc = m == M(BTS) ? "a | bm" : m == M(BTR) ? "a & ~bm" : m == M(BTC) ? "a ^ bm" : "a";
        emit("{ ");
        if (d->type == OP_MEM) { /* register bit offsets (reaching outside the operand): the interpreter */
            if (src->type != OP_IMM || !address(off, in, d, &ad, &stack)) return 0;
            emit("const uint64_t ea = %s; const unsigned bit = (unsigned)(%s) & %d; ", ad.s, b.s, bits - 1);
            emit("const uint64_t a = %s(ea, %d); ", stack ? "rc_lds" : "rc_ld", size);
        } else if (gpr(d)) {
            if (!read_op(off, in, d, size, &a)) return 0;
            emit("const uint64_t a = %s; const unsigned bit = (unsigned)(%s) & %d; ", a.s, b.s, bits - 1);
        } else {
            return 0;
        }
        emit("const uint64_t bm = 1ull << bit; c->flags = (rc_flags(fk, fa, fb, fr, fz, fcf, c->flags) & ~(uint64_t)F_CF) | "
             "((a & bm) ? F_CF : 0); fk = FK_CPU; ");
        if (m != M(BT)) {
            emit("const uint64_t v = %s; ", calc);
            if (d->type == OP_MEM) emit("%s(ea, %d, v);", stack ? "rc_sts" : "rc_st", size);
            else {
                if (!write_op(off, in, d, "v", &w)) return 0;
                emit("%s", w.s);
            }
        }
        emit(" }\n");
        return 1;
    }
    case M(SHL): case M(SHR): case M(SAR): {
        if (in->count < 2 || src->type != OP_REG || src->reg != RCX || src->size != 1) return 0;
        const int size = d->size, bits = size * 8;
        if (!sext[size]) return 0;
        if (gpr(d) && size == 4) emit("r[%d] = (uint32_t)r[%d];\n", d->reg, d->reg);
        emit("{ const unsigned n = (unsigned)r[RCX] & %d; if (n) { ", size == 8 ? 63 : 31);
        if (d->type == OP_MEM) {
            if (!address(off, in, d, &ad, &stack)) return 0;
            emit("const uint64_t ea = %s; const uint64_t a = %s(ea, %d); ", ad.s, stack ? "rc_lds" : "rc_ld", size);
        } else if (gpr(d)) {
            if (!read_op(off, in, d, size, &a)) return 0;
            emit("const uint64_t a = %s; ", a.s);
        } else {
            return 0;
        }
        if (m == M(SHL)) emit("const uint64_t v = n >= %d ? 0 : (a << n) & 0x%" PRIx64 "ull; ", bits, mask(size));
        else if (m == M(SHR)) emit("const uint64_t v = n >= %d ? 0 : a >> n; ", bits);
        else emit("const uint64_t v = (uint64_t)((int64_t)(%s)a >> (n >= %d ? %d : n)) & 0x%" PRIx64 "ull; ", sext[size], bits,
                  bits - 1, mask(size));
        emit("c->flags = rc_shift_flags(rc_flags(fk, fa, fb, fr, fz, fcf, c->flags), %d, %s, n, v, %d); fk = FK_CPU; ",
             m == M(SHL) ? 0 : m == M(SHR) ? 1 : 2, m == M(SAR) ? str("(uint64_t)(int64_t)(%s)a", sext[size]).s : "a", size);
        if (d->type == OP_MEM) emit("%s(ea, %d, v);", stack ? "rc_sts" : "rc_st", size);
        else {
            if (!write_op(off, in, d, "v", &w)) return 0;
            emit("%s", w.s);
        }
        emit(" } }\n");
        return 1;
    }
    default:
        return 0;
    }
}

/* shl/shr/sar by a constant; imul with two or three operands. */
static int translate_shift_mul(uint64_t off, const BbInsn *in) {
    const int m = in->mnemonic;
    const BbOp *d = &in->op[0];
    const int size = d->size;
    if (size != 4 && size != 8 && size != 2 && size != 1) return 0;
    static const char *const sext[9] = {0, "int8_t", "int16_t", 0, "int32_t", 0, 0, 0, "int64_t"};
    Str a, w;
    if (m == M(SHL) || m == M(SHR) || m == M(SAR)) {
        unsigned count = 1;
        if (in->count > 1) {
            if (in->op[1].type != OP_IMM) return 0; /* by cl */
            count = (unsigned)in->op[1].disp;
        }
        count &= size == 8 ? 63 : 31;
        if (!count) {
            if (gpr(d) && size == 4) emit("r[%d] = (uint32_t)r[%d];\n", d->reg, d->reg);
            return 1;
        }
        const int bits = size * 8;
        Str da;
        int stack = 0;
        emit("{ ");
        if (d->type == OP_MEM) {
            if (!address(off, in, d, &da, &stack)) return 0;
            emit("const uint64_t ea = %s; const uint64_t a = %s(ea, %d); ", da.s, stack ? "rc_lds" : "rc_ld", size);
        } else if (gpr(d)) {
            if (!read_op(off, in, d, size, &a)) return 0;
            emit("const uint64_t a = %s; ", a.s);
        } else {
            return 0;
        }
        if (m == M(SHL)) emit("const uint64_t v = %s; ", count >= (unsigned)bits ? "0" : str("(a << %u) & 0x%" PRIx64 "ull", count, mask(size)).s);
        else if (m == M(SHR)) emit("const uint64_t v = %s; ", count >= (unsigned)bits ? "0" : str("a >> %u", count).s);
        else emit("const uint64_t v = (uint64_t)((int64_t)(%s)a >> %u) & 0x%" PRIx64 "ull; ", sext[size],
                  count >= (unsigned)bits ? (unsigned)bits - 1 : count, mask(size));
        emit("c->flags = rc_shift_flags(rc_flags(fk, fa, fb, fr, fz, fcf, c->flags), %d, %s, %u, v, %d); fk = FK_CPU; ",
             m == M(SHL) ? 0 : m == M(SHR) ? 1 : 2, m == M(SAR) ? str("(uint64_t)(int64_t)(%s)a", sext[size]).s : "a", count, size);
        if (d->type == OP_MEM) emit("%s(ea, %d, v);", stack ? "rc_sts" : "rc_st", size);
        else {
            if (!write_op(off, in, d, "v", &w)) return 0;
            emit("%s", w.s);
        }
        emit(" }\n");
        return 1;
    }
    if (m == M(IMUL) && in->count >= 2 && gpr(d) && size >= 2) {
        Str x, y;
        if (!read_op(off, in, in->count == 3 ? &in->op[1] : d, size, &x)) return 0;
        if (in->count == 3) {
            if (in->op[2].type != OP_IMM) return 0;
            y = str("(int64_t)%" PRId64 "ll", in->op[2].disp);
        } else {
            Str t;
            if (!read_op(off, in, &in->op[1], size, &t)) return 0;
            y = str("(int64_t)(%s)(%s)", sext[size], t.s);
        }
        if (!write_op(off, in, d, "v", &w)) return 0;
        emit("{ const __int128 full = (__int128)(int64_t)(%s)(%s) * %s; const uint64_t v = (uint64_t)full & 0x%" PRIx64 "ull; "
             "const int ov = (__int128)(int64_t)(%s)v != full; "
             "c->flags = rc_szp((rc_flags(fk, fa, fb, fr, fz, fcf, c->flags) & ~(uint64_t)(F_CF | F_OF)) | (ov ? F_CF | F_OF : 0), v, %d); "
             "fk = FK_CPU; %s }\n", sext[size], x.s, y.s, mask(size), sext[size], size, w.s);
        return 1;
    }
    return 0;
}

/* The instructions of [start, start + size) the code reaches from the entry: fall-through, direct
 * jumps and branches inside the function (data between them, such as jump tables, is never decoded;
 * a place only an indirect jump reaches goes back to the translator). Sorted by offset. */
typedef struct { uint64_t off; BbInsn in; } Insn;
static int insn_order(const void *a, const void *b) {
    const uint64_t x = ((const Insn *)a)->off, y = ((const Insn *)b)->off;
    return x < y ? -1 : x > y;
}
/* Targets of the jump tables decode found (labels too), for the function being generated. */
static uint64_t *table_targets;
static size_t table_target_count, table_target_capacity;

/* A compiler's jump table ending at list[n - 1] (jmp reg): lea T, [rip + table]; movsxd C,
 * dword [T + 4 * I]; add C, T; jmp C, its size from cmp I, N; ja (N + 1 entries). Its targets
 * are pushed to `work` and kept in table_targets; 0 if it is not one. */
static int jump_table(Function fn, const Insn *list, size_t n, uint64_t *work, size_t *pending, const uint8_t *seen) {
    if (n < 4) return 0;
    const BbInsn *jmp = &list[n - 1].in, *add = &list[n - 2].in, *load = &list[n - 3].in;
    if (jmp->op[0].type != OP_REG || jmp->op[0].kind != RK_GPR || jmp->op[0].size != 8) return 0;
    const int c = jmp->op[0].reg;
    if (add->mnemonic != M(ADD) || add->op[0].type != OP_REG || add->op[0].reg != c || add->op[1].type != OP_REG ||
        add->op[0].size != 8) return 0;
    const int t = add->op[1].reg;
    if (load->mnemonic != M(MOVSXD) || load->op[0].type != OP_REG || load->op[0].reg != c || load->op[1].type != OP_MEM ||
        load->op[1].base != t || load->op[1].scale != 4 || load->op[1].index == 0xff || load->op[1].disp != 0) return 0;
    const int index = load->op[1].index;
    uint64_t table = 0, entries = 0;
    for (size_t k = n - 3; k-- > 0 && k + 12 > n;) {
        const Insn *x = &list[k];
        if (!table && x->in.mnemonic == M(LEA) && x->in.op[0].type == OP_REG && x->in.op[0].reg == t &&
            x->in.op[1].base == 0xfe && x->in.op[1].index == 0xff)
            table = x->off + x->in.length + (uint64_t)x->in.op[1].disp;
        if (!entries && x->in.mnemonic == M(CMP) && x->in.op[0].type == OP_REG && x->in.op[0].reg == index &&
            x->in.op[1].type == OP_IMM && k + 1 < n && list[k + 1].in.mnemonic == M(JNBE))
            entries = (uint64_t)x->in.op[1].disp + 1;
    }
    if (!table || !entries || entries > 4096) return 0;
    for (uint64_t e = 0; e < entries; ++e) {
        int32_t rel;
        memcpy(&rel, (const void *)(uintptr_t)(base + table + 4 * e), 4);
        const uint64_t target = table + (uint64_t)(int64_t)rel;
        if (target < fn.offset || target >= fn.offset + fn.size) return 0; /* not what it looked like */
        if (table_target_count == table_target_capacity) {
            table_target_capacity = table_target_capacity ? table_target_capacity * 2 : 256;
            table_targets = realloc(table_targets, table_target_capacity * sizeof(*table_targets));
        }
        table_targets[table_target_count++] = target;
        if (!seen[target - fn.offset]) work[(*pending)++] = target;
    }
    return 1;
}

static Insn *decode(Function fn, size_t *count) {
    Insn *list = NULL;
    size_t n = 0, capacity = 0;
    uint8_t *seen = calloc(fn.size + 16, 1);
    size_t work_capacity = fn.size + 16 + 4096;
    uint64_t *work = malloc(work_capacity * sizeof(*work));
    size_t pending = 0;
    table_target_count = 0;
    work[pending++] = fn.offset;
    while (pending) {
        uint64_t off = work[--pending];
        while (off >= fn.offset && off < fn.offset + fn.size && !seen[off - fn.offset]) {
            const BbBlock *block = bbcpu_block(base + off);
            if (!block->count) break;
            int ended = 0;
            for (uint32_t i = 0; i < block->count && !ended; ++i) {
                if (off >= fn.offset + fn.size || seen[off - fn.offset]) { ended = 1; break; }
                const BbInsn *in = &block->insn[i];
                seen[off - fn.offset] = 1;
                if (n == capacity) {
                    capacity = capacity ? capacity * 2 : 256;
                    list = realloc(list, capacity * sizeof(*list));
                }
                list[n++] = (Insn){off, *in};
                const int m = in->mnemonic, cc = cc_of(m);
                if (((cc >= 0 && cc < 16) || m == M(JMP) || m == M(JRCXZ) || m == M(JECXZ) || m == M(LOOP) ||
                     m == M(LOOPE) || m == M(LOOPNE)) && in->op[0].type == OP_IMM) {
                    const uint64_t t = off + (uint64_t)in->op[0].disp;
                    if (t >= fn.offset && t < fn.offset + fn.size && !seen[t - fn.offset]) work[pending++] = t;
                }
                if (m == M(JMP) && in->op[0].type == OP_REG && pending + 4096 < work_capacity &&
                    jump_table(fn, list, n, work, &pending, seen))
                    list[n - 1].in.branch |= 0x80; /* E3: a resolved jump table, not a tail call */
                /* No fall-through after these. */
                if (m == M(JMP) || m == M(RET) || m == M(INVALID) || m == M(UD2) || m == M(HLT)) ended = 2;
                off += in->length;
            }
            if (ended == 2) break;
        }
    }
    free(work);
    free(seen);
    qsort(list, n, sizeof(*list), insn_order);
    *count = n;
    return list;
}

/* ---- Arithmetic flags: arithmetic flags across calls and returns ----
 * Whole-program backward liveness of the arithmetic flags over each decoded function, with
 * direct calls of recompiled functions summarized by what the callee may read before writing
 * (exposed, a least fixpoint over the call graph; a callee is assumed to pass every flag
 * through). Unknown places (indirect jumps, int3, jumps into undecoded code) read every flag;
 * so do indirect calls and calls of guest code that is not recompiled; a host import reads
 * none and passes them through.
 *   - A direct call skips materializing the lazy flags when the callee exposes none and none
 *     is live after the call.
 *   - A return materializes them (the pre-existing gap: RET used to drop the lazy flags) when
 *     some caller may read flags after a direct call of this function, or a tail call from
 *     such a function. Indirect call/tail call sites with flags possibly live after them are
 *     counted, not resolved: their targets' returns keep the earlier behavior (a bounded gap;
 *     Win64 code does not read status flags across calls). BB_GEN_FLAGS_RET_ALL=1 makes every
 *     return materialize when such a site exists.
 * Code the decoder does not reach (run by the translator) is outside the analysis; it is not
 * known to read flags after calls. BB_GEN_FLAGS=0 keeps materializing at every call and no
 * return. */
enum { FL_ALL = F_ARITH };
typedef struct { uint64_t off, target; uint16_t mnemonic, freads, fwrites; uint8_t length, kind; } FlagInsn;
enum { FI_PLAIN, FI_BRANCH, FI_JUMP, FI_JUMP_UNKNOWN, FI_RET, FI_CALL, FI_CALL_UNKNOWN, FI_STOP };
static int gen_flags = 1;
static FlagInsn *flag_insns;
static size_t *flag_start;
static uint16_t *flag_exposed;
static uint8_t *flag_ret_needed;
static int flag_ret_all, flag_ret_all_mode;
static uint64_t flag_indirect_live; /* indirect call/jump sites with flags possibly live after (last round) */
static uint16_t *current_live_out;
static size_t current_flag_function = SIZE_MAX;
static uint64_t flag_call_sites, flag_calls_skipped, flag_rets_materialized;

static size_t recompiled_index(uint64_t t) {
    const uint64_t *at = recompiled ? bsearch(&t, recompiled, function_count, sizeof(*recompiled), by_offset) : NULL;
    return at ? (size_t)(at - recompiled) : SIZE_MAX;
}

static size_t flag_find(const FlagInsn *list, size_t count, uint64_t off) {
    size_t lo = 0, hi = count;
    while (lo < hi) {
        const size_t mid = (lo + hi) / 2;
        if (list[mid].off < off) lo = mid + 1; else hi = mid;
    }
    return lo < count && list[lo].off == off ? lo : SIZE_MAX;
}

/* live_out per instruction; returns the flags live at the entry. ret_live: what a return (or a
 * tail call's return) passes to the caller. Also records what calls/tail calls need. */
static uint16_t flag_liveness(size_t function, uint16_t ret_live, uint16_t *live_out, int *changed_needs) {
    const FlagInsn *list = flag_insns + flag_start[function];
    const size_t count = flag_start[function + 1] - flag_start[function];
    const Function fn = functions[function];
    uint16_t *live_in = calloc(count + 1, sizeof(*live_in));
    for (int changed = 1; changed;) {
        changed = 0;
        for (size_t k = count; k-- > 0;) {
            const FlagInsn *x = &list[k];
            uint16_t out = 0;
            if (x->kind != FI_JUMP && x->kind != FI_JUMP_UNKNOWN && x->kind != FI_RET && x->kind != FI_STOP) {
                const size_t n = k + 1 < count && list[k + 1].off == x->off + x->length ? k + 1 : flag_find(list, count, x->off + x->length);
                out |= n == SIZE_MAX ? FL_ALL : live_in[n];
            }
            if (x->kind == FI_BRANCH || x->kind == FI_JUMP) {
                if (x->target >= fn.offset && x->target < fn.offset + fn.size) {
                    const size_t n = flag_find(list, count, x->target);
                    out |= n == SIZE_MAX ? FL_ALL : live_in[n];
                } else {
                    const size_t callee = recompiled_index(x->target);
                    out |= callee == SIZE_MAX ? FL_ALL : (uint16_t)(flag_exposed[callee] | ret_live);
                }
            }
            if (x->kind == FI_JUMP_UNKNOWN || x->kind == FI_STOP) out = FL_ALL;
            if (x->kind == FI_RET) out = ret_live;
            uint16_t in;
            if (x->kind == FI_CALL) {
                const size_t callee = recompiled_index(x->target);
                in = callee == SIZE_MAX ? FL_ALL : (uint16_t)(flag_exposed[callee] | out);
            } else if (x->kind == FI_CALL_UNKNOWN) {
                /* A host import reads no guest flags and leaves the materialized ones. */
                in = x->target && import_name(x->target) ? out : FL_ALL;
            } else {
                in = (uint16_t)((x->freads & FL_ALL) | (out & ~x->fwrites & FL_ALL));
            }
            if (live_out) live_out[k] = out;
            if (in != live_in[k]) { live_in[k] = in; changed = 1; }
        }
    }
    if (changed_needs) {
        for (size_t k = 0; k < count; ++k) {
            const FlagInsn *x = &list[k];
            const int outside = x->target < fn.offset || x->target >= fn.offset + fn.size;
            uint16_t after = 0;
            if (x->kind == FI_CALL || x->kind == FI_CALL_UNKNOWN) {
                const size_t n = flag_find(list, count, x->off + x->length);
                after = n == SIZE_MAX ? FL_ALL : live_in[n];
            } else if ((x->kind == FI_JUMP || x->kind == FI_BRANCH) && outside) {
                after = ret_live;
            } else if (x->kind == FI_JUMP_UNKNOWN) {
                after = ret_live;
            }
            if (!after) continue;
            const size_t callee = x->kind == FI_CALL_UNKNOWN || x->kind == FI_JUMP_UNKNOWN ? SIZE_MAX : recompiled_index(x->target);
            if (x->kind == FI_CALL_UNKNOWN || x->kind == FI_JUMP_UNKNOWN) {
                /* A direct call of something not recompiled returns through the translator or
                 * a host function, which leave exact flags; an indirect call or jump may reach
                 * any recompiled function. */
                if (x->target) continue; /* a direct call of something else, or a jump table */
                ++flag_indirect_live;
                if (getenv("BB_GEN_FLAGS_DEBUG"))
                    fprintf(stderr, "flags: live after %s at %#" PRIx64 " in %#" PRIx64 ": %#x\n",
                            ZydisMnemonicGetString((ZydisMnemonic)x->mnemonic), x->off, fn.offset, after);
                if (flag_ret_all_mode && !flag_ret_all) { flag_ret_all = 1; *changed_needs = 1; }
            } else if (callee != SIZE_MAX && !flag_ret_needed[callee]) {
                flag_ret_needed[callee] = 1;
                *changed_needs = 1;
            }
        }
    }
    const uint16_t entry = count ? live_in[0] : FL_ALL;
    free(live_in);
    return entry;
}

static uint16_t flag_ret_live(size_t function) {
    return flag_ret_all || flag_ret_needed[function] ? FL_ALL : 0;
}

static void analyze_flags(void) {
    flag_start = calloc(function_count + 1, sizeof(*flag_start));
    size_t capacity = 0, total = 0;
    for (size_t i = 0; i < function_count; ++i) {
        size_t count;
        Insn *list = decode(functions[i], &count);
        if (total + count > capacity) {
            capacity = (total + count) * 2;
            flag_insns = realloc(flag_insns, capacity * sizeof(*flag_insns));
        }
        for (size_t k = 0; k < count; ++k) {
            const BbInsn *in = &list[k].in;
            const int m = in->mnemonic, cc = cc_of(m);
            FlagInsn *x = &flag_insns[total + k];
            *x = (FlagInsn){list[k].off, 0, in->mnemonic, in->freads, in->fwrites, in->length, FI_PLAIN};
            const int imm = in->op[0].type == OP_IMM;
            if (imm) x->target = list[k].off + (uint64_t)in->op[0].disp;
            if (m == M(CALL)) x->kind = imm && is_recompiled(x->target) ? FI_CALL : FI_CALL_UNKNOWN;
            else if (m == M(JMP)) {
                x->kind = imm ? FI_JUMP : FI_JUMP_UNKNOWN;
                if (!imm && (in->branch & 0x80)) x->target = 1; /* jump table */
            }
            else if (m == M(RET)) x->kind = FI_RET;
            else if ((cc >= 0 && cc < 16) || m == M(JRCXZ) || m == M(JECXZ) || m == M(LOOP) || m == M(LOOPE) || m == M(LOOPNE))
                x->kind = imm ? FI_BRANCH : FI_STOP;
            else if (m == M(INVALID) || m == M(UD2) || m == M(HLT) || m == M(INT3) || m == M(INT) || m == M(SYSCALL)) x->kind = FI_STOP;
        }
        total += count;
        flag_start[i + 1] = total;
        free(list);
    }
    flag_exposed = calloc(function_count, sizeof(*flag_exposed));
    flag_ret_needed = calloc(function_count, sizeof(*flag_ret_needed));
    int rounds = 0;
    for (int changed = 1; changed; ++rounds) {
        changed = 0;
        for (size_t i = function_count; i-- > 0;) {
            const uint16_t entry = flag_liveness(i, 0, NULL, NULL);
            if (entry != flag_exposed[i]) { flag_exposed[i] = entry; changed = 1; }
        }
    }
    for (int changed = 1; changed; ++rounds) {
        changed = 0;
        flag_indirect_live = 0;
        for (size_t i = 0; i < function_count; ++i) flag_liveness(i, flag_ret_live(i), NULL, &changed);
    }
    size_t readers = 0, needed = 0;
    for (size_t i = 0; i < function_count; ++i) { readers += flag_exposed[i] != 0; needed += flag_ret_needed[i]; }
    printf("flags: %zu instructions, %zu of %zu functions read incoming flags, %zu functions' returns materialize%s, "
           "%" PRIu64 " indirect call/jump sites with flags possibly live after, %d rounds\n",
           total, readers, function_count, needed, flag_ret_all ? " (all: BB_GEN_FLAGS_RET_ALL=1)" : "", flag_indirect_live, rounds);
}

/* Per function being generated: live_out for each decoded instruction. */
static void flag_prepare(uint64_t offset) {
    free(current_live_out);
    current_live_out = NULL;
    current_flag_function = SIZE_MAX;
    if (!flag_start) return;
    const size_t i = recompiled_index(offset);
    if (i == SIZE_MAX) return;
    current_live_out = malloc((flag_start[i + 1] - flag_start[i] + 1) * sizeof(*current_live_out));
    flag_liveness(i, flag_ret_live(i), current_live_out, NULL);
    current_flag_function = i;
}

static const char *call_flags_out(uint64_t off, uint64_t callee) {
    ++flag_call_sites;
    if (current_flag_function == SIZE_MAX) return FLAGS_OUT;
    const FlagInsn *list = flag_insns + flag_start[current_flag_function];
    const size_t k = flag_find(list, flag_start[current_flag_function + 1] - flag_start[current_flag_function], off);
    const size_t c = recompiled_index(callee);
    if (k == SIZE_MAX || c == SIZE_MAX || flag_exposed[c] || (current_live_out[k] & FL_ALL)) return FLAGS_OUT;
    ++flag_calls_skipped;
    return "fk = FK_CPU; /* E3: flags dead across this call */";
}

static const char *ret_flags_out(void) {
    if (current_flag_function == SIZE_MAX || !flag_ret_live(current_flag_function)) return "";
    ++flag_rets_materialized;
    return FLAGS_OUT;
}

/* Reference instrumentation must use reachable decoding, so it never patches embedded tables. */
static int indirect_sites(const char *elf, const char *table, const char *path) {
    map_image(elf);
    FILE *input = fopen(table, "r"), *output = fopen(path, "w");
    if (!input || !output) { perror(path); return 1; }
    char starts_path[4096];
    if (snprintf(starts_path, sizeof(starts_path), "%s.starts", path) >= (int)sizeof(starts_path)) return 1;
    FILE *starts = fopen(starts_path, "wb");
    if (!starts) { perror(starts_path); return 1; }
    if (snprintf(starts_path, sizeof(starts_path), "%s.refs", path) >= (int)sizeof(starts_path)) return 1;
    FILE *refs = fopen(starts_path, "wb");
    if (!refs) { perror(starts_path); return 1; }
    fputs("offset\tlength\tkind\ttype\treg\tbase\tindex\tscale\tsegment\tdisplacement\taddress_bits\tbytes\tprefix_offset\tprefix_bytes\n", output);
    ZydisDecoder decoder;
    ZydisDecoderInit(&decoder, ZYDIS_MACHINE_MODE_LONG_64, ZYDIS_STACK_WIDTH_64);
    char line[256];
    size_t sites = 0;
    while (fgets(line, sizeof(line), input)) {
        unsigned long long offset, size;
        if (sscanf(line, "%llx\t%llu", &offset, &size) != 2) continue;
        size_t count;
        Insn *instructions = decode((Function){offset, size}, &count);
        for (size_t i = 0; i < count; ++i) {
            const Insn *instruction = &instructions[i];
            const BbInsn *in = &instruction->in;
            const BbOp *op = &in->op[0];
            if (fwrite(&instruction->off, sizeof(instruction->off), 1, starts) != 1) return 1;
            const int cc = cc_of(in->mnemonic);
            if (op->type == OP_IMM && (in->mnemonic == M(CALL) || in->mnemonic == M(JMP) || cc >= 0 ||
                in->mnemonic == M(JRCXZ) || in->mnemonic == M(JECXZ) || in->mnemonic == M(LOOP) ||
                in->mnemonic == M(LOOPE) || in->mnemonic == M(LOOPNE))) {
                const uint64_t target = instruction->off + (uint64_t)op->disp;
                if (fwrite(&target, sizeof(target), 1, refs) != 1) return 1;
            }
            if (in->mnemonic == M(LEA) && in->op[1].base == 0xfe) {
                const uint64_t target = instruction->off + in->length + (uint64_t)in->op[1].disp;
                if (fwrite(&target, sizeof(target), 1, refs) != 1) return 1;
            }
            if ((in->mnemonic != M(CALL) && in->mnemonic != M(JMP)) || op->type == OP_IMM) continue;
            ZydisDecodedInstruction decoded;
            ZydisDecodedOperand operands[ZYDIS_MAX_OPERAND_COUNT];
            if ((op->type != OP_REG && op->type != OP_MEM) || op->size != 8 ||
                (op->type == OP_REG && op->kind != RK_GPR) ||
                !ZYAN_SUCCESS(ZydisDecoderDecodeFull(&decoder, (void *)(base + instruction->off), in->length,
                                                    &decoded, operands))) {
                fprintf(stderr, "unsupported indirect instruction at %#" PRIx64 "\n", instruction->off);
                return 1;
            }
            fprintf(output, "%#" PRIx64 "\t%u\t%d\t%u\t%u\t%u\t%u\t%u\t%u\t%" PRId64 "\t%u\t",
                    instruction->off, in->length, in->mnemonic == M(JMP), op->type, op->reg,
                    op->base, op->index, op->scale, op->segment, op->disp, decoded.address_width);
            for (unsigned b = 0; b < in->length; ++b) fprintf(output, "%02x", *(uint8_t *)(base + instruction->off + b));
            uint64_t prefix = instruction->off;
            for (size_t j = i; in->length + instruction->off - prefix < 5 && j > 0;) {
                const Insn *previous = &instructions[--j];
                const int m = previous->in.mnemonic;
                if (previous->off + previous->in.length != prefix ||
                    instruction->off - previous->off > 15 ||
                    (m != M(MOV) && m != M(MOVSXD) && m != M(LEA) && m != M(ADD) && m != M(SUB) &&
                     m != M(AND) && m != M(OR) && m != M(XOR) && m != M(CMP) && m != M(TEST))) break;
                int relative = 0;
                for (unsigned o = 0; o < previous->in.count; ++o)
                    if ((previous->in.op[o].type == OP_MEM || previous->in.op[o].type == OP_AGEN) &&
                        previous->in.op[o].base == 0xfe) relative = 1;
                if (relative) break;
                prefix = previous->off;
            }
            if (in->length + instruction->off - prefix < 5) prefix = instruction->off;
            fprintf(output, "\t%#" PRIx64 "\t", prefix);
            for (uint64_t b = prefix; b < instruction->off; ++b) fprintf(output, "%02x", *(uint8_t *)(base + b));
            fputc('\n', output);
            ++sites;
        }
        free(instructions);
    }
    fclose(input);
    fclose(output);
    fclose(starts);
    fclose(refs);
    printf("%zu reachable indirect sites\n", sites);
    return 0;
}

/* Snippet mode (fuzzing, tests/fuzz_recomp.c): one instruction, then a return at its end. */
static int snippet_mode;
/* BB_RECOMP_TRACE=1: a trace point before each instruction (replay --lockstep). */
static int trace_points;
static uint64_t snippet_line;

static int by_offset(const void *a, const void *b) {
    const uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

static int scan_loop(Range f, const Insn *list, size_t count) {
    if (count < 5) return 0;
    const BbInsn *cmp = &list[0].in, *eq = &list[1].in, *add = &list[2].in;
    const BbInsn *dec = &list[3].in, *ne = &list[4].in;
    for (size_t i = 0; i < 5; ++i) {
        if (list[i].in.lock || list[i].in.rep || list[i].in.repne) return 0;
        if (i && list[i - 1].off + list[i - 1].in.length != list[i].off) return 0;
    }
    if (cmp->mnemonic != M(CMP) || cmp->count != 2 || cmp->op[0].type != OP_MEM ||
        cmp->op[0].size != 8 || cmp->op[0].base >= 16 || cmp->op[0].index != 0xff ||
        cmp->op[0].disp || cmp->op[0].segment || cmp->op[1].type != OP_REG ||
        cmp->op[1].kind != RK_GPR || cmp->op[1].size != 8) return 0;
    const unsigned address = cmp->op[0].base, value = cmp->op[1].reg;
    if (add->mnemonic != M(ADD) || add->count != 2 || add->op[0].type != OP_REG ||
        add->op[0].kind != RK_GPR || add->op[0].size != 8 || add->op[0].reg != address ||
        add->op[1].type != OP_IMM || add->op[1].disp != 8 || dec->mnemonic != M(DEC) ||
        dec->count != 1 || dec->op[0].type != OP_REG || dec->op[0].kind != RK_GPR ||
        dec->op[0].size != 8) return 0;
    const unsigned remaining = dec->op[0].reg;
    if (address == value || address == remaining || value == remaining ||
        address == RSP || value == RSP || remaining == RSP) return 0;
    if (cc_of(eq->mnemonic) != 4 || eq->op[0].type != OP_IMM ||
        cc_of(ne->mnemonic) != 5 || ne->op[0].type != OP_IMM ||
        list[4].off + (uint64_t)ne->op[0].disp != list[0].off) return 0;
    const uint64_t target = list[1].off + (uint64_t)eq->op[0].disp;
    const uint64_t end = list[4].off + ne->length;
    if (target < f.start || target >= f.end || (target >= list[0].off && target < end)) return 0;
    emit("{ const RcScan scan = rc_scan64(r[%u], r[%u], r[%u]); r[%u] = scan.address; r[%u] = scan.count; fz = 8; "
         "if (scan.found) { fk = FK_SUB; fa = fb = r[%u]; fr = 0; goto L_%" PRIx64 "; } "
         "fk = FK_DEC; fa = fb = 1; fr = 0; fcf = scan.address < 8; goto L_scan_%" PRIx64 "; }\n",
         address, remaining, value, address, remaining, value, target, list[0].off);
    return 1;
}

/* Host math replacements: game math routines with a guarded host entry, recognized by
 * address, size and the runtime's byte hash so a different executable keeps the lifted code.
 * 0xb5380 is the game's software sqrt: xmm1 in, *r8 out, xmm6/xmm7/rsi/rdi/rbx preserved and,
 * for a positive normal input, no other memory written outside its own frame (its helper
 * 0xf1590 is an ldexp writing only its *r8). The host entry stores the correctly rounded root,
 * which differs from the routine's Newton result by at most 1 ulp, and returns; zero, negative,
 * denormal, infinite and NaN inputs, other rounding modes, SS_FP_EXACT=1 and
 * SS_HOST_MATH_OFF run the lifted original. */
static const struct { uint64_t offset, size, hash; } host_math[] = {
    {0xb5380, 658, 0x38885cbd19f6e77full},
};

static int host_math_index(Function fn) {
    for (size_t i = 0; i < sizeof(host_math) / sizeof(host_math[0]); ++i)
        if (host_math[i].offset == fn.offset && host_math[i].size == fn.size &&
            bbcpu_recomp_hash(base + fn.offset, fn.size) == host_math[i].hash) return (int)i;
    return -1;
}

static void emit_host_math(uint64_t owner) {
    if (owner == 0xb5380)
        emit("    if (rc_host_%" PRIx64 " && !(c->mxcsr & fp_mask) && c->v[1].q[0] - 0x0010000000000000ull < 0x7fe0000000000000ull) {\n"
             "        double x; memcpy(&x, &c->v[1].q[0], 8); x = __builtin_sqrt(x); uint64_t y; memcpy(&y, &x, 8);\n"
             "        rc_st(r[R8], 8, y);\n"
             "        const uint64_t t = rc_lds(r[RSP], 8); r[RSP] += 8; " SPILL " c->rip = t; return;\n    }\n", owner);
}

static int host_math_owner = -1;

/* Fast kernels, recognized like host_math. Each gets a second
 * version, k_<offset>_fast, that f_<offset> enters while rc_fast_<offset> is set and the guest
 * rounds to nearest (L2). The fast version keeps the vector registers it uses in locals,
 * written back before and reloaded after every boundary that spills general registers (calls,
 * the interpreter, the translator, returns), and takes the host FP path unconditionally; after
 * a call or an interpreted instruction that leaves the guest outside round-to-nearest it hands
 * the rest of the function to the translator. 0x32f7b0 is the periodic simulation pass. */
static const struct { uint64_t offset, size, hash; } fast_kernels[] = {
    {0x32f7b0, 26319, 0x339dd180254651abull},
};
/* BB_GEN_FAST_ALL=1 (test fixtures only): every unsplit function also gets a fast version,
 * gated by one rc_fast_all switch, so the dispatch tests run the fast-tier machinery. */
static int gen_fast = 1, fast_mode, fast_all;
static uint64_t fast_generated;

static int fast_kernel_index(Function fn) {
    if (!gen_fast || snippet_mode || trace_points) return -1;
    if (fast_all) return 0;
    for (size_t i = 0; i < sizeof(fast_kernels) / sizeof(fast_kernels[0]); ++i)
        if (fast_kernels[i].offset == fn.offset && fast_kernels[i].size == fn.size &&
            bbcpu_recomp_hash(base + fn.offset, fn.size) == fast_kernels[i].hash) return (int)i;
    return -1;
}

static const char *mxcsr_exit(void) { return fast_mode ? " || (c->mxcsr & fp_mask)" : ""; }
static const char *fast_gate(uint64_t owner) {
    static char text[32];
    if (fast_all) return "rc_fast_all";
    snprintf(text, sizeof(text), "rc_fast_%" PRIx64, owner);
    return text;
}
static int fast_owner = -1;

static void generate_body(Range f, const Insn *list, size_t count, const uint64_t *targets, size_t target_count, uint64_t *stats, uint64_t owner, int region) {
    emit("\n/* 0x%" PRIx64 ", %" PRIu64 " bytes, %zu instructions */\n", f.start, f.end - f.start, count);
    if (region >= 0) emit("static __attribute__((noinline)) void r_%" PRIx64 "_%d(BbCpu *c, uint64_t entry_rsp, int *resume) {\n    *resume = 0;\n", owner, region);
    else if (snippet_mode) emit("static void s_%" PRIx64 "(BbCpu *c) {\n", snippet_line);
    else if (fast_mode) emit("static __attribute__((noinline)) void k_%" PRIx64 "_fast(BbCpu *c) {\n", owner);
    else emit("__attribute__((visibility(\"hidden\"))) void f_%" PRIx64 "(BbCpu *c) {\n", owner);
    if (region < 0 && !fast_mode && fast_owner >= 0)
        emit("    if (%s && !(c->mxcsr & rc_fp_mask)) { k_%" PRIx64 "_fast(c); return; }\n", fast_gate(owner), owner);
    emit("    const uint64_t B = rc->image_base;\n");
    if (fast_mode) emit("    BbVec v[16];\n");
    emit("    uint64_t r[16];\n    " RELOAD "\n");
    emit("    int fk = FK_CPU, fz = 8, fcf = 0;\n    uint64_t fa = 0, fb = 0, fr = 0, dn = 0;\n");
    if (region < 0) emit("    const uint64_t entry_rsp = r[RSP];\n");
    emit("    BbFpEnv fp_saved = {0}; int fp_active = 0; const uint32_t fp_mask = rc_fp_mask; (void)fp_mask;\n");
    emit("    (void)fa; (void)fb; (void)fr; (void)fz; (void)fcf; (void)entry_rsp; (void)dn;\n");
    if (region < 0 && host_math_owner >= 0) emit_host_math(owner);
    if (region >= 0) emit("    dn = c->rip; goto L_dispatch;\n");
    uint64_t scan_end = UINT64_MAX, scan_start = 0;
    for (size_t i = 0; i < count; ++i) {
        const Insn *x = &list[i];
        if (x->off == scan_end) { emit("L_scan_%" PRIx64 ": ", scan_start); scan_end = UINT64_MAX; }
        if (bsearch(&x->off, targets, target_count, sizeof(*targets), by_offset)) emit("L_%" PRIx64 ": ", x->off);
        if (trace_points) emit(FP_END " VSPILL rc->trace(0x%" PRIx64 ", r, c); ", x->off);
        if (!trace_points && scan_loop(f, list + i, count - i)) {
            scan_start = x->off;
            scan_end = list[i + 4].off + list[i + 4].in.length;
        }
        ++stats[2];
        const long mark = ftell(out);
        if (translate(f, x->off, &x->in, stats)) {
            ++stats[0];
            continue;
        }
        fseek(out, mark, SEEK_SET); /* what a translation wrote before it gave up */
        /* The interpreter: state spilled, flags in cpu->flags; an unexpected next rip dispatches. */
        emit("/* %s */ { " SPILL " " FLAGS_OUT " c->rip = B + 0x%" PRIx64 "ull; const uint64_t n = rc->step(c); " RELOAD
             " if (n != B + 0x%" PRIx64 "ull%s) { dn = n; goto L_dispatch; } }\n",
             ZydisMnemonicGetString((ZydisMnemonic)x->in.mnemonic), x->off, x->off + x->in.length, mxcsr_exit());
    }
    if (scan_end != UINT64_MAX) emit("L_scan_%" PRIx64 ": ", scan_start);
    if (snippet_mode) emit("    " SPILL " " FLAGS_OUT " c->rip = B + 0x%" PRIx64 "ull; return;\n", f.end);
    emit("    dn = B + 0x%" PRIx64 "ull; /* past the end */\n", f.end);
    emit("L_dispatch:\n    switch (dn - B) {\n");
    for (size_t i = 0; i < target_count; ++i)
        if (targets[i] >= f.start && targets[i] < f.end && (!i || targets[i] != targets[i - 1])) emit("    case 0x%" PRIx64 ": goto L_%" PRIx64 ";\n", targets[i], targets[i]);
    emit("    default: break;\n    }\n");
    emit("    " SPILL " " FLAGS_OUT "\n    c->rip = dn;\n");
    if (region >= 0)
        emit("    if ((dn - B < 0x%" PRIx64 "ull || dn - B >= 0x%" PRIx64 "ull) && dn - B >= 0x%" PRIx64 "ull && dn - B < 0x%" PRIx64 "ull) { *resume = 1; return; }\n", f.start, f.end, split_function.start, split_function.end);
    emit("    if ((dn - B >= 0x%" PRIx64 "ull && dn - B < 0x%" PRIx64 "ull) || r[RSP] != entry_rsp) rc->bail(c, entry_rsp); /* the translator */\n", region >= 0 ? split_function.start : f.start, region >= 0 ? split_function.end : f.end);
    emit("    else rc->tail(c); /* out of the function, the stack as at its entry: a tail call */\n}\n");
}

static void generate(Function fn, uint64_t *stats) {
    size_t count;
    Insn *list = decode(fn, &count);
    flag_prepare(fn.offset);
    const Range f = {fn.offset, fn.offset + fn.size};
    /* Labels only where a direct jump goes (and the entry): every other address an indirect jump
     * or an interpreted branch reaches goes back to the translator (L_dispatch). */
    uint64_t *targets = malloc((count * 2 + 1 + table_target_count) * sizeof(*targets));
    size_t target_count = 0;
    targets[target_count++] = f.start;
    for (size_t i = 0; i < table_target_count; ++i) targets[target_count++] = table_targets[i]; /* jump tables */
    for (size_t i = 0; i < count; ++i) {
        const BbInsn *in = &list[i].in;
        const int cc = cc_of(in->mnemonic);
        if (((cc >= 0 && cc < 16) || in->mnemonic == M(JMP)) && in->op[0].type == OP_IMM) {
            const uint64_t t = list[i].off + (uint64_t)in->op[0].disp;
            if (t >= f.start && t < f.end) targets[target_count++] = t;
        }
    }
    const size_t region_size = 1024;
    /* Bound optimizer cost; region exits commit lazy flags, registers and the host FP environment. */
    const int split = !snippet_mode && count > 5000;
    if (split) for (size_t i = 0; i < count; i += region_size) targets[target_count++] = list[i].off;
    qsort(targets, target_count, sizeof(*targets), by_offset);
    host_math_owner = snippet_mode || split ? -1 : host_math_index(fn);
    if (host_math_owner >= 0)
        emit("\nextern __attribute__((visibility(\"hidden\"))) uint8_t rc_host_%" PRIx64 ";\n", fn.offset);
    fast_owner = split ? -1 : fast_kernel_index(fn);
    if (fast_owner >= 0) {
        /* The fast body goes to a scratch file first: its vector registers are known after. */
        FILE *const saved = out;
        out = tmpfile();
        if (!out) { perror("tmpfile"); exit(1); }
        uint64_t fast_stats[3] = {stats[0], stats[1], stats[2]};
        fast_mode = 1;
        generate_body(f, list, count, targets, target_count, fast_stats, fn.offset, -1);
        fast_mode = 0;
        const long length = ftell(out);
        char *text = malloc((size_t)length + 1);
        rewind(out);
        if (fread(text, 1, (size_t)length, out) != (size_t)length) { perror("tmpfile"); exit(1); }
        text[length] = 0;
        fclose(out);
        out = saved;
        /* Used registers are reloaded after each boundary; only written ones are written back:
         * a register whose address is taken, that memcpy/memset writes, or that is assigned. */
        unsigned used = 0, written = 0;
        for (const char *at = text; (at = strstr(at, "RC_V[")); at += 5) {
            const unsigned bit = 1u << (atoi(at + 5) & 15);
            used |= bit;
            const int address = at > text && at[-1] == '&';
            const int copied = at - text >= 7 && (!strncmp(at - 7, "memcpy(", 7) || !strncmp(at - 7, "memset(", 7));
            const char *after = strchr(at, ']') + 1;
            while (*after == '.' || *after == '[' || isalnum((unsigned char)*after) || *after == '_' || *after == ']') ++after;
            while (*after == ' ') ++after;
            const int assigned = after[0] == '=' && after[1] != '=';
            if (address || copied || assigned) written |= bit;
        }
        emit("\nextern __attribute__((visibility(\"hidden\"))) uint8_t %s;\n", fast_gate(fn.offset));
        emit("#undef RC_V\n#define RC_V v\n#undef RC_FP_HOST\n#define RC_FP_HOST if (1)\n#undef VSPILL\n#define VSPILL");
        for (int n = 0; n < 16; ++n) if (written & (1u << n)) emit(" memcpy(&c->v[%d], &v[%d], sizeof(BbVec));", n, n);
        emit("\n#undef VRELOAD\n#define VRELOAD");
        for (int n = 0; n < 16; ++n) if (used & (1u << n)) emit(" memcpy(&v[%d], &c->v[%d], sizeof(BbVec));", n, n);
        emit("\n/* E5 fast version: vector registers %#x in locals, %#x written back */", used, written);
        fwrite(text, 1, (size_t)length, out);
        free(text);
        emit("#undef RC_V\n#define RC_V c->v\n#undef RC_FP_HOST\n#define RC_FP_HOST if (!(c->mxcsr & fp_mask))\n"
             "#undef VSPILL\n#define VSPILL\n#undef VRELOAD\n#define VRELOAD\n");
        ++fast_generated;
    }
    if (!split) {
        generate_body(f, list, count, targets, target_count, stats, fn.offset, -1);
        host_math_owner = -1;
        fast_owner = -1;
    } else {
        split_function = f;
        const size_t regions = (count + region_size - 1) / region_size;
        for (size_t i = 0; i < regions; ++i) {
            const size_t start = i * region_size, end = start + region_size < count ? start + region_size : count;
            const Range range = {list[start].off, end < count ? list[end].off : f.end};
            generate_body(range, list + start, end - start, targets, target_count, stats, fn.offset, (int)i);
        }
        split_function = (Range){0};
        emit("\n/* 0x%" PRIx64 ", %" PRIu64 " bytes, %zu instructions, %zu optimized regions */\n", fn.offset, fn.size, count, regions);
        emit("__attribute__((visibility(\"hidden\"))) void f_%" PRIx64 "(BbCpu *c) {\n", fn.offset);
        emit("    const uint64_t entry_rsp = c->r[RSP];\n    static const uint64_t starts[] = {");
        for (size_t i = 0; i < regions; ++i) emit("0x%" PRIx64 "ull,", list[i * region_size].off);
        emit("};\n    static void (*const regions[])(BbCpu *, uint64_t, int *) = {");
        for (size_t i = 0; i < regions; ++i) emit("r_%" PRIx64 "_%zu,", fn.offset, i);
        emit("};\n    int resume;\n    do {\n        const uint64_t offset = c->rip - rc->image_base;\n");
        emit("        size_t lo = 0, hi = %zu;\n        while (lo + 1 < hi) { const size_t mid = (lo + hi) / 2; if (starts[mid] <= offset) lo = mid; else hi = mid; }\n", regions);
        emit("        regions[lo](c, entry_rsp, &resume);\n    } while (resume);\n}\n");
    }
    free(targets);
    free(list);
}

/* --snippets ENCODINGS OUT.c: each instruction (hex bytes per line) at CODE_AT, alone; the ones
 * translated natively get a function s_<line number>, in a table (offset: the line number). */
#define SNIPPET_AT UINT64_C(0x30000000000)
static int snippets(const char *encodings, const char *path) {
    uint8_t *code = mmap((void *)SNIPPET_AT, 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    if (code == MAP_FAILED) { perror("mmap"); return 1; }
    base = SNIPPET_AT;
    bbcpu_add_guest_code(SNIPPET_AT, 0x4000);
    static BbCpu warm;
    bbcpu_run(&warm, 0);
    snippet_mode = 1;
    FILE *in = fopen(encodings, "r");
    out = fopen(path, "w");
    if (!in || !out) { perror(encodings); return 1; }
    emit("/* Written by tools/recomp/bbrecomp.c --snippets (tests/fuzz_recomp.c). */\n");
    emit("#include \"recomp/rc.h\"\n\nstatic const RcApi *rc;\n__attribute__((visibility(\"hidden\"))) uint32_t rc_fp_mask = ~0u;\n");
    char line[128];
    uint64_t stats[3] = {0, 0, 0}, number = 0;
    uint64_t *lines = NULL;
    size_t count = 0, capacity = 0;
    while (fgets(line, sizeof(line), in)) {
        ++number;
        uint8_t bytes[16];
        int len = 0;
        for (const char *p = line; p[0] && p[1] && p[0] != '\n' && len < 15; p += 2) {
            unsigned v;
            if (sscanf(p, "%2x", &v) != 1) break;
            bytes[len++] = (uint8_t)v;
        }
        if (!len) continue;
        memset(code, 0x90, 64);
        memcpy(code, bytes, (size_t)len);
        bbcpu_invalidate(SNIPPET_AT, 64);
        const BbBlock *block = bbcpu_block(SNIPPET_AT);
        if (!block->count || block->insn[0].length != len) continue;
        /* Natively translated only: a fallback is the interpreter itself. */
        const long mark = ftell(out);
        const uint64_t before = stats[0];
        snippet_line = number;
        generate((Function){0, (uint64_t)len}, stats);
        if (stats[0] == before) { fseek(out, mark, SEEK_SET); continue; }
        if (count == capacity) { capacity = capacity ? capacity * 2 : 4096; lines = realloc(lines, capacity * 8); }
        lines[count++] = number;
    }
    emit("\nstatic const RcFunction table[] = {\n");
    for (size_t i = 0; i < count; ++i) emit("    {%" PRIu64 ", 0, 0, s_%" PRIx64 "},\n", lines[i], lines[i]);
    emit("};\n\nconst RcFunction *bb_recomp_init(const RcApi *api, size_t *count) {\n");
    emit("    rc = api;\n    rc_fp_mask = rc_fp_exact() ? ~0u : 0x6040u;\n    *count = sizeof(table) / sizeof(table[0]);\n    return table;\n}\n");
    close_output();
    printf("%zu instructions translated natively (of %" PRIu64 " lines)\n", count, number);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 5 && !strcmp(argv[1], "--indirect-sites")) return indirect_sites(argv[2], argv[3], argv[4]);
    if (argc == 4 && !strcmp(argv[1], "--snippets")) return snippets(argv[2], argv[3]);
    if (argc < 5) {
        fprintf(stderr, "usage: %s ELF FUNCTIONS_TSV OUT.c OFFSET...\n", argv[0]);
        return 2;
    }
    map_image(argv[1]);
    static BbCpu warm;
    bbcpu_run(&warm, 0); /* the interpreter's tables */
    trace_points = getenv("BB_RECOMP_TRACE") && getenv("BB_RECOMP_TRACE")[0] == '1';
    /* OFFSET... or @LIST (one offset a line). */
    size_t capacity = (size_t)argc;
    functions = calloc(capacity, sizeof(*functions));
    for (int i = 4; i < argc; ++i) {
        FILE *list = argv[i][0] == '@' ? fopen(argv[i] + 1, "r") : NULL;
        if (argv[i][0] == '@' && !list) { perror(argv[i] + 1); return 1; }
        char line[64];
        while (list ? fgets(line, sizeof(line), list) != NULL : (snprintf(line, sizeof(line), "%s", argv[i]), 1)) {
            const uint64_t offset = strtoull(line, NULL, 0);
            if (offset || !list) {
                const uint64_t size = size_of(argv[2], offset);
                if (!size) { fprintf(stderr, "%#" PRIx64 ": not in %s\n", offset, argv[2]); return 1; }
                if (function_count == capacity) { capacity *= 2; functions = realloc(functions, capacity * sizeof(*functions)); }
                functions[function_count++] = (Function){offset, size};
            }
            if (!list) break;
        }
        if (list) fclose(list);
    }
    /* Nonlocal-jump callers stay interpreted: generated C must not continue after the guest
     * restores an earlier stack. Include both jump-stub calls and calls through IAT slots. */
    {
        char dir[1024];
        snprintf(dir, sizeof(dir), "%s", argv[2]);
        char *slash = strrchr(dir, '/');
        if (slash) slash[1] = 0; else dir[0] = 0;
        char path[1100], line[512];
        snprintf(path, sizeof(path), "%simports.tsv", dir);
        FILE *f = fopen(path, "r");
        while (f && fgets(line, sizeof(line), f)) {
            char name[256];
            unsigned long long stub;
            if (sscanf(line, "%llx\t%255s", &stub, name) == 2) {
                imports = realloc(imports, (import_count + 1) * sizeof(*imports));
                imports[import_count].stub = stub;
                snprintf(imports[import_count].name, sizeof(imports[import_count].name), "%s", name);
                ++import_count; /* imports.tsv is sorted */
            }
        }
        if (f) fclose(f);
        else fprintf(stderr, "%s: none (nonlocal-jump callers are not known)\n", path);
        size_t skipped = 0;
        const char *edges[] = {"calls.tsv", "slots.tsv"};
        for (size_t e = 0; e < sizeof(edges) / sizeof(*edges); ++e) {
            snprintf(path, sizeof(path), "%s%s", dir, edges[e]);
            f = fopen(path, "r");
            while (f && fgets(line, sizeof(line), f)) {
                unsigned long long caller, callee;
                if (sscanf(line, "%llx\t%llx", &caller, &callee) != 2) continue;
                const char *name = import_name(callee);
                if (!name) continue;
                const char *bang = strrchr(name, '!');
                if (bang) name = bang + 1;
                if (strcmp(name, "setjmp") && strcmp(name, "_setjmp") && strcmp(name, "sigsetjmp") &&
                    strcmp(name, "__intrinsic_setjmp") && strcmp(name, "longjmp") && strcmp(name, "_longjmpex")) continue;
                for (size_t i = 0; i < function_count; ++i)
                    if (functions[i].offset == caller) { functions[i] = functions[--function_count]; ++skipped; break; }
            }
            if (f) fclose(f);
        }
        if (skipped) printf("%zu nonlocal-jump functions: left to the interpreter\n", skipped);
        /* Import stubs (a jump through a slot the loader fills) stay too: recompiled, the jump is a
         * tail call through the runtime, which puts its own return address on the stack, and
         * setjmp saved that one. They gain nothing in C. */
        size_t stubs = 0;
        for (size_t i = 0; i < function_count;) {
            if (import_name(functions[i].offset)) { functions[i] = functions[--function_count]; ++stubs; }
            else ++i;
        }
        if (stubs) printf("%zu import stubs: left to the translator\n", stubs);
    }
    /* By offset, once each. */
    qsort(functions, function_count, sizeof(*functions), by_offset); /* offset first in Function */
    size_t unique = 0;
    for (size_t i = 0; i < function_count; ++i)
        if (!unique || functions[i].offset != functions[unique - 1].offset) functions[unique++] = functions[i];
    function_count = unique;
    recompiled = malloc(function_count * sizeof(*recompiled));
    for (size_t i = 0; i < function_count; ++i) recompiled[i] = functions[i].offset;
    /* Generator optimizations can be disabled independently for comparison. */
    gen_direct = !getenv("BB_GEN_DIRECT") || getenv("BB_GEN_DIRECT")[0] != '0';
    gen_flags = !getenv("BB_GEN_FLAGS") || getenv("BB_GEN_FLAGS")[0] != '0';
    gen_fast = !getenv("BB_GEN_FAST") || getenv("BB_GEN_FAST")[0] != '0';
    fast_all = getenv("BB_GEN_FAST_ALL") && getenv("BB_GEN_FAST_ALL")[0] == '1';
    flag_ret_all_mode = getenv("BB_GEN_FLAGS_RET_ALL") && getenv("BB_GEN_FLAGS_RET_ALL")[0] == '1';
    if (gen_flags && !trace_points) analyze_flags();
    /* A file per WINDOW of the image (OUT_<window>.c, compiled in parallel; the table in OUT.c):
     * adding functions changes only the files of their windows, and recomp.sh compiles only files
     * that changed. */
    enum { WINDOW = 0x20000 };
    char path[1024];
    const size_t stem = strlen(argv[3]) - (strlen(argv[3]) > 2 && !strcmp(argv[3] + strlen(argv[3]) - 2, ".c") ? 2 : 0);
    uint64_t stats[3] = {0, 0, 0}; /* translated, indirect jumps, instructions */
    int files = 0;
    uint64_t window = UINT64_MAX;
    out = NULL;
    for (size_t i = 0; i < function_count; ++i) {
        if (functions[i].offset / WINDOW != window) {
            if (out) close_output();
            window = functions[i].offset / WINDOW;
            snprintf(path, sizeof(path), "%.*s_%05" PRIx64 ".c", (int)stem, argv[3], window);
            out = fopen(path, "w");
            if (!out) { perror(path); return 1; }
            ++files;
            emit("/* Written by tools/recomp/bbrecomp.c from the game's eboot.bin: not to be distributed. */\n");
            emit("#include \"recomp/rc.h\"\n\nextern const RcApi *rc;\n");
        }
        generate(functions[i], stats);
    }
    if (out) close_output();
    out = fopen(argv[3], "w");
    if (!out) { perror(argv[3]); return 1; }
    emit("/* Written by tools/recomp/bbrecomp.c from the game's eboot.bin: not to be distributed. */\n");
    emit("#include \"recomp/rc.h\"\n\n__attribute__((visibility(\"hidden\"))) const RcApi *rc;\n"
         "__attribute__((visibility(\"hidden\"))) uint32_t rc_fp_mask = ~0u;\n");
    for (size_t i = 0; i < sizeof(host_math) / sizeof(host_math[0]); ++i)
        emit("__attribute__((visibility(\"hidden\"))) uint8_t rc_host_%" PRIx64 ";\n", host_math[i].offset);
    for (size_t i = 0; i < sizeof(fast_kernels) / sizeof(fast_kernels[0]); ++i)
        emit("__attribute__((visibility(\"hidden\"))) uint8_t rc_fast_%" PRIx64 ";\n", fast_kernels[i].offset);
    if (fast_all) emit("__attribute__((visibility(\"hidden\"))) uint8_t rc_fast_all;\n");
    for (size_t i = 0; i < function_count; ++i)
        emit("void f_%" PRIx64 "(BbCpu *c);\n__attribute__((visibility(\"hidden\"))) RcFn d_%" PRIx64 ";\n",
             functions[i].offset, functions[i].offset);
    emit("\nstatic const RcFunction table[] = {\n");
    for (size_t i = 0; i < function_count; ++i)
        emit("    {0x%" PRIx64 ", %" PRIu64 ", 0x%" PRIx64 "ull, f_%" PRIx64 ", &d_%" PRIx64 "},\n", functions[i].offset,
             functions[i].size, bbcpu_recomp_hash(base + functions[i].offset, functions[i].size), functions[i].offset,
             functions[i].offset);
    emit("};\n\n#ifdef BB_PGO_GEN\nint __llvm_profile_write_file(void);\n"
         "__attribute__((visibility(\"default\"))) void bb_recomp_profile_flush(void) { __llvm_profile_write_file(); }\n#endif\n");
    emit("\n__attribute__((visibility(\"default\"))) const RcFunction *bb_recomp_init(const RcApi *api, size_t *count) {\n");
    emit("    rc = api;\n    rc_fp_mask = rc_fp_exact() ? ~0u : 0x6040u;\n");
    for (size_t i = 0; i < sizeof(host_math) / sizeof(host_math[0]); ++i)
        emit("    rc_host_%" PRIx64 " = (uint8_t)rc_host_math(0x%" PRIx64 ");\n", host_math[i].offset, host_math[i].offset);
    for (size_t i = 0; i < sizeof(fast_kernels) / sizeof(fast_kernels[0]); ++i)
        emit("    rc_fast_%" PRIx64 " = (uint8_t)rc_fast(0x%" PRIx64 ");\n", fast_kernels[i].offset, fast_kernels[i].offset);
    if (fast_all) emit("    rc_fast_all = (uint8_t)rc_fast(0);\n");
    emit("    *count = sizeof(table) / sizeof(table[0]);\n    return table;\n}\n");
    fclose(out);
    printf("E3: %" PRIu64 " of %" PRIu64 " direct calls skip flag materialization, %" PRIu64 " returns materialize; E5: %" PRIu64 " fast kernels\n",
           flag_calls_skipped, flag_call_sites, flag_rets_materialized, fast_generated);
    printf("%zu functions, %" PRIu64 " instructions: %" PRIu64 " in C (%.0f%%), the rest in the interpreter; %d files\n",
           function_count, stats[2], stats[0], stats[2] ? 100.0 * (double)stats[0] / (double)stats[2] : 0.0, files);
    return 0;
}
