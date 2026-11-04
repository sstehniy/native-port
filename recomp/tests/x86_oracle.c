/* Executes one x86 instruction through Rosetta, independently of bbcpu. A signal return loads
 * every register; int3 captures fallthrough results, TF captures branch destinations. */
#include "x86_oracle.h"
#include <assert.h>
#include <immintrin.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/ucontext.h>

static X86Oracle packet;
static sigjmp_buf resume_host;
static uint8_t *code, *scratch, *rip_memory;
static uint64_t rip_page, instruction_rip;
#define GPRS(X) X(RAX, rax) X(RCX, rcx) X(RDX, rdx) X(RBX, rbx) X(RSP, rsp) X(RBP, rbp) \
    X(RSI, rsi) X(RDI, rdi) X(R8, r8) X(R9, r9) X(R10, r10) X(R11, r11) X(R12, r12) \
    X(R13, r13) X(R14, r14) X(R15, r15)

static void trap(int sig, siginfo_t *info, void *context) {
    ucontext_t *u = context;
    if (u->uc_mcsize != sizeof(_STRUCT_MCONTEXT_AVX64)) _exit(3);
    _STRUCT_MCONTEXT_AVX64 *m = (void *)u->uc_mcontext;
    uint8_t *xmm = (void *)&m->__fs.__fpu_xmm0, *ymmh = (void *)&m->__fs.__fpu_ymmh0;
    if (sig == SIGUSR1) {
#define LOAD(index, name) m->__ss.__##name = packet.cpu.r[index];
        GPRS(LOAD)
#undef LOAD
        m->__ss.__rip = packet.cpu.rip;
        m->__ss.__rflags = (packet.cpu.flags & 0xcd5) | 0x202;
        if (packet.single_step) m->__ss.__rflags |= 0x100;
        m->__fs.__fpu_mxcsr = packet.cpu.mxcsr;
        if (packet.x87) {
            const uint16_t status = (uint16_t)(packet.cpu.top << 11);
            memcpy(&m->__fs.__fpu_fcw, &packet.cpu.fcw, 2);
            memcpy(&m->__fs.__fpu_fsw, &status, 2);
            m->__fs.__fpu_ftw = (uint8_t)(1u << packet.cpu.top);
            long double value = packet.cpu.st[packet.cpu.top];
            memset(&m->__fs.__fpu_stmm0, 0, 8 * 16);
            memcpy((uint8_t *)&m->__fs.__fpu_stmm0 + packet.cpu.top * 16, &value, 10);
        }
        for (int i = 0; i < 16; ++i) {
            memcpy(xmm + i * 16, packet.cpu.v[i].b, 16);
            memcpy(ymmh + i * 16, packet.cpu.v[i].b + 16, 16);
        }
        return;
    }
#define SAVE(index, name) packet.cpu.r[index] = m->__ss.__##name;
    GPRS(SAVE)
#undef SAVE
    packet.cpu.rip = m->__ss.__rip;
    packet.cpu.flags = m->__ss.__rflags & ~UINT64_C(0x100);
    packet.cpu.mxcsr = m->__fs.__fpu_mxcsr;
    if (packet.x87) {
        uint16_t status;
        memcpy(&status, &m->__fs.__fpu_fsw, 2);
        memcpy(&packet.cpu.fcw, &m->__fs.__fpu_fcw, 2);
        packet.cpu.top = (status >> 11) & 7;
        if (m->__fs.__fpu_ftw & (1u << packet.cpu.top)) {
            long double value = 0;
            memcpy(&value, (uint8_t *)&m->__fs.__fpu_stmm0 + packet.cpu.top * 16, 10);
            packet.cpu.st[packet.cpu.top] = (double)value;
        }
    }
    for (int i = 0; i < 16; ++i) {
        memcpy(packet.cpu.v[i].b, xmm + i * 16, 16);
        memcpy(packet.cpu.v[i].b + 16, ymmh + i * 16, 16);
    }
    packet.signal = sig;
    /* Rosetta reports TF as TRAP_BRKPT too; the caller classifies explicit int3 forms. */
    if (sig == SIGTRAP && packet.single_step) packet.signal = 0;
    else if (sig == SIGTRAP && packet.cpu.rip == instruction_rip + packet.length + 1) {
        packet.signal = 0;
        --packet.cpu.rip;
    }
    (void)info;
    siglongjmp(resume_host, 1);
}

