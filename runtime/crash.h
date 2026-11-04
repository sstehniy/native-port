#ifndef SS_CRASH_H
#define SS_CRASH_H
#include "runtime.h"
#include <array>

struct alignas(16) RtContext {
    uint64_t home[6];
    uint32_t flags, mxcsr;
    uint16_t cs, ds, es, fs, gs, ss;
    uint32_t eflags;
    uint64_t debug[6], r[16], rip;
    uint8_t floating[512], tail[464];
};
static_assert(sizeof(RtContext) == 1232 && offsetof(RtContext, r) == 120 && offsetof(RtContext, rip) == 248);
struct RtException {
    uint32_t code, flags;
    uint64_t chained, address;
    uint32_t count, padding;
    uint64_t information[15];
};
struct RtExceptionPointers { RtException *record; RtContext *context; };
struct RtFunction { uint32_t begin, end, unwind; };

bool rt_read_guest(uint64_t address, void *out, size_t size);
void rt_crash_init(uint64_t base, uint64_t size, const char *path);
RtContext rt_capture_context(const BbCpu *cpu);
uint64_t rt_lookup_function(uint64_t pc);
bool rt_unwind(RtContext &context, uint64_t function, uint32_t type = 0,
               uint64_t *handler = nullptr, uint64_t *data = nullptr, uint64_t *frame = nullptr,
               uint64_t *pointers = nullptr);
void rt_crash_fault(BbCpu *cpu, int signal, uint64_t address, uint32_t access);
void rt_crash_signal(int signal, uint64_t address, const BbCpu *cpu);
#endif
