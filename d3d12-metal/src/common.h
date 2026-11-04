// Private helpers shared by the library's translation units.
#pragma once
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include "d3d12_metal.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <vector>

namespace d3dm {

extern D3DMHost host;

// Reference counting for one single-inheritance interface chain. Every interface of the chain
// shares the object's address, so QueryInterface returns `this` for each accepted IID.
template <class Top> class Object : public Top {
public:
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG left = --refs_;
        if (!left) delete this;
        return left;
    }
    virtual ~Object() = default;

protected:
    template <class... Chain> HRESULT query(REFIID riid, void **out) {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (!((riid == __uuidof(Chain)) || ...)) return E_NOINTERFACE;
        AddRef();
        *out = static_cast<Top *>(this);
        return S_OK;
    }
    std::atomic<ULONG> refs_{1};
};

// Get/SetPrivateData storage with DXGI and D3D12 semantics; interface entries hold a reference.
class PrivateData {
public:
    HRESULT set(REFGUID name, UINT size, const void *data);
    HRESULT set_interface(REFGUID name, const IUnknown *object);
    HRESULT get(REFGUID name, UINT *size, void *data);
    ~PrivateData();

private:
    struct Entry {
        GUID name;
        std::vector<uint8_t> bytes;
        IUnknown *object;
    };
    void erase(REFGUID name);
    std::mutex mutex_;
    std::vector<Entry> entries_;
};

inline HRESULT query_out(IUnknown *object, REFIID riid, void **out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    return object ? object->QueryInterface(riid, out) : E_NOINTERFACE;
}

void copy_name(WCHAR *target, size_t capacity, NSString *name);
double refresh_rate(uint32_t display);
std::vector<D3DMOutputInfo> outputs();

IDXGIAdapter4 *create_adapter(IDXGIFactory *factory, id<MTLDevice> device);
// Null past the last output.
IDXGIOutput6 *create_output(IDXGIAdapter *adapter, UINT index);
HRESULT create_swap_chain(IDXGIFactory *factory, IUnknown *device, HWND window, const DXGI_SWAP_CHAIN_DESC1 *desc,
                          const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *fullscreen, IDXGIOutput *restrict_to,
                          IDXGISwapChain1 **out);
void track_device_errors(IUnknown *queue, id<MTLCommandBuffer> commands);

} // namespace d3dm
