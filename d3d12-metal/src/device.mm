#include "common.h"
#include "resources.h"
#include "descriptors.h"
#include "root_signature.h"
#include "pipeline.h"
#include "commands.h"
#include "utility.h"
#include <cstdlib>
#include <map>

namespace d3dm {
namespace {
class Device;
std::recursive_mutex device_mutex;
std::map<uint64_t, Device *> devices;

class Device final : public Object<ID3D12Device2>, public ID3DMDeviceStatus {
public:
    explicit Device(id<MTLDevice> metal) : metal_(metal) {
        for (NSString *name in @[@"mask_indirect",@"fill_pattern",@"clear_2d",@"clear_3d",@"clear_buffer"]) utility_compute(metal,name);
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (out && iid == __uuidof(ID3DMDeviceStatus)) {
            AddRef(); *out = static_cast<ID3DMDeviceStatus *>(this); return S_OK;
        }
        return query<IUnknown, ID3D12Object, ID3D12Device, ID3D12Device1, ID3D12Device2>(iid, out);
    }
    ULONG STDMETHODCALLTYPE AddRef() override {
        std::lock_guard lock(device_mutex);
        return ++refs_;
    }
    ULONG STDMETHODCALLTYPE Release() override {
        std::lock_guard lock(device_mutex);
        const ULONG remaining = --refs_;
        if (!remaining) { devices.erase(metal_.registryID); delete this; }
        return remaining;
    }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID name, UINT *size, void *data) override { return data_.get(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID name, UINT size, const void *data) override { return data_.set(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID name, const IUnknown *object) override { return data_.set_interface(name, object); }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR name) override {
        return data_.set(WKPDID_D3DDebugObjectNameW, name ? (UINT)((wcslen(name) + 1) * sizeof(WCHAR)) : 0, name);
    }
    UINT STDMETHODCALLTYPE GetNodeCount() override { return 1; }
    HRESULT STDMETHODCALLTYPE CheckFeatureSupport(D3D12_FEATURE feature, void *data, UINT size) override {
        const HRESULT reason = removed_.load();
        if (FAILED(reason)) return reason;
        if (!data || !size) return E_INVALIDARG;
        return host.check_feature ? host.check_feature(feature, data, size) : E_INVALIDARG;
    }
    UINT STDMETHODCALLTYPE GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE type) override {
        return descriptor_stride(type);
    }
    HRESULT STDMETHODCALLTYPE GetDeviceRemovedReason() override { return removed_.load(); }
    LUID STDMETHODCALLTYPE GetAdapterLuid() override { return {(ULONG)metal_.registryID, (LONG)(metal_.registryID >> 32)}; }
    void STDMETHODCALLTYPE RecordError(HRESULT reason) override {
        if (SUCCEEDED(reason)) return;
        HRESULT expected = S_OK;
        if (removed_.compare_exchange_strong(expected, reason)) signal_removed_fences(this);
    }
    HRESULT STDMETHODCALLTYPE CreatePipelineState(const D3D12_PIPELINE_STATE_STREAM_DESC *, REFIID, void **out) override {
        if (out) *out = nullptr;
        return unavailable();
    }
    HRESULT STDMETHODCALLTYPE CreateCommandQueue(const D3D12_COMMAND_QUEUE_DESC *desc,REFIID iid,void **out) override {
        if (out) *out=nullptr;const HRESULT reason=removed_.load();if (FAILED(reason)) return reason;
        @autoreleasepool { return create_command_queue(this,metal_,desc,iid,out); }
    }
    HRESULT STDMETHODCALLTYPE CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE type,REFIID iid,void **out) override {
        if (out) *out=nullptr;const HRESULT reason=removed_.load();if (FAILED(reason)) return reason;
        return create_command_allocator(this,type,iid,out);
    }
    HRESULT STDMETHODCALLTYPE CreateGraphicsPipelineState(const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc, REFIID iid, void **out) override {
        if (out) *out=nullptr; const HRESULT reason=removed_.load(); if (FAILED(reason)) return reason;
        @autoreleasepool { return create_graphics_pipeline(this,metal_,desc,iid,out); }
    }
    HRESULT STDMETHODCALLTYPE CreateComputePipelineState(const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc, REFIID iid, void **out) override {
        if (out) *out=nullptr; const HRESULT reason=removed_.load(); if (FAILED(reason)) return reason;
        @autoreleasepool { return create_compute_pipeline(this,metal_,desc,iid,out); }
    }
    HRESULT STDMETHODCALLTYPE CreateCommandList(UINT node,D3D12_COMMAND_LIST_TYPE type,ID3D12CommandAllocator *allocator,ID3D12PipelineState *initial,REFIID iid,void **out) override {
        if (out) *out=nullptr;const HRESULT reason=removed_.load();if (FAILED(reason)) return reason;
        @autoreleasepool { return create_command_list(this,metal_,node,type,allocator,initial,iid,out); }
    }
    HRESULT STDMETHODCALLTYPE CreateDescriptorHeap(const D3D12_DESCRIPTOR_HEAP_DESC *pDescriptorHeapDesc, const IID & riid, void **ppvHeap) override {
        if (ppvHeap) *ppvHeap = nullptr; const HRESULT reason = removed_.load(); if (FAILED(reason)) return reason; @autoreleasepool { return create_descriptor_heap(this, metal_, pDescriptorHeapDesc, riid, ppvHeap); }
    }
    HRESULT STDMETHODCALLTYPE CreateRootSignature(UINT nodeMask, const void *blob, SIZE_T size, REFIID iid, void **out) override {
        if (out) *out = nullptr;
        const HRESULT reason = removed_.load();
        if (FAILED(reason)) return reason;
        @autoreleasepool { return create_root_signature(this, metal_, nodeMask, blob, size, iid, out); }
    }
    void STDMETHODCALLTYPE CreateConstantBufferView(const D3D12_CONSTANT_BUFFER_VIEW_DESC *pDesc, D3D12_CPU_DESCRIPTOR_HANDLE DestDescriptor) override {
        @autoreleasepool { create_cbv(this, pDesc, DestDescriptor); }
    }
    void STDMETHODCALLTYPE CreateShaderResourceView(ID3D12Resource *pResource, const D3D12_SHADER_RESOURCE_VIEW_DESC *pDesc, D3D12_CPU_DESCRIPTOR_HANDLE DestDescriptor) override {
        @autoreleasepool { create_srv(this, pResource, pDesc, DestDescriptor); }
    }
    void STDMETHODCALLTYPE CreateUnorderedAccessView(ID3D12Resource *pResource, ID3D12Resource *pCounterResource, const D3D12_UNORDERED_ACCESS_VIEW_DESC *pDesc, D3D12_CPU_DESCRIPTOR_HANDLE DestDescriptor) override {
        @autoreleasepool { create_uav(this, pResource, pCounterResource, pDesc, DestDescriptor); }
    }
    void STDMETHODCALLTYPE CreateRenderTargetView(ID3D12Resource *pResource, const D3D12_RENDER_TARGET_VIEW_DESC *pDesc, D3D12_CPU_DESCRIPTOR_HANDLE DestDescriptor) override {
        @autoreleasepool { create_rtv(this, pResource, pDesc, DestDescriptor); }
    }
    void STDMETHODCALLTYPE CreateDepthStencilView(ID3D12Resource *pResource, const D3D12_DEPTH_STENCIL_VIEW_DESC *pDesc, D3D12_CPU_DESCRIPTOR_HANDLE DestDescriptor) override {
        @autoreleasepool { create_dsv(this, pResource, pDesc, DestDescriptor); }
    }
    void STDMETHODCALLTYPE CreateSampler(const D3D12_SAMPLER_DESC *pDesc, D3D12_CPU_DESCRIPTOR_HANDLE DestDescriptor) override {
        @autoreleasepool { create_sampler(this, metal_, pDesc, DestDescriptor); }
    }
    void STDMETHODCALLTYPE CopyDescriptors(UINT NumDestDescriptorRanges, const D3D12_CPU_DESCRIPTOR_HANDLE *pDestDescriptorRangeStarts, const UINT *pDestDescriptorRangeSizes, UINT NumSrcDescriptorRanges, const D3D12_CPU_DESCRIPTOR_HANDLE *pSrcDescriptorRangeStarts, const UINT *pSrcDescriptorRangeSizes, D3D12_DESCRIPTOR_HEAP_TYPE DescriptorHeapsType) override {
        @autoreleasepool { copy_descriptors(this, NumDestDescriptorRanges, pDestDescriptorRangeStarts, pDestDescriptorRangeSizes, NumSrcDescriptorRanges, pSrcDescriptorRangeStarts, pSrcDescriptorRangeSizes, DescriptorHeapsType); }
    }
    void STDMETHODCALLTYPE CopyDescriptorsSimple(UINT NumDescriptors, D3D12_CPU_DESCRIPTOR_HANDLE DestDescriptorRangeStart, D3D12_CPU_DESCRIPTOR_HANDLE SrcDescriptorRangeStart, D3D12_DESCRIPTOR_HEAP_TYPE DescriptorHeapsType) override {
        @autoreleasepool { copy_descriptors(this, 1, &DestDescriptorRangeStart, &NumDescriptors, 1, &SrcDescriptorRangeStart, &NumDescriptors, DescriptorHeapsType); }
    }
    D3D12_RESOURCE_ALLOCATION_INFO STDMETHODCALLTYPE GetResourceAllocationInfo(UINT mask, UINT count, const D3D12_RESOURCE_DESC *descs) override {
        @autoreleasepool { return allocation_info(metal_, mask, count, descs); }
    }
    D3D12_HEAP_PROPERTIES STDMETHODCALLTYPE GetCustomHeapProperties(UINT node, D3D12_HEAP_TYPE type) override {
        return custom_heap_properties(node, type);
    }
    HRESULT STDMETHODCALLTYPE CreateCommittedResource(const D3D12_HEAP_PROPERTIES *properties, D3D12_HEAP_FLAGS flags,
        const D3D12_RESOURCE_DESC *desc, D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE *clear, REFIID iid, void **out) override {
        if (out) *out = nullptr;
        const HRESULT reason = removed_.load();
        if (FAILED(reason)) return reason;
        @autoreleasepool { return create_committed_resource(this, metal_, properties, flags, desc, state, clear, iid, out); }
    }
    HRESULT STDMETHODCALLTYPE CreateHeap(const D3D12_HEAP_DESC *desc, REFIID iid, void **out) override {
        if (out) *out = nullptr;
        const HRESULT reason = removed_.load();
        if (FAILED(reason)) return reason;
        @autoreleasepool { return create_heap(this, metal_, desc, iid, out); }
    }
    HRESULT STDMETHODCALLTYPE CreatePlacedResource(ID3D12Heap *heap, UINT64 offset, const D3D12_RESOURCE_DESC *desc,
        D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE *clear, REFIID iid, void **out) override {
        if (out) *out = nullptr;
        const HRESULT reason = removed_.load();
        if (FAILED(reason)) return reason;
        @autoreleasepool { return create_placed_resource(this, metal_, heap, offset, desc, state, clear, iid, out); }
    }
    HRESULT STDMETHODCALLTYPE CreateReservedResource(const D3D12_RESOURCE_DESC *pDesc, D3D12_RESOURCE_STATES InitialState, const D3D12_CLEAR_VALUE *pOptimizedClearValue, const IID & riid, void **ppvResource) override { if (ppvResource) *ppvResource = nullptr; return unavailable(); }
    HRESULT STDMETHODCALLTYPE CreateSharedHandle(ID3D12DeviceChild *pObject, const SECURITY_ATTRIBUTES *pAttributes, DWORD Access, LPCWSTR Name, HANDLE *pHandle) override { return unavailable(); }
    HRESULT STDMETHODCALLTYPE OpenSharedHandle(HANDLE NTHandle, const IID & riid, void **ppvObj) override { if (ppvObj) *ppvObj = nullptr; return unavailable(); }
    HRESULT STDMETHODCALLTYPE OpenSharedHandleByName(LPCWSTR Name, DWORD Access, HANDLE *pNTHandle) override { return unavailable(); }
    HRESULT STDMETHODCALLTYPE MakeResident(UINT count,ID3D12Pageable *const *objects) override { return residency(count,objects); }
    HRESULT STDMETHODCALLTYPE Evict(UINT count,ID3D12Pageable *const *objects) override { return residency(count,objects); }
    HRESULT STDMETHODCALLTYPE CreateFence(UINT64 value,D3D12_FENCE_FLAGS flags,REFIID iid,void **out) override {
        if (out) *out=nullptr;const HRESULT reason=removed_.load();if (FAILED(reason)) return reason;
        @autoreleasepool { return create_fence(this,metal_,value,flags,iid,out); }
    }
    void STDMETHODCALLTYPE GetCopyableFootprints(const D3D12_RESOURCE_DESC *desc,UINT first,UINT count,UINT64 offset,D3D12_PLACED_SUBRESOURCE_FOOTPRINT *layouts,UINT *rows,UINT64 *sizes,UINT64 *total) override { copyable_footprints(desc,first,count,offset,layouts,rows,sizes,total); }
    HRESULT STDMETHODCALLTYPE CreateQueryHeap(const D3D12_QUERY_HEAP_DESC *desc,REFIID iid,void **out) override {
        if (out) *out=nullptr;const HRESULT reason=removed_.load();if (FAILED(reason)) return reason;
        @autoreleasepool { return create_query_heap(this,metal_,desc,iid,out); }
    }
    HRESULT STDMETHODCALLTYPE SetStablePowerState(WINBOOL Enable) override { return unavailable(); }
    HRESULT STDMETHODCALLTYPE CreateCommandSignature(const D3D12_COMMAND_SIGNATURE_DESC *desc,ID3D12RootSignature *root,REFIID iid,void **out) override {
        if (out) *out=nullptr;const HRESULT reason=removed_.load();if (FAILED(reason)) return reason;
        return create_command_signature(this,desc,root,iid,out);
    }
    void STDMETHODCALLTYPE GetResourceTiling(ID3D12Resource *pTiledResource, UINT *pNumTilesForEntireResource, D3D12_PACKED_MIP_INFO *pPackedMipDesc, D3D12_TILE_SHAPE *pStandardTileShapeForNonPackedMips, UINT *pNumSubresourceTilings, UINT FirstSubresourceTilingToGet, D3D12_SUBRESOURCE_TILING *pSubresourceTilingsForNonPackedMips) override { std::abort(); }
    HRESULT STDMETHODCALLTYPE CreatePipelineLibrary(const void *pLibraryBlob, SIZE_T BlobLength, const IID & riid, void **ppPipelineLibrary) override { if (ppPipelineLibrary) *ppPipelineLibrary = nullptr; return unavailable(); }
    HRESULT STDMETHODCALLTYPE SetEventOnMultipleFenceCompletion(ID3D12Fence *const *ppFences, const UINT64 *pFenceValues, UINT NumFences, D3D12_MULTIPLE_FENCE_WAIT_FLAGS Flags, HANDLE hEvent) override { return unavailable(); }
    HRESULT STDMETHODCALLTYPE SetResidencyPriority(UINT count,ID3D12Pageable *const *objects,const D3D12_RESIDENCY_PRIORITY *priorities) override {
        if (count && !priorities) return E_INVALIDARG;return residency(count,objects);
    }
private:
    HRESULT residency(UINT count,ID3D12Pageable *const *objects) {
        const HRESULT reason=removed_.load();if (FAILED(reason)) return reason;
        if (count && !objects) return E_INVALIDARG;
        // Metal manages backing residency for live resources; Windows residency calls remain validated hints.
        for (UINT i=0;i<count;++i) {
            if (!objects[i]) return E_INVALIDARG;
            ID3D12Device *owner=nullptr;const HRESULT hr=objects[i]->GetDevice(__uuidof(ID3D12Device),(void **)&owner);
            const bool same=SUCCEEDED(hr) && owner==static_cast<ID3D12Device *>(this);if (owner) owner->Release();
            if (!same) return E_INVALIDARG;
        }
        return S_OK;
    }
    HRESULT unavailable() const {
        const HRESULT reason = removed_.load();
        return FAILED(reason) ? reason : E_NOTIMPL;
    }
    id<MTLDevice> metal_;
    std::atomic<HRESULT> removed_{S_OK};
    PrivateData data_;
};

