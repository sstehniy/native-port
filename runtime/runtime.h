/* The native runtime for the recompiled game (RECOMP-PLAN Phase 0/2): loader and Windows imports. */
#ifndef SS_RUNTIME_H
#define SS_RUNTIME_H
#include "cpu/cpu_internal.h"

#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

/* Imports point at thunks in this range: never mapped, never guest code (bbcpu_set_host_thunks). */
#define THUNK_BASE UINT64_C(0x0000600000000000)
#define THUNK_STRIDE 16

struct Import;
struct WinCall {
    BbCpu *cpu;
    uint64_t stack_args; /* the caller's shadow space: argument 4 is at stack_args + 32 */
    const Import *import;
};
using ImportHandler = uint64_t (*)(WinCall *call);

struct Import {
    const char *dll, *name;
    ImportHandler handler;
};
/* A kernel object behind a handle (sync.cpp). Each subclass has a `type` that rt_object<T> checks
 * (the runtime has no RTTI); the object goes away with its last handle or other holder. */
enum class Kind { Event, Semaphore, Thread, File, Mapping, Find, Stream };
struct Object {
    explicit Object(Kind kind) : kind(kind) {}
    virtual ~Object() = default;
    Object(const Object &) = delete;
    Object &operator=(const Object &) = delete;
    /* Wait state, used with the wait lock held: whether a wait succeeds now, and its side effect. */
    virtual bool ready() const { return true; }
    virtual void acquire() {}
    const Kind kind;
};
uint64_t rt_new_handle(std::shared_ptr<Object> object);
std::shared_ptr<Object> rt_object(uint64_t handle);
template <class T> std::shared_ptr<T> rt_object(uint64_t handle) {
    std::shared_ptr<Object> object = rt_object(handle);
    if (!object || object->kind != T::type) return nullptr;
    return std::static_pointer_cast<T>(std::move(object));
}
uint64_t rt_close_handle(uint64_t handle);
uint64_t rt_semaphore_create(int32_t initial, int32_t maximum);
bool rt_semaphore_release(uint64_t handle, int32_t count, int32_t *previous = nullptr);
bool rt_semaphore_try_wait(uint64_t handle);
uint64_t rt_signal_event(uint64_t handle);
/* Copies a GlobalAlloc block's contents; frees a block the clipboard owns (heap.cpp). */
bool rt_global_copy(uint64_t handle, std::vector<uint8_t> &out);
void rt_global_free(uint64_t handle);
/* Queues an I/O completion routine for the calling thread's next alertable wait (sync.cpp). */
void rt_queue_completion(uint64_t routine, uint32_t error, uint32_t bytes, uint64_t overlapped);
/* Zero-filled guest memory, reserved away from host mappings so calls can be replayed (also used by bbcpu). */
extern "C" void *runtime_low_map(size_t size, int prot);
/* Maps the game folder and the port's profile folder (files.cpp). */
void rt_files_init(const char *exe_path);
bool rt_write_handle(uint64_t handle, const void *data, size_t size);
void rt_math_init();
void rt_math_report();
/* Saves pending pipeline-archive entries, waiting for a scheduled background write (graphics.mm). */
void rt_graphics_before_exit();
void rt_audio_init();
void rt_gamepad_init();
void rt_gamepad_pump();
void rt_window_device_change(uint64_t identity, bool connected);
bool rt_window_pump_native();
void rt_process_init(const char *exe_path, int argc, char **argv);
/* Sets up the TEB, then calls TLS callbacks with the Win32 attach reason; returns the TEB. */
uint64_t rt_thread_init(const void *stack, size_t size, uint32_t reason);
size_t rt_thread_stack_size(uint64_t requested, bool reservation);
void rt_thread_detach(uint64_t teb, void *stack, size_t size);
/* Guest UTF-16 text as UTF-8 and back; unpaired surrogates pass through (win32.cpp). */
std::string rt_utf8(std::u16string_view wide);
std::u16string rt_utf16(std::string_view text);
/* A NUL-terminated guest wide string, which may be null. */
inline std::string rt_utf8(const char16_t *wide) { return wide ? rt_utf8(std::u16string_view(wide)) : std::string(); }
/* Stores `text` as a terminated wide string when it fits in `capacity` units and returns its
 * length; otherwise returns the size needed with the terminator, like Windows path functions. */
uint32_t rt_put_wide(std::string_view text, uint16_t *out, uint32_t capacity);
/* Win32 last-error value of the calling thread. */
void rt_set_last_error(uint32_t code);
uint32_t rt_last_error(void);
/* An import table: name and handler pairs, ending with {nullptr, nullptr} (one per runtime file). */
struct RtEntry { const char *name; ImportHandler handler; };
extern const RtEntry rt_win32_entries[], rt_sync_entries[], rt_memory_entries[], rt_heap_entries[], rt_file_entries[], rt_steam_entries[], rt_user32_entries[], rt_window_entries[], rt_input_entries[], rt_gamepad_entries[], rt_text_entries[], rt_stdio_entries[], rt_math_entries[], rt_crash_entries[], rt_com_entries[], rt_graphics_entries[];
#define A(i) rt_arg(c, i)
/* A guest pointer argument; converts to any host pointer type, since guest memory is host memory. */
struct GuestPtr {
    uint64_t address;
    template <class T> operator T *() const { return reinterpret_cast<T *>(address); }
    explicit operator bool() const { return address != 0; }
};
#define P(i) (GuestPtr{rt_arg(c, i)})
#define H(name) static uint64_t name(WinCall *c)
/* Routes guest calls of every import thunk, present and future, to the handlers (loader.cpp). */
void rt_bind_thunks(void);
/* GetProcAddress: the thunk of an implemented function, 0 otherwise (loader.cpp). */
uint64_t rt_dynamic_import(const char *dll, const char *name);
/* Register a host method in the same guest thunk range as imports. Names are copied. */
uint64_t rt_host_thunk(const char *name, ImportHandler handler);

/* Stores a guest field, which may be unaligned. */
template <class T> void rt_put(void *at, T value) { memcpy(at, &value, sizeof value); }

/* Where the image is mapped (loader.cpp); bbcpu reads it for reports. */
extern "C" uint64_t bb_image_base;
/* malloc, or calloc when `zero`; a 0-byte request still returns a unique block. */
void *rt_alloc(uint64_t size, int zero);
void *rt_local_alloc(uint64_t size);
/* Win64 integer argument `index` (0: rcx). */
uint64_t rt_arg(const WinCall *call, int index);
/* The host implementation of an import, or nullptr (win32.cpp). */
ImportHandler rt_find_handler(const char *dll, const char *name);
[[noreturn]] void rt_fatal(const char *format, ...) __attribute__((format(printf, 1, 2)));

enum class RtPackageStatus { Ready, Cancelled, Failed };
RtPackageStatus rt_prepare_package(const char *&executable);

#endif
