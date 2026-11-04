/* R1.06: CPUID/XGETBV through bbcpu (tools/recomp_cpu_identity.py). Usage: cpu-identity-test
 * fixture.elf functions leaf:subleaf... Prints one JSON line of the guest-visible values. */
#include "../src/cpu/cpu_internal.h"
#include "cpu_identity_offsets.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

uint64_t bb_image_base;
void *runtime_low_map(size_t size, int prot) {
    void *p = mmap(NULL, size, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}

static void load_fixture(const char *path) {
    FILE *f = fopen(path, "rb");
    assert(f && fseek(f, 0, SEEK_END) == 0);
    const long size = ftell(f);
    assert(size > 0x1000 && fseek(f, 0, SEEK_SET) == 0);
    uint8_t *image = runtime_low_map((size_t)size, PROT_READ | PROT_WRITE);
    assert(image && fread(image, 1, (size_t)size, f) == (size_t)size);
    fclose(f);
    /* tools/recomp_dispatch.py's fixture ELF: one segment, code at file offset = address 0x1000. */
    assert(memcmp(image, "\177ELF\2\1\1", 7) == 0);
    bb_image_base = (uint64_t)(uintptr_t)image;
    bbcpu_add_guest_code((uintptr_t)image + 0x1000, (size_t)size - 0x1000);
}

int main(int argc, char **argv) {
    assert(argc >= 3);
    setenv("BB_JIT", "0", 1);
    load_fixture(argv[1]);
    bbcpu_recomp_load(bb_image_base);
    assert(bbcpu_recomp_functions() == strtoull(argv[2], NULL, 10));
    char *text = NULL;
    size_t length = 0;
    FILE *json = open_memstream(&text, &length);
    assert(json);
    fprintf(json, "{\"recompiled_functions\":%zu,\"cpuid\":[", bbcpu_recomp_functions());
    for (int i = 3; i < argc; ++i) {
        char *end;
        const uint64_t leaf = strtoull(argv[i], &end, 0);
        assert(*end == ':');
        const uint64_t subleaf = strtoull(end + 1, &end, 0);
        assert(!*end);
        uint32_t out[4] = {0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef};
        const uint64_t args[] = {leaf, subleaf, (uint64_t)(uintptr_t)out};
        bbcpu_call_win64(bb_image_base + GUEST_CPUID, 3, args);
        fprintf(json, "%s{\"leaf\":\"0x%08llx\",\"subleaf\":%llu,\"eax\":\"0x%08x\",\"ebx\":\"0x%08x\",\"ecx\":\"0x%08x\",\"edx\":\"0x%08x\"}",
                i > 3 ? "," : "", (unsigned long long)leaf, (unsigned long long)subleaf, out[0], out[1], out[2], out[3]);
    }
    const uint64_t zero = 0;
    const uint64_t xcr0 = bbcpu_call_win64(bb_image_base + GUEST_XGETBV, 1, &zero);
    fprintf(json, "],\"xgetbv_0\":\"0x%016llx\"}", (unsigned long long)xcr0);
    fclose(json);
    printf("\n%s\n", text); /* the CPU logs to stdout too: the JSON is the last line */
    free(text);
    return 0;
}