static void execute(void) {
    instruction_rip = packet.cpu.rip;
    /* Use a following breakpoint so ordinary instructions run without debugger single stepping. */
    if (!packet.single_step) *((uint8_t *)packet.cpu.rip + packet.length) = 0xcc;
    if (!sigsetjmp(resume_host, 1)) raise(SIGUSR1);
    _mm_setcsr(0x1f80);
}

static void self_check(void) {
    memset(&packet, 0, sizeof(packet));
    packet.cpu.rip = ORACLE_CODE;
    packet.cpu.r[RSP] = ORACLE_SCRATCH + 0x8000;
    packet.cpu.r[RAX] = UINT64_C(0x7fffffffffffffff);
    packet.cpu.mxcsr = 0x1f80;
    packet.length = 3;
    memcpy(code, "\x48\xff\xc0", 3); /* inc rax */
    execute();
    assert(!packet.signal && packet.cpu.r[RAX] == UINT64_C(0x8000000000000000));
    assert(packet.cpu.rip == ORACLE_CODE + 3 && (packet.cpu.flags & 0x880) == 0x880);
    packet.cpu.rip = ORACLE_CODE;
    packet.cpu.r[RAX] = 0x10;
    packet.cpu.r[RCX] = 0x30;
    packet.cpu.r[RDX] = ORACLE_SCRATCH;
    *(uint32_t *)scratch = 0x20;
    packet.length = 4;
    memcpy(code, "\xf0\x0f\xb1\x0a", 4); /* failed lock cmpxchg [rdx], ecx */
    execute();
    assert(!packet.signal && packet.cpu.r[RAX] == 0x20 && *(uint32_t *)scratch == 0x20);
    uint32_t memory = 0x20, expected = 0x10;
    uint64_t flags;
    __asm__ volatile("lock cmpxchgl %3, %1\n\tpushfq\n\tpopq %2"
                     : "+a"(expected), "+m"(memory), "=r"(flags) : "r"(0x30) : "cc", "memory");
    assert(expected == 0x20 && memory == 0x20);
    assert((packet.cpu.flags & 0x8d5) == (flags & 0x8d5));
    fprintf(stderr, "Rosetta failed-cmpxchg flags=%#llx; architectural subtraction flags=0x85\n", flags & 0x8d5);
    packet.cpu.rip = ORACLE_CODE;
    for (int i = 0; i < 8; ++i) { packet.cpu.v[0].f[i] = (float)i; packet.cpu.v[1].f[i] = 2; }
    packet.length = 4;
    memcpy(code, "\xc5\xfc\x58\xc1", 4); /* vaddps ymm0, ymm0, ymm1 */
    execute();
    assert(!packet.signal);
    for (int i = 0; i < 8; ++i) assert(packet.cpu.v[0].f[i] == (float)i + 2);
    packet.cpu.rip = ORACLE_CODE;
    packet.cpu.mxcsr = 0x5f80; /* round upward */
    packet.cpu.v[0].f[0] = 1.25f;
    memcpy(code, "\xf3\x0f\x2d\xc0", 4); /* cvtss2si eax, xmm0 */
    execute();
    assert(!packet.signal && packet.cpu.r[RAX] == 2);
    packet.cpu.rip = ORACLE_CODE;
    packet.cpu.r[RAX] = ORACLE_SCRATCH;
    packet.cpu.r[RCX] = UINT64_C(0xfedcba9876543210);
    packet.length = 3;
    memcpy(code, "\x48\x89\x08", 3);
    execute();
    assert(!packet.signal && *(uint64_t *)scratch == UINT64_C(0xfedcba9876543210));
    packet.cpu.rip = ORACLE_CODE;
    packet.length = 2;
    packet.single_step = 1;
    memcpy(code, "\xeb\x20", 2);
    execute();
    assert(!packet.signal && packet.cpu.rip == ORACLE_CODE + 34);
    packet.cpu.rip = ORACLE_CODE;
    packet.cpu.r[RCX] = 0;
    packet.length = 3;
    packet.single_step = 0;
    memcpy(code, "\x48\xf7\xf1", 3); /* div rcx */
    execute();
    assert(packet.signal == SIGFPE && packet.cpu.rip == ORACLE_CODE);
    packet.cpu.rip = ORACLE_CODE;
    packet.cpu.r[RBX] = ORACLE_SCRATCH;
    packet.cpu.fcw = 0x37f;
    packet.cpu.top = 0;
    packet.cpu.st[0] = 2.25;
    packet.x87 = 1;
    packet.length = 2;
    *(float *)scratch = 1.5f;
    memcpy(code, "\xd9\x03", 2); /* fld dword [rbx] */
    execute();
    assert(!packet.signal && packet.cpu.top == 7 && packet.cpu.st[7] == 1.5);
    packet.cpu.rip = ORACLE_CODE;
    packet.cpu.top = 0;
    memcpy(code, "\xdb\x3b", 2); /* fstp tbyte [rbx] */
    execute();
    uint64_t mantissa;
    uint16_t exponent;
    memcpy(&mantissa, scratch, 8);
    memcpy(&exponent, scratch + 8, 2);
    assert(!packet.signal && packet.cpu.top == 1 && mantissa == UINT64_C(0x9000000000000000) && exponent == 0x4000);
    fprintf(stderr, "x86 oracle self-check PASS: integer/atomic flags, YMM, x87, rounding, memory, branch, fault\n");
}

