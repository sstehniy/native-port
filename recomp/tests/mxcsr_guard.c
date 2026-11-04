/* R1.04: LDMXCSR accepts masked exception settings and stops on unmasked ones, which the game never
 * loads (results/recomp/fp-status.json). Usage: mxcsr_guard masked|unmasked */
#include "../src/cpu/bbcpu.h"
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

uint64_t bb_image_base;

void *runtime_low_map(size_t size, int prot) {
    void *p = mmap(NULL, size, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    static const uint8_t guest[] = {0x0f, 0xae, 0x17, 0xc3}; /* ldmxcsr [rdi]; ret */
    uint8_t *code = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (code == MAP_FAILED) return 2;
    memcpy(code, guest, sizeof(guest));
    bbcpu_add_guest_code((uintptr_t)code, 0x1000);
    static uint32_t value;
    value = strcmp(argv[1], "unmasked") ? 0x9fc0 : 0x1d80;
    const uint64_t args[1] = {(uintptr_t)&value};
    bbcpu_call((uintptr_t)code, 1, args);
    printf("LDMXCSR %#x accepted\n", value);
    return 0;
}
