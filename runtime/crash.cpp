#include "crash.h"
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <signal.h>
#include <string>
#include <unistd.h>
#include <vector>
#include <pthread.h>

uint64_t rt_crash_base, rt_crash_size;
static std::string crash_directory, module_name;
static std::atomic<uint64_t> exception_filter;
static thread_local bool reporting;

RtContext rt_capture_context(const BbCpu *cpu) {
    RtContext context{};
    context.flags = 0x10000b;
    context.cs = 0x33; context.ss = 0x2b;
    if (!cpu) return context;
    memcpy(context.r, cpu->r, sizeof(context.r));
    context.rip = cpu->rip;
    context.eflags = (uint32_t)cpu->flags;
    context.mxcsr = cpu->mxcsr;
    memcpy(context.floating, &cpu->fcw, 2);
    memcpy(context.floating + 2, &cpu->fsw, 2);
    memcpy(context.floating + 24, &cpu->mxcsr, 4);
    for (unsigned i = 0; i < 16; ++i) memcpy(context.floating + 160 + i * 16, cpu->v[i].b, 16);
    return context;
}
static RtContext caller_context(WinCall *c) {
    RtContext context = rt_capture_context(c->cpu);
    context.r[RSP] = c->stack_args;
    if (!rt_read_guest(c->cpu->r[RSP], &context.rip, 8)) context.rip = c->cpu->rip;
    context.rip = bbcpu_unwind_return(context.rip);
    return context;
}
static std::string stack_text(RtContext context) {
    std::string text;
    for (unsigned i = 0; i < 64 && context.rip; ++i) {
        if (context.rip < rt_crash_base || context.rip - rt_crash_base >= rt_crash_size) break;
        char line[160];
        snprintf(line, sizeof(line), "  #%u %s+0x%llx pc=%#llx rsp=%#llx\n", i, module_name.c_str(),
                 (unsigned long long)(context.rip - rt_crash_base), (unsigned long long)context.rip,
                 (unsigned long long)context.r[RSP]);
        text += line;
        const uint64_t before = context.r[RSP];
        const uint64_t lookup = context.rip - (i != 0);
        if (!rt_unwind(context, rt_lookup_function(lookup)) || context.r[RSP] <= before) break;
    }
    return text;
}
static void write_log(const RtException &exception, const RtContext &context, const char *precision) {
    char header[256];
    snprintf(header, sizeof(header), "Windows guest exception %#x at %#llx; %s\n", exception.code,
             (unsigned long long)exception.address, precision);
    std::string text = header;
    for (unsigned i = 0; i < 16; i += 4) {
        snprintf(header, sizeof(header), "  r%u=%#llx r%u=%#llx r%u=%#llx r%u=%#llx\n", i,
                 (unsigned long long)context.r[i], i + 1, (unsigned long long)context.r[i + 1],
                 i + 2, (unsigned long long)context.r[i + 2], i + 3, (unsigned long long)context.r[i + 3]);
        text += header;
    }
    text += stack_text(context);
    fputs(text.c_str(), stderr);
    uint64_t thread = 0;
    pthread_threadid_np(nullptr, &thread);
    std::error_code error;
    std::filesystem::create_directories(crash_directory, error);
    const std::string path = crash_directory + "/crash-" + std::to_string(getpid()) + "-" + std::to_string(thread) + ".log";
    FILE *file = error ? nullptr : fopen(path.c_str(), "w");
    if (!file) { fprintf(stderr, "cannot write guest crash log %s\n", path.c_str()); return; }
    const bool written = fwrite(text.data(), 1, text.size(), file) == text.size();
    if (fclose(file) || !written) fprintf(stderr, "incomplete guest crash log %s\n", path.c_str());
    else fprintf(stderr, "guest crash log: %s\n", path.c_str());
}
static int32_t call_filter(RtExceptionPointers &pointers) {
    const uint64_t filter = exception_filter.load();
    if (!filter) return 0;
    const uint64_t args[] = {(uintptr_t)&pointers};
    return (int32_t)bbcpu_call_win64(filter, 1, args);
}
void rt_crash_fault(BbCpu *cpu, int signal, uint64_t address, uint32_t access) {
    RtContext context = rt_capture_context(cpu);
    RtException record{};
    record.code = 0xc0000005; record.address = context.rip; record.count = 2;
    record.information[0] = access; record.information[1] = address;
    if (signal == SIGILL) { record.code = 0xc000001d; record.count = 0; }
    if (signal == SIGFPE) { record.code = 0xc0000094; record.count = 0; }
    RtExceptionPointers pointers{&record, &context};
    if (reporting) { fputs("recursive guest fault while reporting an exception\n", stderr); _exit(3); }
    reporting = true;
    write_log(record, context, "last consistent guest state (native fault PC may be later)");
    const int32_t action = call_filter(pointers);
    if (action == -1) fputs("cannot resume a native fault from an approximate guest snapshot\n", stderr);
    rt_math_report();
    fflush(nullptr);
    _exit(3);
}
void rt_crash_signal(int signal, uint64_t address, const BbCpu *cpu) {
    // No guest callbacks or allocations when a fault occurred inside a native import.
    char line[256];
    const int n = snprintf(line, sizeof(line), "STOP: host signal %d at %#llx; guest rip %#llx rsp %#llx (native import, no guest resume)\n",
                           signal, (unsigned long long)address, (unsigned long long)(cpu ? cpu->rip : 0),
                           (unsigned long long)(cpu ? cpu->r[RSP] : 0));
    if (write(2, line, (size_t)std::min<int>(n, sizeof(line) - 1)) < 0) {}
}
void rt_crash_init(uint64_t base, uint64_t size, const char *path) {
    module_name = path;
    if (const size_t slash = module_name.rfind('/'); slash != std::string::npos) module_name.erase(0, slash + 1);
    rt_crash_base = base; rt_crash_size = size;
    const char *profile = getenv("SS_PROFILE_DIR");
    crash_directory = std::string(profile ? profile : "build/recomp/userdata/Player") + "/Crashes";
    bbcpu_set_fault_handler(rt_crash_fault);
}
H(RtlCaptureContext) { const auto context = caller_context(c); memcpy(P(0), &context, sizeof(context)); return 0; }
H(RtlLookupFunctionEntry) {
    const uint64_t function = rt_lookup_function(A(0));
    if (P(1)) rt_put<uint64_t>(P(1), function ? rt_crash_base : 0);
    return function;
}
H(RtlVirtualUnwind) {
    if (A(1) != rt_crash_base || !P(4)) { rt_set_last_error(487); return 0; }
    RtContext context; memcpy(&context, P(4), sizeof(context)); context.rip = A(2);
    uint64_t handler = 0, data = 0, frame = 0, saved[32] = {};
    if (!rt_unwind(context, A(3), (uint32_t)A(0), &handler, &data, &frame, saved)) { rt_set_last_error(487); return 0; }
    memcpy(P(4), &context, sizeof(context));
    if (P(5)) rt_put<uint64_t>(P(5), data);
    if (P(6)) rt_put<uint64_t>(P(6), frame);
    if (P(7)) memcpy(P(7), saved, sizeof(saved));
    return handler;
}
H(SetUnhandledExceptionFilter) { return exception_filter.exchange(A(0)); }
H(UnhandledExceptionFilter) {
    if (reporting) return 1;
    return (uint32_t)call_filter(*(RtExceptionPointers *)(uintptr_t)A(0));
}
H(RaiseException) {
    const uint32_t code = (uint32_t)A(0);
    if (code == 0x406d1388 && (uint32_t)A(1) == 0 && (uint32_t)A(2) == 3 && P(3)) {
        struct { uint32_t type, pad; uint64_t name; uint32_t thread, flags; } info;
        memcpy(&info, P(3), sizeof(info));
        if (info.type != 0x1000 || info.flags) rt_fatal("invalid thread-name exception");
        printf("runtime: thread-name notification for %#x: %s\n", info.thread, (const char *)(uintptr_t)info.name);
        return 0;
    }
    RtContext context = caller_context(c);
    RtException record{};
    record.code = code & ~0x10000000u; record.flags = (uint32_t)A(1) & 1;
    record.address = context.rip; record.count = std::min<uint32_t>((uint32_t)A(2), 15);
    if (record.count && !rt_read_guest(A(3), record.information, record.count * 8)) rt_fatal("invalid RaiseException parameters");
    if (reporting) rt_fatal("recursive RaiseException(%#x)", code);
    reporting = true;
    write_log(record, context, "software exception at the import return");
    RtExceptionPointers pointers{&record, &context};
    const int32_t action = call_filter(pointers);
    reporting = false;
    if (action == -1 && !record.flags) {
        if (!bbcpu_can_resume(context.r[RSP])) rt_fatal("exception continuation across host callbacks is unsupported");
        if (!bbcpu_is_guest((uintptr_t)context.rip)) rt_fatal("exception filter requested a non-guest continuation");
        memcpy(c->cpu->r, context.r, sizeof(context.r));
        c->cpu->flags = context.eflags; c->cpu->mxcsr = context.mxcsr;
        memcpy(&c->cpu->fcw, context.floating, 2);
        memcpy(&c->cpu->fsw, context.floating + 2, 2);
        for (unsigned i = 0; i < 16; ++i) memcpy(c->cpu->v[i].b, context.floating + 160 + i * 16, 16);
        c->cpu->r[RSP] -= 8;
        bb_store(c->cpu->r[RSP], 8, context.rip);
        return context.r[RAX];
    }
    rt_fatal("unhandled RaiseException(%#x)%s", code, action == -1 ? ": noncontinuable exception" : "");
}
H(SymSetOptions) { return (uint32_t)A(0); }
H(SymInitialize) { return 1; }
H(SymFunctionTableAccess64) { return rt_lookup_function(A(1)); }
H(SymGetModuleBase64) { return A(1) >= rt_crash_base && A(1) - rt_crash_base < rt_crash_size ? rt_crash_base : 0; }
H(ImageNtHeader) {
    uint16_t mz; uint32_t nt, signature;
    if (!rt_read_guest(A(0), &mz, 2) || mz != 0x5a4d || !rt_read_guest(A(0) + 0x3c, &nt, 4) ||
        nt > 0x100000 || !rt_read_guest(A(0) + nt, &signature, 4) || signature != 0x4550) return 0;
    return A(0) + nt;
}
H(SymGetSymFromAddr64) {
    if (A(1) < rt_crash_base || A(1) - rt_crash_base >= rt_crash_size || !P(3)) { rt_set_last_error(487); return 0; }
    uint32_t capacity; memcpy(&capacity, (uint8_t *)(uintptr_t)A(3) + 24, 4);
    uint32_t structure_size; memcpy(&structure_size, P(3), 4);
    if (!capacity || structure_size != 32) { rt_set_last_error(87); return 0; }
    const uint64_t function = rt_lookup_function(A(1));
    RtFunction fn{};
    const bool named = function && rt_read_guest(function, &fn, sizeof(fn));
    const uint64_t address = rt_crash_base + (named ? fn.begin : A(1) - rt_crash_base);
    char name[80]; snprintf(name, sizeof(name), "%s+0x%llx", module_name.c_str(), (unsigned long long)(address - rt_crash_base));
    rt_put<uint64_t>((uint8_t *)(uintptr_t)A(3) + 8, address);
    rt_put<uint32_t>((uint8_t *)(uintptr_t)A(3) + 16, named ? fn.end - fn.begin : 0);
    rt_put<uint32_t>((uint8_t *)(uintptr_t)A(3) + 20, 0);
    const size_t count = std::min<size_t>(strlen(name), capacity - 1);
    memcpy((uint8_t *)(uintptr_t)A(3) + 28, name, count);
    *((char *)(uintptr_t)A(3) + 28 + count) = 0;
    if (P(2)) rt_put<uint64_t>(P(2), A(1) - address);
    return 1;
}
H(SymGetLineFromAddr64) { if (P(2)) rt_put<uint32_t>(P(2), 0); rt_set_last_error(487); return 0; }
H(StackWalk64) {
    if ((uint32_t)A(0) != 0x8664 || !P(3) || !P(4)) { rt_set_last_error(87); return 0; }
    // The runtime walks its own identity-mapped process, with its PE function table.
    if (A(5) || A(8)) { rt_set_last_error(50); return 0; }
    RtContext context; memcpy(&context, P(4), sizeof(context));
    const uint64_t before = context.r[RSP];
    const uint64_t args[] = {A(1), context.rip};
    if (A(7) && bbcpu_call_win64(A(7), 2, args) != rt_crash_base) return 0;
    const uint64_t function = A(6) ? bbcpu_call_win64(A(6), 2, args) : rt_lookup_function(context.rip);
    if (!rt_unwind(context, function) || context.r[RSP] <= before ||
        context.rip < rt_crash_base || context.rip - rt_crash_base >= rt_crash_size) return 0;
    memcpy(P(4), &context, sizeof(context));
    auto *frame = (uint8_t *)(uintptr_t)A(3);
    for (unsigned i : {0u, 2u, 3u}) {
        uint64_t address = context.rip;
        if (i == 2) address = context.r[RBP];
        if (i == 3) address = context.r[RSP];
        rt_put<uint64_t>(frame + i * 16, address);
        rt_put<uint32_t>(frame + i * 16 + 12, 3);
    }
    uint64_t returned = 0;
    rt_read_guest(context.r[RSP], &returned, 8);
    rt_put<uint64_t>(frame + 16, returned);
    return 1;
}

