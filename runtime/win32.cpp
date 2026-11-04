/* Host implementations of the game's Windows imports. Handlers read
 * Win64 arguments with A(i) and return rax. */
#include "runtime.h"

#include <algorithm>
#include <atomic>
#include <filesystem>
#include <unordered_map>
#include <mutex>
#include <iterator>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <vector>

static thread_local uint32_t last_error;
void rt_set_last_error(uint32_t code) { last_error = code; }
uint32_t rt_last_error(void) { return last_error; }

std::string rt_utf8(std::u16string_view in) {
    std::string out;
    for (size_t i = 0; i < in.size(); ++i) {
        uint32_t ch = in[i];
        if (ch >= 0xd800 && ch < 0xdc00 && i + 1 < in.size() && in[i + 1] >= 0xdc00 && in[i + 1] < 0xe000)
            ch = 0x10000 + ((ch - 0xd800) << 10) + (in[++i] - 0xdc00u);
        if (ch < 0x80) out += (char)ch;
        else if (ch < 0x800) out += {(char)(0xc0 | ch >> 6), (char)(0x80 | (ch & 63))};
        else if (ch < 0x10000) out += {(char)(0xe0 | ch >> 12), (char)(0x80 | (ch >> 6 & 63)), (char)(0x80 | (ch & 63))};
        else out += {(char)(0xf0 | ch >> 18), (char)(0x80 | (ch >> 12 & 63)), (char)(0x80 | (ch >> 6 & 63)), (char)(0x80 | (ch & 63))};
    }
    return out;
}

/* Lenient, as the game's text is trusted: a truncated sequence reads missing bytes as zero. */
std::u16string rt_utf16(std::string_view in) {
    std::u16string out;
    for (size_t i = 0; i < in.size();) {
        uint32_t ch = (uint8_t)in[i++];
        int extra = 0;
        if (ch >= 0xf0) { ch &= 7; extra = 3; }
        else if (ch >= 0xe0) { ch &= 15; extra = 2; }
        else if (ch >= 0xc0) { ch &= 31; extra = 1; }
        for (; extra; --extra) ch = ch << 6 | (i < in.size() ? (uint8_t)in[i++] & 63u : 0);
        if (ch >= 0x10000) out += {(char16_t)(0xd800 + ((ch - 0x10000) >> 10)), (char16_t)(0xdc00 + ((ch - 0x10000) & 0x3ff))};
        else out += (char16_t)ch;
    }
    return out;
}

uint32_t rt_put_wide(std::string_view text, uint16_t *out, uint32_t capacity) {
    const std::u16string wide = rt_utf16(text);
    const uint32_t n = (uint32_t)wide.size();
    if (n + 1 > capacity) return n + 1;
    memcpy(out, wide.data(), n * 2);
    out[n] = 0;
    return n;
}

/* ---- time ---- */

/* The game's two clocks, both in 100 ns units like Windows: wall time since 1601-01-01 and the
 * performance counter (10 MHz, as Windows 10 reports). Every time import reads one of these. */
enum : uint64_t { EPOCH_1601 = UINT64_C(11644473600), TICKS_PER_SECOND = 10000000 };
static uint64_t filetime_now(void) {
    return clock_gettime_nsec_np(CLOCK_REALTIME) / 100 + EPOCH_1601 * TICKS_PER_SECOND;
}
static uint64_t performance_counter(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 100; }
H(GetSystemTimeAsFileTime) { rt_put(P(0), filetime_now()); return 0; }
H(GetSystemTimePreciseAsFileTime) { rt_put(P(0), filetime_now()); return 0; }
H(_time64) {
    const int64_t seconds = (int64_t)(filetime_now() / TICKS_PER_SECOND - EPOCH_1601);
    if (P(0)) rt_put(P(0), seconds);
    return (uint64_t)seconds;
}
H(QueryPerformanceFrequency) { rt_put<int64_t>(P(0), TICKS_PER_SECOND); return 1; }
H(QueryPerformanceCounter) { rt_put(P(0), performance_counter()); return 1; }

/* SYSTEMTIME from FILETIME (UTC). */
H(FileTimeToSystemTime) {
    uint64_t ft;
    memcpy(&ft, P(0), 8);
    if (ft >> 63) { rt_set_last_error(87); return 0; } /* ERROR_INVALID_PARAMETER */
    const time_t t = (time_t)(ft / TICKS_PER_SECOND) - (time_t)EPOCH_1601;
    struct tm tm;
    gmtime_r(&t, &tm);
    const uint16_t st[8] = {(uint16_t)(tm.tm_year + 1900), (uint16_t)(tm.tm_mon + 1), (uint16_t)tm.tm_wday,
                            (uint16_t)tm.tm_mday, (uint16_t)tm.tm_hour, (uint16_t)tm.tm_min, (uint16_t)tm.tm_sec,
                            (uint16_t)(ft / 10000 % 1000)};
    memcpy(P(1), st, 16);
    return 1;
}
/* Like Windows, applies the current offset from UTC, not the one in effect at the given time. */
H(FileTimeToLocalFileTime) {
    uint64_t ft;
    memcpy(&ft, P(0), 8);
    const time_t now = (time_t)(filetime_now() / TICKS_PER_SECOND - EPOCH_1601);
    struct tm tm;
    localtime_r(&now, &tm);
    ft += (uint64_t)((int64_t)tm.tm_gmtoff * (int64_t)TICKS_PER_SECOND);
    rt_put(P(1), ft);
    return 1;
}

