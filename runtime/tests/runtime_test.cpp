/* Checks runtime contracts beyond startup's happy path, including file safety and boot adapters.
 * Build and run: runtime/tests/run.sh */
#include "../runtime.h"
#include "../graphics.h"
#include "d3d12_metal.h"

#include <assert.h>
#include <fcntl.h>
#include <malloc/malloc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static BbCpu cpu;

static void test_graphics_handles() {
    class Probe final : public IUnknown {
    public:
        ULONG references=1;
        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID,void **out) override { *out=nullptr;return E_NOINTERFACE; }
        ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
        ULONG STDMETHODCALLTYPE Release() override { return --references; }
    };
    Probe native;
    const uint64_t handle=rt_graphics_wrap(&native);
    assert(handle && rt_graphics_native(handle)==&native);
    assert(!rt_graphics_native(0) && !rt_graphics_native(handle+1) && !rt_graphics_native(UINT64_MAX));
    native.AddRef();assert(rt_graphics_wrap(&native)==handle);
    const auto *table=*(const uint64_t **)(uintptr_t)handle;
    assert(bbcpu_call_win64(table[2],1,&handle)==1 && rt_graphics_native(handle)==&native);
    assert(bbcpu_call_win64(table[2],1,&handle)==0 && !rt_graphics_native(handle));
    assert(native.references==0);
}

/* Calls the import `name` with Win64 integer arguments: four in registers, the rest from the
 * caller's stack area (its first four slots are the shadow space). */
static uint64_t call_args(const char *name, int count, const uint64_t *args) {
    static const int regs[4] = {RCX, RDX, R8, R9};
    static uint64_t stack[16];
    memset(stack, 0, sizeof(stack));
    for (int i = 0; i < count; ++i) {
        if (i < 4) cpu.r[regs[i]] = args[i];
        else stack[i] = args[i];
    }
    WinCall c = {&cpu, (uint64_t)(uintptr_t)stack, nullptr};
    ImportHandler h = rt_find_handler("kernel32.dll", name);
    assert(h);
    return h(&c);
}
template <class... Args> static uint64_t call(const char *name, Args... values) {
    const uint64_t args[] = {static_cast<uint64_t>(values)...};
    return call_args(name, sizeof...(values), args);
}

static uint16_t *wide(const char *s) {
    static uint16_t buffers[4][512];
    static int next;
    uint16_t *w = buffers[next++ % 4];
    size_t i = 0;
    for (; s[i]; ++i) w[i] = (uint8_t)s[i];
    w[i] = 0;
    return w;
}
#define W(s) ((uint64_t)(uintptr_t)wide(s))

static void write_text(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
}
static int has_text(const char *path, const char *text) {
    char buffer[64] = "";
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    size_t n = fread(buffer, 1, sizeof(buffer) - 1, f);
    fclose(f);
    buffer[n] = 0;
    return !strcmp(buffer, text);
}

static void test_replace_file(const char *profile) {
    char save[1024], backup[1024];
    snprintf(save, sizeof(save), "%s/save.txt", profile);
    snprintf(backup, sizeof(backup), "%s/save.bak", profile);
    write_text(save, "original");
    /* A missing replacement fails and leaves the save where it was. */
    assert(call("ReplaceFileW", W("C:\\Users\\Player\\save.txt"), W("C:\\Users\\Player\\missing.txt"), W("C:\\Users\\Player\\save.bak")) == 0);
    assert(rt_last_error() == 1176);
    assert(has_text(save, "original"));
    /* A good replacement swaps in the new file and keeps the old one as the backup. */
    char next[1024];
    snprintf(next, sizeof(next), "%s/next.txt", profile);
    write_text(next, "replacement");
    assert(call("ReplaceFileW", W("C:\\Users\\Player\\save.txt"), W("C:\\Users\\Player\\next.txt"), W("C:\\Users\\Player\\save.bak")) == 1);
    assert(has_text(save, "replacement") && has_text(backup, "original"));
}

static void test_mapping_survives_its_file(const char *profile) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/mapped.txt", profile);
    write_text(path, "mapped contents");
    const uint64_t file = call("CreateFileW", W("C:\\Users\\Player\\mapped.txt"), 0x80000000, 1, 0, 3, 0, 0);
    const uint64_t mapping = call("CreateFileMappingW", file, 0, 2, 0, 0, 0);
    assert(mapping);
    assert(call("CloseHandle", file) == 1);
    /* Another open file may now get the descriptor number the first one had. */
    char other[1024];
    snprintf(other, sizeof(other), "%s/other.txt", profile);
    write_text(other, "unrelated file");
    const uint64_t second = call("CreateFileW", W("C:\\Users\\Player\\other.txt"), 0x80000000, 1, 0, 3, 0, 0);
    const char *view = (const char *)(uintptr_t)call("MapViewOfFile", mapping, 4, 0, 0, 0);
    assert(view && !strncmp(view, "mapped contents", 15));
    call("CloseHandle", second);
    call("CloseHandle", mapping);
}

