// Flip-model swap chains: private Metal back buffers copied into CAMetalLayer drawables on present.
#include "common.h"

#include <algorithm>
#include <cmath>

namespace d3dm {
namespace {

MTLPixelFormat pixel_format(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R8G8B8A8_UNORM: return MTLPixelFormatRGBA8Unorm;
    case DXGI_FORMAT_B8G8R8A8_UNORM: return MTLPixelFormatBGRA8Unorm;
    case DXGI_FORMAT_R10G10B10A2_UNORM: return MTLPixelFormatRGB10A2Unorm;
    case DXGI_FORMAT_R16G16B16A16_FLOAT: return MTLPixelFormatRGBA16Float;
    default: return MTLPixelFormatInvalid; // flip-model swap chains reject sRGB formats too
    }
}

bool color_space_supported(DXGI_FORMAT format, DXGI_COLOR_SPACE_TYPE space) {
    switch (space) {
    case DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709: return true;
    case DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709: return format == DXGI_FORMAT_R16G16B16A16_FLOAT;
    case DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020: return format == DXGI_FORMAT_R10G10B10A2_UNORM;
    default: return false;
    }
}

CGSize pixel_size(CAMetalLayer *layer) {
    return CGSizeMake(layer.bounds.size.width * layer.contentsScale, layer.bounds.size.height * layer.contentsScale);
}

template <class Change> void layer_transaction(Change change) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    change();
    [CATransaction commit];
}

HRESULT get_queue_device(IUnknown *queue, REFIID riid, void **out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    ID3D12DeviceChild *child = nullptr;
    const HRESULT queried = queue->QueryInterface(__uuidof(ID3D12DeviceChild), (void **)&child);
    if (FAILED(queried)) return queried;
    const HRESULT hr = child->GetDevice(riid, out);
    child->Release();
    return hr;
}

class BackBuffer final : public Object<ID3D12Resource>, public ID3DMMetalTexture {
public:
    BackBuffer(IUnknown *device, id<MTLTexture> texture, const D3D12_RESOURCE_DESC &desc) : device_(device), texture_(texture), desc_(desc) {
        device_->AddRef();
    }
    ~BackBuffer() override { device_->Release(); }
    ULONG references() const { return refs_; }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (out && riid == __uuidof(ID3DMMetalTexture)) {
            AddRef();
            *out = static_cast<ID3DMMetalTexture *>(this);
            return S_OK;
        }
        return query<IUnknown, ID3D12Object, ID3D12DeviceChild, ID3D12Pageable, ID3D12Resource>(riid, out);
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return Object::AddRef(); }
    ULONG STDMETHODCALLTYPE Release() override { return Object::Release(); }
    void *STDMETHODCALLTYPE MetalTexture() override { return (__bridge void *)texture_; }

    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID name, UINT *size, void *data) override { return data_.get(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID name, UINT size, const void *data) override { return data_.set(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID name, const IUnknown *object) override { return data_.set_interface(name, object); }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR name) override {
        if (!name) return data_.set(WKPDID_D3DDebugObjectNameW, 0, nullptr);
        const size_t length = wcslen(name);
        texture_.label = [[NSString alloc] initWithBytes:name length:length * sizeof(WCHAR) encoding:NSUTF32LittleEndianStringEncoding];
        return data_.set(WKPDID_D3DDebugObjectNameW, (UINT)((length + 1) * sizeof(WCHAR)), name);
    }
    // The swap chain's device argument is the D3D12 command queue, a device child.
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID riid, void **out) override {
        if (!out) return E_INVALIDARG;
        return get_queue_device(device_, riid, out);
    }
    // Back buffers live in a default heap: no CPU mapping and no GPU virtual address of their own.
    HRESULT STDMETHODCALLTYPE Map(UINT, const D3D12_RANGE *, void **data) override {
        if (data) *data = nullptr;
        return E_INVALIDARG;
    }
    void STDMETHODCALLTYPE Unmap(UINT, const D3D12_RANGE *) override {}
    D3D12_RESOURCE_DESC STDMETHODCALLTYPE GetDesc() override { return desc_; }
    D3D12_GPU_VIRTUAL_ADDRESS STDMETHODCALLTYPE GetGPUVirtualAddress() override { return 0; }
    HRESULT STDMETHODCALLTYPE WriteToSubresource(UINT, const D3D12_BOX *, const void *, UINT, UINT) override { return E_INVALIDARG; }
    HRESULT STDMETHODCALLTYPE ReadFromSubresource(void *, UINT, UINT, UINT, const D3D12_BOX *) override { return E_INVALIDARG; }
    HRESULT STDMETHODCALLTYPE GetHeapProperties(D3D12_HEAP_PROPERTIES *properties, D3D12_HEAP_FLAGS *flags) override {
        if (properties) *properties = {D3D12_HEAP_TYPE_DEFAULT, D3D12_CPU_PAGE_PROPERTY_UNKNOWN, D3D12_MEMORY_POOL_UNKNOWN, 1, 1};
        if (flags) *flags = D3D12_HEAP_FLAG_NONE;
        return S_OK;
    }

