#include "com.h"
#include <cstdlib>
#include <mutex>
#include <utility>

static constexpr uint32_t E_POINTER = 0x80004003, E_INVALIDARG = 0x80070057;
static constexpr uint32_t E_NOINTERFACE = 0x80004002, CLASS_NOT_REGISTERED = 0x80040154;
static thread_local struct { uint32_t model = 0, count = 0; } apartment;
static std::mutex class_lock;
static std::vector<std::pair<RtGuid, RtComFactory>> classes;

RtComObject::RtComObject(std::initializer_list<RtComInterfaceSpec> specs) {
    if (!specs.size()) rt_fatal("COM object has no interfaces");
    interfaces.reserve(specs.size());
    for (const auto &spec : specs) interfaces.push_back({spec.vtable, this, spec.iid});
}
uint32_t RtComObject::query(const RtGuid &iid, void **out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    for (auto &interface : interfaces) {
        if (iid == RT_IUNKNOWN || iid == interface.iid) {
            add_ref();
            *out = &interface;
            return 0;
        }
    }
    return E_NOINTERFACE;
}
uint32_t RtComObject::add_ref() { return references.fetch_add(1, std::memory_order_relaxed) + 1; }
uint32_t RtComObject::release() {
    const uint32_t remaining = references.fetch_sub(1, std::memory_order_acq_rel) - 1;
    if (!remaining) delete this;
    return remaining;
}
H(QueryInterface) {
    if (!P(2)) return E_POINTER;
    rt_put<uint64_t>(P(2), 0);
    if (!P(1)) return E_INVALIDARG;
    RtGuid iid; memcpy(&iid, P(1), sizeof(iid));
    void *out = nullptr;
    const uint32_t result = ((RtComInterface *)(uintptr_t)A(0))->object->query(iid, &out);
    rt_put<uint64_t>(P(2), (uintptr_t)out);
    return result;
}
H(AddRef) { return ((RtComInterface *)(uintptr_t)A(0))->object->add_ref(); }
H(Release) { return ((RtComInterface *)(uintptr_t)A(0))->object->release(); }
std::vector<uint64_t> rt_com_vtable(std::initializer_list<RtEntry> methods) {
    std::vector<uint64_t> table;
    for (const auto &entry : {RtEntry{"IUnknown.QueryInterface", QueryInterface}, {"IUnknown.AddRef", AddRef}, {"IUnknown.Release", Release}})
        table.push_back(rt_host_thunk(entry.name, entry.handler));
    for (const auto &entry : methods) table.push_back(rt_host_thunk(entry.name, entry.handler));
    return table;
}
bool rt_com_register_class(const RtGuid &clsid, RtComFactory factory) {
    if (!factory) return false;
    std::lock_guard guard(class_lock);
    for (const auto &[id, existing] : classes) if (id == clsid) return existing == factory;
    classes.emplace_back(clsid, factory);
    return true;
}
H(CoInitializeEx) {
    const uint32_t flags = (uint32_t)A(1), model = flags & 2;
    if (A(0) || (flags & ~0xeu)) return E_INVALIDARG;
    if (apartment.count && model != apartment.model) return 0x80010106; // RPC_E_CHANGED_MODE
    if (apartment.count == UINT32_MAX) return 0x8000ffff;
    apartment.model = model;
    return apartment.count++ ? 1 : 0;
}
H(CoUninitialize) { if (apartment.count) --apartment.count; return 0; }
H(CoCreateInstance) {
    if (!P(4)) return E_POINTER;
    rt_put<uint64_t>(P(4), 0);
    if (!P(0) || !P(3)) return E_INVALIDARG;
    if (!apartment.count) return 0x800401f0; // CO_E_NOTINITIALIZED
    if (!(A(2) & 1)) return CLASS_NOT_REGISTERED;
    RtGuid clsid, iid;
    memcpy(&clsid, P(0), 16); memcpy(&iid, P(3), 16);
    RtComFactory factory = nullptr;
    {
        std::lock_guard guard(class_lock);
        for (const auto &[id, create] : classes) if (id == clsid) { factory = create; break; }
    }
    if (!factory) return CLASS_NOT_REGISTERED;
    if (A(1)) return 0x80040110; // CLASS_E_NOAGGREGATION
    RtComObject *object = factory();
    if (!object) return 0x8007000e;
    void *out = nullptr;
    const uint32_t result = object->query(iid, &out);
    object->release();
    rt_put<uint64_t>(P(4), (uintptr_t)out);
    return result;
}
H(CoCreateGuid) {
    if (!P(0)) return E_POINTER;
    RtGuid guid;
    arc4random_buf(&guid, sizeof(guid));
    guid.data3 = (guid.data3 & 0xfff) | 0x4000;
    guid.data4[0] = (guid.data4[0] & 0x3f) | 0x80;
    memcpy(P(0), &guid, sizeof(guid));
    return 0;
}
H(CoTaskMemAlloc) { return (uintptr_t)rt_alloc(A(0), false); }
H(CoTaskMemFree) { free(P(0)); return 0; }
static bool scalar_type(uint16_t type) {
    switch (type) {
    case 0: case 1: case 2: case 3: case 4: case 5: case 6: case 7: case 10: case 11: case 14:
    case 16: case 17: case 18: case 19: case 20: case 21: case 22: case 23: case 64: return true;
    default: return false;
    }
}
H(PropVariantClear) {
    if (!P(0)) return E_INVALIDARG;
    auto *variant = (uint8_t *)(uintptr_t)A(0);
    uint16_t type; uint64_t pointer;
    memcpy(&type, variant, 2); memcpy(&pointer, variant + 8, 8);
    const uint16_t base = type & ~0x4000;
    const bool allocated = base == 30 || base == 31 || base == 72; // LPSTR, LPWSTR, CLSID
    const bool object = base == 9 || base == 13 || base == 66 || base == 67; // IUnknown prefix
    // shortcut: compound/vector/SAFEARRAY and owned BSTR variants need their allocator when a caller uses them.
    if (!scalar_type(base) && !allocated && !object && base != 65) return 0x80020008;
    if (!(type & 0x4000)) {
        if (allocated) free((void *)(uintptr_t)pointer);
        else if (base == 65) { memcpy(&pointer, variant + 16, 8); free((void *)(uintptr_t)pointer); }
        else if (object && pointer) {
            uint64_t vtable; memcpy(&vtable, (void *)(uintptr_t)pointer, 8);
            uint64_t release; memcpy(&release, (void *)(uintptr_t)(vtable + 16), 8);
            bbcpu_call_win64(release, 1, &pointer);
        }
    }
    memset(variant, 0, 24);
    return 0;
}
#define E(name) {#name, name}
const RtEntry rt_com_entries[] = {
    E(CoInitializeEx), E(CoUninitialize), E(CoCreateInstance), E(CoCreateGuid),
    E(CoTaskMemAlloc), E(CoTaskMemFree), E(PropVariantClear), {nullptr, nullptr}
};
