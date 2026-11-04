#include "x86_oracle.h"
#include "../src/cpu/trace.h"
#include "../src/recomp/rc.h"
#include "dispatch_offsets.h"
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/wait.h>

uint64_t bb_image_base;
void *runtime_low_map(size_t size, int prot) {
    void *p = mmap(NULL, size, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}

static uint64_t step(BbCpu *cpu) {
    return bbcpu_step_insn(cpu, &bbcpu_block(cpu->rip)->insn[0]);
}

static unsigned trace_calls;
static void trace(uint64_t offset, const uint64_t registers[16], const BbCpu *cpu) {
    (void)offset; (void)registers; (void)cpu;
    ++trace_calls;
}

static uint64_t random_state = UINT64_C(0xa3fb192e45c6708d);
static uint64_t random_word(void) {
    random_state ^= random_state << 13;
    random_state ^= random_state >> 7;
    random_state ^= random_state << 17;
    return random_state;
}

int main(int argc, char **argv) {
    assert(argc == 4 || (argc == 5 && !strcmp(argv[4], "trace")));
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(library);
    RcInit init = (RcInit)dlsym(library, BB_RECOMP_INIT);
    assert(init);
    bb_image_base = ORACLE_CODE - GUEST_SCAN_ORACLE;
    static BbCpu warm;
    bbcpu_run(&warm, 0);
    RcApi api = {.version = BB_RECOMP_API_VERSION, .image_base = bb_image_base, .step = step, .trace = trace};
    size_t count = 0;
    const RcFunction *functions = init(&api, &count);
    RcFn scan = NULL;
    for (size_t i = 0; i < count; ++i) if (functions[i].offset == GUEST_SCAN_ORACLE) scan = functions[i].fn;
    assert(scan);
    uint8_t code[17];
    FILE *elf = fopen(argv[2], "rb");
    assert(elf && !fseek(elf, GUEST_SCAN_ORACLE, SEEK_SET) && fread(code, sizeof(code), 1, elf) == 1);
    fclose(elf);
    assert(code[14] == 0x9c && code[15] == 0x5a && code[16] == 0xc3);
    void *guest_code = mmap((void *)ORACLE_CODE, 0x4000, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    assert(guest_code == (void *)ORACLE_CODE);
    memcpy(guest_code, code, sizeof(code));
    bbcpu_add_guest_code(ORACLE_CODE, 0x4000);
    uint8_t *memory = mmap((void *)ORACLE_SCRATCH, ORACLE_MEMORY, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    assert(memory == (void *)ORACLE_SCRATCH);
    int input[2], output[2];
    assert(!pipe(input) && !pipe(output));
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        assert(dup2(input[0], STDIN_FILENO) >= 0 && dup2(output[1], STDOUT_FILENO) >= 0);
        close(input[0]); close(input[1]); close(output[0]); close(output[1]);
        execl(argv[3], argv[3], NULL);
        _exit(127);
    }
    close(input[0]); close(output[1]);
    uint64_t hello[2];
    assert(oracle_io(output[0], hello, sizeof(hello), 0));
    assert(hello[0] == UINT64_C(0x5838364f5241434c) && hello[1] == sizeof(X86Oracle));
    unsigned checks = 0;
    for (unsigned alignment = 0; alignment < 8; ++alignment) for (unsigned n = 0; n <= 16; ++n) {
        for (unsigned match = 0; match <= n; ++match) for (unsigned df = 0; df < 2; ++df) {
            X86Oracle request = {0}, reference;
            for (unsigned i = 0; i < 16; ++i) {
                request.cpu.r[i] = random_word();
                for (unsigned j = 0; j < 4; ++j) request.cpu.v[i].q[j] = random_word();
            }
            const uint64_t address = ORACLE_SCRATCH + alignment;
            for (unsigned i = 0; i <= n; ++i) bb_store(address + i * 8, 8, random_word());
            const uint64_t needle = n && match == n ? UINT64_MAX : bb_load(address + match * 8, 8);
            request.cpu.r[RCX] = address; request.cpu.r[RAX] = n; request.cpu.r[R15] = needle;
            request.cpu.r[RSP] = ORACLE_SCRATCH + ORACLE_MEMORY - 16;
            const uint64_t return_address = UINT64_C(0x123456780000);
            bb_store(request.cpu.r[RSP], 8, return_address);
            request.cpu.rip = ORACLE_CODE;
            request.cpu.flags = F_ARITH | 0x202 | (df ? F_DF : 0);
            request.cpu.mxcsr = 0x1f80;
            memcpy(request.code, code, 15); request.length = 15;
            BbCpu actual = request.cpu;
            uint8_t reference_memory[ORACLE_MEMORY];
            assert(oracle_io(input[1], &request, sizeof(request), 1));
            assert(oracle_io(input[1], memory, ORACLE_MEMORY, 1));
            assert(oracle_io(output[0], &reference, sizeof(reference), 0));
            assert(oracle_io(output[0], reference_memory, sizeof(reference_memory), 0));
            if (reference.signal || reference.cpu.rip != ORACLE_CODE + 15) {
                fprintf(stderr, "scan oracle: alignment=%u n=%u match=%u df=%u signal=%u rip=%#llx\n",
                        alignment, n, match, df, reference.signal, (unsigned long long)reference.cpu.rip);
                abort();
            }
            trace_calls = 0;
            scan(&actual);
            unsigned expected_trace = 0;
            if (argc == 5) expected_trace = n && match == n ? 5 * n + 3 : 5 * match + 5;
            assert(trace_calls == expected_trace);
            memcpy(&reference.cpu.r[RDX], reference_memory + reference.cpu.r[RSP] - ORACLE_SCRATCH, 8);
            reference.cpu.r[RSP] += 16;
            assert(actual.rip == return_address && !memcmp(actual.r, reference.cpu.r, sizeof(actual.r)));
            if ((actual.flags & (F_ARITH | F_DF)) != (reference.cpu.flags & (F_ARITH | F_DF))) {
                fprintf(stderr, "scan flags: alignment=%u n=%u match=%u df=%u actual=%#llx reference=%#llx\n",
                        alignment, n, match, df, (unsigned long long)actual.flags, (unsigned long long)reference.cpu.flags);
                abort();
            }
            assert(!memcmp(actual.v, reference.cpu.v, sizeof(actual.v)) && actual.mxcsr == reference.cpu.mxcsr);
            assert(!memcmp(memory, reference_memory, ORACLE_MEMORY));
            ++checks;
        }
    }
    close(input[1]); close(output[0]);
    int status;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    printf("{\"scan_oracle_checks\":%u}\n", checks);
    assert(!munmap(memory, ORACLE_MEMORY));
    dlclose(library);
    return 0;
}