static uint64_t observed_targets[4];
static unsigned observed_counts[4];
static void observe_target(uint64_t target, int kind) {
    assert(kind >= 0 && kind < 4);
    observed_targets[kind] = target;
    ++observed_counts[kind];
}

/* Guest code calling WakeAllConditionVariable through a thunk GetProcAddress made. */
static void test_dynamic_import_call(void) {
    const uint64_t module = call("GetModuleHandleW", W("kernel32.dll"));
    const uint64_t thunk = call("GetProcAddress", module, (uint64_t)(uintptr_t)"WakeAllConditionVariable");
    assert(thunk);
    uint8_t *code = static_cast<uint8_t *>(mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0));
    const uint8_t body[] = {0x48, 0x83, 0xec, 0x28, 0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xd0, 0x48, 0x83, 0xc4, 0x28, 0xc3};
    memcpy(code, body, sizeof(body)); /* sub rsp,40; mov rax,thunk; call rax; add rsp,40; ret */
    memcpy(code + 6, &thunk, 8);
    bbcpu_add_guest_code((uintptr_t)code, 4096);
    static uint64_t condition;
    const uint64_t arg = (uint64_t)(uintptr_t)&condition;
    bbcpu_set_target_observer(observe_target);
    for (int i = 0; i < 80; ++i) bbcpu_call_win64((uintptr_t)code, 1, &arg);
    assert(observed_counts[BB_TARGET_ENTRY] == 80 && observed_targets[BB_TARGET_ENTRY] == (uintptr_t)code);
    assert(observed_counts[BB_TARGET_CALL] == 80 && observed_targets[BB_TARGET_CALL] == thunk);
    uint8_t *tail = code + 128;
    const uint8_t jump[] = {0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xe0};
    memcpy(tail, jump, sizeof(jump)); /* mov rax,thunk; jmp rax */
    memcpy(tail + 2, &thunk, 8);
    for (int i = 0; i < 80; ++i) bbcpu_call_win64((uintptr_t)tail, 1, &arg);
    assert(observed_counts[BB_TARGET_ENTRY] == 160 && observed_targets[BB_TARGET_ENTRY] == (uintptr_t)tail);
    assert(observed_counts[BB_TARGET_JUMP] == 80 && observed_targets[BB_TARGET_JUMP] == thunk);
    assert(observed_counts[BB_TARGET_CALL] == 80);
    bbcpu_set_target_observer(nullptr);
    fflush(nullptr);
    const pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        const uint64_t invalid = thunk + 1;
        memcpy(code + 6, &invalid, 8);
        bbcpu_invalidate((uintptr_t)code, sizeof(body));
        bbcpu_call_win64((uintptr_t)code, 1, &arg);
        _exit(99);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 2)
        fprintf(stderr, "invalid thunk rejection: unexpected child status %#x\n", status);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 2);
}

static void test_bounded_string_copies(void) {
    const uint16_t text[] = {'A', 0xe9, 'B', 0};
    const struct { uint64_t capacity, count, status; uint16_t expected[4]; } cases[] = {
        {4, 3, 0, {'A', 0xe9, 'B', 0}},
        {4, 8, 0, {'A', 0xe9, 'B', 0}},
        {4, 1, 0, {'A', 0}},
        {3, 3, 34, {0}},
        {3, UINT64_MAX, 80, {'A', 0xe9, 0}},
        {1, UINT64_MAX, 80, {0}},
        {4, 0, 0, {0}},
    };
    for (size_t width = 1; width <= 2; ++width) {
        const char *name = width == 1 ? "strncpy_s" : "wcsncpy_s";
        uint8_t source[8], out[10];
        for (size_t i = 0; i < 4; ++i) memcpy(source + i * width, &text[i], width);
        const uint64_t src = (uint64_t)(uintptr_t)source, dst = (uint64_t)(uintptr_t)out;
        for (size_t i = 0; i < sizeof(cases) / sizeof(*cases); ++i) {
            memset(out, 0xcc, sizeof(out));
            assert(call(name, dst, cases[i].capacity, src, cases[i].count) == cases[i].status);
            for (size_t j = 0; j < 4; ++j) {
                uint16_t value = 0;
                memcpy(&value, out + j * width, width);
                assert(value == cases[i].expected[j]);
                if (!value) break;
            }
            assert(out[cases[i].capacity * width] == 0xcc); /* no write past the declared buffer */
        }
        assert(call(name, dst, 4, 0, 1) == 22 && out[0] == 0);
        assert(call(name, dst, 4, 0, 0) == 0);
        assert(call(name, 0, 4, src, 3) == 22);
        out[0] = 0xcc;
        assert(call(name, dst, 0, src, 3) == 22 && out[0] == 0xcc);
    }
}

