#include "runtime.h"

#include <atomic>
#include <malloc/malloc.h>
#include <mutex>
#include <stdlib.h>
#include <unordered_map>

static constexpr uint64_t PROCESS_HEAP = 0x10000;
static std::mutex heap_lock;
static std::unordered_map<void *, size_t> heap_blocks;
static std::atomic<int> new_mode;

void *rt_alloc(uint64_t size, int zero) {
    if (!size) size = 1;
    if (zero) return calloc(1, size);
    return malloc(size);
}
static bool heap_flags(uint64_t heap, uint32_t flags, uint32_t allowed) {
    if (heap != PROCESS_HEAP) { rt_set_last_error(6); return false; }
    if (flags & 4) rt_fatal("HEAP_GENERATE_EXCEPTIONS is unsupported");
    if (flags & ~allowed) { rt_set_last_error(87); return false; }
    return true;
}
H(GetProcessHeap) { return PROCESS_HEAP; }
H(HeapAlloc) {
    if (!heap_flags(A(0), A(1), 1 | 8)) return 0;
    void *p = rt_alloc(A(2), (A(1) & 8) != 0);
    if (p) { std::lock_guard guard(heap_lock); heap_blocks[p] = A(2); }
    return (uintptr_t)p;
}
H(HeapFree) {
    if (!heap_flags(A(0), A(1), 1)) return 0;
    if (!P(2)) return 1;
    std::lock_guard guard(heap_lock);
    if (!heap_blocks.erase(P(2))) { rt_set_last_error(87); return 0; }
    free(P(2));
    return 1;
}
H(HeapReAlloc) {
    if (!heap_flags(A(0), A(1), 1 | 8 | 0x10)) return 0;
    std::lock_guard guard(heap_lock);
    auto found = heap_blocks.find(P(2));
    if (found == heap_blocks.end()) { rt_set_last_error(87); return 0; }
    const size_t old = found->second, size = A(3);
    void *p;
    if (A(1) & 0x10) {
        if (size > malloc_size(P(2))) return 0;
        p = P(2);
    } else p = realloc(P(2), size ? size : 1);
    if (!p) return 0;
    if ((A(1) & 8) && size > old) memset((uint8_t *)p + old, 0, size - old);
    heap_blocks.erase(found);
    heap_blocks[p] = size;
    return (uintptr_t)p;
}
H(_set_new_mode) {
    const int mode = (int)A(0);
    if (mode != 0 && mode != 1) return UINT32_MAX;
    return new_mode.exchange(mode);
}
// The executable imports no new-handler setter; UCRT's initial handler is null in either new mode.
H(_callnewh) { return 0; }
H(malloc_) { return (uintptr_t)rt_alloc(A(0), false); }
H(calloc_) {
    if (A(1) && A(0) > SIZE_MAX / A(1)) return 0;
    return (uintptr_t)rt_alloc(A(0) * A(1), true);
}
H(realloc_) {
    if (!A(1) && P(0)) { free(P(0)); return 0; }
    return (uintptr_t)realloc(P(0), A(1) ? A(1) : 1);
}
H(free_) { free(P(0)); return 0; }

struct GlobalBlock { void *data; bool movable; uint32_t locks; uint64_t size; };
static std::unordered_map<uint64_t, GlobalBlock> global_blocks;
void *rt_local_alloc(uint64_t size) {
    void *p = rt_alloc(size, false);
    if (p) {
        std::lock_guard guard(heap_lock);
        global_blocks.emplace((uintptr_t)p, GlobalBlock{p, false, 0, size});
    }
    return p;
}
H(GlobalAlloc) {
    const uint32_t flags = A(0);
    // GMEM_DDESHARE (0x2000) only mattered for 16-bit Windows; clipboard data still carries it.
    if (flags & ~(2u | 0x40u | 0x2000u)) { rt_set_last_error(87); return 0; }
    const bool movable = (flags & 2) != 0;
    void *data = nullptr;
    if (A(1) || !movable) data = rt_alloc(A(1), (flags & 0x40) != 0);
    if (!data && (A(1) || !movable)) { rt_set_last_error(8); return 0; }
    const uint64_t handle = (uintptr_t)(movable ? rt_alloc(16, false) : data);
    if (!handle) { free(data); rt_set_last_error(8); return 0; }
    std::lock_guard guard(heap_lock);
    global_blocks.emplace(handle, GlobalBlock{data, movable, 0, A(1)});
    return handle;
}
H(GlobalLock) {
    std::lock_guard guard(heap_lock);
    const auto found = global_blocks.find(A(0));
    if (found == global_blocks.end()) { rt_set_last_error(6); return 0; }
    GlobalBlock &b = found->second;
    if (!b.data) { rt_set_last_error(157); return 0; }
    if (b.movable) ++b.locks;
    return (uintptr_t)b.data;
}
H(GlobalUnlock) {
    std::lock_guard guard(heap_lock);
    const auto found = global_blocks.find(A(0));
    if (found == global_blocks.end()) { rt_set_last_error(6); return 0; }
    GlobalBlock &b = found->second;
    if (!b.movable) return 1;
    if (!b.locks) { rt_set_last_error(158); return 0; }
    rt_set_last_error(0);
    return --b.locks != 0;
}
static uint64_t local_free(uint64_t handle) {
    std::lock_guard guard(heap_lock);
    const auto found = global_blocks.find(handle);
    if (found != global_blocks.end()) {
        free(found->second.data);
        if (found->second.movable) free((void *)(uintptr_t)handle);
        global_blocks.erase(found);
    } else if (handle) { rt_set_last_error(6); return handle; }
    return 0;
}
bool rt_global_copy(uint64_t handle, std::vector<uint8_t> &out) {
    std::lock_guard guard(heap_lock);
    const auto found = global_blocks.find(handle);
    if (found == global_blocks.end() || !found->second.data) return false;
    const uint8_t *data = (const uint8_t *)found->second.data;
    out.assign(data, data + found->second.size);
    return true;
}
void rt_global_free(uint64_t handle) { local_free(handle); }
H(LocalFree) { return local_free(A(0)); }
H(GlobalFree) { return local_free(A(0)); }

#define E(name) {#name, name}
const RtEntry rt_heap_entries[] = {
    E(GetProcessHeap), E(HeapAlloc), E(HeapReAlloc), E(HeapFree),
    {"malloc", malloc_}, {"calloc", calloc_}, {"realloc", realloc_}, {"free", free_},
    E(_callnewh), E(_set_new_mode),
    E(GlobalAlloc), E(GlobalLock), E(GlobalUnlock), E(GlobalFree), E(LocalFree),
    {nullptr, nullptr},
};