/* ---- process and thread identity ---- */

H(GetCurrentProcessId) { return (uint32_t)getpid(); }
H(GetCurrentThreadId) { uint64_t tid; pthread_threadid_np(nullptr, &tid); return (uint32_t)tid; }
H(GetCurrentProcess) { return UINT64_MAX; }
H(GetCurrentThread) { return UINT64_MAX - 1; }
H(IsDebuggerPresent) { return 0; }
H(GetLastError) { return last_error; }

/* The game starts one program: Visual Studio's JIT debugger, from its crash handler. A Mac has none,
 * so the launch fails and the handler goes on without a debugger. */
H(CreateProcessW) {
    printf("runtime: CreateProcessW(%s) refused, no Windows programs\n", rt_utf8((const char16_t *)P(1)).c_str());
    rt_set_last_error(50); /* ERROR_NOT_SUPPORTED */
    return 0;
}
enum { STILL_ACTIVE = 259 };
H(GetExitCodeProcess) {
    if (A(0) != UINT64_MAX) { rt_set_last_error(6); return 0; } /* ERROR_INVALID_HANDLE: no child processes */
    rt_put<uint32_t>(P(1), STILL_ACTIVE);
    return 1;
}
/* Every call passes the current-process handle (directly or as a stored -1): fatal errors and fast fail. */
H(TerminateProcess) {
    if (A(0) != UINT64_MAX) { rt_set_last_error(6); return 0; }
    printf("game: TerminateProcess(%#x)\n", (uint32_t)A(1));
    fflush(nullptr);
    rt_math_report();
    _exit((int)A(1));
}

/* ---- C runtime startup ---- */

static uint64_t call_guest(uint64_t fn, int count, const uint64_t *args) {
    return bbcpu_call_win64((uintptr_t)fn, count, args);
}
H(_initterm) {
    uint64_t *const end = P(1);
    for (uint64_t *f = P(0); f < end; ++f)
        if (*f) call_guest(*f, 0, nullptr);
    return 0;
}
H(_initterm_e) {
    uint64_t *const end = P(1);
    for (uint64_t *f = P(0); f < end; ++f)
        if (*f) {
            const uint32_t r = (uint32_t)call_guest(*f, 0, nullptr);
            if (r) return r;
        }
    return 0;
}
static int guest_argc = 1;
static std::string program_path = "C:\\Game\\sinking_star.exe";
static std::vector<std::string> guest_arguments, guest_environment;
static std::vector<char *> guest_argv, guest_environ;
static char **guest_argv_pointer;
static std::string command_line;
static std::u16string wide_command_line;