/* After test_kernel_objects in main: the threads-sync baseline build lacks wcsncat_s. */
static void test_wide_append(void) {
    uint16_t cat[6] = {'A', 0, 0xcc, 0xcc, 0xcc, 0xcc};
    const uint64_t to = (uint64_t)(uintptr_t)cat;
    assert(call("wcsncat_s", to, 5, W("BCD"), 2) == 0 && cat[1] == 'B' && cat[2] == 'C' && !cat[3] && cat[4] == 0xcc);
    assert(call("wcsncat_s", to, 5, W("XYZ"), UINT64_MAX) == 80 && cat[3] == 'X' && !cat[4] && cat[5] == 0xcc);
    cat[3] = 0;
    assert(call("wcsncat_s", to, 4, W("D"), 1) == 34 && !cat[0]);
    for (uint16_t &unit : cat) unit = 'A';
    assert(call("wcsncat_s", to, 4, W("D"), 1) == 22 && !cat[0]); /* unterminated destination */
}

static void test_thread_notification_and_clock(void) {
    struct { uint32_t type, padding; uint64_t name; uint32_t thread, flags; } info = {
        0x1000, 0, (uint64_t)(uintptr_t)"Probe thread", 123, 0};
    assert(call("RaiseException", 0x406d1388, UINT64_C(1) << 32, (UINT64_C(1) << 32) | 3, (uint64_t)(uintptr_t)&info) == 0);
    const struct { const char *name, *message; uint64_t first; } stops[] = {
        {"RaiseException", "unhandled RaiseException(0xe06d7363)", 0xe06d7363},
        {"RaiseException", "invalid thread-name exception", 0x406d1388},
        {"_CxxThrowException", "unhandled C++ exception: object=0x1234 throw_info=0x5678", 0x1234},
        {"__C_specific_handler", "Windows exception unwinding is unsupported", 0},
    };
    for (size_t i = 0; i < sizeof(stops) / sizeof(*stops); ++i) {
        int errors[2];
        assert(pipe(errors) == 0);
        fflush(nullptr);
        const pid_t child = fork();
        assert(child >= 0);
        if (!child) {
            close(errors[0]);
            assert(dup2(errors[1], STDERR_FILENO) >= 0);
            close(errors[1]);
            info.type = 0;
            call(stops[i].name, stops[i].first, i == 2 ? 0x5678 : 0, 3, (uint64_t)(uintptr_t)&info);
            _exit(99);
        }
        close(errors[1]);
        char message[1024] = {0};
        FILE *log = fdopen(errors[0], "r");
        assert(log && fread(message, 1, sizeof(message) - 1, log) > 0);
        fclose(log);
        int status;
        assert(waitpid(child, &status, 0) == child);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 2 && strstr(message, stops[i].message));
    }
    const int64_t before = (int64_t)time(nullptr);
    int64_t stored = -1;
    const int64_t returned = (int64_t)call("_time64", (uint64_t)(uintptr_t)&stored);
    const int64_t no_pointer = (int64_t)call("_time64", 0);
    assert(stored == returned && returned >= before && no_pointer >= returned && no_pointer <= (int64_t)time(nullptr));
}

