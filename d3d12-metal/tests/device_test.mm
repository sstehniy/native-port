// Device identity, policy delegation and permanent submission failures at the native boundary.
#import <Metal/Metal.h>
#include <cassert>
#include <cstdio>
#include <thread>
#include <vector>

@interface DeviceCommands : NSObject
@property MTLCommandBufferStatus status;
@property NSError *error;
@property(copy) MTLCommandBufferHandler handler;
@end
@implementation DeviceCommands
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler { self.handler = handler; }
- (void)complete { self.handler((id<MTLCommandBuffer>)self); self.handler = nil; }
@end

#include "common.h"

class Queue final : public ID3D12DeviceChild {
public:
    explicit Queue(ID3D12Device *device) : device(device) { device->AddRef(); }
    ~Queue() { device->Release(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        *out = nullptr;
        if (iid != __uuidof(IUnknown) && iid != __uuidof(ID3D12DeviceChild)) return E_NOINTERFACE;
        AddRef(); *out = this; return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override { return --references; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID, UINT *, void *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID, UINT, const void *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID, const IUnknown *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID iid, void **out) override { return device->QueryInterface(iid, out); }
    ID3D12Device *device;
    ULONG references = 1;
};

static HRESULT feature(D3D12_FEATURE feature, void *data, UINT size) {
    if (feature != D3D12_FEATURE_FEATURE_LEVELS || !data || size != sizeof(D3D12_FEATURE_DATA_FEATURE_LEVELS)) return E_INVALIDARG;
    auto &levels = *(D3D12_FEATURE_DATA_FEATURE_LEVELS *)data;
    levels.MaxSupportedFeatureLevel = {};
    for (UINT i = 0; i < levels.NumFeatureLevels; ++i)
        if (levels.pFeatureLevelsRequested[i] <= D3D_FEATURE_LEVEL_12_0) levels.MaxSupportedFeatureLevel = levels.pFeatureLevelsRequested[i];
    return S_OK;
}

int main() {
    @autoreleasepool {
        D3DMHost host = {};
        D3DMSetHost(&host);
        void *out = (void *)1;
        assert(D3DMCreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, __uuidof(ID3D12Device), &out) == DXGI_ERROR_UNSUPPORTED && !out);
        host.check_feature = feature;
        D3DMSetHost(&host);
        assert(D3DMCreateDevice(nullptr, D3D_FEATURE_LEVEL_12_2, __uuidof(ID3D12Device), &out) == DXGI_ERROR_UNSUPPORTED && !out);
        assert(D3DMCreateDevice(nullptr, (D3D_FEATURE_LEVEL)0, __uuidof(ID3D12Device), &out) == E_INVALIDARG && !out);
        assert(D3DMCreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, __uuidof(ID3D12Device), nullptr) == S_FALSE);
        assert(D3DMCreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, __uuidof(IDXGIOutput), &out) == E_NOINTERFACE && !out);
        ID3D12Device *device = nullptr;
        assert(D3DMCreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, __uuidof(ID3D12Device), (void **)&device) == S_OK);
        assert(device->GetNodeCount() == 1 && device->GetDeviceRemovedReason() == S_OK);
        ID3D12Device1 *version1 = nullptr;
        assert(device->QueryInterface(__uuidof(ID3D12Device1), (void **)&version1) == S_OK && (void *)version1 == device);
        version1->Release();
        IDXGIFactory4 *factory = nullptr;
        IDXGIAdapter1 *adapter = nullptr;
        assert(D3DMCreateDXGIFactory2(0, __uuidof(IDXGIFactory4), (void **)&factory) == S_OK);
        assert(factory->EnumAdapters1(0, &adapter) == S_OK);
        ID3D12Device *same = nullptr;
        assert(D3DMCreateDevice(adapter, D3D_FEATURE_LEVEL_12_0, __uuidof(ID3D12Device), (void **)&same) == S_OK && same == device);
        DXGI_ADAPTER_DESC1 desc;
        assert(adapter->GetDesc1(&desc) == S_OK);
        const LUID luid = device->GetAdapterLuid();
        assert(luid.LowPart == desc.AdapterLuid.LowPart && luid.HighPart == desc.AdapterLuid.HighPart);
        same->Release(); adapter->Release(); factory->Release();
        std::vector<std::thread> workers;
        for (int i = 0; i < 8; ++i) workers.emplace_back([&] {
            for (int n = 0; n < 100; ++n) {
                ID3D12Device *same = nullptr;
                assert(D3DMCreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, __uuidof(ID3D12Device), (void **)&same) == S_OK && same == device);
                same->Release();
            }
        });
        for (auto &worker : workers) worker.join();
        UINT data = 0x1234;
        assert(device->CheckFeatureSupport((D3D12_FEATURE)999, &data, sizeof data) == E_INVALIDARG && data == 0x1234);
        assert(device->GetDescriptorHandleIncrementSize((D3D12_DESCRIPTOR_HEAP_TYPE)4) == 0);
        {
            Queue queue(device);
            for (auto code : {MTLCommandBufferErrorOutOfMemory, MTLCommandBufferErrorTimeout}) {
                DeviceCommands *commands = [DeviceCommands new];
                commands.status = MTLCommandBufferStatusError;
                commands.error = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:code userInfo:nil];
                d3dm::track_device_errors(&queue, (id<MTLCommandBuffer>)commands);
                assert(commands.handler);
                [commands complete];
                const HRESULT expected = code == MTLCommandBufferErrorOutOfMemory ? S_OK : DXGI_ERROR_DEVICE_HUNG;
                assert(device->GetDeviceRemovedReason() == expected);
            }
        }
        ID3DMDeviceStatus *status = nullptr;
        assert(device->QueryInterface(__uuidof(ID3DMDeviceStatus), (void **)&status) == S_OK);
        status->RecordError(DXGI_ERROR_DEVICE_REMOVED);
        assert(device->GetDeviceRemovedReason() == DXGI_ERROR_DEVICE_HUNG);
        status->Release();
        assert(device->CheckFeatureSupport((D3D12_FEATURE)999, &data, sizeof data) == DXGI_ERROR_DEVICE_HUNG);
        assert(D3DMCreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, __uuidof(ID3D12Device), &out) == DXGI_ERROR_DEVICE_HUNG && !out);
        assert(device->Release() == 0);
        assert(D3DMCreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, __uuidof(ID3D12Device), (void **)&device) == S_OK);
        assert(device->GetDeviceRemovedReason() == S_OK && device->Release() == 0);
        puts("device_test: policy, COM identity, LUID, 800 concurrent creations, GPU error mapping and removed-device rejection passed");
    }
}
