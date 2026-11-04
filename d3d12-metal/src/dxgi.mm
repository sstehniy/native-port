// DXGI factory, adapters and outputs over Metal devices and Quartz displays.
#include "common.h"
#include "resources.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <string>
#include <thread>

namespace d3dm {

D3DMHost host;

void PrivateData::erase(REFGUID name) {
    for (auto it = entries_.begin(); it != entries_.end(); ++it) {
        if (it->name != name) continue;
        if (it->object) it->object->Release();
        entries_.erase(it);
        return;
    }
}

HRESULT PrivateData::set(REFGUID name, UINT size, const void *data) {
    if (size && !data) return E_INVALIDARG;
    std::lock_guard lock(mutex_);
    erase(name);
    if (size) entries_.push_back({name, std::vector<uint8_t>((const uint8_t *)data, (const uint8_t *)data + size), nullptr});
    return S_OK;
}

HRESULT PrivateData::set_interface(REFGUID name, const IUnknown *object) {
    IUnknown *held = const_cast<IUnknown *>(object);
    if (held) held->AddRef();
    std::lock_guard lock(mutex_);
    erase(name);
    if (!object) return S_OK;
    entries_.push_back({name, std::vector<uint8_t>((const uint8_t *)&held, (const uint8_t *)&held + sizeof held), held});
    return S_OK;
}

HRESULT PrivateData::get(REFGUID name, UINT *size, void *data) {
    if (!size) return E_INVALIDARG;
    std::lock_guard lock(mutex_);
    for (const Entry &entry : entries_) {
        if (entry.name != name) continue;
        const UINT needed = (UINT)entry.bytes.size();
        if (!data) { *size = needed; return S_OK; }
        if (*size < needed) { *size = needed; return DXGI_ERROR_MORE_DATA; }
        memcpy(data, entry.bytes.data(), needed);
        if (entry.object) entry.object->AddRef();
        *size = needed;
        return S_OK;
    }
    *size = 0;
    return DXGI_ERROR_NOT_FOUND;
}

PrivateData::~PrivateData() {
    for (Entry &entry : entries_) if (entry.object) entry.object->Release();
}

void copy_name(WCHAR *target, size_t capacity, NSString *name) {
    NSData *text = [name dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const size_t count = std::min(capacity - 1, (size_t)text.length / sizeof(WCHAR));
    memcpy(target, text.bytes, count * sizeof(WCHAR));
    target[count] = 0;
}

double refresh_rate(uint32_t display) {
    double rate = 0;
    if (CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display)) {
        rate = CGDisplayModeGetRefreshRate(mode);
        CGDisplayModeRelease(mode);
    }
    return rate > 0 ? rate : 60;
}

std::vector<D3DMOutputInfo> outputs() {
    std::vector<D3DMOutputInfo> list(16);
    if (host.outputs) {
        list.resize(std::min<UINT>(host.outputs(list.data(), (UINT)list.size()), (UINT)list.size()));
        return list;
    }
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess) count = 0;
    std::stable_partition(ids, ids + count, [](CGDirectDisplayID id) { return id == CGMainDisplayID(); });
    list.clear();
    for (uint32_t i = 0; i < count; ++i) {
        // shortcut: default desktop rectangles are in points; hosts with a pixel desktop pass `outputs`.
        const CGRect bounds = CGDisplayBounds(ids[i]);
        list.push_back({ids[i], (HMONITOR)(uintptr_t)ids[i],
                        {(int)bounds.origin.x, (int)bounds.origin.y, (int)CGRectGetMaxX(bounds), (int)CGRectGetMaxY(bounds)}});
    }
    return list;
}

namespace {

bool mode_format(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R8G8B8A8_UNORM:
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
    case DXGI_FORMAT_B8G8R8A8_UNORM:
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
    case DXGI_FORMAT_R10G10B10A2_UNORM:
    case DXGI_FORMAT_R16G16B16A16_FLOAT: return true;
    default: return false;
    }
}