void rt_process_init(const char *exe, int argc, char **argv) {
    program_path = "C:\\Game\\" + std::filesystem::path(exe).filename().string();
    guest_arguments = {program_path};
    for (int i = 0; i < argc; ++i) guest_arguments.emplace_back(argv[i]);
    guest_argc = (int)guest_arguments.size();
    guest_argv.clear();
    command_line.clear();
    for (std::string &arg : guest_arguments) {
        guest_argv.push_back(arg.data());
        if (!command_line.empty()) command_line += ' ';
        command_line += '"';
        size_t slashes = 0;
        for (char ch : arg) {
            if (ch == '\\') { ++slashes; continue; }
            if (ch == '"') command_line.append(slashes * 2 + 1, '\\');
            else command_line.append(slashes, '\\');
            slashes = 0;
            command_line += ch;
        }
        command_line.append(slashes * 2, '\\');
        command_line += '"';
    }
    guest_argv.push_back(nullptr);
    guest_argv_pointer = guest_argv.data();
    wide_command_line = rt_utf16(command_line);
    guest_environment = {"USERPROFILE=C:\\Users\\Player", "APPDATA=C:\\Users\\Player\\AppData\\Roaming",
        "LOCALAPPDATA=C:\\Users\\Player\\AppData\\Local", "SystemRoot=C:\\Windows"};
    guest_environ.clear();
    for (std::string &entry : guest_environment) guest_environ.push_back(entry.data());
    guest_environ.push_back(nullptr);
    printf("runtime: process argc=%d argv0=%s environment=isolated(%zu) console=none\n",
           guest_argc, program_path.c_str(), guest_environment.size());
}
H(GetCommandLineA) { return (uintptr_t)command_line.c_str(); }
H(GetCommandLineW) { return (uintptr_t)wide_command_line.c_str(); }
H(__p___argc) { return (uint64_t)(uintptr_t)&guest_argc; }
H(__p___argv) { return (uint64_t)(uintptr_t)&guest_argv_pointer; }
H(_get_initial_narrow_environment) { return (uint64_t)(uintptr_t)guest_environ.data(); }
static int commode;
H(__p__commode) { return (uint64_t)(uintptr_t)&commode; }
H(returns_zero) { return 0; }
H(_configure_narrow_argv) {
    if (A(0) > 1) rt_fatal("CRT wildcard-expanded argv is unsupported");
    return 0;
}
static thread_local int thread_locale = 2; // _DISABLE_PER_THREAD_LOCALE; the game retains the C locale.
H(_configthreadlocale) {
    const int previous = thread_locale;
    if (A(0) == 1 || A(0) == 2) thread_locale = (int)A(0);
    else if (A(0)) return UINT32_MAX;
    return previous;
}
H(_wassert) {
    rt_fatal("assertion failed: %s, file %s, line %u", rt_utf8(P(0)).c_str(), rt_utf8(P(1)).c_str(), (uint32_t)A(2));
}
H(_purecall) { rt_fatal("game called _purecall()"); }
static std::atomic<uint64_t> tls_exit_callback;
H(_register_thread_local_exe_atexit_callback) {
    uint64_t empty = 0;
    if (!tls_exit_callback.compare_exchange_strong(empty, A(0))) rt_fatal("CRT TLS exit callback registered twice");
    return 0;
}
static void run_tls_exit() {
    const uint64_t callback = tls_exit_callback.load();
    if (callback) {
        const uint64_t args[] = {0, 0, 0}; // DLL_PROCESS_DETACH; the EXE callback destroys main-thread TLS.
        call_guest(callback, 3, args);
    }
}
static std::recursive_mutex exit_lock;
static std::unordered_map<uint64_t, std::vector<uint64_t>> onexit;
H(_initialize_onexit_table) {
    if (!P(0)) return UINT32_MAX;
    std::lock_guard guard(exit_lock);
    if (onexit.try_emplace(A(0)).second) memset(P(0), 0, 24);
    return 0;
}
static uint64_t add_onexit(uint64_t table, uint64_t fn) {
    std::lock_guard guard(exit_lock);
    onexit[table].push_back(fn);
    return 0;
}
H(_register_onexit_function) { return P(0) ? add_onexit(A(0), A(1)) : UINT32_MAX; }
H(_crt_atexit) { return add_onexit(0, A(0)); }
H(_crt_at_quick_exit) { return add_onexit(UINT64_MAX, A(0)); }
static void run_onexit(uint64_t table) {
    std::lock_guard guard(exit_lock);
    for (;;) {
        uint64_t fn;
        {
            auto found = onexit.find(table);
            if (found == onexit.end()) return;
            if (found->second.empty()) { onexit.erase(found); return; }
            fn = found->second.back();
            found->second.pop_back();
        }
        if (fn) call_guest(fn, 0, nullptr);
    }
}
H(_execute_onexit_table) { if (!P(0)) return UINT32_MAX; run_onexit(A(0)); return 0; }
H(_cexit) { run_tls_exit(); run_onexit(0); fflush(nullptr); return 0; }
H(exit_) {
    const int code = (int)A(0); // Callbacks can change guest argument registers.
    run_tls_exit();
    run_onexit(0);
    printf("game: exit(%d)\n", code);
    fflush(nullptr);
    rt_math_report();
    rt_graphics_before_exit();
    _exit(code);
}
H(_exit_) { printf("game: _exit(%d)\n", (int)A(0)); fflush(stdout); rt_math_report(); rt_graphics_before_exit(); _exit((int)A(0)); }
H(quick_exit_) { const int code = (int)A(0); run_onexit(UINT64_MAX); fflush(stdout); rt_math_report(); rt_graphics_before_exit(); _exit(code); }
H(ExitProcess) { printf("game: ExitProcess(%d)\n", (int)A(0)); fflush(stdout); rt_math_report(); rt_graphics_before_exit(); _exit((int)A(0)); }
H(terminate) { rt_fatal("game called terminate()"); }