private:
    IUnknown *device_;
    id<MTLTexture> texture_;
    D3D12_RESOURCE_DESC desc_;
    PrivateData data_;
};

struct Latency {
    explicit Latency(HANDLE handle) : handle(handle) {}
    ~Latency() { if (handle) host.close_handle(handle); }
    void signal() {
        std::lock_guard lock(mutex);
        if (debt) --debt;
        else host.release_semaphore(handle, 1);
    }
    HANDLE handle;
    UINT debt = 0;
    std::mutex mutex;
};

class SwapChain final : public Object<IDXGISwapChain3> {
public:
    SwapChain(IDXGIFactory *factory, IUnknown *device, id<MTLCommandQueue> queue, CAMetalLayer *layer, HWND window,
              const DXGI_SWAP_CHAIN_DESC1 &desc, const DXGI_SWAP_CHAIN_FULLSCREEN_DESC &fullscreen, IDXGIOutput *restrict_to)
        : factory_(factory), device_(device), restrict_to_(restrict_to), queue_(queue), layer_(layer), window_(window), desc_(desc),
          fullscreen_desc_(fullscreen), fullscreen_(FALSE),
          refresh_(refresh_rate(CGMainDisplayID())) {
        factory_->AddRef();
        device_->AddRef();
        if (restrict_to_) restrict_to_->AddRef();
        if (desc_.Flags & DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT)
            latency_event_ = std::make_shared<Latency>(host.create_semaphore(latency_, 16));
        layer_transaction([&] {
            layer_.device = queue_.device;
            layer_.framebufferOnly = NO;
            layer_.opaque = desc_.AlphaMode != DXGI_ALPHA_MODE_PREMULTIPLIED;
            layer_.displaySyncEnabled = YES;
            CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            layer_.colorspace = srgb;
            CGColorSpaceRelease(srgb);
            // Gravity names assume unflipped geometry; flipped views (AppKit's y-down views) swap top and bottom.
            if (desc_.Scaling == DXGI_SCALING_NONE) layer_.contentsGravity = layer_.contentsAreFlipped ? kCAGravityBottomLeft : kCAGravityTopLeft;
            else if (desc_.Scaling == DXGI_SCALING_ASPECT_RATIO_STRETCH) layer_.contentsGravity = kCAGravityResizeAspect;
            else layer_.contentsGravity = kCAGravityResize;
        });
    }
    ~SwapChain() override {
        [last_ waitUntilCompleted];
        for (BackBuffer *buffer : buffers_) buffer->Release();
        if (fullscreen_ && host.set_fullscreen) host.set_fullscreen(window_, FALSE, nullptr);
        if (restrict_to_) restrict_to_->Release();
        if (fullscreen_output_) fullscreen_output_->Release();
        device_->Release();
        factory_->Release();
    }