int main(int argc, char **argv) {
    int translated = 0;
    size_t size = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0) || translated != 1) return 2;
    code = mmap((void *)ORACLE_CODE, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC,
                MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    scratch = mmap((void *)ORACLE_SCRATCH, ORACLE_MEMORY, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    stack_t stack = {.ss_sp = malloc(SIGSTKSZ * 4), .ss_size = SIGSTKSZ * 4};
    if (code == MAP_FAILED || scratch == MAP_FAILED || !stack.ss_sp || sigaltstack(&stack, NULL)) return 2;
    struct sigaction action = {.sa_sigaction = trap, .sa_flags = SA_SIGINFO | SA_ONSTACK};
    sigemptyset(&action.sa_mask);
    const int signals[] = {SIGUSR1, SIGTRAP, SIGSEGV, SIGBUS, SIGILL, SIGFPE};
    for (unsigned i = 0; i < sizeof(signals) / sizeof(*signals); ++i)
        if (sigaction(signals[i], &action, NULL)) return 2;
    self_check();
    if (argc == 2 && !strcmp(argv[1], "--self-check")) return 0;
    const uint64_t hello[] = {UINT64_C(0x5838364f5241434c), sizeof(packet)};
    if (!oracle_io(STDOUT_FILENO, (void *)hello, sizeof(hello), 1)) return 2;
    while (oracle_io(STDIN_FILENO, &packet, sizeof(packet), 0)) {
        if (!packet.length || packet.length > 15 || packet.cpu.rip < ORACLE_CODE ||
            packet.cpu.rip + packet.length >= ORACLE_CODE + 0x4000) return 2;
        if (packet.branch_target && (packet.branch_target < ORACLE_CODE ||
            packet.branch_target >= ORACLE_CODE + 0x4000)) return 2;
        memcpy((void *)packet.cpu.rip, packet.code, packet.length);
        if (packet.rip_page && packet.rip_page != rip_page) {
            if (rip_memory) munmap(rip_memory, ORACLE_RIP_MEMORY);
            rip_page = packet.rip_page;
            rip_memory = mmap((void *)rip_page, ORACLE_RIP_MEMORY, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
            if (rip_memory == MAP_FAILED) return 2;
        }
        if (!oracle_io(STDIN_FILENO, scratch, ORACLE_MEMORY, 0) ||
            (packet.rip_page && !oracle_io(STDIN_FILENO, rip_memory, ORACLE_RIP_MEMORY, 0))) return 2;
        if (packet.cpu.gs_base) {
            if (packet.cpu.gs_base != ORACLE_SCRATCH + 0x1000) return 2;
            for (uint64_t offset = 0; offset < 128; offset += 8) {
                uint64_t value;
                __asm__ volatile("movq %%gs:(%1), %0" : "=r"(value) : "r"(offset));
                memcpy(scratch + 0x1000 + offset, &value, 8);
            }
        }
        packet.signal = 0;
        alarm(5);
        execute();
        alarm(0);
        if (!oracle_io(STDOUT_FILENO, &packet, sizeof(packet), 1) ||
            !oracle_io(STDOUT_FILENO, scratch, ORACLE_MEMORY, 1) ||
            (packet.rip_page && !oracle_io(STDOUT_FILENO, rip_memory, ORACLE_RIP_MEMORY, 1))) return 2;
    }
    return 0;
}