/* Microsoft x64 _JUMP_BUFFER: guest machine state, never a host setjmp/C stack. */
struct JumpBuffer {
    uint64_t frame, rbx, rsp, rbp, rsi, rdi, r12, r13, r14, r15, rip;
    uint32_t mxcsr;
    uint16_t fcw, depth;
    uint8_t xmm[10][16];
};
static_assert(sizeof(JumpBuffer) == 256 && offsetof(JumpBuffer, xmm) == 96, "Win64 jump buffer");
H(__intrinsic_setjmp) {
    BbCpu *cpu = c->cpu;
    if ((A(0) & 15) || cpu->depth > UINT16_MAX) rt_fatal("invalid Win64 jump buffer");
    JumpBuffer buffer = {
        .frame = A(1), .rbx = cpu->r[RBX], .rsp = c->stack_args, .rbp = cpu->r[RBP],
        .rsi = cpu->r[RSI], .rdi = cpu->r[RDI], .r12 = cpu->r[R12], .r13 = cpu->r[R13],
        .r14 = cpu->r[R14], .r15 = cpu->r[R15], .rip = bb_load(cpu->r[RSP], 8),
        .mxcsr = cpu->mxcsr, .fcw = cpu->fcw, .depth = (uint16_t)cpu->depth,
    };
    for (int i = 0; i < 10; ++i) memcpy(buffer.xmm[i], cpu->v[i + 6].b, 16);
    memcpy(P(0), &buffer, sizeof(buffer));
    return 0;
}
H(longjmp_) {
    JumpBuffer buffer;
    const uint32_t value = (uint32_t)A(1);
    if (A(0) & 15) rt_fatal("invalid Win64 jump buffer");
    memcpy(&buffer, P(0), sizeof(buffer));
    BbCpu *cpu = c->cpu;
    /* Spare holds our call depth so a jump cannot silently bypass a host callback frame. */
    if (buffer.depth != cpu->depth) rt_fatal("longjmp across host callbacks is unsupported");
    cpu->r[RBX] = buffer.rbx; cpu->r[RBP] = buffer.rbp;
    cpu->r[RSI] = buffer.rsi; cpu->r[RDI] = buffer.rdi;
    cpu->r[R12] = buffer.r12; cpu->r[R13] = buffer.r13;
    cpu->r[R14] = buffer.r14; cpu->r[R15] = buffer.r15;
    cpu->mxcsr = buffer.mxcsr; cpu->fcw = buffer.fcw;
    for (int i = 0; i < 10; ++i) memcpy(cpu->v[i + 6].b, buffer.xmm[i], 16);
    cpu->r[RSP] = buffer.rsp - 8;
    bb_store(cpu->r[RSP], 8, buffer.rip); /* the import's normal return resumes the saved PC */
    return value ? value : 1;
}

H(_CxxThrowException) {
    rt_fatal("unhandled C++ exception: object=%#llx throw_info=%#llx guest_return=%#llx; unwinding is unsupported",
             (unsigned long long)A(0), (unsigned long long)A(1),
             (unsigned long long)bbcpu_import_return());
}
H(unsupported_unwind) { rt_fatal("Windows exception unwinding is unsupported"); }
/* ---- system ---- */

/* The features the R0.08 cpuid profile advertises: cmpxchg8b, MMX, SSE to SSE4.2, AVX, AVX2, rdtsc(p),
 * PAE/NX, cmpxchg16b, XSAVE, RDRAND and fast fail. The game only asks for fast fail (23). */
H(IsProcessorFeaturePresent) {
    switch ((uint32_t)A(0)) {
    case 2: case 3: case 6: case 8: case 9: case 10: case 12: case 13: case 14: case 17: case 23: case 28: case 32:
    case 36: case 37: case 38: case 39: case 40: return 1;
    default: return 0;
    }
}

/* ---- modules: the game image, and built-in stand-ins for the system DLLs the game loads ---- */

