/* Windows 4 KiB allocation state over macOS VM mappings. */
#include "runtime.h"

#include <algorithm>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mutex>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <vector>

enum { MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_DECOMMIT = 0x4000, MEM_RELEASE = 0x8000,
       MEM_FREE = 0x10000, MEM_PRIVATE = 0x20000, PAGE_NOACCESS = 1, GRANULARITY = 0x10000, PAGE = 4096 };

struct Region {
    uint64_t base, size, mapped;
    uint32_t protect;
    std::unique_ptr<uint8_t[], decltype(&free)> pages{nullptr, free};
};
static std::vector<Region> regions;
static std::mutex lock;

static Region *find(uint64_t address) {
    for (Region &r : regions)
        if (address >= r.base && address - r.base < r.size) return &r;
    return nullptr;
}
static uint64_t down(uint64_t n, uint64_t alignment) { return n & ~(alignment - 1); }
static uint64_t up(uint64_t n, uint64_t alignment) { return (n + alignment - 1) & ~(alignment - 1); }
static int host_protection(uint32_t p) {
    if (!p || p == PAGE_NOACCESS) return PROT_NONE;
    if (p == 4 || p == 8 || p == 0x40 || p == 0x80) return PROT_READ | PROT_WRITE;
    return PROT_READ; // Guest executable pages are interpreted, never executed by the host CPU.
}
static bool valid_protection(uint32_t p) { return p && p <= 0x80 && !(p & (p - 1)); }

static void protect(Region &r, uint64_t from, uint64_t to) {
    const uint64_t host_page = getpagesize();
    for (uint64_t at = down(from, host_page); at < up(to, host_page); at += host_page) {
        int prot = PROT_NONE;
        for (uint64_t p = at; p < std::min(at + host_page, r.size); p += PAGE)
            prot |= host_protection(r.pages[p / PAGE]);
        // shortcut: shared 16 KiB host pages use the union; subpage access faults need CPU instrumentation.
        if (mprotect((void *)(uintptr_t)(r.base + at), host_page, prot)) rt_fatal("cannot protect guest allocation");
    }
}

H(VirtualAlloc) {
    const uint64_t want = A(0), bytes = A(1);
    const uint32_t type = A(2), protection = A(3);
    if (!bytes || bytes > UINT64_C(0x7fffffff0000) || want > UINT64_C(0x7fffffff0000) - bytes ||
        !(type & (MEM_RESERVE | MEM_COMMIT)) || (type & ~(MEM_RESERVE | MEM_COMMIT)) || !valid_protection(protection)) {
        rt_set_last_error(87); return 0;
    }
    std::lock_guard guard(lock);
    const uint64_t end = up(want + bytes, PAGE);
    if (Region *r = want ? find(want) : nullptr) {
        if (type != MEM_COMMIT || end > r->base + r->size) { rt_set_last_error(487); return 0; }
        const uint64_t from = down(want, PAGE) - r->base, to = end - r->base;
        for (uint64_t p = from; p < to; p += PAGE)
            if (!r->pages[p / PAGE]) r->pages[p / PAGE] = protection;
        protect(*r, from, to);
        return r->base + from;
    }
    if (want && !(type & MEM_RESERVE)) { rt_set_last_error(487); return 0; }
    const uint64_t base = down(want, GRANULARITY);
    const uint64_t size = up(want - base + bytes, PAGE), mapped = up(size, getpagesize());
    Region r{.base = base, .size = size, .mapped = mapped, .protect = protection};
    r.pages.reset(static_cast<uint8_t *>(calloc(size / PAGE, 1)));
    if (!r.pages) { rt_set_last_error(8); return 0; }
    void *p;
    if (want) {
        p = mmap((void *)(uintptr_t)base, mapped, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p != MAP_FAILED && (uint64_t)(uintptr_t)p != base) { munmap(p, mapped); p = MAP_FAILED; }
    } else {
        p = runtime_low_map(mapped + GRANULARITY, PROT_NONE);
        if (p) {
            const uint64_t start = (uintptr_t)p, aligned = up(start, GRANULARITY);
            if (aligned > start) munmap(p, aligned - start);
            munmap((void *)(uintptr_t)(aligned + mapped), GRANULARITY - (aligned - start));
            p = (void *)(uintptr_t)aligned;
        } else p = MAP_FAILED;
    }
    if (p == MAP_FAILED) { rt_set_last_error(want ? 487 : 8); return 0; }
    r.base = (uintptr_t)p;
    if (type & MEM_COMMIT) { memset(r.pages.get(), protection, size / PAGE); protect(r, 0, size); }
    const uint64_t result = r.base;
    regions.push_back(std::move(r));
    return result;
}