H(MiniDumpWriteDump) {
    if (A(0) != UINT64_MAX || (uint32_t)A(1) != (uint32_t)getpid()) { rt_set_last_error(6); return 0; }
    if ((A(3) & 2) || A(5)) { rt_set_last_error(50); return 0; } // Full process memory and custom streams are outside this snapshot.
    RtContext context = caller_context(c);
    RtException record{};
    uint32_t thread = (uint32_t)rt_find_handler("kernel32.dll", "GetCurrentThreadId")(c);
    if (A(4)) {
        uint8_t info[16]; RtExceptionPointers pointers;
        uint64_t at;
        if (!rt_read_guest(A(4), info, sizeof(info))) { rt_set_last_error(87); return 0; }
        memcpy(&at, info + 4, 8);
        if (at && (!rt_read_guest(at, &pointers, sizeof(pointers)) ||
                   !rt_read_guest((uintptr_t)pointers.record, &record, sizeof(record)) ||
                   !rt_read_guest((uintptr_t)pointers.context, &context, sizeof(context)))) { rt_set_last_error(87); return 0; }
        uint32_t supplied; memcpy(&supplied, info, 4); if (supplied) thread = supplied;
    }
    struct Region { uint64_t address; std::vector<uint8_t> bytes; };
    std::vector<Region> memory;
    Region stack{context.r[RSP], {}};
    uint64_t limit = 65536;
    if (c->cpu->stack_top > stack.address) limit = std::min(limit, c->cpu->stack_top - stack.address);
    for (uint64_t offset = 0; offset < limit;) {
        uint8_t page[4096];
        const size_t size = std::min<uint64_t>(4096 - ((stack.address + offset) & 4095), limit - offset);
        if (!rt_read_guest(stack.address + offset, page, size)) break;
        stack.bytes.insert(stack.bytes.end(), page, page + size);
        offset += size;
    }
    memory.push_back(std::move(stack));
    if (A(6)) {
        uint64_t callback[2];
        if (!rt_read_guest(A(6), callback, sizeof(callback)) || !callback[0]) { rt_set_last_error(87); return 0; }
        for (unsigned i = 0;; ++i) {
            if (i == 16) { rt_set_last_error(87); return 0; }
            alignas(16) uint8_t input[2048] = {}, output[128] = {};
            rt_put<uint32_t>(input, (uint32_t)getpid());
            rt_put<uint64_t>(input + 4, UINT64_MAX);
            rt_put<uint32_t>(input + 12, 5); // MemoryCallback: supplemental guest regions.
            const uint64_t args[] = {callback[1], (uintptr_t)input, (uintptr_t)output};
            if (!(uint32_t)bbcpu_call_win64(callback[0], 3, args)) break;
            uint64_t address; uint32_t size;
            memcpy(&address, output, 8); memcpy(&size, output + 8, 4);
            if (!size || size > 1024 * 1024) { rt_set_last_error(87); return 0; }
            Region region{address, std::vector<uint8_t>(size)};
            if (!rt_read_guest(address, region.bytes.data(), size)) { rt_set_last_error(487); return 0; }
            memory.push_back(std::move(region));
        }
    }
    std::vector<uint8_t> dump(32 + 5 * 12);
    const auto add = [&](size_t size, size_t alignment = 4) {
        const size_t offset = (dump.size() + alignment - 1) & ~(alignment - 1);
        dump.resize(offset + size);
        return (uint32_t)offset;
    };
    const auto put32 = [&](uint32_t offset, uint32_t value) { rt_put<uint32_t>(dump.data() + offset, value); };
    const auto put64 = [&](uint32_t offset, uint64_t value) { rt_put<uint64_t>(dump.data() + offset, value); };
    const auto stream = [&](unsigned index, uint32_t type, uint32_t size, uint32_t offset) {
        put32(32 + index * 12, type); put32(36 + index * 12, size); put32(40 + index * 12, offset);
    };
    put32(0, 0x504d444d); put32(4, 0xa793); put32(8, 5); put32(12, 32);
    put32(20, (uint32_t)time(nullptr));
    const uint32_t context_at = add(sizeof(context), 16);
    memcpy(dump.data() + context_at, &context, sizeof(context));
    const uint32_t memory_at = add(4 + memory.size() * 16);
    put32(memory_at, (uint32_t)memory.size());
    uint32_t stack_at = 0;
    for (size_t i = 0; i < memory.size(); ++i) {
        const uint32_t at = add(memory[i].bytes.size());
        memcpy(dump.data() + at, memory[i].bytes.data(), memory[i].bytes.size());
        put64(memory_at + 4 + i * 16, memory[i].address);
        put32(memory_at + 12 + i * 16, (uint32_t)memory[i].bytes.size());
        put32(memory_at + 16 + i * 16, at);
        if (!i) stack_at = at;
    }
    stream(0, 5, 4 + (uint32_t)memory.size() * 16, memory_at);
    const uint32_t threads = add(52); put32(threads, 1); put32(threads + 4, thread);
    put64(threads + 20, c->cpu->gs_base); put64(threads + 28, context.r[RSP]);
    put32(threads + 36, (uint32_t)memory[0].bytes.size()); put32(threads + 40, stack_at);
    put32(threads + 44, sizeof(context)); put32(threads + 48, context_at); stream(1, 3, 52, threads);
    const uint32_t exception = add(168); put32(exception, thread);
    memcpy(dump.data() + exception + 8, &record, sizeof(record));
    put32(exception + 160, sizeof(context)); put32(exception + 164, context_at); stream(2, 6, 168, exception);
    const uint32_t system = add(56); rt_put<uint16_t>(dump.data() + system, 9);
    dump[system + 6] = 1; put32(system + 8, 10); put32(system + 16, 19045); put32(system + 20, 2);
    stream(3, 7, 56, system);
    const uint32_t module = add(112); put32(module, 1); put64(module + 4, rt_crash_base);
    put32(module + 12, (uint32_t)rt_crash_size);
    const std::u16string wide_name = rt_utf16(module_name);
    const uint32_t name_bytes = (uint32_t)wide_name.size() * 2;
    const uint32_t name = add(4 + name_bytes + 2); put32(name, name_bytes);
    memcpy(dump.data() + name + 4, wide_name.c_str(), name_bytes + 2); put32(module + 24, name);
    stream(4, 4, 112, module);
    return rt_write_handle(A(2), dump.data(), dump.size());
}

#define E(name) {#name, name}
const RtEntry rt_crash_entries[] = {
    E(RtlCaptureContext), E(RtlLookupFunctionEntry), E(RtlVirtualUnwind), E(SetUnhandledExceptionFilter),
    E(UnhandledExceptionFilter), E(RaiseException), E(SymSetOptions), E(SymInitialize), E(SymFunctionTableAccess64),
    E(SymGetModuleBase64), E(ImageNtHeader), E(SymGetSymFromAddr64), E(SymGetLineFromAddr64), E(StackWalk64),
    E(MiniDumpWriteDump), {nullptr, nullptr}
};
