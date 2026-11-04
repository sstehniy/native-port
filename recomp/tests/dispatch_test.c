#include "../src/cpu/trace.h"
#include <unistd.h>
#include "dispatch_offsets.h"
#include <assert.h>
#include <fenv.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

uint64_t bb_image_base;
void *runtime_low_map(size_t size, int prot) {
    void *p = mmap(NULL, size, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}

typedef struct { unsigned char ident[16]; uint16_t type, machine; uint32_t version;
    uint64_t entry, phoff, shoff; uint32_t flags; uint16_t ehsize, phentsize, phnum,
    shentsize, shnum, shstrndx; } ElfHeader;
typedef struct { uint32_t type, flags; uint64_t offset, vaddr, paddr, filesz, memsz, align; } ElfSegment;

static void load_fixture(const char *path) {
    FILE *f = fopen(path, "rb");
    assert(f && fseek(f, 0, SEEK_END) == 0);
    const long size = ftell(f);
    assert(size >= (long)sizeof(ElfHeader) && fseek(f, 0, SEEK_SET) == 0);
    uint8_t *data = malloc((size_t)size);
    assert(data && fread(data, 1, (size_t)size, f) == (size_t)size);
    fclose(f);
    const ElfHeader *header = (const ElfHeader *)data;
    assert(memcmp(header->ident, "\177ELF\2\1\1", 7) == 0 && header->machine == 62);
    assert(header->phentsize == sizeof(ElfSegment));
    assert(header->phoff + (uint64_t)header->phnum * sizeof(ElfSegment) <= (uint64_t)size);
    const ElfSegment *segments = (const ElfSegment *)(data + header->phoff);
    uint64_t end = 0;
    for (int i = 0; i < header->phnum; ++i) {
        const ElfSegment *p = &segments[i];
        if (p->type != 1) continue;
        assert(p->filesz <= p->memsz && p->offset + p->filesz <= (uint64_t)size);
        assert(p->vaddr + p->memsz < 1 << 20);
        if (p->vaddr + p->memsz > end) end = p->vaddr + p->memsz;
    }
    assert(end);
    uint8_t *image = runtime_low_map((size_t)end, PROT_READ | PROT_WRITE);
    assert(image);
    bb_image_base = (uint64_t)(uintptr_t)image;
    for (int i = 0; i < header->phnum; ++i) {
        const ElfSegment *p = &segments[i];
        if (p->type != 1) continue;
        memcpy(image + p->vaddr, data + p->offset, (size_t)p->filesz);
        if (p->flags & 1) bbcpu_add_guest_code((uintptr_t)image + p->vaddr, (size_t)p->memsz);
    }
    free(data);
}

#define THUNKS UINT64_C(0x600000000000)
static unsigned host_calls, checks;
static fenv_t expected_environment;
static unsigned fp_calls;
static void host_thunk(BbCpu *cpu, uint64_t address, uint64_t stack_args) {
    assert((stack_args & 15) == 0);
    if (address == THUNKS + 80) {
        fenv_t actual = {0};
        assert(fegetenv(&actual) == 0);
        assert(memcmp(&actual, &expected_environment, sizeof(actual)) == 0);
        assert(fesetround(FE_TOWARDZERO) == 0 && feraiseexcept(FE_OVERFLOW) == 0);
        assert(fegetenv(&expected_environment) == 0);
        ++fp_calls;
        return;
    }
    if (address == THUNKS + 32) {
        assert(cpu->r[RCX] == 11 && cpu->r[R8] == 33);
        assert(cpu->v[1].q[0] == UINT64_C(0x3ff8000000000000) && cpu->v[3].d[0] == 0xc0100000);
        assert(bb_load(stack_args + 32, 8) == UINT64_C(0x400a000000000000));
        assert(bb_load(stack_args + 40, 8) == 66);
        for (unsigned i = 0; i < 4; ++i) bb_store(stack_args + i * 8, 8, 0x1234);
        cpu->v[0].d[0] = 0x40880000; /* float return: 4.25 */
        return;
    }
    if (address == THUNKS + 48) { cpu->r[RAX] = UINT64_C(0x8877665544332211); return; }
    if (address == THUNKS + 64) {
        assert(cpu->r[RDX] == UINT64_C(0x1234567887654321));
        assert(cpu->v[2].q[0] == UINT64_C(0x4004000000000000) && cpu->r[R9] == 77);
        uint64_t *out = (uint64_t *)(uintptr_t)cpu->r[RCX];
        out[0] = 0x1234; out[1] = UINT64_C(0x8877665544332211); out[2] = UINT64_MAX;
        cpu->r[RAX] = cpu->r[RCX];
        return;
    }
    assert(address == THUNKS || address == THUNKS + 16);
    cpu->r[RAX] = cpu->r[RCX] + cpu->r[RDX];
    if (address == THUNKS + 16)
        cpu->r[RAX] += cpu->r[R8] + cpu->r[R9] + bb_load(stack_args + 32, 8) + bb_load(stack_args + 40, 8);
    ++host_calls;
}

static void check(uint64_t offset, int count, const uint64_t *args, uint64_t expected) {
    const uint64_t got = bbcpu_call_win64(bb_image_base + offset, count, args);
    if (got != expected) {
        fprintf(stderr, "dispatch at %#llx: got %#llx, expected %#llx\n", (unsigned long long)offset,
                (unsigned long long)got, (unsigned long long)expected);
        abort();
    }
    ++checks;
}

static void test_code_hash(void) {
    const size_t page = (size_t)getpagesize();
    uint8_t *mapping = mmap(NULL, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(mapping != MAP_FAILED && mprotect(mapping + page, page, PROT_NONE) == 0);
    uint8_t *bytes = mapping + page - 5;
    memcpy(bytes, "hello", 5);
    assert(bbcpu_recomp_hash((uintptr_t)bytes, 5) == UINT64_C(0xa430d84680aabd0b));
    assert(bbcpu_recomp_hash((uintptr_t)bytes, 1) == UINT64_C(0xa430d84680aabd0b));
    assert(bbcpu_recomp_hash((uintptr_t)(mapping + page), 0) == UINT64_C(0xcbf29ce484222325));
    bytes[4] = 'x';
    assert(bbcpu_recomp_hash((uintptr_t)bytes, 5) != UINT64_C(0xa430d84680aabd0b));
    assert(munmap(mapping, page * 2) == 0);
}

static void test_scan(void) {
    const size_t page = (size_t)getpagesize();
    uint8_t *memory = mmap(NULL, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(memory != MAP_FAILED && mprotect(memory + page, page, PROT_NONE) == 0);
    for (unsigned stride = 8; stride <= 16; stride += 8) for (unsigned alignment = 0; alignment < 8; ++alignment) {
        for (unsigned n = 1; n <= 16; ++n) for (unsigned match = 0; match <= n; ++match) {
            uint8_t *start = memory + page - n * stride - alignment;
            for (unsigned i = 0; i < n; ++i) { uint64_t value = i + 1; memcpy(start + i * stride, &value, 8); }
            uint64_t result[3] = {0};
            const uint64_t args[] = {(uintptr_t)start, n, match < n ? match + 1 : UINT64_MAX, (uintptr_t)result};
            check(stride == 8 ? GUEST_SCAN : GUEST_SCAN_STRIDE, 4, args, 0xcafe);
            assert(result[0] == (uintptr_t)(start + match * stride) && result[1] == n - match);
            assert((result[2] & F_ARITH) == (F_ZF | F_PF));
            assert(result[2] & F_DF);
        }
    }
    uint64_t value = 7, result[3] = {0};
    const uint64_t zero_count[] = {(uintptr_t)&value, 0, 7, (uintptr_t)result};
    check(GUEST_SCAN, 4, zero_count, 0xcafe);
    assert(result[0] == (uintptr_t)&value && result[1] == 0 && (result[2] & F_ARITH) == (F_ZF | F_PF));
    assert(result[2] & F_DF);
    assert(munmap(memory, page * 2) == 0);
}

int main(int argc, char **argv) {
    assert(argc == 3);
    setenv("BB_JIT", "0", 1);
    test_code_hash();
    load_fixture(argv[1]);
    bbcpu_set_host_thunks(THUNKS, 96, host_thunk);
    bbcpu_recomp_load(bb_image_base);
    assert(bbcpu_recomp_functions() == strtoull(argv[2], NULL, 10));
    test_scan();
    const uint64_t vtable[] = {bb_image_base + GUEST_LEAF}, host_vtable[] = {THUNKS};
    const uint64_t object[] = {(uint64_t)(uintptr_t)vtable}, host_object[] = {(uint64_t)(uintptr_t)host_vtable};
    const uint64_t values[] = {0, 1, 2, 7, 0xffffffff, UINT64_C(0x100000000), UINT64_C(0x8000000000000000), UINT64_MAX};
    for (size_t i = 0; i < sizeof(values) / sizeof(*values); ++i) {
        for (size_t j = 0; j < sizeof(values) / sizeof(*values); ++j) {
            const uint64_t a = values[i], b = values[j];
            const uint64_t pair[] = {a, b};
            const uint64_t virtual_args[] = {(uint64_t)(uintptr_t)object, a, b};
            const uint64_t tail[] = {bb_image_base + GUEST_LEAF, a, b};
            const uint64_t host_virtual_args[] = {(uint64_t)(uintptr_t)host_object, a, b};
            const uint64_t host_tail[] = {THUNKS, a, b};
            const uint64_t six[] = {THUNKS + 16, a, b, 13};
            const uint64_t flags[] = {a, b, bb_image_base + GUEST_CAPTURE_CARRY};
            check(GUEST_VTABLE, 3, virtual_args, a + b);
            check(GUEST_TAIL, 2, pair, a + b);
            check(GUEST_INDIRECT_TAIL, 3, tail, a + b);
            check(GUEST_VTABLE, 3, host_virtual_args, a + b);
            check(GUEST_INDIRECT_TAIL, 3, host_tail, a + b);
            check(GUEST_HOST_CALL, 4, six, a + b + 13 + 4 + 0x5566 + 0x7788);
            for (uint64_t index = 0; index < 3; ++index) {
                const uint64_t branch[] = {index, a, b};
                uint64_t expected = UINT64_MAX;
                if (index == 0) expected = a + b;
                else if (index == 1) expected = a - b;
                check(GUEST_SWITCH, 3, branch, expected);
            }
            check(GUEST_FLAGS_DIRECT, 2, pair, a < b);
            check(GUEST_FLAGS_INDIRECT, 3, flags, a < b);
            check(GUEST_FLAGS_RETURN, 2, pair, a < b);
            check(GUEST_FLAGS_THROUGH, 2, pair, a < b);
            check(GUEST_FLAGS_DEAD, 2, pair, 8);
        }
    }
    const uint64_t counts[] = {0, 1, 31, 32, 63, 64, 65, UINT64_MAX};
    for (size_t i = 0; i < sizeof(values) / sizeof(*values); ++i) {
        for (size_t j = 0; j < sizeof(counts) / sizeof(*counts); ++j) {
            uint64_t changed_flags = UINT64_MAX;
            const uint64_t args[] = {values[i], counts[j], (uint64_t)(uintptr_t)&changed_flags};
            check(GUEST_SHLX64, 3, args, values[i] << (counts[j] & 63));
            assert(changed_flags == 0);
            check(GUEST_SHLX32, 3, args, (uint32_t)values[i] << (counts[j] & 31));
            assert(changed_flags == 0);
        }
    }
    assert(host_calls == 3 * 64);
    for (unsigned skip = 0; skip < 2; ++skip) {
        const uint64_t ascending[] = {2, 7, skip}, descending[] = {7, 2, skip};
        check(GUEST_REGIONS, 3, ascending, 2 + 3 * (1 + (skip ? 0 : 7)));
        check(GUEST_REGIONS, 3, descending, 7 + 3 * (skip ? 0 : 7));
    }
    const uint64_t many[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
    check(GUEST_MANY_ARGS, 16, many, 136);
    const uint64_t floats[] = {THUNKS + 32};
    check(GUEST_FLOAT_CALL, 1, floats, 0x40880000);
    const uint64_t small[] = {THUNKS + 48, 0, 0};
    check(GUEST_INDIRECT_TAIL, 3, small, UINT64_C(0x8877665544332211));
    uint64_t large[3] = {0};
    const uint64_t structure[] = {THUNKS + 64, (uint64_t)(uintptr_t)large, UINT64_C(0x1234567887654321)};
    check(GUEST_STRUCT_CALL, 3, structure, (uint64_t)(uintptr_t)large);
    assert(large[0] == 0x1234 && large[1] == UINT64_C(0x8877665544332211) && large[2] == UINT64_MAX);
    fenv_t original;
    assert(fegetenv(&original) == 0);
    assert(fesetround(FE_DOWNWARD) == 0 && feraiseexcept(FE_INEXACT | FE_DIVBYZERO) == 0);
    assert(fegetenv(&expected_environment) == 0);
    const uint64_t fp_functions[] = {GUEST_FP_SCOPE, GUEST_FP_REGIONS};
    for (unsigned function = 0; function < 2; ++function) for (unsigned flush = 0; flush < 2; ++flush) {
        uint32_t result[12] = {0};
        const uint64_t args[] = {THUNKS + 80, 0x5f80 | (flush ? 0x8040 : 0), (uintptr_t)result};
        check(fp_functions[function], 3, args, 0xf00d);
        for (unsigned i = 0; i < 4; ++i) {
            assert(result[i] == 0x3f800020 && result[i + 4] == 0x3f800000);
            assert(result[i + 8] == 0x3f800002);
        }
        fenv_t after = {0};
        assert(fegetenv(&after) == 0 && memcmp(&after, &expected_environment, sizeof(after)) == 0);
    }
    assert(fp_calls == 4 && fesetenv(&original) == 0);
    printf("{\"checks\":%u,\"host_calls\":%u,\"fp_callbacks\":%u,\"recompiled_functions\":%zu}\n", checks, host_calls, fp_calls, bbcpu_recomp_functions());
    return 0;
}