std::vector<DXGI_MODE_DESC1> display_modes(uint32_t display, DXGI_FORMAT format) {
    std::vector<DXGI_MODE_DESC1> modes;
    if (!mode_format(format)) return modes;
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef list = CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)options);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); ++i) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(list, i);
        if (!CGDisplayModeIsUsableForDesktopGUI(mode)) continue;
        const double rate = CGDisplayModeGetRefreshRate(mode);
        DXGI_MODE_DESC1 desc = {(UINT)CGDisplayModeGetPixelWidth(mode), (UINT)CGDisplayModeGetPixelHeight(mode),
                                {rate > 0 ? (UINT)llround(rate * 1000) : 60000, 1000}, format,
                                DXGI_MODE_SCANLINE_ORDER_PROGRESSIVE, DXGI_MODE_SCALING_UNSPECIFIED, FALSE};
        const bool seen = std::any_of(modes.begin(), modes.end(), [&](const DXGI_MODE_DESC1 &m) {
            return m.Width == desc.Width && m.Height == desc.Height && m.RefreshRate.Numerator == desc.RefreshRate.Numerator;
        });
        if (!seen) modes.push_back(desc);
    }
    if (list) CFRelease(list);
    std::sort(modes.begin(), modes.end(), [](const DXGI_MODE_DESC1 &a, const DXGI_MODE_DESC1 &b) {
        if (a.Width != b.Width) return a.Width < b.Width;
        if (a.Height != b.Height) return a.Height < b.Height;
        return a.RefreshRate.Numerator < b.RefreshRate.Numerator;
    });
    return modes;
}

DXGI_MODE_DESC1 to_mode1(const DXGI_MODE_DESC &m) {
    return {m.Width, m.Height, m.RefreshRate, m.Format, m.ScanlineOrdering, m.Scaling, FALSE};
}
DXGI_MODE_DESC to_mode(const DXGI_MODE_DESC1 &m) {
    return {m.Width, m.Height, m.RefreshRate, m.Format, m.ScanlineOrdering, m.Scaling};
}
double hz(const DXGI_RATIONAL &r) { return r.Denominator ? (double)r.Numerator / r.Denominator : 0; }