    HRESULT create_buffers(const DXGI_SWAP_CHAIN_DESC1 &desc) {
        if (latency_event_ && !latency_event_->handle) return E_OUTOFMEMORY;
        if (desc.Width > 16384 || desc.Height > 16384) return DXGI_ERROR_INVALID_CALL;
        const MTLPixelFormat format = pixel_format(desc.Format);
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:desc.Width
                                                                                             height:desc.Height mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        if (desc.BufferUsage & DXGI_USAGE_UNORDERED_ACCESS) {
            descriptor.usage |= MTLTextureUsageShaderWrite;
            flags |= D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        }
        const D3D12_RESOURCE_DESC resource = {D3D12_RESOURCE_DIMENSION_TEXTURE2D, D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT,
                                              desc.Width, desc.Height, 1, 1, desc.Format, {1, 0}, D3D12_TEXTURE_LAYOUT_UNKNOWN, flags};
        std::vector<BackBuffer *> buffers;
        for (UINT i = 0; i < desc.BufferCount; ++i) {
            id<MTLTexture> texture = [queue_.device newTextureWithDescriptor:descriptor];
            if (!texture) {
                for (BackBuffer *buffer : buffers) buffer->Release();
                return E_OUTOFMEMORY;
            }
            texture.label = [NSString stringWithFormat:@"DXGI back buffer %u", i];
            buffers.push_back(new BackBuffer(device_, texture, resource));
        }
        [last_ waitUntilCompleted];
        for (BackBuffer *buffer : buffers_) buffer->Release();
        buffers_ = std::move(buffers);
        desc_ = desc;
        index_ = 0;
        source_width_ = desc.Width;
        source_height_ = desc.Height;
        layer_transaction([&] {
            layer_.pixelFormat = format;
            layer_.drawableSize = CGSizeMake(desc.Width, desc.Height);
        });
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        return query<IUnknown, IDXGIObject, IDXGIDeviceSubObject, IDXGISwapChain, IDXGISwapChain1, IDXGISwapChain2,
                     IDXGISwapChain3>(riid, out);
    }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID name, UINT size, const void *data) override { return data_.set(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID name, const IUnknown *object) override { return data_.set_interface(name, object); }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID name, UINT *size, void *data) override { return data_.get(name, size, data); }
    HRESULT STDMETHODCALLTYPE GetParent(REFIID riid, void **out) override { return query_out(factory_, riid, out); }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID riid, void **out) override { return get_queue_device(device_, riid, out); }

    HRESULT STDMETHODCALLTYPE Present(UINT sync, UINT flags) override {
        if (sync > 4) return DXGI_ERROR_INVALID_CALL;
        if ((flags & DXGI_PRESENT_ALLOW_TEARING) && (sync || !(desc_.Flags & DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING) || fullscreen_))
            return DXGI_ERROR_INVALID_CALL;
        ID3D12Device *device = nullptr;
        if (SUCCEEDED(GetDevice(__uuidof(ID3D12Device), (void **)&device))) {
            const HRESULT reason = device->GetDeviceRemovedReason();
            device->Release();
            if (FAILED(reason)) return reason;
        }
        if (flags & DXGI_PRESENT_TEST) return S_OK;
        D3DMSchedulePipelineArchiveFlush();
        std::lock_guard lock(mutex_);
        @autoreleasepool {
            const CGSize size = CGSizeMake(source_width_, source_height_);
            double minimum_duration = 0;
            if (sync > 1) minimum_duration = sync / refresh_;
            if (std::isfinite(host.minimum_present_duration) && host.minimum_present_duration > 0 && host.minimum_present_duration <= 1)
                minimum_duration = std::max(minimum_duration, host.minimum_present_duration);
            const bool vsync = sync != 0 || minimum_duration > 0;
            if (!CGSizeEqualToSize(layer_.drawableSize, size) || vsync != vsync_) {
                layer_transaction([&] {
                    layer_.drawableSize = size;
                    layer_.displaySyncEnabled = vsync;
                });
                vsync_ = vsync;
            }
            id<CAMetalDrawable> drawable = [layer_ nextDrawable];
            BackBuffer *buffer = buffers_[index_];
            if (!drawable) return DXGI_STATUS_OCCLUDED;
            index_ = (index_ + 1) % (UINT)buffers_.size();
            ++present_count_;
            id<MTLTexture> source = (__bridge id<MTLTexture>)buffer->MetalTexture();
            id<MTLCommandBuffer> commands = [queue_ commandBuffer];
            commands.label = @"DXGI present";
            id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
            // The host may resize the drawable between frames; copy the overlapping region.
            const MTLSize copy = MTLSizeMake(std::min(source_width_, (UINT)drawable.texture.width),
                                             std::min(source_height_, (UINT)drawable.texture.height), 1);
            [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:copy
                        toTexture:drawable.texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
            if (minimum_duration > 0) [commands presentDrawable:drawable afterMinimumDuration:minimum_duration];
            else [commands presentDrawable:drawable];
            if (latency_event_) {
                const auto event = latency_event_;
                [drawable addPresentedHandler:^(id<MTLDrawable>) { event->signal(); }];
            }
            track_device_errors(device_, commands);
            [commands commit];
            last_ = commands;
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetBuffer(UINT index, REFIID riid, void **out) override {
        if (!out) return E_INVALIDARG;
        *out = nullptr;
        std::lock_guard lock(mutex_);
        if (index >= buffers_.size()) return DXGI_ERROR_INVALID_CALL;
        return buffers_[index]->QueryInterface(riid, out);
    }
    HRESULT STDMETHODCALLTYPE SetFullscreenState(WINBOOL fullscreen, IDXGIOutput *target) override {
        if (!fullscreen && target) return DXGI_ERROR_INVALID_CALL;
        if ((fullscreen != 0) == (fullscreen_ != 0) && !target) return S_OK;
        if (!host.set_fullscreen) return fullscreen ? DXGI_ERROR_NOT_CURRENTLY_AVAILABLE : S_OK;
        IDXGIOutput *output = nullptr;
        if (fullscreen) {
            if (target) { target->AddRef(); output = target; }
            else if (FAILED(GetContainingOutput(&output))) return DXGI_ERROR_NOT_FOUND;
        }
        DXGI_OUTPUT_DESC desc = {};
        if (output) output->GetDesc(&desc);
        const HRESULT hr = host.set_fullscreen(window_, fullscreen, desc.Monitor);
        if (SUCCEEDED(hr)) {
            fullscreen_ = fullscreen != 0;
            if (fullscreen_output_) fullscreen_output_->Release();
            fullscreen_output_ = output;
        } else if (output) output->Release();
        return hr;
    }
    HRESULT STDMETHODCALLTYPE GetFullscreenState(WINBOOL *fullscreen, IDXGIOutput **target) override {
        if (fullscreen) *fullscreen = fullscreen_;
        if (!target) return S_OK;
        *target = nullptr;
        if (fullscreen_output_) fullscreen_output_->AddRef();
        *target = fullscreen_output_;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDesc(DXGI_SWAP_CHAIN_DESC *desc) override {
        if (!desc) return E_INVALIDARG;
        *desc = {{desc_.Width, desc_.Height, fullscreen_desc_.RefreshRate, desc_.Format, fullscreen_desc_.ScanlineOrdering,
                  fullscreen_desc_.Scaling},
                 desc_.SampleDesc, desc_.BufferUsage, desc_.BufferCount, window_, !fullscreen_, desc_.SwapEffect, desc_.Flags};
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE ResizeBuffers(UINT count, UINT width, UINT height, DXGI_FORMAT format, UINT flags) override {
        std::lock_guard lock(mutex_);
        if (flags & ~(DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT | DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING))
            return DXGI_ERROR_UNSUPPORTED;
        for (BackBuffer *buffer : buffers_) if (buffer->references() > 1) return DXGI_ERROR_INVALID_CALL;
        if (count && (count < 2 || count > DXGI_MAX_SWAP_CHAIN_BUFFERS)) return DXGI_ERROR_INVALID_CALL;
        if (format != DXGI_FORMAT_UNKNOWN && pixel_format(format) == MTLPixelFormatInvalid) return DXGI_ERROR_INVALID_CALL;
        if ((flags ^ desc_.Flags) & (DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT | DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING))
            return DXGI_ERROR_INVALID_CALL;
        if (!width || !height) {
            const CGSize client = pixel_size(layer_);
            if (!width) width = (UINT)client.width;
            if (!height) height = (UINT)client.height;
        }
        DXGI_SWAP_CHAIN_DESC1 actual = desc_;
        if (count) actual.BufferCount = count;
        if (format != DXGI_FORMAT_UNKNOWN) actual.Format = format;
        actual.Width = std::max(width, 1u);
        actual.Height = std::max(height, 1u);
        actual.Flags = flags;
        return create_buffers(actual);
    }
    HRESULT STDMETHODCALLTYPE ResizeTarget(const DXGI_MODE_DESC *) override { return DXGI_ERROR_UNSUPPORTED; }
    HRESULT STDMETHODCALLTYPE GetContainingOutput(IDXGIOutput **out) override {
        if (!out) return E_INVALIDARG;
        *out = nullptr;
        const auto list = outputs();
        const HMONITOR monitor = host.window_monitor ? host.window_monitor(window_) : nullptr;
        UINT index = 0;
        if (monitor) {
            for (UINT i = 0; i < list.size(); ++i) if (list[i].monitor == monitor) index = i;
        }
        IDXGIAdapter4 *adapter = create_adapter(factory_, queue_.device);
        *out = create_output(adapter, index);
        adapter->Release();
        return *out ? S_OK : DXGI_ERROR_NOT_FOUND;
    }
    HRESULT STDMETHODCALLTYPE GetFrameStatistics(DXGI_FRAME_STATISTICS *) override { return DXGI_ERROR_FRAME_STATISTICS_DISJOINT; }
    HRESULT STDMETHODCALLTYPE GetLastPresentCount(UINT *count) override {
        if (!count) return E_INVALIDARG;
        *count = present_count_;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetDesc1(DXGI_SWAP_CHAIN_DESC1 *desc) override {
        if (!desc) return E_INVALIDARG;
        *desc = desc_;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetFullscreenDesc(DXGI_SWAP_CHAIN_FULLSCREEN_DESC *desc) override {
        if (!desc) return E_INVALIDARG;
        *desc = fullscreen_desc_;
        desc->Windowed = !fullscreen_;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetHwnd(HWND *window) override {
        if (!window) return E_INVALIDARG;
        *window = window_;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetCoreWindow(REFIID, void **out) override {
        if (out) *out = nullptr;
        return DXGI_ERROR_INVALID_CALL;
    }
    HRESULT STDMETHODCALLTYPE Present1(UINT sync, UINT flags, const DXGI_PRESENT_PARAMETERS *) override { return Present(sync, flags); }
    WINBOOL STDMETHODCALLTYPE IsTemporaryMonoSupported() override { return FALSE; }
    HRESULT STDMETHODCALLTYPE GetRestrictToOutput(IDXGIOutput **out) override {
        if (!out) return E_INVALIDARG;
        if (restrict_to_) restrict_to_->AddRef();
        *out = restrict_to_;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetBackgroundColor(const DXGI_RGBA *color) override {
        if (!color) return E_INVALIDARG;
        background_ = *color;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetBackgroundColor(DXGI_RGBA *color) override {
        if (!color) return E_INVALIDARG;
        *color = background_;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetRotation(DXGI_MODE_ROTATION rotation) override {
        return rotation == DXGI_MODE_ROTATION_IDENTITY ? S_OK : DXGI_ERROR_UNSUPPORTED;
    }
    HRESULT STDMETHODCALLTYPE GetRotation(DXGI_MODE_ROTATION *rotation) override {
        if (!rotation) return E_INVALIDARG;
        *rotation = DXGI_MODE_ROTATION_IDENTITY;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE SetSourceSize(UINT width, UINT height) override {
        std::lock_guard lock(mutex_);
        if (!width || !height || width > desc_.Width || height > desc_.Height) return DXGI_ERROR_INVALID_CALL;
        source_width_ = width;
        source_height_ = height;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetSourceSize(UINT *width, UINT *height) override {
        if (!width || !height) return E_INVALIDARG;
        std::lock_guard lock(mutex_);
        *width = source_width_;
        *height = source_height_;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetMaximumFrameLatency(UINT latency) override {
        if (!latency_event_ || !latency || latency > DXGI_MAX_SWAP_CHAIN_BUFFERS) return DXGI_ERROR_INVALID_CALL;
        std::lock_guard lock(mutex_);
        std::lock_guard event_lock(latency_event_->mutex);
        for (UINT i = latency; i < latency_; ++i)
            if (!host.try_wait_semaphore(latency_event_->handle)) ++latency_event_->debt;
        for (UINT i = latency_; i < latency; ++i) {
            if (latency_event_->debt) --latency_event_->debt;
            else host.release_semaphore(latency_event_->handle, 1);
        }
        latency_ = latency;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetMaximumFrameLatency(UINT *latency) override {
        if (!latency_event_ || !latency) return DXGI_ERROR_INVALID_CALL;
        *latency = latency_;
        return S_OK;
    }
    HANDLE STDMETHODCALLTYPE GetFrameLatencyWaitableObject() override {
        return latency_event_ ? host.duplicate_handle(latency_event_->handle) : nullptr;
    }
    // Matrix transforms belong to composition swap chains only.
    HRESULT STDMETHODCALLTYPE SetMatrixTransform(const DXGI_MATRIX_3X2_F *) override { return DXGI_ERROR_INVALID_CALL; }
    HRESULT STDMETHODCALLTYPE GetMatrixTransform(DXGI_MATRIX_3X2_F *) override { return DXGI_ERROR_INVALID_CALL; }

    UINT STDMETHODCALLTYPE GetCurrentBackBufferIndex() override {
        std::lock_guard lock(mutex_);
        return index_;
    }
    HRESULT STDMETHODCALLTYPE CheckColorSpaceSupport(DXGI_COLOR_SPACE_TYPE space, UINT *support) override {
        if (!support) return E_INVALIDARG;
        *support = color_space_supported(desc_.Format, space) ? DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT : 0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetColorSpace1(DXGI_COLOR_SPACE_TYPE space) override {
        if (!color_space_supported(desc_.Format, space)) return E_INVALIDARG;
        CFStringRef name = kCGColorSpaceSRGB;
        if (space == DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709) name = kCGColorSpaceExtendedLinearSRGB;
        if (space == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020) name = kCGColorSpaceITUR_2100_PQ;
        layer_transaction([&] {
            CGColorSpaceRef color_space = CGColorSpaceCreateWithName(name);
            layer_.colorspace = color_space;
            CGColorSpaceRelease(color_space);
            layer_.wantsExtendedDynamicRangeContent = space != DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
        });
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE ResizeBuffers1(UINT count, UINT width, UINT height, DXGI_FORMAT format, UINT flags, const UINT *masks,
                                             IUnknown *const *queues) override {
        if (count > DXGI_MAX_SWAP_CHAIN_BUFFERS) return DXGI_ERROR_INVALID_CALL;
        const UINT actual = count ? count : desc_.BufferCount;
        for (UINT i = 0; i < actual; ++i) {
            if (masks && masks[i] > 1) return DXGI_ERROR_INVALID_CALL;
            if (queues && queues[i] != device_) return DXGI_ERROR_UNSUPPORTED;
        }
        return ResizeBuffers(count, width, height, format, flags);
    }

private:
    IDXGIFactory *factory_;
    IUnknown *device_;
    IDXGIOutput *restrict_to_;
    IDXGIOutput *fullscreen_output_ = nullptr;
    id<MTLCommandQueue> queue_;
    CAMetalLayer *layer_;
    id<MTLCommandBuffer> last_;
    HWND window_;
    DXGI_SWAP_CHAIN_DESC1 desc_;
    DXGI_SWAP_CHAIN_FULLSCREEN_DESC fullscreen_desc_;
    WINBOOL fullscreen_;
    double refresh_;
    std::vector<BackBuffer *> buffers_;
    UINT index_ = 0, present_count_ = 0, source_width_ = 0, source_height_ = 0, latency_ = 1;
    bool vsync_ = true;
    std::shared_ptr<Latency> latency_event_;
    DXGI_RGBA background_ = {};
    std::recursive_mutex mutex_;
    PrivateData data_;
};

} // namespace

HRESULT create_swap_chain(IDXGIFactory *factory, IUnknown *device, HWND window, const DXGI_SWAP_CHAIN_DESC1 *desc,
                          const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *fullscreen, IDXGIOutput *restrict_to, IDXGISwapChain1 **out) {
    if (!out) return DXGI_ERROR_INVALID_CALL;
    *out = nullptr;
    if (!device || !window || !desc) return DXGI_ERROR_INVALID_CALL;
    if (desc->Flags & ~(DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT | DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING))
        return DXGI_ERROR_UNSUPPORTED;
    const bool flip = desc->SwapEffect == DXGI_SWAP_EFFECT_FLIP_DISCARD || desc->SwapEffect == DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    if (!flip || desc->Stereo || desc->SampleDesc.Count != 1 || desc->SampleDesc.Quality ||
        desc->BufferCount < 2 || desc->BufferCount > DXGI_MAX_SWAP_CHAIN_BUFFERS || pixel_format(desc->Format) == MTLPixelFormatInvalid)
        return DXGI_ERROR_INVALID_CALL;
    const bool waitable = desc->Flags & DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
    if (waitable && !(host.create_semaphore && host.release_semaphore && host.duplicate_handle && host.close_handle && host.try_wait_semaphore))
        return DXGI_ERROR_UNSUPPORTED;
    CAMetalLayer *layer = host.metal_layer ? (__bridge CAMetalLayer *)host.metal_layer(window) : nil;
    if (![layer isKindOfClass:CAMetalLayer.class]) return DXGI_ERROR_INVALID_CALL;
    ID3DMMetalQueue *metal = nullptr;
    if (FAILED(device->QueryInterface(__uuidof(ID3DMMetalQueue), (void **)&metal))) return DXGI_ERROR_INVALID_CALL;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)metal->MetalCommandQueue();
    metal->Release();
    if (!queue) return DXGI_ERROR_INVALID_CALL;

    @autoreleasepool {
        DXGI_SWAP_CHAIN_DESC1 actual = *desc;
        if (!actual.Width || !actual.Height) {
            const CGSize client = pixel_size(layer);
            if (!actual.Width) actual.Width = std::max((UINT)client.width, 1u);
            if (!actual.Height) actual.Height = std::max((UINT)client.height, 1u);
        }
        const DXGI_SWAP_CHAIN_FULLSCREEN_DESC windowed = {{0, 1}, DXGI_MODE_SCANLINE_ORDER_UNSPECIFIED, DXGI_MODE_SCALING_UNSPECIFIED, TRUE};
        SwapChain *chain = new SwapChain(factory, device, queue, layer, window, actual, fullscreen ? *fullscreen : windowed, restrict_to);
        HRESULT hr = chain->create_buffers(actual);
        if (SUCCEEDED(hr) && fullscreen && !fullscreen->Windowed) hr = chain->SetFullscreenState(TRUE, restrict_to);
        if (FAILED(hr)) {
            chain->Release();
            return hr;
        }
        *out = chain;
        return S_OK;
    }
}

} // namespace d3dm