H(VirtualFree) {
    const uint64_t address = A(0), bytes = A(1);
    const uint32_t type = A(2);
    if (type != MEM_RELEASE && type != MEM_DECOMMIT) { rt_set_last_error(87); return 0; }
    std::lock_guard guard(lock);
    Region *r = find(address);
    if (!r) { rt_set_last_error(487); return 0; }
    if (type == MEM_RELEASE) {
        if (address != r->base || bytes) { rt_set_last_error(87); return 0; }
        if (munmap((void *)(uintptr_t)r->base, r->mapped)) { rt_set_last_error(487); return 0; }
        if (r != &regions.back()) *r = std::move(regions.back());
        regions.pop_back();
        return 1;
    }
    if ((!bytes && address != r->base) || bytes > r->size || address - r->base > r->size - bytes) {
        rt_set_last_error(487); return 0;
    }
    const uint64_t from = down(address - r->base, PAGE);
    const uint64_t to = bytes ? up(address - r->base + bytes, PAGE) : r->size;
    for (uint64_t at = from; at < to; at += PAGE) {
        if (!r->pages[at / PAGE]) continue;
        const uint64_t host_page = getpagesize();
        if (mprotect((void *)(uintptr_t)(r->base + down(at, host_page)), host_page, PROT_READ | PROT_WRITE))
            rt_fatal("cannot clear decommitted guest page");
        memset((void *)(uintptr_t)(r->base + at), 0, PAGE);
        r->pages[at / PAGE] = 0;
    }
    const uint64_t host_page = getpagesize();
    for (uint64_t at = down(from, host_page); at < up(to, host_page); at += host_page) {
        bool committed = false;
        for (uint64_t p = at; p < std::min(at + host_page, r->size); p += PAGE)
            committed |= r->pages[p / PAGE] != 0;
        if (committed) protect(*r, at, std::min(at + host_page, r->size));
        else if (mmap((void *)(uintptr_t)(r->base + at), host_page, PROT_NONE,
                      MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0) == MAP_FAILED)
            rt_fatal("cannot discard decommitted guest pages");
    }
    return 1;
}

struct MemoryBasicInformation {
    uint64_t base, allocation_base;
    uint32_t allocation_protect, partition;
    uint64_t size;
    uint32_t state, protect, type, padding;
};
static_assert(sizeof(MemoryBasicInformation) == 48, "Win64 MEMORY_BASIC_INFORMATION");

H(VirtualQuery) {
    const uint64_t address = down(A(0), PAGE);
    if (address >= UINT64_C(0x7fffffff0000)) { rt_set_last_error(87); return 0; }
    if (!P(1) || A(2) < sizeof(MemoryBasicInformation)) { rt_set_last_error(24); return 0; }
    MemoryBasicInformation info = {};
    std::lock_guard guard(lock);
    if (const Region *r = find(address)) {
        const uint32_t protection = r->pages[(address - r->base) / PAGE];
        uint64_t end = address + PAGE;
        while (end < r->base + r->size && r->pages[(end - r->base) / PAGE] == protection) end += PAGE;
        info.base = address;
        info.allocation_base = r->base;
        info.allocation_protect = r->protect;
        info.size = end - address;
        info.state = protection ? MEM_COMMIT : MEM_RESERVE;
        info.protect = protection;
        info.type = MEM_PRIVATE;
    } else {
        mach_vm_address_t a = address;
        mach_vm_size_t s = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t host;
        mach_msg_type_number_t n = VM_REGION_SUBMAP_INFO_COUNT_64;
        const bool mapped = mach_vm_region_recurse(mach_task_self(), &a, &s, &depth,
            (vm_region_recurse_info_t)&host, &n) == KERN_SUCCESS;
        info.base = address;
        if (!mapped || a > address) {
            uint64_t end = mapped ? a : UINT64_C(0x7fffffff0000);
            for (const Region &r : regions) if (r.base > address) end = std::min(end, r.base);
            info.size = std::max<uint64_t>(PAGE, end - address);
            info.state = MEM_FREE;
        } else {
            info.allocation_base = a;
            info.size = a + s - address;
            info.state = MEM_COMMIT;
            info.protect = PAGE_NOACCESS;
            if (host.protection & VM_PROT_READ) info.protect = 2;
            if (host.protection & VM_PROT_WRITE) info.protect = 4;
            info.allocation_protect = info.protect;
            info.type = MEM_PRIVATE;
        }
    }
    memcpy(P(1), &info, sizeof(info));
    return sizeof(info);
}

struct MemoryStatus {
    uint32_t length, load;
    uint64_t total_physical, available_physical, total_page_file, available_page_file;
    uint64_t total_virtual, available_virtual, available_extended_virtual;
};
static_assert(sizeof(MemoryStatus) == 64, "MEMORYSTATUSEX");
H(GlobalMemoryStatusEx) {
    if (!P(0) || *(const uint32_t *)P(0) != sizeof(MemoryStatus)) { rt_set_last_error(87); return 0; }
    uint64_t total = 0;
    size_t length = sizeof(total);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (sysctlbyname("hw.memsize", &total, &length, nullptr, 0) ||
        host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) {
        rt_set_last_error(31); return 0;
    }
    const uint64_t available = std::min(total, ((uint64_t)vm.free_count + vm.inactive_count) * getpagesize());
    const uint64_t virt = UINT64_C(0x7ffffffe0000);
    const MemoryStatus status = {sizeof(MemoryStatus), (uint32_t)((total - available) * 100 / total),
        total, available, total, available, virt, virt, 0};
    memcpy(P(0), &status, sizeof(status));
    return 1;
}

struct SystemInfo {
    uint16_t architecture, reserved;
    uint32_t page_size;
    uint64_t minimum_address, maximum_address, active_processors;
    uint32_t processors, processor_type, granularity;
    uint16_t level, revision;
};
static_assert(sizeof(SystemInfo) == 48, "Win64 SYSTEM_INFO");
H(GetSystemInfo) {
    const uint32_t cpus = (uint32_t)sysconf(_SC_NPROCESSORS_ONLN);
    const SystemInfo info = {9, 0, 4096, 0x10000, UINT64_C(0x7ffffffeffff), (UINT64_C(1) << cpus) - 1,
                             cpus, 8664, GRANULARITY, 6, 0x2c00}; /* family 6, model 0x2c, stepping 0: R0.08's 0x206c0 */
    memcpy(P(0), &info, sizeof(info));
    return 0;
}

#define E(name) {#name, name}
const RtEntry rt_memory_entries[] = {
    E(VirtualAlloc), E(VirtualFree), E(VirtualQuery), E(GlobalMemoryStatusEx), E(GetSystemInfo),
    {nullptr, nullptr},
};