static void test_kernel_objects(void) {
    enum : uint64_t { TIMEOUT = 258 };
    const uint64_t once = call("CreateEventW", 0, 0, 1, 0); /* auto-reset, initially set */
    assert(call("WaitForSingleObject", once, 0) == 0 && call("WaitForSingleObject", once, 0) == TIMEOUT);
    const uint64_t gate = call("CreateEventW", 0, 1, 0, 0); /* manual reset */
    assert(call("WaitForSingleObject", gate, 0) == TIMEOUT && call("SetEvent", gate) == 1);
    assert(call("WaitForSingleObject", gate, 0) == 0 && call("WaitForSingleObject", gate, 0) == 0);
    assert(call("ResetEvent", gate) == 1 && call("WaitForSingleObject", gate, 0) == TIMEOUT);

    assert(!call("CreateSemaphoreW", 0, 0, 0, 0) && rt_last_error() == 87);
    assert(!call("CreateSemaphoreW", 0, -1, 2, 0) && rt_last_error() == 87);
    assert(!call("CreateSemaphoreW", 0, 3, 2, 0) && rt_last_error() == 87);
    const uint64_t semaphore = call("CreateSemaphoreW", 0, 0, 2, 0);
    int32_t previous = -1;
    assert(call("ReleaseSemaphore", semaphore, 2, (uint64_t)(uintptr_t)&previous) == 1 && previous == 0);
    previous = 99;
    assert(!call("ReleaseSemaphore", semaphore, 0, (uint64_t)(uintptr_t)&previous) && rt_last_error() == 87 && previous == 99);
    assert(!call("ReleaseSemaphore", semaphore, -1, 0) && rt_last_error() == 87);
    assert(!call("ReleaseSemaphore", semaphore, INT32_MAX, (uint64_t)(uintptr_t)&previous) && rt_last_error() == 298 && previous == 99);
    assert(call("ReleaseSemaphore", semaphore, 1, 0) == 0 && call("GetLastError") == 298);
    const uint64_t pair[2] = {gate, semaphore};
    assert(call("WaitForMultipleObjectsEx", 2, (uint64_t)(uintptr_t)pair, UINT64_C(1) << 32, 0, 0) == 1);
    assert(call("WaitForMultipleObjectsEx", 2, (uint64_t)(uintptr_t)pair, 1, 0, 0) == TIMEOUT);

    uint32_t code;
    assert(call("SetEvent", semaphore) == 0 && rt_last_error() == 6);
    assert(!call("ResetEvent", 0) && rt_last_error() == 6);
    assert(call("WaitForMultipleObjectsEx", 0, (uint64_t)(uintptr_t)pair, 0, 0, 0) == 0xffffffff && rt_last_error() == 87);
    const uint64_t duplicate[2] = {semaphore, semaphore};
    assert(call("WaitForMultipleObjectsEx", 2, (uint64_t)(uintptr_t)duplicate, 1, 0, 0) == 0xffffffff && rt_last_error() == 87);
    assert(call("WaitForSingleObject", semaphore, 0) == 0); // Failed wait-all did not consume its remaining token.
    assert(call("WaitForSingleObject", semaphore, 0) == TIMEOUT);
    const uint64_t acquire_both[] = {once, semaphore};
    assert(call("SetEvent", once) && call("ReleaseSemaphore", semaphore, 1, 0));
    assert(call("WaitForMultipleObjectsEx", 2, (uint64_t)(uintptr_t)acquire_both, 1, 0, 0) == 0);
    assert(call("WaitForMultipleObjectsEx", 2, (uint64_t)(uintptr_t)acquire_both, 0, 0, 0) == TIMEOUT);
    assert(call("SetEvent", once) && call("ReleaseSemaphore", semaphore, 1, 0));
    assert(call("WaitForMultipleObjectsEx", 2, (uint64_t)(uintptr_t)acquire_both, 0, 0, 0) == 0);
    assert(call("WaitForMultipleObjectsEx", 2, (uint64_t)(uintptr_t)acquire_both, 0, 0, 0) == 1);
    assert(call("GetExitCodeThread", gate, (uint64_t)(uintptr_t)&code) == 0 && call("GetLastError") == 6);
    assert(call("CloseHandle", once) == 1 && call("CloseHandle", once) == 0 && call("GetLastError") == 6);
    assert(call("WaitForSingleObject", once, 0) == 0xffffffff);
    call("CloseHandle", gate);
    call("CloseHandle", semaphore);

    const uint64_t bool_event = call("CreateEventW", 0, UINT64_C(1) << 32, (UINT64_C(1) << 32) | 1, 0);
    assert(bool_event && call("WaitForSingleObject", bool_event, 0) == 0);
    assert(call("WaitForSingleObject", bool_event, 0) == TIMEOUT && call("CloseHandle", bool_event));

    const uint64_t named = call("CreateEventW", 0, 1, 1, W("R2.06 named event"));
    const uint64_t alias = call("CreateEventW", 0, 0, 0, W("R2.06 named event"));
    assert(named && alias && named != alias && rt_last_error() == 183);
    assert(!call("CreateSemaphoreW", 0, 0, 1, W("R2.06 named event")) && rt_last_error() == 6);
    assert(call("WaitForSingleObject", named, 0) == 0 && call("WaitForSingleObject", alias, 0) == 0);
    assert(call("CloseHandle", named) && call("ResetEvent", alias));
    assert(call("WaitForSingleObject", alias, 0) == TIMEOUT && call("CloseHandle", alias));
    const uint64_t fresh = call("CreateEventW", 0, 0, 0, W("R2.06 named event"));
    assert(fresh && rt_last_error() == 0 && call("WaitForSingleObject", fresh, 0) == TIMEOUT);
    assert(call("CloseHandle", fresh));
}