id<MTLDevice> select_device(IUnknown *adapter) {
    if (!adapter) return MTLCreateSystemDefaultDevice();
    IDXGIAdapter *dxgi = nullptr;
    if (FAILED(adapter->QueryInterface(__uuidof(IDXGIAdapter), (void **)&dxgi))) return nil;
    DXGI_ADAPTER_DESC desc;
    const HRESULT hr = dxgi->GetDesc(&desc);
    dxgi->Release();
    if (FAILED(hr)) return nil;
    const uint64_t registry = (uint64_t)(uint32_t)desc.AdapterLuid.HighPart << 32 | desc.AdapterLuid.LowPart;
    for (id<MTLDevice> device in MTLCopyAllDevices()) if (device.registryID == registry) return device;
    return nil;
}
}

void track_device_errors(IUnknown *queue, id<MTLCommandBuffer> commands) {
    ID3D12DeviceChild *child = nullptr;
    if (FAILED(queue->QueryInterface(__uuidof(ID3D12DeviceChild), (void **)&child))) return;
    ID3DMDeviceStatus *status = nullptr;
    const HRESULT hr = child->GetDevice(__uuidof(ID3DMDeviceStatus), (void **)&status);
    child->Release();
    if (FAILED(hr)) return;
    [commands addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status == MTLCommandBufferStatusError && completed.error.code != MTLCommandBufferErrorOutOfMemory) {
            const HRESULT reason = completed.error.code == MTLCommandBufferErrorTimeout ? DXGI_ERROR_DEVICE_HUNG : DXGI_ERROR_DEVICE_REMOVED;
            status->RecordError(reason);
        }
        status->Release();
    }];
}
}

