#ifndef SS_COM_H
#define SS_COM_H
#include "runtime.h"
#include <atomic>
#include <initializer_list>
#include <vector>

struct RtGuid {
    uint32_t data1;
    uint16_t data2, data3;
    uint8_t data4[8];
    bool operator==(const RtGuid &) const = default;
};
static_assert(sizeof(RtGuid) == 16);
inline constexpr RtGuid RT_IUNKNOWN = {0, 0, 0, {0xc0, 0, 0, 0, 0, 0, 0, 0x46}};
class RtComObject;
struct RtComInterface {
    const uint64_t *vtable;
    RtComObject *object;
    RtGuid iid;
};
struct RtComInterfaceSpec { RtGuid iid; const uint64_t *vtable; };
// IUnknown slots precede these methods. Keep the returned table alive with its interfaces.
std::vector<uint64_t> rt_com_vtable(std::initializer_list<RtEntry> methods);
class RtComObject {
public:
    uint32_t query(const RtGuid &iid, void **out);
    uint32_t add_ref();
    uint32_t release();
    RtComObject(const RtComObject &) = delete;
    RtComObject &operator=(const RtComObject &) = delete;
protected:
    explicit RtComObject(std::initializer_list<RtComInterfaceSpec> interfaces);
    virtual ~RtComObject() = default;
private:
    std::atomic<uint32_t> references{1};
    std::vector<RtComInterface> interfaces;
};
using RtComFactory = RtComObject *(*)();
// Register in-process, non-aggregating classes; factories return one owned reference, or null.
bool rt_com_register_class(const RtGuid &clsid, RtComFactory factory);
#endif