/* Every module the game asks for by name, and the functions it looks up in it. */
struct Module { const char *name; std::vector<const char *> exports; };
static const Module modules[] = {
    {"kernel32.dll", {"SleepConditionVariableCS", "WakeAllConditionVariable"}},
    /* The address waits are for R2.06's tests; the game does not use them. */
    {"api-ms-win-core-synch-l1-2-0.dll", {"SleepConditionVariableCS", "WakeAllConditionVariable", "WaitOnAddress",
                                          "WakeByAddressSingle", "WakeByAddressAll"}},
    {"xinput1_4.dll", {"XInputGetState"}},
    {"d3d12.dll", {"D3D12CreateDevice"}},
};
/* Modules the game can do without, missing as on a Windows PC without them. */
static const char *const absent_modules[][2] = {
    {"xinput1_3.dll", "older XInput, tried only without xinput1_4.dll"},
    {"xinput1_9_0.dll", "older XInput, tried only without xinput1_4.dll"},
    {"WinPixEventRuntime.dll", "PIX GPU capture markers, a developer tool"},
    {"nvml.dll", "NVIDIA driver queries, loaded only on NVIDIA adapters"},
};
enum { MODULE_BASE = 0x7ff700000000ull, MODULE_STRIDE = 0x10000 };
static const Module *module_of(uint64_t handle) {
    const uint64_t index = (handle - MODULE_BASE) / MODULE_STRIDE;
    if (handle < MODULE_BASE || (handle - MODULE_BASE) % MODULE_STRIDE || index >= std::size(modules)) return nullptr;
    return &modules[index];
}
static uint64_t module_result(std::string name) {
    std::replace(name.begin(), name.end(), '/', '\\');
    const char *base = name.c_str() + (name.find_last_of('\\') + 1); /* npos + 1 is 0 */
    for (size_t i = 0; i < std::size(modules); ++i)
        if (!strcasecmp(base, modules[i].name)) {
            printf("runtime: module %s built in\n", name.c_str());
            return MODULE_BASE + MODULE_STRIDE * i;
        }
    const char *reason = "unlisted";
    for (const auto &absent : absent_modules)
        if (!strcasecmp(base, absent[0])) reason = absent[1];
    /* Wwise looks for plugin DLLs beside the game; the game ships none. */
    if (!strncmp(base, "Ak", 2) && strlen(base) > 6 && !strcasecmp(base + strlen(base) - 4, ".dll"))
        reason = "Wwise plugin, not shipped with the game";
    printf("runtime: module %s missing (%s)\n", name.c_str(), reason);
    last_error = 126; /* ERROR_MOD_NOT_FOUND */
    return 0;
}
H(GetModuleHandleW) {
    if (!P(0)) return bb_image_base;
    std::string name = rt_utf8(P(0));
    std::replace(name.begin(), name.end(), '/', '\\');
    const std::string base = name.substr(name.find_last_of('\\') + 1);
    const std::string program = program_path.substr(program_path.find_last_of('\\') + 1);
    if (!strcasecmp(name.c_str(), program_path.c_str()) ||
        (name == base && !strcasecmp(base.c_str(), program.c_str()))) return bb_image_base;
    return module_result(name);
}
H(GetModuleFileNameW) {
    std::string path = program_path;
    if (A(0) && A(0) != bb_image_base) {
        const Module *module = module_of(A(0));
        if (!module) { rt_set_last_error(126); return 0; }
        path = std::string("C:\\Windows\\system32\\") + module->name;
    }
    const uint32_t capacity = A(2);
    if (!capacity) { rt_set_last_error(122); return 0; }
    const std::u16string wide = rt_utf16(path);
    const size_t count = std::min<size_t>(wide.size(), capacity - 1);
    memcpy(P(1), wide.data(), count * 2);
    static_cast<uint16_t *>(P(1))[count] = 0;
    if (wide.size() >= capacity) { rt_set_last_error(122); return capacity; }
    return wide.size();
}
H(LoadLibraryW) { return module_result(rt_utf8(P(0))); }
H(LoadLibraryA) { return module_result((const char *)P(0)); }
/* Built-in modules stay loaded, as system DLLs do. */
H(FreeLibrary) {
    if (module_of(A(0))) return 1;
    rt_set_last_error(126);
    return 0;
}
H(GetProcAddress) {
    const Module *module = module_of(A(0));
    if (!module) { last_error = 126; return 0; }
    const char *name = A(1) >> 16 ? (const char *)P(1) : nullptr; /* a low word alone is an ordinal */
    if (!name && A(1) == 101 && !strcmp(module->name, "d3d12.dll")) name = "D3D12CreateDevice";
    const bool exported = name && std::any_of(module->exports.begin(), module->exports.end(),
                                              [name](const char *e) { return !strcmp(e, name); });
    const uint64_t thunk = exported ? rt_dynamic_import(module->name, name) : 0;
    if (!thunk) {
        printf("runtime: %s!%s not provided\n", module->name, name ? name : "(ordinal)");
        last_error = 127; /* ERROR_PROC_NOT_FOUND */
    }
    return thunk;
}

H(GetStartupInfoW) { memset(P(0), 0, 104); rt_put<uint32_t>(P(0), 104); return 0; }

static int guest_compare(void *context, const void *left, const void *right) {
    const uint64_t args[] = {(uint64_t)(uintptr_t)left, (uint64_t)(uintptr_t)right};
    return (int32_t)bbcpu_call_win64((uintptr_t)context, 2, args);
}
H(qsort_) { qsort_r(P(0), A(1), A(2), P(3), guest_compare); return 0; }

/* ---- C string and memory functions (host libc, Win64 arguments) ---- */