static void allocation_cycle(unsigned i) {
    const uint64_t heap = call("GetProcessHeap");
    const size_t size = 1 + (i % 1024);
    uint64_t p = call("HeapAlloc", heap, 8, size);
    assert(p && !(p & 15));
    memset((void *)(uintptr_t)p, 0x45, size);
    p = call("HeapReAlloc", heap, 8, p, size + 257);
    assert(p && *(uint8_t *)(uintptr_t)p == 0x45);
    assert(call("HeapFree", heap, 0, p));
    p = call("calloc", 3, size);
    assert(p);
    p = call("realloc", p, size * 4);
    assert(p);
    call("free", p);
    p = call("GlobalAlloc", 2 | 0x40, size);
    assert(p && call("GlobalLock", p));
    call("GlobalUnlock", p);
    assert(!call("GlobalFree", p));
    if (i % 16 == 0) {
        p = call("VirtualAlloc", 0, 65536, 0x3000, 4);
        assert(p);
        memset((void *)(uintptr_t)p, 0x45, 65536);
        assert(call("VirtualFree", p, 0, 0x4000));
        assert(call("VirtualAlloc", p, 65536, 0x1000, 4) == p);
        assert(!*(uint8_t *)(uintptr_t)p);
        assert(call("VirtualFree", p, 0, 0x8000));
    }
}
static void test_allocation_lifecycle(void) {
    // Warm up allocator and bookkeeping capacities before checking live allocations, not RSS caches.
    for (unsigned i = 0; i < 4096; ++i) allocation_cycle(i);
    malloc_statistics_t before, after;
    malloc_zone_statistics(nullptr, &before);
    for (unsigned i = 0; i < 100000; ++i) allocation_cycle(i);
    malloc_zone_statistics(nullptr, &after);
    printf("allocation soak: 100000 cycles, before=%u/%zu after=%u/%zu blocks/bytes\n",
           before.blocks_in_use, before.size_in_use, after.blocks_in_use, after.size_in_use);
    assert(after.blocks_in_use <= before.blocks_in_use && after.size_in_use <= before.size_in_use);
}
static void access_fault(int signal) { _exit(signal); }
static void test_reservation_protection(void) {
    const uint64_t p = call("VirtualAlloc", 0, 65536, 0x2000, 4);
    assert(p);
    for (int state = 0; state < 3; ++state) {
        fflush(nullptr);
        const pid_t child = fork();
        assert(child >= 0);
        if (!child) {
            signal(SIGSEGV, access_fault);
            signal(SIGBUS, access_fault);
            *(volatile uint8_t *)(uintptr_t)p = 42;
            _exit(0);
        }
        int status;
        assert(waitpid(child, &status, 0) == child && WIFEXITED(status));
        if (state == 1) assert(WEXITSTATUS(status) == 0);
        else assert(WEXITSTATUS(status) == SIGSEGV || WEXITSTATUS(status) == SIGBUS);
        if (state == 0) assert(call("VirtualAlloc", p, 65536, 0x1000, 4) == p);
        if (state == 1) assert(call("VirtualFree", p, 0, 0x4000));
    }
    assert(call("VirtualFree", p, 0, 0x8000));
}

int main(void) {
    setenv("BB_JIT", "0", 1);
    char profile[] = "/tmp/runtime-test-player's profile-XXXXXX";
    assert(mkdtemp(profile));
    setenv("SS_PROFILE_DIR", profile, 1);
    rt_files_init("/tmp/no-game/sinking_star.exe"); /* a profile path with an apostrophe */
    char game_writes[1100];
    snprintf(game_writes, sizeof(game_writes), "%s/Game", profile);
    struct stat st;
    assert(stat(game_writes, &st) == 0 && S_ISDIR(st.st_mode));
    rt_bind_thunks();
    test_graphics_handles();
    test_replace_file(profile);
    test_mapping_survives_its_file(profile);
    test_dynamic_import_call();
    test_bounded_string_copies();
    test_thread_notification_and_clock();
    test_kernel_objects();
    test_reservation_protection();
    test_allocation_lifecycle();
    test_wide_append();
    puts("runtime tests passed");
    return 0;
}