class Output final : public Object<IDXGIOutput6> {
public:
    Output(IDXGIAdapter *adapter, UINT index, const D3DMOutputInfo &info) : adapter_(adapter), index_(index), info_(info) {
        adapter_->AddRef();
    }
    ~Output() override { adapter_->Release(); }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        return query<IUnknown, IDXGIObject, IDXGIOutput, IDXGIOutput1, IDXGIOutput2, IDXGIOutput3, IDXGIOutput4,
                     IDXGIOutput5, IDXGIOutput6>(riid, out);
    }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID name, UINT size, const void *data) override { return data_.set(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID name, const IUnknown *object) override { return data_.set_interface(name, object); }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID name, UINT *size, void *data) override { return data_.get(name, size, data); }
    HRESULT STDMETHODCALLTYPE GetParent(REFIID riid, void **out) override { return query_out(adapter_, riid, out); }

    HRESULT STDMETHODCALLTYPE GetDesc(DXGI_OUTPUT_DESC *desc) override {
        if (!desc) return E_INVALIDARG;
        *desc = {};
        copy_name(desc->DeviceName, 32, [NSString stringWithFormat:@"\\\\.\\DISPLAY%u", index_ + 1]);
        desc->DesktopCoordinates = info_.desktop;
        desc->AttachedToDesktop = TRUE;
        desc->Rotation = DXGI_MODE_ROTATION_IDENTITY;
        desc->Monitor = info_.monitor;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDisplayModeList(DXGI_FORMAT format, UINT flags, UINT *count, DXGI_MODE_DESC *desc) override {
        std::vector<DXGI_MODE_DESC1> modes1 = display_modes(info_.display, format);
        std::vector<DXGI_MODE_DESC> modes(modes1.size());
        std::transform(modes1.begin(), modes1.end(), modes.begin(), to_mode);
        return copy_modes(modes, count, desc);
    }
    HRESULT STDMETHODCALLTYPE FindClosestMatchingMode(const DXGI_MODE_DESC *match, DXGI_MODE_DESC *closest, IUnknown *device) override {
        if (!match || !closest) return E_INVALIDARG;
        DXGI_MODE_DESC1 found;
        const DXGI_MODE_DESC1 match1 = to_mode1(*match);
        const HRESULT hr = FindClosestMatchingMode1(&match1, &found, device);
        if (SUCCEEDED(hr)) *closest = to_mode(found);
        return hr;
    }
    HRESULT STDMETHODCALLTYPE WaitForVBlank() override {
        // shortcut: refresh-period sleep; use a display-link signal when a caller needs vblank phase.
        std::this_thread::sleep_for(std::chrono::duration<double>(1 / refresh_rate(info_.display)));
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE TakeOwnership(IUnknown *, WINBOOL) override { return DXGI_ERROR_UNSUPPORTED; }
    void STDMETHODCALLTYPE ReleaseOwnership() override {}
    // Windowed outputs never own gamma, as on Windows outside exclusive fullscreen.
    HRESULT STDMETHODCALLTYPE GetGammaControlCapabilities(DXGI_GAMMA_CONTROL_CAPABILITIES *) override { return DXGI_ERROR_NOT_CURRENTLY_AVAILABLE; }
    HRESULT STDMETHODCALLTYPE SetGammaControl(const DXGI_GAMMA_CONTROL *) override { return DXGI_ERROR_NOT_CURRENTLY_AVAILABLE; }
    HRESULT STDMETHODCALLTYPE GetGammaControl(DXGI_GAMMA_CONTROL *) override { return DXGI_ERROR_NOT_CURRENTLY_AVAILABLE; }
    HRESULT STDMETHODCALLTYPE SetDisplaySurface(IDXGISurface *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetDisplaySurfaceData(IDXGISurface *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetFrameStatistics(DXGI_FRAME_STATISTICS *) override { return DXGI_ERROR_NOT_CURRENTLY_AVAILABLE; }

    HRESULT STDMETHODCALLTYPE GetDisplayModeList1(DXGI_FORMAT format, UINT flags, UINT *count, DXGI_MODE_DESC1 *desc) override {
        return copy_modes(display_modes(info_.display, format), count, desc);
    }
    HRESULT STDMETHODCALLTYPE FindClosestMatchingMode1(const DXGI_MODE_DESC1 *match, DXGI_MODE_DESC1 *closest, IUnknown *device) override {
        if (!match || !closest) return E_INVALIDARG;
        if (match->Format == DXGI_FORMAT_UNKNOWN && !device) return E_INVALIDARG;
        const DXGI_FORMAT format = match->Format == DXGI_FORMAT_UNKNOWN ? DXGI_FORMAT_R8G8B8A8_UNORM : match->Format;
        const std::vector<DXGI_MODE_DESC1> modes = display_modes(info_.display, format);
        if (modes.empty()) return DXGI_ERROR_NOT_FOUND;
        // shortcut: size/rate ranking; add scanline/scaling preference when a caller requests those modes.
        const double rate = hz(match->RefreshRate);
        auto score = [&](const DXGI_MODE_DESC1 &m) {
            const double size = (match->Width ? std::fabs((double)m.Width - match->Width) : 0) +
                                (match->Height ? std::fabs((double)m.Height - match->Height) : 0);
            return size * 1000 + (rate > 0 ? std::fabs(hz(m.RefreshRate) - rate) : -hz(m.RefreshRate));
        };
        *closest = *std::min_element(modes.begin(), modes.end(), [&](const auto &a, const auto &b) { return score(a) < score(b); });
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDisplaySurfaceData1(IDXGIResource *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE DuplicateOutput(IUnknown *, IDXGIOutputDuplication **out) override { return unsupported(out); }
    WINBOOL STDMETHODCALLTYPE SupportsOverlays() override { return FALSE; }
    HRESULT STDMETHODCALLTYPE CheckOverlaySupport(DXGI_FORMAT, IUnknown *, UINT *) override { return DXGI_ERROR_UNSUPPORTED; }
    HRESULT STDMETHODCALLTYPE CheckOverlayColorSpaceSupport(DXGI_FORMAT, DXGI_COLOR_SPACE_TYPE, IUnknown *, UINT *) override {
        return DXGI_ERROR_UNSUPPORTED;
    }
    HRESULT STDMETHODCALLTYPE DuplicateOutput1(IUnknown *, UINT, UINT, const DXGI_FORMAT *, IDXGIOutputDuplication **out) override {
        return unsupported(out);
    }
    HRESULT STDMETHODCALLTYPE GetDesc1(DXGI_OUTPUT_DESC1 *desc) override {
        if (!desc) return E_INVALIDARG;
        DXGI_OUTPUT_DESC base;
        GetDesc(&base);
        // shortcut: reports an sRGB SDR display; read the display's EDR headroom when HDR output lands.
        *desc = {{}, base.DesktopCoordinates, base.AttachedToDesktop, base.Rotation, base.Monitor, 8,
                 DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709, {0.64f, 0.33f}, {0.30f, 0.60f}, {0.15f, 0.06f},
                 {0.3127f, 0.3290f}, 0.5f, 270, 270};
        memcpy(desc->DeviceName, base.DeviceName, sizeof base.DeviceName);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE CheckHardwareCompositionSupport(UINT *flags) override {
        if (!flags) return E_INVALIDARG;
        *flags = 0;
        return S_OK;
    }

private:
    template <class Mode> static HRESULT copy_modes(const std::vector<Mode> &modes, UINT *count, Mode *desc) {
        if (!count) return E_INVALIDARG;
        if (!desc) { *count = (UINT)modes.size(); return S_OK; }
        const UINT copied = std::min<UINT>(*count, (UINT)modes.size());
        std::copy_n(modes.begin(), copied, desc);
        *count = copied;
        return copied < modes.size() ? DXGI_ERROR_MORE_DATA : S_OK;
    }
    static HRESULT unsupported(IDXGIOutputDuplication **out) {
        if (out) *out = nullptr;
        return DXGI_ERROR_UNSUPPORTED;
    }
    IDXGIAdapter *adapter_;
    UINT index_;
    D3DMOutputInfo info_;
    PrivateData data_;
};

class Adapter final : public Object<IDXGIAdapter4> {
public:
    Adapter(IDXGIFactory *factory, id<MTLDevice> device) : factory_(factory), device_(device) { factory_->AddRef(); }
    ~Adapter() override { factory_->Release(); }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        return query<IUnknown, IDXGIObject, IDXGIAdapter, IDXGIAdapter1, IDXGIAdapter2, IDXGIAdapter3, IDXGIAdapter4>(riid, out);
    }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID name, UINT size, const void *data) override { return data_.set(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID name, const IUnknown *object) override { return data_.set_interface(name, object); }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID name, UINT *size, void *data) override { return data_.get(name, size, data); }
    HRESULT STDMETHODCALLTYPE GetParent(REFIID riid, void **out) override { return query_out(factory_, riid, out); }

    HRESULT STDMETHODCALLTYPE EnumOutputs(UINT index, IDXGIOutput **out) override {
        if (!out) return E_INVALIDARG;
        *out = create_output(this, index);
        return *out ? S_OK : DXGI_ERROR_NOT_FOUND;
    }
    HRESULT STDMETHODCALLTYPE GetDesc(DXGI_ADAPTER_DESC *desc) override {
        if (!desc) return E_INVALIDARG;
        DXGI_ADAPTER_DESC3 full;
        GetDesc3(&full);
        memcpy(desc, &full, sizeof *desc);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE CheckInterfaceSupport(REFGUID, LARGE_INTEGER *) override { return DXGI_ERROR_UNSUPPORTED; }
    HRESULT STDMETHODCALLTYPE GetDesc1(DXGI_ADAPTER_DESC1 *desc) override {
        if (!desc) return E_INVALIDARG;
        DXGI_ADAPTER_DESC3 full;
        GetDesc3(&full);
        memcpy(desc, &full, sizeof *desc);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDesc2(DXGI_ADAPTER_DESC2 *desc) override {
        if (!desc) return E_INVALIDARG;
        DXGI_ADAPTER_DESC3 full;
        GetDesc3(&full);
        static_assert(sizeof(DXGI_ADAPTER_DESC2) == sizeof(DXGI_ADAPTER_DESC3));
        memcpy(desc, &full, sizeof *desc);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE RegisterHardwareContentProtectionTeardownStatusEvent(HANDLE, DWORD *) override { return DXGI_ERROR_UNSUPPORTED; }
    void STDMETHODCALLTYPE UnregisterHardwareContentProtectionTeardownStatus(DWORD) override {}
    HRESULT STDMETHODCALLTYPE QueryVideoMemoryInfo(UINT node, DXGI_MEMORY_SEGMENT_GROUP group, DXGI_QUERY_VIDEO_MEMORY_INFO *info) override {
        if (node || !info || group > DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL) return E_INVALIDARG;
        // Apple GPUs use unified memory: everything is reported in the local segment.
        *info = {};
        if (group == DXGI_MEMORY_SEGMENT_GROUP_LOCAL) {
            info->Budget = device_.recommendedMaxWorkingSetSize;
            info->CurrentUsage = device_.currentAllocatedSize;
            info->AvailableForReservation = info->Budget / 2;
            info->CurrentReservation = reservation_;
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetVideoMemoryReservation(UINT node, DXGI_MEMORY_SEGMENT_GROUP group, UINT64 reservation) override {
        if (node || group > DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL) return E_INVALIDARG;
        if (group == DXGI_MEMORY_SEGMENT_GROUP_LOCAL) reservation_ = reservation;
        return S_OK;
    }
    // The budget never changes, so registered events are accepted and never signalled.
    HRESULT STDMETHODCALLTYPE RegisterVideoMemoryBudgetChangeNotificationEvent(HANDLE event, DWORD *cookie) override {
        if (!event || !cookie) return E_INVALIDARG;
        *cookie = ++cookies_;
        return S_OK;
    }
    void STDMETHODCALLTYPE UnregisterVideoMemoryBudgetChangeNotification(DWORD) override {}
    HRESULT STDMETHODCALLTYPE GetDesc3(DXGI_ADAPTER_DESC3 *desc) override {
        if (!desc) return E_INVALIDARG;
        *desc = {};
        copy_name(desc->Description, 128, device_.name);
        desc->VendorId = 0x106b;
        desc->DedicatedVideoMemory = device_.recommendedMaxWorkingSetSize;
        const uint64_t id = device_.registryID;
        desc->AdapterLuid = {(ULONG)id, (LONG)(id >> 32)};
        desc->Flags = DXGI_ADAPTER_FLAG3_NONE;
        desc->GraphicsPreemptionGranularity = DXGI_GRAPHICS_PREEMPTION_DMA_BUFFER_BOUNDARY;
        desc->ComputePreemptionGranularity = DXGI_COMPUTE_PREEMPTION_DMA_BUFFER_BOUNDARY;
        return S_OK;
    }

private:
    IDXGIFactory *factory_;
    id<MTLDevice> device_;
    UINT64 reservation_ = 0;
    std::atomic<DWORD> cookies_{0};
    PrivateData data_;
};

class Factory final : public Object<IDXGIFactory6> {
public:
    explicit Factory(UINT flags) : flags_(flags) {
        id<MTLDevice> preferred = MTLCreateSystemDefaultDevice();
        if (preferred) devices_.push_back(preferred);
        for (id<MTLDevice> device in MTLCopyAllDevices()) if (device.registryID != preferred.registryID) devices_.push_back(device);
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        return query<IUnknown, IDXGIObject, IDXGIFactory, IDXGIFactory1, IDXGIFactory2, IDXGIFactory3, IDXGIFactory4,
                     IDXGIFactory5, IDXGIFactory6>(riid, out);
    }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID name, UINT size, const void *data) override { return data_.set(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID name, const IUnknown *object) override { return data_.set_interface(name, object); }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID name, UINT *size, void *data) override { return data_.get(name, size, data); }
    HRESULT STDMETHODCALLTYPE GetParent(REFIID, void **out) override {
        if (out) *out = nullptr;
        return E_NOINTERFACE;
    }

    HRESULT STDMETHODCALLTYPE EnumAdapters(UINT index, IDXGIAdapter **out) override {
        return EnumAdapterByGpuPreference(index, DXGI_GPU_PREFERENCE_UNSPECIFIED, __uuidof(IDXGIAdapter), (void **)out);
    }
    HRESULT STDMETHODCALLTYPE MakeWindowAssociation(HWND window, UINT flags) override {
        if (flags & ~DXGI_MWA_VALID) return DXGI_ERROR_INVALID_CALL;
        // shortcut: association is recorded; route host shortcuts here when a caller needs automatic changes.
        window_ = window;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetWindowAssociation(HWND *window) override {
        if (!window) return DXGI_ERROR_INVALID_CALL;
        *window = window_;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE CreateSwapChain(IUnknown *device, DXGI_SWAP_CHAIN_DESC *desc, IDXGISwapChain **out) override {
        if (!desc) return DXGI_ERROR_INVALID_CALL;
        const DXGI_MODE_DESC &mode = desc->BufferDesc;
        const DXGI_SWAP_CHAIN_DESC1 desc1 = {mode.Width, mode.Height, mode.Format, FALSE, desc->SampleDesc, desc->BufferUsage,
                                             desc->BufferCount, DXGI_SCALING_STRETCH, desc->SwapEffect, DXGI_ALPHA_MODE_UNSPECIFIED,
                                             desc->Flags};
        const DXGI_SWAP_CHAIN_FULLSCREEN_DESC fullscreen = {mode.RefreshRate, mode.ScanlineOrdering, mode.Scaling, desc->Windowed};
        return create_swap_chain(this, device, desc->OutputWindow, &desc1, &fullscreen, nullptr, (IDXGISwapChain1 **)out);
    }
    HRESULT STDMETHODCALLTYPE CreateSoftwareAdapter(HMODULE, IDXGIAdapter **out) override {
        if (out) *out = nullptr;
        return DXGI_ERROR_UNSUPPORTED;
    }
    HRESULT STDMETHODCALLTYPE EnumAdapters1(UINT index, IDXGIAdapter1 **out) override {
        return EnumAdapterByGpuPreference(index, DXGI_GPU_PREFERENCE_UNSPECIFIED, __uuidof(IDXGIAdapter1), (void **)out);
    }
    WINBOOL STDMETHODCALLTYPE IsCurrent() override { return TRUE; }
    WINBOOL STDMETHODCALLTYPE IsWindowedStereoEnabled() override { return FALSE; }
    HRESULT STDMETHODCALLTYPE CreateSwapChainForHwnd(IUnknown *device, HWND window, const DXGI_SWAP_CHAIN_DESC1 *desc,
                                                     const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *fullscreen, IDXGIOutput *restrict_to,
                                                     IDXGISwapChain1 **out) override {
        return create_swap_chain(this, device, window, desc, fullscreen, restrict_to, out);
    }
    HRESULT STDMETHODCALLTYPE CreateSwapChainForCoreWindow(IUnknown *, IUnknown *, const DXGI_SWAP_CHAIN_DESC1 *, IDXGIOutput *,
                                                           IDXGISwapChain1 **out) override {
        if (out) *out = nullptr;
        return DXGI_ERROR_UNSUPPORTED;
    }
    HRESULT STDMETHODCALLTYPE GetSharedResourceAdapterLuid(HANDLE, LUID *) override { return DXGI_ERROR_UNSUPPORTED; }
    // Stereo and occlusion status never change here, so registrations are accepted and never signalled.
    HRESULT STDMETHODCALLTYPE RegisterStereoStatusWindow(HWND, UINT, DWORD *cookie) override { return register_status(cookie); }
    HRESULT STDMETHODCALLTYPE RegisterStereoStatusEvent(HANDLE, DWORD *cookie) override { return register_status(cookie); }
    void STDMETHODCALLTYPE UnregisterStereoStatus(DWORD) override {}
    HRESULT STDMETHODCALLTYPE RegisterOcclusionStatusWindow(HWND, UINT, DWORD *cookie) override { return register_status(cookie); }
    HRESULT STDMETHODCALLTYPE RegisterOcclusionStatusEvent(HANDLE, DWORD *cookie) override { return register_status(cookie); }
    void STDMETHODCALLTYPE UnregisterOcclusionStatus(DWORD) override {}
    HRESULT STDMETHODCALLTYPE CreateSwapChainForComposition(IUnknown *, const DXGI_SWAP_CHAIN_DESC1 *, IDXGIOutput *,
                                                            IDXGISwapChain1 **out) override {
        if (out) *out = nullptr;
        return DXGI_ERROR_UNSUPPORTED;
    }
    UINT STDMETHODCALLTYPE GetCreationFlags() override { return flags_; }
    HRESULT STDMETHODCALLTYPE EnumAdapterByLuid(LUID luid, REFIID riid, void **out) override {
        if (!out) return E_INVALIDARG;
        *out = nullptr;
        for (id<MTLDevice> device : devices_) {
            if ((ULONG)device.registryID != luid.LowPart || (LONG)(device.registryID >> 32) != luid.HighPart) continue;
            return wrap(create_adapter(this, device), riid, out);
        }
        return DXGI_ERROR_NOT_FOUND;
    }
    HRESULT STDMETHODCALLTYPE EnumWarpAdapter(REFIID, void **out) override {
        if (out) *out = nullptr;
        return DXGI_ERROR_UNSUPPORTED;
    }
    HRESULT STDMETHODCALLTYPE CheckFeatureSupport(DXGI_FEATURE feature, void *data, UINT size) override {
        if (feature != DXGI_FEATURE_PRESENT_ALLOW_TEARING || !data || size != sizeof(WINBOOL)) return E_INVALIDARG;
        *(WINBOOL *)data = TRUE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE EnumAdapterByGpuPreference(UINT index, DXGI_GPU_PREFERENCE preference, REFIID riid, void **out) override {
        if (!out) return E_INVALIDARG;
        *out = nullptr;
        if (preference > DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE) return E_INVALIDARG;
        if (index >= devices_.size()) return DXGI_ERROR_NOT_FOUND;
        return wrap(create_adapter(this, devices_[index]), riid, out);
    }

private:
    static HRESULT wrap(IUnknown *object, REFIID riid, void **out) {
        const HRESULT hr = object->QueryInterface(riid, out);
        object->Release();
        return hr;
    }
    HRESULT register_status(DWORD *cookie) {
        if (!cookie) return DXGI_ERROR_INVALID_CALL;
        *cookie = ++cookies_;
        return S_OK;
    }
    UINT flags_;
    HWND window_ = nullptr;
    std::vector<id<MTLDevice>> devices_;
    std::atomic<DWORD> cookies_{0};
    PrivateData data_;
};

} // namespace

IDXGIAdapter4 *create_adapter(IDXGIFactory *factory, id<MTLDevice> device) { return new Adapter(factory, device); }

IDXGIOutput6 *create_output(IDXGIAdapter *adapter, UINT index) {
    const std::vector<D3DMOutputInfo> list = outputs();
    return index < list.size() ? new Output(adapter, index, list[index]) : nullptr;
}

} // namespace d3dm

void D3DMSetHost(const D3DMHost *host) { d3dm::host = host ? *host : D3DMHost{}; }

HRESULT D3DMCreateDXGIFactory2(UINT flags, REFIID riid, void **out) {
    if (!out) return E_INVALIDARG;
    *out = nullptr;
    if (flags & ~DXGI_CREATE_FACTORY_DEBUG) return E_INVALIDARG;
    const HRESULT prepared = d3dm::prepare_metal();
    if (FAILED(prepared)) return prepared;
    @autoreleasepool {
        IDXGIFactory6 *factory = new d3dm::Factory(flags);
        const HRESULT hr = factory->QueryInterface(riid, out);
        factory->Release();
        return hr;
    }
}