H(memcpy_) { return (uint64_t)(uintptr_t)memcpy(P(0), P(1), A(2)); }
H(memmove_) { return (uint64_t)(uintptr_t)memmove(P(0), P(1), A(2)); }
H(memset_) { return (uint64_t)(uintptr_t)memset(P(0), (int)A(1), A(2)); }
H(memcmp_) { return (uint64_t)(int64_t)memcmp(P(0), P(1), A(2)); }
H(memchr_) { return (uint64_t)(uintptr_t)memchr(static_cast<const void *>(P(0)), (int)A(1), A(2)); }
H(strlen_) { return strlen(P(0)); }
H(strcmp_) { return (uint64_t)(int64_t)strcmp(P(0), P(1)); }
H(strncmp_) { return (uint64_t)(int64_t)strncmp(P(0), P(1), A(2)); }
H(strrchr_) { return (uint64_t)(uintptr_t)strrchr(static_cast<const char *>(P(0)), (int)A(1)); }
H(strstr_) { return (uint64_t)(uintptr_t)strstr(static_cast<const char *>(P(0)), static_cast<const char *>(P(1))); }
H(strncpy_) { return (uint64_t)(uintptr_t)strncpy(P(0), P(1), A(2)); }
H(wcslen_) { return std::char_traits<char16_t>::length(static_cast<const char16_t *>(P(0))); }
H(wcsncpy_) {
    char16_t *out = P(0);
    const char16_t *source = P(1);
    uint64_t i = 0;
    for (; i < A(2) && source[i]; ++i) out[i] = source[i];
    for (; i < A(2); ++i) out[i] = 0;
    return A(0);
}
H(wcsstr_) {
    const char16_t *text = P(0), *needle = P(1);
    const size_t at = std::u16string_view(text).find(needle);
    return at == std::u16string_view::npos ? 0 : (uintptr_t)(text + at);
}
/* strncpy_s/wcsncpy_s, or wcsncat_s with `append`: copies at most `count` source units, leaving the
 * destination empty on failure. */
static uint64_t copy_string_s(WinCall *c, size_t width, bool append = false) {
    uint8_t *out = P(0);
    const uint8_t *source = P(2);
    const uint64_t capacity = A(1), count = A(3);
    const auto unit = [width](const uint8_t *at) {
        uint16_t value = 0;
        memcpy(&value, at, width);
        return value;
    };
    if (!out || !capacity) return 22; /* EINVAL */
    if (!source && count) { memset(out, 0, width); return 22; }
    uint64_t i = 0;
    if (append) {
        while (i < capacity && unit(out + i * width)) ++i;
        if (i == capacity) { memset(out, 0, width); return 22; } /* unterminated destination */
    }
    for (uint64_t n = 0; n < count; ++n, ++i) {
        const uint16_t value = unit(source + n * width);
        if (!value) break;
        if (i + 1 == capacity) {
            if (count == UINT64_MAX) { memset(out + i * width, 0, width); return 80; } /* STRUNCATE */
            memset(out, 0, width);
            return 34; /* ERANGE */
        }
        memcpy(out + i * width, &value, width);
    }
    memset(out + i * width, 0, width);
    return 0;
}
H(strncpy_s) { return copy_string_s(c, 1); }
H(wcsncpy_s) { return copy_string_s(c, 2); }
H(wcsncat_s) { return copy_string_s(c, 2, true); }
H(strtol_) {
    // Windows long is 32-bit: clamp before narrowing, including inputs larger than a host long.
    const int64_t value = strtoll(P(0), P(1), (int)A(2));
    return (uint64_t)std::clamp<int64_t>(value, INT32_MIN, INT32_MAX);
}
H(getenv_) {
    if (!P(0)) return 0;
    const char *name = P(0);
    const size_t n = strlen(name);
    for (std::string &entry : guest_environment)
        if (entry.size() > n && entry[n] == '=' && !strncasecmp(entry.c_str(), name, n)) return (uintptr_t)(entry.data() + n + 1);
    return 0;
}

/* ---- debugging, console, strings ---- */

H(OutputDebugStringA) {
    const char *text = P(0);
    const size_t n = strlen(text);
    printf("game debug: %s%s", text, n && text[n - 1] == '\n' ? "" : "\n");
    return 0;
}
H(GetConsoleMode) { rt_set_last_error(6); return 0; } /* no console attached: a GUI app */
H(SetConsoleMode) { rt_set_last_error(6); return 0; }
H(SetConsoleOutputCP) { rt_set_last_error(6); return 0; }
enum { STD_INPUT = 0xfffffff6, STD_OUTPUT = 0xfffffff5, STD_ERROR = 0xfffffff4 };
H(GetStdHandle) {
    const uint32_t id = A(0);
    if (id == STD_INPUT || id == STD_OUTPUT || id == STD_ERROR) return 0; // GUI process, no attached console.
    rt_set_last_error(87);
    return UINT64_MAX;
}

/* ---- process settings and system identity (Windows 10 22H2, en-US) ---- */