HRESULT D3DMCreateDevice(IUnknown *adapter, D3D_FEATURE_LEVEL minimum, REFIID iid, void **out) {
    if (out) *out = nullptr;
    switch (minimum) {
    case D3D_FEATURE_LEVEL_11_0: case D3D_FEATURE_LEVEL_11_1: case D3D_FEATURE_LEVEL_12_0:
    case D3D_FEATURE_LEVEL_12_1: case D3D_FEATURE_LEVEL_12_2: break;
    default: return E_INVALIDARG;
    }
    const HRESULT prepared = d3dm::prepare_metal();
    if (FAILED(prepared)) return prepared;
    if (!d3dm::host.check_feature) return DXGI_ERROR_UNSUPPORTED;
    D3D12_FEATURE_DATA_FEATURE_LEVELS levels = {1, &minimum, {}};
    const HRESULT capability = d3dm::host.check_feature(D3D12_FEATURE_FEATURE_LEVELS, &levels, sizeof levels);
    if (FAILED(capability)) return capability;
    if (levels.MaxSupportedFeatureLevel < minimum) return DXGI_ERROR_UNSUPPORTED;
    @autoreleasepool {
        id<MTLDevice> metal = d3dm::select_device(adapter);
        if (!metal) return DXGI_ERROR_NOT_FOUND;
        std::lock_guard lock(d3dm::device_mutex);
        auto found = d3dm::devices.find(metal.registryID);
        d3dm::Device *device = nullptr;
        if (found != d3dm::devices.end()) {
            device = found->second;
            const HRESULT reason = device->GetDeviceRemovedReason();
            if (FAILED(reason)) return reason;
            device->AddRef();
        } else {
            device = new d3dm::Device(metal);
            d3dm::devices.emplace(metal.registryID, device);
        }
        void *result = nullptr;
        const HRESULT hr = device->QueryInterface(iid, &result);
        device->Release();
        if (FAILED(hr)) return hr;
        if (!out) { ((IUnknown *)result)->Release(); return S_FALSE; }
        *out = result;
        return S_OK;
    }
}
