// Win64 DXGI thunks and layout conversion; the graphics library never depends on the guest CPU.
#include "runtime.h"
#include "input.h"
#include "graphics.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include "d3d12_metal.h"
#include "shader_cache.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <mutex>
#include <type_traits>
#include <unordered_map>
#include "device_features.h"

namespace {
struct Bridge {
    const uint64_t *vtable;
    IUnknown *native;
    uint32_t references = 1;
};
std::recursive_mutex bridge_mutex;
std::unordered_map<IUnknown *, Bridge *> bridges;
std::unordered_map<uint64_t, IUnknown *> native_interfaces;

template <class T> T *object(WinCall *call) {
    return static_cast<T *>(((Bridge *)(uintptr_t)rt_arg(call, 0))->native);
}

// Only integer/pointer arguments use this path. UTF-16, COM pointers and aggregate returns are below.
template <class T> T argument(WinCall *call, int index) {
    const uint64_t bits = rt_arg(call, index);
    if constexpr (std::is_reference_v<T>) return *(std::remove_reference_t<T> *)(uintptr_t)bits;
    else if constexpr (std::is_pointer_v<T>) {
        if constexpr (std::is_convertible_v<T, const IUnknown *>) return static_cast<T>((IUnknown *)rt_graphics_native(bits));
        else return (T)(uintptr_t)bits;
    }
    else {
        static_assert(sizeof(T) <= sizeof bits);
        T value;
        if constexpr (std::is_floating_point_v<T>) {
            if (index<4) memcpy(&value,&call->cpu->v[index],sizeof value);
            else memcpy(&value,&bits,sizeof value);
        } else memcpy(&value, &bits, sizeof value);
        return value;
    }
}
template <auto Method> struct Forward;
template <class T, class R, class... Args, R (T::*Method)(Args...)> struct Forward<Method> {
    template <size_t... I> static uint64_t invoke(WinCall *call, std::index_sequence<I...>) {
        if constexpr (std::is_void_v<R>) {
            (object<T>(call)->*Method)(argument<Args>(call, I + 1)...);
            return 0;
        } else {
            const auto value = (object<T>(call)->*Method)(argument<Args>(call, I + 1)...);
            return (uint64_t)value;
        }
    }
    static uint64_t call(WinCall *call) { return invoke(call, std::index_sequence_for<Args...>{}); }
};
template <auto Method, size_t N> void bind(std::array<uint64_t, N> &table, const char *name, ImportHandler handler = Forward<Method>::call) {
    // Apple's arm64 member pointers encode the virtual bit in adjustment and the vtable byte offset separately.
    const auto method = Method;
    struct { ptrdiff_t offset, adjustment; } representation;
    static_assert(sizeof method == sizeof representation);
    memcpy(&representation, &method, sizeof method);
    assert(representation.adjustment == 1 && representation.offset >= 0 && representation.offset % 8 == 0);
    const size_t slot = representation.offset / 8;
    assert(slot < N);
    table[slot] = rt_host_thunk(name, handler);
}

template <class Call> uint64_t returned(WinCall *call, int index, Call invoke) {
    const auto out = (uint64_t *)(uintptr_t)rt_arg(call, index);
    if (!out) return (uint32_t)E_POINTER;
    *out = 0;
    void *native = nullptr;
    const HRESULT hr = invoke(&native);
    if (SUCCEEDED(hr) && native) *out = rt_graphics_wrap(native);
    return (uint32_t)hr;
}
bool native_only_iid(REFIID iid) {
    return iid == __uuidof(ID3DMMetalQueue) || iid == __uuidof(ID3DMMetalTexture) || iid == __uuidof(ID3DMMetalBuffer) ||
        iid == __uuidof(ID3DMMetalHeap) || iid == __uuidof(ID3DMDescriptorHeap) || iid == __uuidof(ID3DMRootSignature) || iid == __uuidof(ID3DMPipeline) || iid == __uuidof(ID3DMDeviceStatus);
}
template<class F> uint64_t created(WinCall *c,int index,F invoke) {
    if (P(index+1)) rt_put<uint64_t>(P(index+1),0);
    if (!P(index)) return (uint32_t)E_INVALIDARG;
    const auto &iid=argument<REFIID>(c,index);
    if (native_only_iid(iid)) return (uint32_t)E_NOINTERFACE;
    auto call=[&](void **out) { return invoke(iid,out); };
    if (!P(index+1)) return (uint32_t)call(nullptr);
    return returned(c,index+1,call);
}
H(QueryInterface) {
    if (!P(1)) return (uint32_t)E_INVALIDARG;
    if (native_only_iid(argument<REFIID>(c, 1))) {
        if (P(2)) rt_put<uint64_t>(P(2), 0);
        return (uint32_t)E_NOINTERFACE;
    }
    return returned(c, 2, [&](void **out) { return object<IUnknown>(c)->QueryInterface(argument<REFIID>(c, 1), out); });
}
H(AddRef) {
    std::lock_guard lock(bridge_mutex);
    auto *bridge = (Bridge *)(uintptr_t)A(0);
    bridge->native->AddRef();
    return ++bridge->references;
}
H(Release) {
    std::lock_guard lock(bridge_mutex);
    auto *bridge = (Bridge *)(uintptr_t)A(0);
    const uint32_t left = --bridge->references;
    IUnknown *native = bridge->native;
    if (!left) { native_interfaces.erase((uintptr_t)bridge); bridges.erase(native); delete bridge; }
    native->Release();
    return left;
}
H(GetParent) {
    return returned(c, 2, [&](void **out) { return object<IDXGIObject>(c)->GetParent(argument<REFIID>(c, 1), out); });
}
H(GetDevice) {
    return returned(c, 2, [&](void **out) { return object<IDXGIDeviceSubObject>(c)->GetDevice(argument<REFIID>(c, 1), out); });
}
H(SetPrivateDataInterface) {
    if (A(2)) return (uint32_t)DXGI_ERROR_UNSUPPORTED; // Guest callbacks cannot be called as native COM methods.
    return (uint32_t)object<IDXGIObject>(c)->SetPrivateDataInterface(argument<REFGUID>(c, 1), nullptr);
}

void copy_wide(const WCHAR *text, size_t capacity, uint8_t *out) {
    NSString *name = [[NSString alloc] initWithBytes:text length:wcsnlen(text, capacity) * sizeof(WCHAR) encoding:NSUTF32LittleEndianStringEncoding];
    memset(out, 0, capacity * 2);
    [name getCharacters:(unichar *)out range:NSMakeRange(0, std::min(capacity - 1, (size_t)name.length))];
}

template <auto Method, class Desc> uint64_t adapter_desc(WinCall *c) {
    if (!P(1)) return (uint32_t)E_INVALIDARG;
    Desc desc = {};
    const HRESULT hr = (object<IDXGIAdapter4>(c)->*Method)(&desc);
    if (FAILED(hr)) return (uint32_t)hr;
    auto *out = (uint8_t *)(uintptr_t)A(1);
    copy_wide(desc.Description, 128, out);
    memcpy(out + 256, (uint8_t *)&desc + sizeof desc.Description, sizeof desc - sizeof desc.Description);
    return S_OK;
}
H(AdapterDesc) { return adapter_desc<&IDXGIAdapter::GetDesc, DXGI_ADAPTER_DESC>(c); }
H(AdapterDesc1) { return adapter_desc<&IDXGIAdapter1::GetDesc1, DXGI_ADAPTER_DESC1>(c); }
H(AdapterDesc2) { return adapter_desc<&IDXGIAdapter2::GetDesc2, DXGI_ADAPTER_DESC2>(c); }
H(AdapterDesc3) { return adapter_desc<&IDXGIAdapter4::GetDesc3, DXGI_ADAPTER_DESC3>(c); }
template <auto Method, class Desc> uint64_t output_desc(WinCall *c) {
    if (!P(1)) return (uint32_t)E_INVALIDARG;
    Desc desc = {};
    const HRESULT hr = (object<IDXGIOutput6>(c)->*Method)(&desc);
    if (FAILED(hr)) return (uint32_t)hr;
    auto *out = (uint8_t *)(uintptr_t)A(1);
    copy_wide(desc.DeviceName, 32, out);
    memcpy(out + 64, (uint8_t *)&desc + sizeof desc.DeviceName, sizeof desc - sizeof desc.DeviceName);
    return S_OK;
}
H(OutputDesc) { return output_desc<&IDXGIOutput::GetDesc, DXGI_OUTPUT_DESC>(c); }
H(OutputDesc1) { return output_desc<&IDXGIOutput6::GetDesc1, DXGI_OUTPUT_DESC1>(c); }
H(EnumAdapters) {
    return returned(c, 2, [&](void **out) { return object<IDXGIFactory>(c)->EnumAdapters(A(1), (IDXGIAdapter **)out); });
}
H(EnumAdapters1) {
    return returned(c, 2, [&](void **out) { return object<IDXGIFactory1>(c)->EnumAdapters1(A(1), (IDXGIAdapter1 **)out); });
}
H(EnumOutputs) {
    return returned(c, 2, [&](void **out) { return object<IDXGIAdapter>(c)->EnumOutputs(A(1), (IDXGIOutput **)out); });
}
H(EnumAdapterByLuid) {
    return returned(c, 3, [&](void **out) { return object<IDXGIFactory4>(c)->EnumAdapterByLuid(argument<LUID>(c, 1), argument<REFIID>(c, 2), out); });
}
H(EnumAdapterByGpuPreference) {
    return returned(c, 4, [&](void **out) { return object<IDXGIFactory6>(c)->EnumAdapterByGpuPreference(A(1), (DXGI_GPU_PREFERENCE)A(2), argument<REFIID>(c, 3), out); });
}
H(CreateSwapChainForHwnd) {
    return returned(c, 6, [&](void **out) { return object<IDXGIFactory2>(c)->CreateSwapChainForHwnd(
        (IUnknown *)rt_graphics_native(A(1)), (HWND)A(2), P(3), P(4), (IDXGIOutput *)rt_graphics_native(A(5)), (IDXGISwapChain1 **)out); });
}
H(CreateSwapChain) {
    return returned(c, 3, [&](void **out) { return object<IDXGIFactory>(c)->CreateSwapChain(
        (IUnknown *)rt_graphics_native(A(1)), P(2), (IDXGISwapChain **)out); });
}
H(GetBuffer) {
    return returned(c, 3, [&](void **out) { return object<IDXGISwapChain>(c)->GetBuffer(A(1), argument<REFIID>(c, 2), out); });
}
H(GetContainingOutput) {
    return returned(c, 1, [&](void **out) { return object<IDXGISwapChain>(c)->GetContainingOutput((IDXGIOutput **)out); });
}
H(GetFullscreenState) {
    if (!P(2)) return (uint32_t)object<IDXGISwapChain>(c)->GetFullscreenState(P(1), nullptr);
    return returned(c, 2, [&](void **out) { return object<IDXGISwapChain>(c)->GetFullscreenState(P(1), (IDXGIOutput **)out); });
}
H(SetFullscreenState) { return (uint32_t)object<IDXGISwapChain>(c)->SetFullscreenState(A(1), (IDXGIOutput *)rt_graphics_native(A(2))); }
H(GetRestrictToOutput) {
    return returned(c, 1, [&](void **out) { return object<IDXGISwapChain1>(c)->GetRestrictToOutput((IDXGIOutput **)out); });
}
H(ResizeBuffers1) {
    const UINT count = (UINT)A(1);
    if (count > DXGI_MAX_SWAP_CHAIN_BUFFERS) return (uint32_t)DXGI_ERROR_INVALID_CALL;
    DXGI_SWAP_CHAIN_DESC1 desc;
    auto *chain = object<IDXGISwapChain3>(c);
    chain->GetDesc1(&desc);
    const UINT actual = count ? count : desc.BufferCount;
    std::array<IUnknown *, DXGI_MAX_SWAP_CHAIN_BUFFERS> queues = {};
    if (P(7)) {
        const auto guest = (const uint64_t *)(uintptr_t)A(7);
        for (UINT i = 0; i < actual; ++i) queues[i] = (IUnknown *)rt_graphics_native(guest[i]);
    }
    return (uint32_t)chain->ResizeBuffers1(count, A(2), A(3), (DXGI_FORMAT)A(4), A(5), P(6), P(7) ? queues.data() : nullptr);
}
H(ResourceDesc) {
    // Win64 returns this 56-byte structure through an extra argument after `this`.
    rt_put<D3D12_RESOURCE_DESC>(P(1), object<ID3D12Resource>(c)->GetDesc());
    return A(1);
}
H(ChildDevice) {
    if (!P(1) || native_only_iid(argument<REFIID>(c, 1))) {
        if (P(2)) rt_put<uint64_t>(P(2), 0);
        if (!P(1)) return (uint32_t)E_INVALIDARG;
        return (uint32_t)E_NOINTERFACE;
    }
    return returned(c, 2, [&](void **out) { return object<ID3D12DeviceChild>(c)->GetDevice(argument<REFIID>(c, 1), out); });
}
H(HeapDesc) {
    rt_put<D3D12_HEAP_DESC>(P(1), object<ID3D12Heap>(c)->GetDesc());
    return A(1);
}
H(DescriptorHeapDesc) {
    rt_put<D3D12_DESCRIPTOR_HEAP_DESC>(P(1), object<ID3D12DescriptorHeap>(c)->GetDesc());
    return A(1);
}
H(CPUDescriptorStart) {
    rt_put<D3D12_CPU_DESCRIPTOR_HANDLE>(P(1), object<ID3D12DescriptorHeap>(c)->GetCPUDescriptorHandleForHeapStart());
    return A(1);
}
H(GPUDescriptorStart) {
    rt_put<D3D12_GPU_DESCRIPTOR_HANDLE>(P(1), object<ID3D12DescriptorHeap>(c)->GetGPUDescriptorHandleForHeapStart());
    return A(1);
}
H(CreateDescriptorHeap) {
    if (!P(2)) return (uint32_t)E_INVALIDARG;
    auto invoke = [&](void **out) { return object<ID3D12Device>(c)->CreateDescriptorHeap(P(1), argument<REFIID>(c, 2), out); };
    if (!P(3)) return (uint32_t)invoke(nullptr);
    return returned(c, 3, invoke);
}
H(ResourceAllocationInfo) {
    rt_put<D3D12_RESOURCE_ALLOCATION_INFO>(P(1), object<ID3D12Device>(c)->GetResourceAllocationInfo(A(2), A(3), P(4)));
    return A(1);
}
H(CustomHeapProperties) {
    rt_put<D3D12_HEAP_PROPERTIES>(P(1), object<ID3D12Device>(c)->GetCustomHeapProperties(A(2), (D3D12_HEAP_TYPE)A(3)));
    return A(1);
}
H(CreateCommittedResource) {
    if (!P(6)) return (uint32_t)E_INVALIDARG;
    auto invoke = [&](void **out) { return object<ID3D12Device>(c)->CreateCommittedResource(
        P(1), (D3D12_HEAP_FLAGS)A(2), P(3), (D3D12_RESOURCE_STATES)A(4), P(5), argument<REFIID>(c, 6), out); };
    if (!P(7)) return (uint32_t)invoke(nullptr);
    return returned(c, 7, invoke);
}
H(CreateHeap) {
    if (!P(2)) return (uint32_t)E_INVALIDARG;
    auto invoke = [&](void **out) { return object<ID3D12Device>(c)->CreateHeap(P(1), argument<REFIID>(c, 2), out); };
    if (!P(3)) return (uint32_t)invoke(nullptr);
    return returned(c, 3, invoke);
}
H(CreateRootSignature) {
    if (!P(4)) {
        if (P(5)) rt_put<uint64_t>(P(5), 0);
        return (uint32_t)E_INVALIDARG;
    }
    if (native_only_iid(argument<REFIID>(c, 4))) {
        if (P(5)) rt_put<uint64_t>(P(5), 0);
        return (uint32_t)E_NOINTERFACE;
    }
    auto invoke = [&](void **out) { return object<ID3D12Device>(c)->CreateRootSignature(A(1), P(2), A(3), argument<REFIID>(c, 4), out); };
    if (!P(5)) return (uint32_t)invoke(nullptr);
    return returned(c, 5, invoke);
}
H(ObjectPrivateDataInterface) {
    if (A(2)) return (uint32_t)DXGI_ERROR_UNSUPPORTED;
    return (uint32_t)object<ID3D12Object>(c)->SetPrivateDataInterface(argument<REFGUID>(c, 1), nullptr);
}
template <class Desc,auto Method> uint64_t create_pipeline(WinCall *c) {
    if (P(3)) rt_put<uint64_t>(P(3),0);
    if (!P(1) || !P(2)) return (uint32_t)E_INVALIDARG;
    if (native_only_iid(argument<REFIID>(c,2))) return (uint32_t)E_NOINTERFACE;
    Desc desc=*(const Desc *)P(1);
    desc.pRootSignature=(ID3D12RootSignature *)rt_graphics_native((uintptr_t)desc.pRootSignature);
    auto invoke=[&](void **out) { return (object<ID3D12Device>(c)->*Method)(&desc,argument<REFIID>(c,2),out); };
    if (!P(3)) return (uint32_t)invoke(nullptr);
    return returned(c,3,invoke);
}
H(CreateGraphicsPipeline) { static_assert(sizeof(D3D12_GRAPHICS_PIPELINE_STATE_DESC)==656);return create_pipeline<D3D12_GRAPHICS_PIPELINE_STATE_DESC,&ID3D12Device::CreateGraphicsPipelineState>(c); }
H(CreateComputePipeline) { return create_pipeline<D3D12_COMPUTE_PIPELINE_STATE_DESC,&ID3D12Device::CreateComputePipelineState>(c); }
H(CreateCommandAllocator) { return created(c,2,[&](REFIID iid,void **out) { return object<ID3D12Device>(c)->CreateCommandAllocator((D3D12_COMMAND_LIST_TYPE)A(1),iid,out); }); }
H(CreateCommandQueue) { return created(c,2,[&](REFIID iid,void **out) { return object<ID3D12Device>(c)->CreateCommandQueue(P(1),iid,out); }); }
H(CreateCommandList) {
    return created(c,5,[&](REFIID iid,void **out)->HRESULT {
        auto *allocator=(ID3D12CommandAllocator *)rt_graphics_native(A(3));auto *initial=(ID3D12PipelineState *)rt_graphics_native(A(4));
        if ((A(3) && !allocator) || (A(4) && !initial)) return E_INVALIDARG;
        return object<ID3D12Device>(c)->CreateCommandList(A(1),(D3D12_COMMAND_LIST_TYPE)A(2),allocator,initial,iid,out);
    });
}
H(CreateFence) { return created(c,3,[&](REFIID iid,void **out) { return object<ID3D12Device>(c)->CreateFence(A(1),(D3D12_FENCE_FLAGS)A(2),iid,out); }); }
H(CreateQueryHeap) { return created(c,2,[&](REFIID iid,void **out) { return object<ID3D12Device>(c)->CreateQueryHeap(P(1),iid,out); }); }
H(CreateCommandSignature) {
    return created(c,3,[&](REFIID iid,void **out)->HRESULT {
        auto *root=(ID3D12RootSignature *)rt_graphics_native(A(2));if (A(2) && !root) return E_INVALIDARG;
        return object<ID3D12Device>(c)->CreateCommandSignature(P(1),root,iid,out);
    });
}
H(QueueDesc) { rt_put<D3D12_COMMAND_QUEUE_DESC>(P(1),object<ID3D12CommandQueue>(c)->GetDesc());return A(1); }
H(QueueClock) {
    if (!P(1) || !P(2)) return (uint32_t)E_POINTER;
    UINT64 gpu=0,cpu=0;const HRESULT hr=object<ID3D12CommandQueue>(c)->GetClockCalibration(&gpu,&cpu);
    // The guest QPC counts 100 ns ticks; native clock calibration returns nanoseconds.
    if (SUCCEEDED(hr)) { rt_put<UINT64>(P(1),gpu);rt_put<UINT64>(P(2),cpu/100); }
    return (uint32_t)hr;
}
H(ExecuteLists) {
    std::vector<ID3D12CommandList *> lists((UINT)A(1));
    if (A(1) && !P(2)) rt_fatal("null command-list array");
    const auto *source=(const uint64_t *)(uintptr_t)A(2);
    for (UINT i=0;i<lists.size();++i) lists[i]=(ID3D12CommandList *)rt_graphics_native(source[i]);
    object<ID3D12CommandQueue>(c)->ExecuteCommandLists(lists.size(),lists.data());return 0;
}
H(SetDescriptorHeaps) {
    if (A(1)>2 || (A(1) && !P(2))) rt_fatal("invalid descriptor-heap array");
    std::array<ID3D12DescriptorHeap *,2> heaps{};const auto *source=(const uint64_t *)(uintptr_t)A(2);
    for (UINT i=0;i<A(1);++i) heaps[i]=(ID3D12DescriptorHeap *)rt_graphics_native(source[i]);
    object<ID3D12GraphicsCommandList>(c)->SetDescriptorHeaps(A(1),heaps.data());return 0;
}
H(CopyTextureRegion) {
    if (!P(1) || !P(5)) rt_fatal("null texture copy location");
    auto dst=*(const D3D12_TEXTURE_COPY_LOCATION *)P(1),src=*(const D3D12_TEXTURE_COPY_LOCATION *)P(5);
    dst.pResource=(ID3D12Resource *)rt_graphics_native((uintptr_t)dst.pResource);src.pResource=(ID3D12Resource *)rt_graphics_native((uintptr_t)src.pResource);
    object<ID3D12GraphicsCommandList>(c)->CopyTextureRegion(&dst,A(2),A(3),A(4),&src,P(6));return 0;
}
H(ResourceBarriers) {
    if (A(1) && !P(2)) rt_fatal("null resource barrier array");
    std::vector<D3D12_RESOURCE_BARRIER> barriers((UINT)A(1));if (A(1)) memcpy(barriers.data(),P(2),barriers.size()*sizeof barriers[0]);
    for (auto &b:barriers) {
        if (b.Type==D3D12_RESOURCE_BARRIER_TYPE_TRANSITION) b.Transition.pResource=(ID3D12Resource *)rt_graphics_native((uintptr_t)b.Transition.pResource);
        if (b.Type==D3D12_RESOURCE_BARRIER_TYPE_UAV) b.UAV.pResource=(ID3D12Resource *)rt_graphics_native((uintptr_t)b.UAV.pResource);
        if (b.Type==D3D12_RESOURCE_BARRIER_TYPE_ALIASING) {
            b.Aliasing.pResourceBefore=(ID3D12Resource *)rt_graphics_native((uintptr_t)b.Aliasing.pResourceBefore);
            b.Aliasing.pResourceAfter=(ID3D12Resource *)rt_graphics_native((uintptr_t)b.Aliasing.pResourceAfter);
        }
    }
    object<ID3D12GraphicsCommandList>(c)->ResourceBarrier(barriers.size(),barriers.data());return 0;
}
std::vector<ID3D12Pageable *> residency_objects(WinCall *c) {
    if (A(1) && !P(2)) return {};
    std::vector<ID3D12Pageable *> objects((UINT)A(1));const auto *values=(const uint64_t *)(uintptr_t)A(2);
    for (UINT i=0;i<objects.size();++i) objects[i]=(ID3D12Pageable *)rt_graphics_native(values[i]);return objects;
}
H(MakeResident) { auto values=residency_objects(c);return (uint32_t)object<ID3D12Device>(c)->MakeResident(A(1),values.empty()?nullptr:values.data()); }
H(Evict) { auto values=residency_objects(c);return (uint32_t)object<ID3D12Device>(c)->Evict(A(1),values.empty()?nullptr:values.data()); }
H(SetResidencyPriority) { auto values=residency_objects(c);return (uint32_t)object<ID3D12Device1>(c)->SetResidencyPriority(A(1),values.empty()?nullptr:values.data(),P(3)); }
H(CreatePlacedResource) {
    if (!P(6)) return (uint32_t)E_INVALIDARG;
    auto invoke = [&](void **out) { return object<ID3D12Device>(c)->CreatePlacedResource(
        (ID3D12Heap *)rt_graphics_native(A(1)), A(2), P(3), (D3D12_RESOURCE_STATES)A(4), P(5), argument<REFIID>(c, 6), out); };
    if (!P(7)) return (uint32_t)invoke(nullptr);
    return returned(c, 7, invoke);
}
H(DeviceLuid) {
    rt_put<LUID>(P(1), object<ID3D12Device>(c)->GetAdapterLuid());
    return A(1);
}
H(ResourceName) {
    const auto wide = (const char16_t *)(uintptr_t)A(1);
    if (!wide) return (uint32_t)object<ID3D12Object>(c)->SetName(nullptr);
    NSString *text = [[NSString alloc] initWithCharacters:(const unichar *)wide length:std::char_traits<char16_t>::length(wide)];
    if (!text) return (uint32_t)E_INVALIDARG;
    NSData *data = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const std::wstring name((const wchar_t *)data.bytes, data.length / sizeof(wchar_t));
    auto *resource = object<ID3D12Object>(c);
    const HRESULT hr = resource->SetName(name.c_str());
    if (FAILED(hr)) return (uint32_t)hr;
    return (uint32_t)resource->SetPrivateData(WKPDID_D3DDebugObjectNameW, (UINT)((std::char_traits<char16_t>::length(wide) + 1) * 2), wide);
}
H(Unsupported) { return (uint32_t)DXGI_ERROR_UNSUPPORTED; }
template <auto Method> uint64_t pending(WinCall *call) { rt_fatal("unimplemented graphics method %s", call->import->name); }

template <size_t N> std::array<uint64_t, N> base_table() {
    std::array<uint64_t, N> table;
    table.fill(rt_host_thunk("graphics.unsupported", Unsupported));
    table[0] = rt_host_thunk("graphics.QueryInterface", QueryInterface);
    table[1] = rt_host_thunk("graphics.AddRef", AddRef);
    table[2] = rt_host_thunk("graphics.Release", Release);
    return table;
}
template <size_t N> void dxgi_base(std::array<uint64_t, N> &table) {
    bind<&IDXGIObject::SetPrivateData>(table, "IDXGIObject.SetPrivateData");
    bind<&IDXGIObject::SetPrivateDataInterface>(table, "IDXGIObject.SetPrivateDataInterface", SetPrivateDataInterface);
    bind<&IDXGIObject::GetPrivateData>(table, "IDXGIObject.GetPrivateData");
    bind<&IDXGIObject::GetParent>(table, "IDXGIObject.GetParent", GetParent);
}
template<size_t N> void d3d_child_base(std::array<uint64_t,N> &table) {
    bind<&ID3D12Object::GetPrivateData>(table,"ID3D12Object.GetPrivateData");
    bind<&ID3D12Object::SetPrivateData>(table,"ID3D12Object.SetPrivateData");
    bind<&ID3D12Object::SetPrivateDataInterface>(table,"ID3D12Object.SetPrivateDataInterface",ObjectPrivateDataInterface);
    bind<&ID3D12Object::SetName>(table,"ID3D12Object.SetName",ResourceName);
    bind<&ID3D12DeviceChild::GetDevice>(table,"ID3D12DeviceChild.GetDevice",ChildDevice);
}
const std::array<uint64_t, 32> &factory_table() {
    static const auto table = [] {
        auto table = base_table<32>();
        dxgi_base(table);
        bind<&IDXGIFactory::EnumAdapters>(table, "IDXGIFactory.EnumAdapters", EnumAdapters);
        bind<&IDXGIFactory::MakeWindowAssociation>(table, "IDXGIFactory.MakeWindowAssociation");
        bind<&IDXGIFactory::GetWindowAssociation>(table, "IDXGIFactory.GetWindowAssociation");
        bind<&IDXGIFactory::CreateSwapChain>(table, "IDXGIFactory.CreateSwapChain", CreateSwapChain);
        bind<&IDXGIFactory1::EnumAdapters1>(table, "IDXGIFactory1.EnumAdapters1", EnumAdapters1);
        bind<&IDXGIFactory1::IsCurrent>(table, "IDXGIFactory1.IsCurrent");
        bind<&IDXGIFactory2::IsWindowedStereoEnabled>(table, "IDXGIFactory2.IsWindowedStereoEnabled");
        bind<&IDXGIFactory2::CreateSwapChainForHwnd>(table, "IDXGIFactory2.CreateSwapChainForHwnd", CreateSwapChainForHwnd);
        bind<&IDXGIFactory2::GetSharedResourceAdapterLuid>(table, "IDXGIFactory2.GetSharedResourceAdapterLuid");
        bind<&IDXGIFactory2::RegisterStereoStatusWindow>(table, "IDXGIFactory2.RegisterStereoStatusWindow");
        bind<&IDXGIFactory2::RegisterStereoStatusEvent>(table, "IDXGIFactory2.RegisterStereoStatusEvent");
        bind<&IDXGIFactory2::UnregisterStereoStatus>(table, "IDXGIFactory2.UnregisterStereoStatus");
        bind<&IDXGIFactory2::RegisterOcclusionStatusWindow>(table, "IDXGIFactory2.RegisterOcclusionStatusWindow");
        bind<&IDXGIFactory2::RegisterOcclusionStatusEvent>(table, "IDXGIFactory2.RegisterOcclusionStatusEvent");
        bind<&IDXGIFactory2::UnregisterOcclusionStatus>(table, "IDXGIFactory2.UnregisterOcclusionStatus");
        bind<&IDXGIFactory3::GetCreationFlags>(table, "IDXGIFactory3.GetCreationFlags");
        bind<&IDXGIFactory4::EnumAdapterByLuid>(table, "IDXGIFactory4.EnumAdapterByLuid", EnumAdapterByLuid);
        bind<&IDXGIFactory5::CheckFeatureSupport>(table, "IDXGIFactory5.CheckFeatureSupport");
        bind<&IDXGIFactory6::EnumAdapterByGpuPreference>(table, "IDXGIFactory6.EnumAdapterByGpuPreference", EnumAdapterByGpuPreference);
        return table;
    }();
    return table;
}

const std::array<uint64_t, 19> &adapter_table() {
    static const auto table = [] {
        auto table = base_table<19>();
        dxgi_base(table);
        bind<&IDXGIAdapter::EnumOutputs>(table, "IDXGIAdapter.EnumOutputs", EnumOutputs);
        bind<&IDXGIAdapter::GetDesc>(table, "IDXGIAdapter.GetDesc", AdapterDesc);
        bind<&IDXGIAdapter::CheckInterfaceSupport>(table, "IDXGIAdapter.CheckInterfaceSupport");
        bind<&IDXGIAdapter1::GetDesc1>(table, "IDXGIAdapter1.GetDesc1", AdapterDesc1);
        bind<&IDXGIAdapter2::GetDesc2>(table, "IDXGIAdapter2.GetDesc2", AdapterDesc2);
        bind<&IDXGIAdapter3::RegisterHardwareContentProtectionTeardownStatusEvent>(table, "IDXGIAdapter3.RegisterHardwareContentProtectionTeardownStatusEvent");
        bind<&IDXGIAdapter3::UnregisterHardwareContentProtectionTeardownStatus>(table, "IDXGIAdapter3.UnregisterHardwareContentProtectionTeardownStatus");
        bind<&IDXGIAdapter3::QueryVideoMemoryInfo>(table, "IDXGIAdapter3.QueryVideoMemoryInfo");
        bind<&IDXGIAdapter3::SetVideoMemoryReservation>(table, "IDXGIAdapter3.SetVideoMemoryReservation");
        bind<&IDXGIAdapter3::RegisterVideoMemoryBudgetChangeNotificationEvent>(table, "IDXGIAdapter3.RegisterVideoMemoryBudgetChangeNotificationEvent");
        bind<&IDXGIAdapter3::UnregisterVideoMemoryBudgetChangeNotification>(table, "IDXGIAdapter3.UnregisterVideoMemoryBudgetChangeNotification");
        bind<&IDXGIAdapter4::GetDesc3>(table, "IDXGIAdapter4.GetDesc3", AdapterDesc3);
        return table;
    }();
    return table;
}

const std::array<uint64_t, 29> &output_table() {
    static const auto table = [] {
        auto table = base_table<29>();
        dxgi_base(table);
        bind<&IDXGIOutput::GetDesc>(table, "IDXGIOutput.GetDesc", OutputDesc);
        bind<&IDXGIOutput::GetDisplayModeList>(table, "IDXGIOutput.GetDisplayModeList");
        bind<&IDXGIOutput::FindClosestMatchingMode>(table, "IDXGIOutput.FindClosestMatchingMode");
        bind<&IDXGIOutput::WaitForVBlank>(table, "IDXGIOutput.WaitForVBlank");
        bind<&IDXGIOutput::ReleaseOwnership>(table, "IDXGIOutput.ReleaseOwnership");
        bind<&IDXGIOutput::GetGammaControlCapabilities>(table, "IDXGIOutput.GetGammaControlCapabilities");
        bind<&IDXGIOutput::SetGammaControl>(table, "IDXGIOutput.SetGammaControl");
        bind<&IDXGIOutput::GetGammaControl>(table, "IDXGIOutput.GetGammaControl");
        bind<&IDXGIOutput::GetFrameStatistics>(table, "IDXGIOutput.GetFrameStatistics");
        bind<&IDXGIOutput1::GetDisplayModeList1>(table, "IDXGIOutput1.GetDisplayModeList1");
        bind<&IDXGIOutput1::FindClosestMatchingMode1>(table, "IDXGIOutput1.FindClosestMatchingMode1");
        bind<&IDXGIOutput2::SupportsOverlays>(table, "IDXGIOutput2.SupportsOverlays");
        bind<&IDXGIOutput6::GetDesc1>(table, "IDXGIOutput6.GetDesc1", OutputDesc1);
        bind<&IDXGIOutput6::CheckHardwareCompositionSupport>(table, "IDXGIOutput6.CheckHardwareCompositionSupport");
        return table;
    }();
    return table;
}

const std::array<uint64_t, 40> &swapchain_table() {
    static const auto table = [] {
        auto table = base_table<40>();
        dxgi_base(table);
        bind<&IDXGIDeviceSubObject::GetDevice>(table, "IDXGIDeviceSubObject.GetDevice", GetDevice);
        bind<&IDXGISwapChain::Present>(table, "IDXGISwapChain.Present");
        bind<&IDXGISwapChain::GetBuffer>(table, "IDXGISwapChain.GetBuffer", GetBuffer);
        bind<&IDXGISwapChain::SetFullscreenState>(table, "IDXGISwapChain.SetFullscreenState", SetFullscreenState);
        bind<&IDXGISwapChain::GetFullscreenState>(table, "IDXGISwapChain.GetFullscreenState", GetFullscreenState);
        bind<&IDXGISwapChain::GetDesc>(table, "IDXGISwapChain.GetDesc");
        bind<&IDXGISwapChain::ResizeBuffers>(table, "IDXGISwapChain.ResizeBuffers");
        bind<&IDXGISwapChain::ResizeTarget>(table, "IDXGISwapChain.ResizeTarget");
        bind<&IDXGISwapChain::GetContainingOutput>(table, "IDXGISwapChain.GetContainingOutput", GetContainingOutput);
        bind<&IDXGISwapChain::GetFrameStatistics>(table, "IDXGISwapChain.GetFrameStatistics");
        bind<&IDXGISwapChain::GetLastPresentCount>(table, "IDXGISwapChain.GetLastPresentCount");
        bind<&IDXGISwapChain1::GetDesc1>(table, "IDXGISwapChain1.GetDesc1");
        bind<&IDXGISwapChain1::GetFullscreenDesc>(table, "IDXGISwapChain1.GetFullscreenDesc");
        bind<&IDXGISwapChain1::GetHwnd>(table, "IDXGISwapChain1.GetHwnd");
        bind<&IDXGISwapChain1::Present1>(table, "IDXGISwapChain1.Present1");
        bind<&IDXGISwapChain1::IsTemporaryMonoSupported>(table, "IDXGISwapChain1.IsTemporaryMonoSupported");
        bind<&IDXGISwapChain1::GetRestrictToOutput>(table, "IDXGISwapChain1.GetRestrictToOutput", GetRestrictToOutput);
        bind<&IDXGISwapChain1::SetBackgroundColor>(table, "IDXGISwapChain1.SetBackgroundColor");
        bind<&IDXGISwapChain1::GetBackgroundColor>(table, "IDXGISwapChain1.GetBackgroundColor");
        bind<&IDXGISwapChain1::SetRotation>(table, "IDXGISwapChain1.SetRotation");
        bind<&IDXGISwapChain1::GetRotation>(table, "IDXGISwapChain1.GetRotation");
        bind<&IDXGISwapChain2::SetSourceSize>(table, "IDXGISwapChain2.SetSourceSize");
        bind<&IDXGISwapChain2::GetSourceSize>(table, "IDXGISwapChain2.GetSourceSize");
        bind<&IDXGISwapChain2::SetMaximumFrameLatency>(table, "IDXGISwapChain2.SetMaximumFrameLatency");
        bind<&IDXGISwapChain2::GetMaximumFrameLatency>(table, "IDXGISwapChain2.GetMaximumFrameLatency");
        bind<&IDXGISwapChain2::GetFrameLatencyWaitableObject>(table, "IDXGISwapChain2.GetFrameLatencyWaitableObject");
        bind<&IDXGISwapChain2::SetMatrixTransform>(table, "IDXGISwapChain2.SetMatrixTransform");
        bind<&IDXGISwapChain2::GetMatrixTransform>(table, "IDXGISwapChain2.GetMatrixTransform");
        bind<&IDXGISwapChain3::GetCurrentBackBufferIndex>(table, "IDXGISwapChain3.GetCurrentBackBufferIndex");
        bind<&IDXGISwapChain3::CheckColorSpaceSupport>(table, "IDXGISwapChain3.CheckColorSpaceSupport");
        bind<&IDXGISwapChain3::SetColorSpace1>(table, "IDXGISwapChain3.SetColorSpace1");
        bind<&IDXGISwapChain3::ResizeBuffers1>(table, "IDXGISwapChain3.ResizeBuffers1", ResizeBuffers1);
        return table;
    }();
    return table;
}

const std::array<uint64_t, 15> &resource_table() {
    static const auto table = [] {
        auto table = base_table<15>();
        bind<&ID3D12Object::GetPrivateData>(table, "ID3D12Object.GetPrivateData");
        bind<&ID3D12Object::SetPrivateData>(table, "ID3D12Object.SetPrivateData");
        bind<&ID3D12Object::SetName>(table, "ID3D12Object.SetName", ResourceName);
        bind<&ID3D12DeviceChild::GetDevice>(table, "ID3D12DeviceChild.GetDevice", ChildDevice);
        bind<&ID3D12Resource::Map>(table, "ID3D12Resource.Map");
        bind<&ID3D12Resource::Unmap>(table, "ID3D12Resource.Unmap");
        bind<&ID3D12Resource::GetDesc>(table, "ID3D12Resource.GetDesc", ResourceDesc);
        bind<&ID3D12Resource::GetGPUVirtualAddress>(table, "ID3D12Resource.GetGPUVirtualAddress");
        bind<&ID3D12Resource::WriteToSubresource>(table, "ID3D12Resource.WriteToSubresource");
        bind<&ID3D12Resource::ReadFromSubresource>(table, "ID3D12Resource.ReadFromSubresource");
        bind<&ID3D12Resource::GetHeapProperties>(table, "ID3D12Resource.GetHeapProperties");
        return table;
    }();
    return table;
}

const std::array<uint64_t, 9> &heap_table() {
    static const auto table = [] {
        auto table = base_table<9>();
        bind<&ID3D12Object::GetPrivateData>(table, "ID3D12Object.GetPrivateData");
        bind<&ID3D12Object::SetPrivateData>(table, "ID3D12Object.SetPrivateData");
        bind<&ID3D12Object::SetName>(table, "ID3D12Object.SetName", ResourceName);
        bind<&ID3D12DeviceChild::GetDevice>(table, "ID3D12DeviceChild.GetDevice", ChildDevice);
        bind<&ID3D12Heap::GetDesc>(table, "ID3D12Heap.GetDesc", HeapDesc);
        return table;
    }();
    return table;
}

const std::array<uint64_t, 11> &descriptor_heap_table() {
    static const auto table = [] {
        auto table = base_table<11>();
        bind<&ID3D12Object::GetPrivateData>(table, "ID3D12Object.GetPrivateData");
        bind<&ID3D12Object::SetPrivateData>(table, "ID3D12Object.SetPrivateData");
        bind<&ID3D12Object::SetName>(table, "ID3D12Object.SetName", ResourceName);
        bind<&ID3D12DeviceChild::GetDevice>(table, "ID3D12DeviceChild.GetDevice", ChildDevice);
        bind<&ID3D12DescriptorHeap::GetDesc>(table, "ID3D12DescriptorHeap.GetDesc", DescriptorHeapDesc);
        bind<&ID3D12DescriptorHeap::GetCPUDescriptorHandleForHeapStart>(table, "ID3D12DescriptorHeap.GetCPUDescriptorHandleForHeapStart", CPUDescriptorStart);
        bind<&ID3D12DescriptorHeap::GetGPUDescriptorHandleForHeapStart>(table, "ID3D12DescriptorHeap.GetGPUDescriptorHandleForHeapStart", GPUDescriptorStart);
        return table;
    }();
    return table;
}

const std::array<uint64_t, 8> &root_signature_table() {
    static const auto table = [] {
        auto table = base_table<8>();
        bind<&ID3D12Object::GetPrivateData>(table, "ID3D12Object.GetPrivateData");
        bind<&ID3D12Object::SetPrivateData>(table, "ID3D12Object.SetPrivateData");
        bind<&ID3D12Object::SetPrivateDataInterface>(table, "ID3D12Object.SetPrivateDataInterface", ObjectPrivateDataInterface);
        bind<&ID3D12Object::SetName>(table, "ID3D12Object.SetName", ResourceName);
        bind<&ID3D12DeviceChild::GetDevice>(table, "ID3D12DeviceChild.GetDevice", ChildDevice);
        return table;
    }();
    return table;
}

const std::array<uint64_t, 3> &unknown_table() {
    static const auto table = [] {
        auto table = base_table<3>();
        return table;
    }();
    return table;
}

const std::array<uint64_t,9> &pipeline_table() {
    static const auto table=[] {
        auto table=base_table<9>();
        bind<&ID3D12Object::GetPrivateData>(table,"ID3D12Object.GetPrivateData");
        bind<&ID3D12Object::SetPrivateData>(table,"ID3D12Object.SetPrivateData");
        bind<&ID3D12Object::SetPrivateDataInterface>(table,"ID3D12Object.SetPrivateDataInterface",ObjectPrivateDataInterface);
        bind<&ID3D12Object::SetName>(table,"ID3D12Object.SetName",ResourceName);
        bind<&ID3D12DeviceChild::GetDevice>(table,"ID3D12DeviceChild.GetDevice",ChildDevice);
        bind<&ID3D12PipelineState::GetCachedBlob>(table,"ID3D12PipelineState.GetCachedBlob",pending<&ID3D12PipelineState::GetCachedBlob>);
        return table;
    }();
    return table;
}

const std::array<uint64_t,9> &allocator_table() {
    static const auto table=[] { auto table=base_table<9>();d3d_child_base(table);bind<&ID3D12CommandAllocator::Reset>(table,"ID3D12CommandAllocator.Reset");return table; }();return table;
}
const std::array<uint64_t,11> &fence_table() {
    static const auto table=[] {
        auto table=base_table<11>();d3d_child_base(table);
        bind<&ID3D12Fence::GetCompletedValue>(table,"ID3D12Fence.GetCompletedValue");
        bind<&ID3D12Fence::SetEventOnCompletion>(table,"ID3D12Fence.SetEventOnCompletion");bind<&ID3D12Fence::Signal>(table,"ID3D12Fence.Signal");return table;
    }();return table;
}
const std::array<uint64_t,19> &queue_table() {
    static const auto table=[] {
        auto table=base_table<19>();d3d_child_base(table);
        bind<&ID3D12CommandQueue::ExecuteCommandLists>(table,"ID3D12CommandQueue.ExecuteCommandLists",ExecuteLists);
        bind<&ID3D12CommandQueue::Signal>(table,"ID3D12CommandQueue.Signal");bind<&ID3D12CommandQueue::Wait>(table,"ID3D12CommandQueue.Wait");
        bind<&ID3D12CommandQueue::GetTimestampFrequency>(table,"ID3D12CommandQueue.GetTimestampFrequency");
        bind<&ID3D12CommandQueue::GetClockCalibration>(table,"ID3D12CommandQueue.GetClockCalibration",QueueClock);bind<&ID3D12CommandQueue::GetDesc>(table,"ID3D12CommandQueue.GetDesc",QueueDesc);
        return table;
    }();return table;
}
const std::array<uint64_t,8> &signature_table() { static const auto table=[] { auto table=base_table<8>();d3d_child_base(table);return table; }();return table; }
const std::array<uint64_t,80> &command_list_table() {
    static const auto table=[] {
        auto table=base_table<80>();d3d_child_base(table);
        bind<&ID3D12CommandList::GetType>(table,"ID3D12CommandList.GetType");
        bind<&ID3D12GraphicsCommandList6::Close>(table,"ID3D12GraphicsCommandList.Close");
        bind<&ID3D12GraphicsCommandList6::Reset>(table,"ID3D12GraphicsCommandList.Reset");
        bind<&ID3D12GraphicsCommandList6::ClearState>(table,"ID3D12GraphicsCommandList.ClearState");
        bind<&ID3D12GraphicsCommandList6::DrawInstanced>(table,"ID3D12GraphicsCommandList.DrawInstanced");
        bind<&ID3D12GraphicsCommandList6::DrawIndexedInstanced>(table,"ID3D12GraphicsCommandList.DrawIndexedInstanced");
        bind<&ID3D12GraphicsCommandList6::Dispatch>(table,"ID3D12GraphicsCommandList.Dispatch");
        bind<&ID3D12GraphicsCommandList6::CopyBufferRegion>(table,"ID3D12GraphicsCommandList.CopyBufferRegion");
        bind<&ID3D12GraphicsCommandList6::CopyTextureRegion>(table,"ID3D12GraphicsCommandList.CopyTextureRegion", CopyTextureRegion);
        bind<&ID3D12GraphicsCommandList6::CopyResource>(table,"ID3D12GraphicsCommandList.CopyResource");
        bind<&ID3D12GraphicsCommandList6::CopyTiles>(table,"ID3D12GraphicsCommandList.CopyTiles");
        bind<&ID3D12GraphicsCommandList6::ResolveSubresource>(table,"ID3D12GraphicsCommandList.ResolveSubresource");
        bind<&ID3D12GraphicsCommandList6::IASetPrimitiveTopology>(table,"ID3D12GraphicsCommandList.IASetPrimitiveTopology");
        bind<&ID3D12GraphicsCommandList6::RSSetViewports>(table,"ID3D12GraphicsCommandList.RSSetViewports");
        bind<&ID3D12GraphicsCommandList6::RSSetScissorRects>(table,"ID3D12GraphicsCommandList.RSSetScissorRects");
        bind<&ID3D12GraphicsCommandList6::OMSetBlendFactor>(table,"ID3D12GraphicsCommandList.OMSetBlendFactor");
        bind<&ID3D12GraphicsCommandList6::OMSetStencilRef>(table,"ID3D12GraphicsCommandList.OMSetStencilRef");
        bind<&ID3D12GraphicsCommandList6::SetPipelineState>(table,"ID3D12GraphicsCommandList.SetPipelineState");
        bind<&ID3D12GraphicsCommandList6::ResourceBarrier>(table,"ID3D12GraphicsCommandList.ResourceBarrier", ResourceBarriers);
        bind<&ID3D12GraphicsCommandList6::ExecuteBundle>(table,"ID3D12GraphicsCommandList.ExecuteBundle");
        bind<&ID3D12GraphicsCommandList6::SetDescriptorHeaps>(table,"ID3D12GraphicsCommandList.SetDescriptorHeaps", SetDescriptorHeaps);
        bind<&ID3D12GraphicsCommandList6::SetComputeRootSignature>(table,"ID3D12GraphicsCommandList.SetComputeRootSignature");
        bind<&ID3D12GraphicsCommandList6::SetGraphicsRootSignature>(table,"ID3D12GraphicsCommandList.SetGraphicsRootSignature");
        bind<&ID3D12GraphicsCommandList6::SetComputeRootDescriptorTable>(table,"ID3D12GraphicsCommandList.SetComputeRootDescriptorTable");
        bind<&ID3D12GraphicsCommandList6::SetGraphicsRootDescriptorTable>(table,"ID3D12GraphicsCommandList.SetGraphicsRootDescriptorTable");
        bind<&ID3D12GraphicsCommandList6::SetComputeRoot32BitConstant>(table,"ID3D12GraphicsCommandList.SetComputeRoot32BitConstant");
        bind<&ID3D12GraphicsCommandList6::SetGraphicsRoot32BitConstant>(table,"ID3D12GraphicsCommandList.SetGraphicsRoot32BitConstant");
        bind<&ID3D12GraphicsCommandList6::SetComputeRoot32BitConstants>(table,"ID3D12GraphicsCommandList.SetComputeRoot32BitConstants");
        bind<&ID3D12GraphicsCommandList6::SetGraphicsRoot32BitConstants>(table,"ID3D12GraphicsCommandList.SetGraphicsRoot32BitConstants");
        bind<&ID3D12GraphicsCommandList6::SetComputeRootConstantBufferView>(table,"ID3D12GraphicsCommandList.SetComputeRootConstantBufferView");
        bind<&ID3D12GraphicsCommandList6::SetGraphicsRootConstantBufferView>(table,"ID3D12GraphicsCommandList.SetGraphicsRootConstantBufferView");
        bind<&ID3D12GraphicsCommandList6::SetComputeRootShaderResourceView>(table,"ID3D12GraphicsCommandList.SetComputeRootShaderResourceView");
        bind<&ID3D12GraphicsCommandList6::SetGraphicsRootShaderResourceView>(table,"ID3D12GraphicsCommandList.SetGraphicsRootShaderResourceView");
        bind<&ID3D12GraphicsCommandList6::SetComputeRootUnorderedAccessView>(table,"ID3D12GraphicsCommandList.SetComputeRootUnorderedAccessView");
        bind<&ID3D12GraphicsCommandList6::SetGraphicsRootUnorderedAccessView>(table,"ID3D12GraphicsCommandList.SetGraphicsRootUnorderedAccessView");
        bind<&ID3D12GraphicsCommandList6::IASetIndexBuffer>(table,"ID3D12GraphicsCommandList.IASetIndexBuffer");
        bind<&ID3D12GraphicsCommandList6::IASetVertexBuffers>(table,"ID3D12GraphicsCommandList.IASetVertexBuffers");
        bind<&ID3D12GraphicsCommandList6::SOSetTargets>(table,"ID3D12GraphicsCommandList.SOSetTargets");
        bind<&ID3D12GraphicsCommandList6::OMSetRenderTargets>(table,"ID3D12GraphicsCommandList.OMSetRenderTargets");
        bind<&ID3D12GraphicsCommandList6::ClearDepthStencilView>(table,"ID3D12GraphicsCommandList.ClearDepthStencilView");
        bind<&ID3D12GraphicsCommandList6::ClearRenderTargetView>(table,"ID3D12GraphicsCommandList.ClearRenderTargetView");
        bind<&ID3D12GraphicsCommandList6::ClearUnorderedAccessViewUint>(table,"ID3D12GraphicsCommandList.ClearUnorderedAccessViewUint");
        bind<&ID3D12GraphicsCommandList6::ClearUnorderedAccessViewFloat>(table,"ID3D12GraphicsCommandList.ClearUnorderedAccessViewFloat");
        bind<&ID3D12GraphicsCommandList6::DiscardResource>(table,"ID3D12GraphicsCommandList.DiscardResource");
        bind<&ID3D12GraphicsCommandList6::BeginQuery>(table,"ID3D12GraphicsCommandList.BeginQuery");
        bind<&ID3D12GraphicsCommandList6::EndQuery>(table,"ID3D12GraphicsCommandList.EndQuery");
        bind<&ID3D12GraphicsCommandList6::ResolveQueryData>(table,"ID3D12GraphicsCommandList.ResolveQueryData");
        bind<&ID3D12GraphicsCommandList6::SetPredication>(table,"ID3D12GraphicsCommandList.SetPredication");
        bind<&ID3D12GraphicsCommandList6::SetMarker>(table,"ID3D12GraphicsCommandList.SetMarker");
        bind<&ID3D12GraphicsCommandList6::BeginEvent>(table,"ID3D12GraphicsCommandList.BeginEvent");
        bind<&ID3D12GraphicsCommandList6::EndEvent>(table,"ID3D12GraphicsCommandList.EndEvent");
        bind<&ID3D12GraphicsCommandList6::ExecuteIndirect>(table,"ID3D12GraphicsCommandList.ExecuteIndirect");
        bind<&ID3D12GraphicsCommandList6::AtomicCopyBufferUINT>(table,"ID3D12GraphicsCommandList.AtomicCopyBufferUINT");
        bind<&ID3D12GraphicsCommandList6::AtomicCopyBufferUINT64>(table,"ID3D12GraphicsCommandList.AtomicCopyBufferUINT64");
        bind<&ID3D12GraphicsCommandList6::OMSetDepthBounds>(table,"ID3D12GraphicsCommandList.OMSetDepthBounds");
        bind<&ID3D12GraphicsCommandList6::SetSamplePositions>(table,"ID3D12GraphicsCommandList.SetSamplePositions");
        bind<&ID3D12GraphicsCommandList6::ResolveSubresourceRegion>(table,"ID3D12GraphicsCommandList.ResolveSubresourceRegion");
        bind<&ID3D12GraphicsCommandList6::SetViewInstanceMask>(table,"ID3D12GraphicsCommandList.SetViewInstanceMask");
        bind<&ID3D12GraphicsCommandList6::WriteBufferImmediate>(table,"ID3D12GraphicsCommandList.WriteBufferImmediate");
        bind<&ID3D12GraphicsCommandList6::SetProtectedResourceSession>(table,"ID3D12GraphicsCommandList.SetProtectedResourceSession");
        bind<&ID3D12GraphicsCommandList6::BeginRenderPass>(table,"ID3D12GraphicsCommandList.BeginRenderPass");
        bind<&ID3D12GraphicsCommandList6::EndRenderPass>(table,"ID3D12GraphicsCommandList.EndRenderPass");
        bind<&ID3D12GraphicsCommandList6::InitializeMetaCommand>(table,"ID3D12GraphicsCommandList.InitializeMetaCommand");
        bind<&ID3D12GraphicsCommandList6::ExecuteMetaCommand>(table,"ID3D12GraphicsCommandList.ExecuteMetaCommand");
        bind<&ID3D12GraphicsCommandList6::BuildRaytracingAccelerationStructure>(table,"ID3D12GraphicsCommandList.BuildRaytracingAccelerationStructure");
        bind<&ID3D12GraphicsCommandList6::EmitRaytracingAccelerationStructurePostbuildInfo>(table,"ID3D12GraphicsCommandList.EmitRaytracingAccelerationStructurePostbuildInfo");
        bind<&ID3D12GraphicsCommandList6::CopyRaytracingAccelerationStructure>(table,"ID3D12GraphicsCommandList.CopyRaytracingAccelerationStructure");
        bind<&ID3D12GraphicsCommandList6::SetPipelineState1>(table,"ID3D12GraphicsCommandList.SetPipelineState1");
        bind<&ID3D12GraphicsCommandList6::DispatchRays>(table,"ID3D12GraphicsCommandList.DispatchRays");
        bind<&ID3D12GraphicsCommandList6::RSSetShadingRate>(table,"ID3D12GraphicsCommandList.RSSetShadingRate");
        bind<&ID3D12GraphicsCommandList6::RSSetShadingRateImage>(table,"ID3D12GraphicsCommandList.RSSetShadingRateImage");
        bind<&ID3D12GraphicsCommandList6::DispatchMesh>(table,"ID3D12GraphicsCommandList.DispatchMesh");
        return table;
    }();return table;
}
const std::array<uint64_t, 48> &device_table() {
    static const auto table = [] {
        auto table = base_table<48>();
        bind<&ID3D12Object::GetPrivateData>(table, "ID3D12Object.GetPrivateData");
        bind<&ID3D12Object::SetPrivateData>(table, "ID3D12Object.SetPrivateData");
        bind<&ID3D12Object::SetName>(table, "ID3D12Object.SetName", ResourceName);
        bind<&ID3D12Device::GetNodeCount>(table, "ID3D12Device.GetNodeCount");
        bind<&ID3D12Device::CreateCommandQueue>(table, "ID3D12Device.CreateCommandQueue", CreateCommandQueue);
        bind<&ID3D12Device::CreateCommandAllocator>(table, "ID3D12Device.CreateCommandAllocator", CreateCommandAllocator);
        bind<&ID3D12Device::CreateGraphicsPipelineState>(table, "ID3D12Device.CreateGraphicsPipelineState",CreateGraphicsPipeline);
        bind<&ID3D12Device::CreateComputePipelineState>(table, "ID3D12Device.CreateComputePipelineState",CreateComputePipeline);
        bind<&ID3D12Device::CreateCommandList>(table, "ID3D12Device.CreateCommandList", CreateCommandList);
        bind<&ID3D12Device::CheckFeatureSupport>(table, "ID3D12Device.CheckFeatureSupport");
        bind<&ID3D12Device::CreateDescriptorHeap>(table, "ID3D12Device.CreateDescriptorHeap", CreateDescriptorHeap);
        bind<&ID3D12Device::GetDescriptorHandleIncrementSize>(table, "ID3D12Device.GetDescriptorHandleIncrementSize");
        bind<&ID3D12Device::CreateRootSignature>(table, "ID3D12Device.CreateRootSignature", CreateRootSignature);
        bind<&ID3D12Device::CreateConstantBufferView>(table, "ID3D12Device.CreateConstantBufferView");
        bind<&ID3D12Device::CreateShaderResourceView>(table, "ID3D12Device.CreateShaderResourceView");
        bind<&ID3D12Device::CreateUnorderedAccessView>(table, "ID3D12Device.CreateUnorderedAccessView");
        bind<&ID3D12Device::CreateRenderTargetView>(table, "ID3D12Device.CreateRenderTargetView");
        bind<&ID3D12Device::CreateDepthStencilView>(table, "ID3D12Device.CreateDepthStencilView");
        bind<&ID3D12Device::CreateSampler>(table, "ID3D12Device.CreateSampler");
        bind<&ID3D12Device::CopyDescriptors>(table, "ID3D12Device.CopyDescriptors");
        bind<&ID3D12Device::CopyDescriptorsSimple>(table, "ID3D12Device.CopyDescriptorsSimple");
        bind<&ID3D12Device::GetResourceAllocationInfo>(table, "ID3D12Device.GetResourceAllocationInfo", ResourceAllocationInfo);
        bind<&ID3D12Device::GetCustomHeapProperties>(table, "ID3D12Device.GetCustomHeapProperties", CustomHeapProperties);
        bind<&ID3D12Device::CreateCommittedResource>(table, "ID3D12Device.CreateCommittedResource", CreateCommittedResource);
        bind<&ID3D12Device::CreateHeap>(table, "ID3D12Device.CreateHeap", CreateHeap);
        bind<&ID3D12Device::CreatePlacedResource>(table, "ID3D12Device.CreatePlacedResource", CreatePlacedResource);
        bind<&ID3D12Device::CreateReservedResource>(table, "ID3D12Device.CreateReservedResource", pending<&ID3D12Device::CreateReservedResource>);
        bind<&ID3D12Device::CreateSharedHandle>(table, "ID3D12Device.CreateSharedHandle", pending<&ID3D12Device::CreateSharedHandle>);
        bind<&ID3D12Device::OpenSharedHandle>(table, "ID3D12Device.OpenSharedHandle", pending<&ID3D12Device::OpenSharedHandle>);
        bind<&ID3D12Device::OpenSharedHandleByName>(table, "ID3D12Device.OpenSharedHandleByName", pending<&ID3D12Device::OpenSharedHandleByName>);
        bind<&ID3D12Device::MakeResident>(table, "ID3D12Device.MakeResident", MakeResident);
        bind<&ID3D12Device::Evict>(table, "ID3D12Device.Evict", Evict);
        bind<&ID3D12Device::CreateFence>(table, "ID3D12Device.CreateFence", CreateFence);
        bind<&ID3D12Device::GetDeviceRemovedReason>(table, "ID3D12Device.GetDeviceRemovedReason");
        bind<&ID3D12Device::GetCopyableFootprints>(table, "ID3D12Device.GetCopyableFootprints");
        bind<&ID3D12Device::CreateQueryHeap>(table, "ID3D12Device.CreateQueryHeap", CreateQueryHeap);
        bind<&ID3D12Device::SetStablePowerState>(table, "ID3D12Device.SetStablePowerState", pending<&ID3D12Device::SetStablePowerState>);
        bind<&ID3D12Device::CreateCommandSignature>(table, "ID3D12Device.CreateCommandSignature", CreateCommandSignature);
        bind<&ID3D12Device::GetResourceTiling>(table, "ID3D12Device.GetResourceTiling", pending<&ID3D12Device::GetResourceTiling>);
        bind<&ID3D12Device::GetAdapterLuid>(table, "ID3D12Device.GetAdapterLuid", DeviceLuid);
        bind<&ID3D12Device1::CreatePipelineLibrary>(table, "ID3D12Device1.CreatePipelineLibrary", pending<&ID3D12Device1::CreatePipelineLibrary>);
        bind<&ID3D12Device1::SetEventOnMultipleFenceCompletion>(table, "ID3D12Device1.SetEventOnMultipleFenceCompletion", pending<&ID3D12Device1::SetEventOnMultipleFenceCompletion>);
        bind<&ID3D12Device1::SetResidencyPriority>(table, "ID3D12Device1.SetResidencyPriority", SetResidencyPriority);
        bind<&ID3D12Device2::CreatePipelineState>(table, "ID3D12Device2.CreatePipelineState", pending<&ID3D12Device2::CreatePipelineState>);
        return table;
    }();
    return table;
}


bool supports(IUnknown *object, REFIID iid) {
    IUnknown *found = nullptr;
    if (FAILED(object->QueryInterface(iid, (void **)&found))) return false;
    found->Release();
    return true;
}

void initialize() {
    static std::once_flag once;
    std::call_once(once, [] {
        const char *pacing = getenv("SS_FRAME_PACING");
        const bool smooth = pacing && !strcmp(pacing, "30");
        const D3DMHost hooks = {
            [](HWND window) -> void * { return (__bridge void *)rt_window_native((uintptr_t)window).contentView.layer; },
            [](D3DMOutputInfo *list, UINT capacity) -> UINT {
                CGDirectDisplayID ids[32]; uint32_t count = 0;
                CGGetActiveDisplayList(32, ids, &count);
                std::stable_partition(ids, ids + count, [](auto id) { return id == CGMainDisplayID(); });
                UINT written = 0;
                for (uint32_t i = 0; i < count; ++i) {
                    if (CGDisplayMirrorsDisplay(ids[i]) != kCGNullDirectDisplay) continue;
                    if (written < capacity) {
                        const CGRect r = CGDisplayBounds(ids[i]);
                        const double top = CGDisplayBounds(CGMainDisplayID()).size.height;
                        const auto desktop = rt_desktop_rect(NSMakeRect(r.origin.x, top - CGRectGetMaxY(r), r.size.width, r.size.height));
                        list[written] = {ids[i], (HMONITOR)(UINT64_C(0x100000000) | ids[i]), {desktop.left, desktop.top, desktop.right, desktop.bottom}};
                    }
                    ++written;
                }
                return written;
            },
            [](LONG initial, LONG maximum) -> HANDLE { return (HANDLE)rt_semaphore_create(initial, maximum); },
            [](HANDLE handle, LONG count) { rt_semaphore_release((uintptr_t)handle, count); },
            [](HANDLE handle) -> HANDLE { const auto object = rt_object((uintptr_t)handle); return object ? (HANDLE)rt_new_handle(object) : nullptr; },
            [](HANDLE handle) { rt_close_handle((uintptr_t)handle); },
            [](HANDLE handle) { return rt_semaphore_try_wait((uintptr_t)handle); },
            [](HWND window) -> HMONITOR {
                NSScreen *screen = rt_window_native((uintptr_t)window).screen;
                if (!screen) return nullptr;
                return (HMONITOR)(UINT64_C(0x100000000) | [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
            },
            [](HWND window, WINBOOL fullscreen, HMONITOR monitor) -> HRESULT {
                return rt_window_fullscreen((uintptr_t)window, fullscreen != 0, (uint32_t)(uintptr_t)monitor) ? S_OK : DXGI_ERROR_NOT_CURRENTLY_AVAILABLE;
            }, device_feature, rt_load_shader,
            [](HANDLE handle)->HANDLE {
                auto event=rt_object((uintptr_t)handle);
                if (!event || event->kind!=Kind::Event) return nullptr;
                return (HANDLE)rt_new_handle(std::move(event));
            },
            [](HANDLE handle) { rt_signal_event((uintptr_t)handle); }, rt_pipeline_archive_path(), rt_spatial_upscale_source,
            smooth ? 1.0 / 30 : 0};
        D3DMSetHost(&hooks);
        printf("graphics: native 30 FPS pacing %s\n", smooth ? "enabled" : "disabled");
    });
}
H(CreateDXGIFactory2) {
    initialize();
    if (!P(1)) return (uint32_t)E_INVALIDARG;
    return returned(c, 2, [&](void **out) { return D3DMCreateDXGIFactory2(A(0), argument<REFIID>(c, 1), out); });
}
H(D3D12CreateDevice) {
    initialize();
    if (!P(2)) return (uint32_t)E_INVALIDARG;
    auto *adapter = (IUnknown *)rt_graphics_native(A(0));
    if (A(0) && !adapter) return (uint32_t)E_INVALIDARG;
    if (!P(3)) return (uint32_t)D3DMCreateDevice(adapter, (D3D_FEATURE_LEVEL)A(1), argument<REFIID>(c, 2), nullptr);
    return returned(c, 3, [&](void **out) { return D3DMCreateDevice(adapter, (D3D_FEATURE_LEVEL)A(1), argument<REFIID>(c, 2), out); });
}
}

uint64_t rt_graphics_wrap(void *owned_interface) {
    if (!owned_interface) return 0;
    auto *native = (IUnknown *)owned_interface;
    std::lock_guard lock(bridge_mutex);
    if (const auto found = bridges.find(native); found != bridges.end()) {
        ++found->second->references;
        return (uintptr_t)found->second;
    }
    const uint64_t *table = nullptr;
    if (supports(native, __uuidof(IDXGIFactory6))) table = factory_table().data();
    else if (supports(native, __uuidof(IDXGIAdapter4))) table = adapter_table().data();
    else if (supports(native, __uuidof(IDXGIOutput6))) table = output_table().data();
    else if (supports(native, __uuidof(IDXGISwapChain3))) table = swapchain_table().data();
    else if (supports(native, __uuidof(ID3D12Resource))) table = resource_table().data();
    else if (supports(native, __uuidof(ID3D12Heap))) table = heap_table().data();
    else if (supports(native, __uuidof(ID3D12DescriptorHeap))) table = descriptor_heap_table().data();
    else if (supports(native, __uuidof(ID3D12RootSignature))) table = root_signature_table().data();
    else if (supports(native, __uuidof(ID3D12PipelineState))) table = pipeline_table().data();
    else if (supports(native,__uuidof(ID3D12GraphicsCommandList6))) table=command_list_table().data();
    else if (supports(native,__uuidof(ID3D12CommandAllocator))) table=allocator_table().data();
    else if (supports(native,__uuidof(ID3D12CommandQueue))) table=queue_table().data();
    else if (supports(native,__uuidof(ID3D12Fence))) table=fence_table().data();
    else if (supports(native,__uuidof(ID3D12CommandSignature))) table=signature_table().data();
    else if (supports(native,__uuidof(ID3D12QueryHeap))) table=signature_table().data();
    else if (supports(native, __uuidof(ID3D12Device2))) table = device_table().data();
    else table = unknown_table().data();
    auto *bridge = new Bridge{table, native};
    bridges.emplace(native, bridge);
    native_interfaces.emplace((uintptr_t)bridge, native);
    return (uintptr_t)bridge;
}
void *rt_graphics_native(uint64_t guest_interface) {
    if (!guest_interface) return nullptr;
    std::lock_guard lock(bridge_mutex);
    const auto found = native_interfaces.find(guest_interface);
    return found == native_interfaces.end() ? nullptr : found->second;
}
const RtEntry rt_graphics_entries[] = {{"CreateDXGIFactory2", CreateDXGIFactory2}, {"D3D12CreateDevice", D3D12CreateDevice}, {nullptr, nullptr}};
void rt_graphics_before_exit() { D3DMFlushPipelineArchive(); }