H(SetProcessInformation) { return 1; }
static std::atomic<uint32_t> error_mode;
H(SetErrorMode) { return error_mode.exchange((uint32_t)A(0)); }
/* Host sleeps are already precise to well under 1 ms, so only the range is checked. */
H(timeBeginPeriod) { return (uint32_t)A(0) - 1 < 1000000 ? 0 : 97; } /* TIMERR_NOCANDO */
H(GetUserDefaultLCID) { return 0x409; }
/* OSVERSIONINFOW / OSVERSIONINFOEXW: 10.0.19045, a workstation. */
H(GetVersionExW) {
    uint8_t *v = P(0);
    uint32_t size;
    memcpy(&size, v, 4);
    if (size >= 284) { memset(v + 276, 0, 8); v[282] = 1; } /* VER_NT_WORKSTATION */
    const uint32_t major = 10, minor = 0, build = 19045, platform = 2;
    memcpy(v + 4, &major, 4);
    memcpy(v + 8, &minor, 4);
    memcpy(v + 12, &build, 4);
    memcpy(v + 16, &platform, 4);
    memset(v + 20, 0, 256);
    return 1;
}
H(GetSystemDirectoryW) { return rt_put_wide("C:\\Windows\\system32", P(0), (uint32_t)A(1)); }
H(GetProcessAffinityMask) {
    const uint64_t mask = (UINT64_C(1) << sysconf(_SC_NPROCESSORS_ONLN)) - 1;
    memcpy(P(1), &mask, 8);
    memcpy(P(2), &mask, 8);
    return 1;
}

/* ---- registry: one value; every other key the game reads is absent ----
 * Absent on purpose: AeDebug (no JIT debugger to launch), the DirectX adapter keys and their Video
 * driver keys (no Windows driver; Wine has none either), and TdrLevel/TdrDelay (Windows defaults). */

/* Predefined keys arrive zero- or sign-extended (the game loads them with a 32-bit move). */
enum : uint32_t { HKEY_LOCAL_MACHINE = 0x80000002, REG_SZ = 1, RRF_RT_REG_SZ = 2, RRF_ZEROONFAILURE = 0x20000000 };
static const char CPU_KEY[] = "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0";
/* The cpuid brand string of the R0.08 profile (leaves 0x80000002-4). */
static const char CPU_NAME[] = "VirtualApple @ 2.50GHz";

H(RegOpenKeyExA) {
    printf("runtime: registry key %#x\\%s absent\n", (uint32_t)A(0), (const char *)P(1));
    return 2; /* ERROR_FILE_NOT_FOUND */
}
static uint32_t get_value(WinCall *c, uint32_t capacity) {
    const char *key = P(1), *value = P(2);
    if ((uint32_t)A(0) != HKEY_LOCAL_MACHINE || !key || strcasecmp(key, CPU_KEY) || !value || strcasecmp(value, "ProcessorNameString")) {
        printf("runtime: registry value %#x\\%s\\%s absent\n", (uint32_t)A(0), key ? key : "", value ? value : "");
        return 2;
    }
    if (!(A(3) & RRF_RT_REG_SZ)) return 1630; /* ERROR_UNSUPPORTED_TYPE */
    if (P(4)) rt_put<uint32_t>(P(4), REG_SZ);
    const uint32_t size = sizeof CPU_NAME;
    if (!P(6)) return P(5) ? 87 : 0;
    rt_put(P(6), size);
    if (!P(5)) return 0;
    if (capacity < size) return 234; /* ERROR_MORE_DATA */
    memcpy(P(5), CPU_NAME, size);
    return 0;
}
H(RegGetValueA) {
    uint32_t capacity = 0;
    if (P(6)) memcpy(&capacity, P(6), 4);
    const uint32_t error = get_value(c, capacity);
    if (error && (A(3) & RRF_ZEROONFAILURE) && P(5)) memset(P(5), 0, capacity);
    return error;
}
/* No key is ever opened, so these only see handles the runtime never gave out. */
H(RegQueryValueExA) { return 6; } /* ERROR_INVALID_HANDLE */
H(RegEnumKeyExA) { return 6; }
H(RegCloseKey) { return 6; }

