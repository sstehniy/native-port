/* Dev-only wire protocol. Both executables are built together from the same BbCpu definition. */
#ifndef X86_ORACLE_H
#define X86_ORACLE_H
#include "../src/cpu/cpu_internal.h"
#include <errno.h>
#include <unistd.h>
#define ORACLE_CODE UINT64_C(0x30000000000)
#define ORACLE_SCRATCH UINT64_C(0x31000000000)
enum { ORACLE_MEMORY = 1 << 16, ORACLE_RIP_MEMORY = 1 << 15 };
typedef struct {
    BbCpu cpu;
    uint64_t rip_page, branch_target;
    uint8_t code[16];
    uint32_t length, signal, single_step, x87;
} X86Oracle;
static int oracle_io(int fd, void *buffer, size_t length, int writing) {
    char *p = buffer;
    while (length) {
        ssize_t n = writing ? write(fd, p, length) : read(fd, p, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        p += n;
        length -= (size_t)n;
    }
    return 1;
}
#endif