/* GetLogicalProcessorInformationEx: one core per host CPU (no SMT) in one package and group. */
H(GetLogicalProcessorInformationEx) {
    const uint32_t relation = (uint32_t)A(0), cpus = (uint32_t)sysconf(_SC_NPROCESSORS_ONLN);
    enum { CORE = 0, PACKAGE = 3, ALL = 0xffff, ENTRY = 48 };
    const int cores = relation == CORE || relation == ALL, package = relation == PACKAGE || relation == ALL;
    const uint32_t needed = ENTRY * ((cores ? cpus : 0) + (package ? 1 : 0));
    uint32_t length;
    memcpy(&length, P(2), 4);
    memcpy(P(2), &needed, 4);
    if (!needed) { rt_set_last_error(87); return 0; }
    if (length < needed || !A(1)) { rt_set_last_error(122); return 0; }
    uint8_t *out = P(1);
    memset(out, 0, needed);
    for (uint32_t i = 0; i < (cores ? cpus : 0) + (package ? 1 : 0); ++i) {
        uint8_t *e = out + ENTRY * i;
        const int is_package = !cores || i == cpus;
        const uint32_t kind = is_package ? PACKAGE : CORE, size = ENTRY;
        const uint16_t groups = 1;
        const uint64_t mask = is_package ? (UINT64_C(1) << cpus) - 1 : UINT64_C(1) << i;
        memcpy(e, &kind, 4);
        memcpy(e + 4, &size, 4);
        memcpy(e + 8 + 22, &groups, 2);
        memcpy(e + 8 + 24, &mask, 8);
    }
    return 1;
}

/* ---- table ---- */

#define E(name) {#name, name}
const RtEntry rt_win32_entries[] = {
    E(GetSystemTimeAsFileTime), E(GetSystemTimePreciseAsFileTime), E(_time64), E(QueryPerformanceFrequency),
    E(QueryPerformanceCounter), E(GetCurrentProcessId), E(GetCurrentThreadId), E(GetCurrentProcess),
    E(GetCurrentThread), E(IsDebuggerPresent), E(GetLastError),
    E(_initterm), E(_initterm_e), E(__p___argc), E(__p___argv), E(_get_initial_narrow_environment),
    E(__p__commode), E(_initialize_onexit_table), E(_register_onexit_function), E(_crt_atexit),
    E(_execute_onexit_table), {"exit", exit_}, {"_exit", _exit_}, E(ExitProcess), E(terminate),
    E(__intrinsic_setjmp), {"longjmp", longjmp_}, E(_CxxThrowException), {"qsort", qsort_},
    {"__C_specific_handler", unsupported_unwind},
    E(_crt_at_quick_exit), {"quick_exit", quick_exit_}, {"_set_app_type", returns_zero},
    E(_configure_narrow_argv), {"_initialize_narrow_environment", returns_zero},
    E(_configthreadlocale), E(_register_thread_local_exe_atexit_callback),
    E(_wassert), E(_purecall), {"_seh_filter_dll", returns_zero},
    {"_seh_filter_exe", returns_zero},
    E(_cexit), {"_c_exit", returns_zero}, E(GetCommandLineA), E(GetCommandLineW),
    E(IsProcessorFeaturePresent), E(GetModuleHandleW), E(GetModuleFileNameW), E(GetStartupInfoW),
    E(LoadLibraryW), E(LoadLibraryA), E(FreeLibrary), E(GetProcAddress),
    E(CreateProcessW), E(GetExitCodeProcess), E(TerminateProcess),
    E(RegOpenKeyExA), E(RegGetValueA), E(RegQueryValueExA), E(RegEnumKeyExA), E(RegCloseKey),
    E(FileTimeToSystemTime), E(FileTimeToLocalFileTime), E(SetProcessInformation), E(SetErrorMode), E(timeBeginPeriod), E(GetUserDefaultLCID), E(GetVersionExW),
    E(GetSystemDirectoryW), E(GetProcessAffinityMask),
    E(GetLogicalProcessorInformationEx), E(OutputDebugStringA), E(GetConsoleMode), E(SetConsoleMode),
    E(SetConsoleOutputCP), E(GetStdHandle),
    {"memcpy", memcpy_}, {"memmove", memmove_}, {"memset", memset_}, {"memcmp", memcmp_}, {"memchr", memchr_},
    {"strlen", strlen_}, {"strcmp", strcmp_}, {"strncmp", strncmp_}, {"strrchr", strrchr_}, {"strstr", strstr_},
    {"strncpy", strncpy_}, {"wcslen", wcslen_}, {"wcsncpy", wcsncpy_}, {"wcsstr", wcsstr_}, E(strncpy_s), E(wcsncpy_s), E(wcsncat_s), {"strtol", strtol_}, {"getenv", getenv_},
    {nullptr, nullptr},
};

ImportHandler rt_find_handler(const char *dll, const char *name) {
    if (!strcasecmp(dll, "d3d12.dll") && !strcmp(name, "#101")) name = "D3D12CreateDevice";
    static const RtEntry *const tables[] = {rt_win32_entries, rt_sync_entries, rt_memory_entries, rt_heap_entries, rt_file_entries, rt_steam_entries, rt_user32_entries, rt_window_entries, rt_input_entries, rt_gamepad_entries, rt_text_entries, rt_stdio_entries, rt_math_entries, rt_crash_entries, rt_com_entries, rt_graphics_entries};
    for (const RtEntry *table : tables)
        for (const RtEntry *e = table; e->name; ++e)
            if (!strcmp(e->name, name)) return e->handler;
    return nullptr;
}
