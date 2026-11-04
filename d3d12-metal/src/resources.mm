#include "resources.h"
#include "formats.h"
#include "descriptors.h"

#include <algorithm>
#include <bit>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <limits>
#include <new>
#include <map>

namespace d3dm {
namespace {
struct AddressEntry { ID3D12Device *device; id<MTLBuffer> buffer; UINT64 size; };
std::mutex address_mutex;
std::multimap<UINT64, AddressEntry> addresses;
constexpr uint64_t page = D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT;
constexpr D3D12_RESOURCE_ALLOCATION_INFO invalid_allocation = {UINT64_MAX, page};

bool align_up(uint64_t value, uint64_t alignment, uint64_t &out) {
    if (!std::has_single_bit(alignment) || value > UINT64_MAX - (alignment - 1)) return false;
    out = (value + alignment - 1) & ~(alignment - 1);
    return true;
}

D3D12_HEAP_PROPERTIES abstract_properties(D3D12_HEAP_TYPE type) {
    D3D12_FEATURE_DATA_ARCHITECTURE1 architecture = {};
    if (host.check_feature && FAILED(host.check_feature(D3D12_FEATURE_ARCHITECTURE1, &architecture, sizeof architecture))) architecture = {};
    D3D12_HEAP_PROPERTIES result = {D3D12_HEAP_TYPE_CUSTOM, D3D12_CPU_PAGE_PROPERTY_NOT_AVAILABLE,
                                   D3D12_MEMORY_POOL_L0, 1, 1};
    switch (type) {
    case D3D12_HEAP_TYPE_DEFAULT:
        if (!architecture.UMA) result.MemoryPoolPreference = D3D12_MEMORY_POOL_L1;
        break;
    case D3D12_HEAP_TYPE_UPLOAD:
        result.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_WRITE_COMBINE;
        if (architecture.UMA && architecture.CacheCoherentUMA) result.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_WRITE_BACK;
        break;
    case D3D12_HEAP_TYPE_READBACK: result.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_WRITE_BACK; break;
    default: return {};
    }
    return result;
}

HRESULT normalize_properties(const D3D12_HEAP_PROPERTIES &input, D3D12_HEAP_PROPERTIES &out, MTLResourceOptions &options) {
    out = input;
    if (out.CreationNodeMask > 1 || out.VisibleNodeMask > 1) return E_INVALIDARG;
    out.CreationNodeMask = out.VisibleNodeMask = 1;
    MTLStorageMode storage = MTLStorageModePrivate;
    MTLCPUCacheMode cache = MTLCPUCacheModeDefaultCache;
    switch (out.Type) {
    case D3D12_HEAP_TYPE_DEFAULT: case D3D12_HEAP_TYPE_UPLOAD: case D3D12_HEAP_TYPE_READBACK:
        if (out.CPUPageProperty != D3D12_CPU_PAGE_PROPERTY_UNKNOWN || out.MemoryPoolPreference != D3D12_MEMORY_POOL_UNKNOWN)
            return E_INVALIDARG;
        if (out.Type != D3D12_HEAP_TYPE_DEFAULT) storage = MTLStorageModeShared;
        if (out.Type == D3D12_HEAP_TYPE_UPLOAD && abstract_properties(out.Type).CPUPageProperty == D3D12_CPU_PAGE_PROPERTY_WRITE_COMBINE)
            cache = MTLCPUCacheModeWriteCombined;
        break;
    case D3D12_HEAP_TYPE_CUSTOM:
        if (out.MemoryPoolPreference != D3D12_MEMORY_POOL_L0 && out.MemoryPoolPreference != D3D12_MEMORY_POOL_L1)
            return E_INVALIDARG;
        switch (out.CPUPageProperty) {
        case D3D12_CPU_PAGE_PROPERTY_NOT_AVAILABLE: break;
        case D3D12_CPU_PAGE_PROPERTY_WRITE_COMBINE: case D3D12_CPU_PAGE_PROPERTY_WRITE_BACK:
            if (out.MemoryPoolPreference != D3D12_MEMORY_POOL_L0) return E_INVALIDARG;
            storage = MTLStorageModeShared;
            if (out.CPUPageProperty == D3D12_CPU_PAGE_PROPERTY_WRITE_COMBINE) cache = MTLCPUCacheModeWriteCombined;
            break;
        default: return E_INVALIDARG;
        }
        break;
    default: return E_INVALIDARG;
    }
    options = (MTLResourceOptions)((storage << MTLResourceStorageModeShift) | (cache << MTLResourceCPUCacheModeShift) |
                                  (MTLHazardTrackingModeTracked << MTLResourceHazardTrackingModeShift));
    return S_OK;
}

struct Layout {
    D3D12_RESOURCE_DESC desc = {};
    FormatInfo format;
    MTLTextureDescriptor *texture = nil;
    MTLSizeAndAlign native = {};
    D3D12_RESOURCE_ALLOCATION_INFO allocation = invalid_allocation;
};

HRESULT resource_layout(id<MTLDevice> metal, const D3D12_RESOURCE_DESC &input, MTLResourceOptions options, Layout &layout) {
    auto &desc = layout.desc;
    desc = input;
    constexpr UINT supported = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET | D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL |
        D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS | D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE | D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS;
    if ((UINT)desc.Flags & ~supported) return DXGI_ERROR_UNSUPPORTED;
    if (!desc.Width || !desc.Height || !desc.DepthOrArraySize || !desc.SampleDesc.Count || desc.SampleDesc.Quality)
        return E_INVALIDARG;
    uint64_t alignment = desc.Alignment;
    if (desc.Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) {
        if (desc.Width > metal.maxBufferLength || desc.Height != 1 || desc.DepthOrArraySize != 1 || desc.MipLevels != 1 ||
            desc.Format != DXGI_FORMAT_UNKNOWN || desc.SampleDesc.Count != 1 || desc.Layout != D3D12_TEXTURE_LAYOUT_ROW_MAJOR ||
            (desc.Flags & (D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET | D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL |
                           D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS)) || (alignment && alignment != page)) return E_INVALIDARG;
        alignment = page;
        layout.native = [metal heapBufferSizeAndAlignWithLength:desc.Width options:options];
    } else {
        const FormatInfo format = format_info(desc.Format);
        layout.format = format;
        if (format.metal == MTLPixelFormatInvalid || format.view_only || desc.Layout != D3D12_TEXTURE_LAYOUT_UNKNOWN)
            return E_INVALIDARG;
        if (format.block > 1 && !metal.supportsBCTextureCompression) return DXGI_ERROR_UNSUPPORTED;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (format.family == DXGI_FORMAT_R24G8_TYPELESS && !metal.depth24Stencil8PixelFormatSupported) return DXGI_ERROR_UNSUPPORTED;
#pragma clang diagnostic pop
        const bool target = desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        const bool depth = desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
        const bool write = desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        if ((target && depth) || (depth && write) || (format.block > 1 && (target || depth || write || desc.SampleDesc.Count != 1)) ||
            (depth && format.family != DXGI_FORMAT_R32_TYPELESS && format.family != DXGI_FORMAT_R16_TYPELESS && !format.depth) ||
            (format.depth && (target || write))) return E_INVALIDARG;
        if (depth && (desc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D ||
                      (desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS))) return E_INVALIDARG;
        if (write && (desc.Format == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB || desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB ||
                      desc.Format == DXGI_FORMAT_B8G8R8X8_UNORM_SRGB)) return E_INVALIDARG;
        UINT maximum = 16384;
        switch (desc.Dimension) {
        case D3D12_RESOURCE_DIMENSION_TEXTURE1D:
            if (desc.Height != 1 || desc.SampleDesc.Count != 1 || desc.DepthOrArraySize > 2048) return E_INVALIDARG;
            break;
        case D3D12_RESOURCE_DIMENSION_TEXTURE2D:
            if (desc.DepthOrArraySize > 2048) return E_INVALIDARG;
            break;
        case D3D12_RESOURCE_DIMENSION_TEXTURE3D:
            maximum = 2048;
            if (desc.SampleDesc.Count != 1 || desc.DepthOrArraySize > maximum || depth || format.block > 1) return E_INVALIDARG;
            break;
        default: return E_INVALIDARG;
        }
        if (desc.Width > maximum || desc.Height > maximum || ![metal supportsTextureSampleCount:desc.SampleDesc.Count]) return E_INVALIDARG;
        uint64_t extent = std::max<uint64_t>(desc.Width, desc.Height);
        if (desc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D) extent = std::max<uint64_t>(extent, desc.DepthOrArraySize);
        const UINT mips = std::bit_width(extent);
        if (!desc.MipLevels) desc.MipLevels = mips;
        if (desc.MipLevels > mips || (desc.SampleDesc.Count > 1 && (desc.MipLevels != 1 || write))) return E_INVALIDARG;
        const uint64_t normal = desc.SampleDesc.Count > 1 ? D3D12_DEFAULT_MSAA_RESOURCE_PLACEMENT_ALIGNMENT : page;
        const uint64_t small = desc.SampleDesc.Count > 1 ? page : D3D12_SMALL_RESOURCE_PLACEMENT_ALIGNMENT;
        if (!alignment) alignment = normal;
        if (alignment != normal && alignment != small) return E_INVALIDARG;
        if (alignment == small && (target || depth)) return E_INVALIDARG;
        MTLTextureDescriptor *texture = [MTLTextureDescriptor new];
        texture.pixelFormat = format.metal;
        if (depth && format.family == DXGI_FORMAT_R32_TYPELESS) texture.pixelFormat = MTLPixelFormatDepth32Float;
        if (depth && format.family == DXGI_FORMAT_R16_TYPELESS) texture.pixelFormat = MTLPixelFormatDepth16Unorm;
        texture.width = desc.Width;
        texture.height = desc.Height;
        texture.depth = 1;
        texture.arrayLength = desc.DepthOrArraySize;
        texture.textureType = MTLTextureType2DArray;
        if (desc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D) {
            texture.textureType = MTLTextureType3D;
            texture.depth = desc.DepthOrArraySize;
            texture.arrayLength = 1;
        } else if (desc.SampleDesc.Count > 1) texture.textureType = MTLTextureType2DMultisampleArray;
        texture.mipmapLevelCount = desc.MipLevels;
        texture.sampleCount = desc.SampleDesc.Count;
        texture.resourceOptions = options;
        // Unneeded view flags disable lossless compression on Apple GPUs.
        texture.usage = format_needs_pixel_format_view(desc.Format) ? MTLTextureUsagePixelFormatView : MTLTextureUsageUnknown;
        if (!(desc.Flags & D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE)) texture.usage |= MTLTextureUsageShaderRead;
        if (target || depth) texture.usage |= MTLTextureUsageRenderTarget;
        if (write) texture.usage |= MTLTextureUsageShaderWrite;
        if (texture.storageMode == MTLStorageModeShared && (depth || format.depth || desc.SampleDesc.Count > 1)) return E_INVALIDARG;
        layout.texture = texture;
        layout.native = [metal heapTextureSizeAndAlignWithDescriptor:texture];
    }
    if (!layout.native.size || !std::has_single_bit((uint64_t)layout.native.align)) return E_INVALIDARG;
    uint64_t size = layout.native.size;
    // A 4 KiB D3D slot can start before Metal's aligned offset; reserve that alignment slack inside the slot.
    if (layout.native.align > alignment) {
        if (size > UINT64_MAX - layout.native.align) return E_INVALIDARG;
        size += layout.native.align;
    }
    if (!align_up(size, alignment, size)) return E_INVALIDARG;
    layout.allocation = {size, alignment};
    return S_OK;
}

HRESULT validate_resource(const D3D12_HEAP_PROPERTIES &properties, D3D12_HEAP_FLAGS flags, const Layout &layout,
                          D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE *clear) {
    const auto &desc = layout.desc;
    constexpr UINT supported = D3D12_HEAP_FLAG_DENY_BUFFERS | D3D12_HEAP_FLAG_DENY_RT_DS_TEXTURES | D3D12_HEAP_FLAG_DENY_NON_RT_DS_TEXTURES;
    if ((UINT)flags & ~supported) return DXGI_ERROR_UNSUPPORTED;
    if (desc.Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) {
        if ((flags & D3D12_HEAP_FLAG_DENY_BUFFERS) || clear) return E_INVALIDARG;
    } else {
        const bool target = desc.Flags & (D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET | D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL);
        if ((target && (flags & D3D12_HEAP_FLAG_DENY_RT_DS_TEXTURES)) ||
            (!target && (flags & D3D12_HEAP_FLAG_DENY_NON_RT_DS_TEXTURES))) return E_INVALIDARG;
        if (properties.Type == D3D12_HEAP_TYPE_UPLOAD || properties.Type == D3D12_HEAP_TYPE_READBACK) return E_INVALIDARG;
        if (clear) {
            const FormatInfo format = format_info(clear->Format);
            if (!target || format.typeless || format.family != layout.format.family || format.metal == MTLPixelFormatInvalid)
                return E_INVALIDARG;
            if (desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL) {
                if (!format.depth || clear->DepthStencil.Depth < 0 || clear->DepthStencil.Depth > 1 ||
                    !std::isfinite(clear->DepthStencil.Depth)) return E_INVALIDARG;
            } else if (format.depth) return E_INVALIDARG;
        }
    }
    constexpr UINT reads = D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER | D3D12_RESOURCE_STATE_INDEX_BUFFER |
        D3D12_RESOURCE_STATE_DEPTH_READ | D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE |
        D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT | D3D12_RESOURCE_STATE_COPY_SOURCE | D3D12_RESOURCE_STATE_RESOLVE_SOURCE;
    constexpr UINT writes = D3D12_RESOURCE_STATE_RENDER_TARGET | D3D12_RESOURCE_STATE_UNORDERED_ACCESS | D3D12_RESOURCE_STATE_DEPTH_WRITE |
        D3D12_RESOURCE_STATE_STREAM_OUT | D3D12_RESOURCE_STATE_COPY_DEST | D3D12_RESOURCE_STATE_RESOLVE_DEST;
    const UINT write_state = (UINT)state & writes;
    if (((UINT)state & ~(reads | writes)) || (write_state && (!std::has_single_bit(write_state) || ((UINT)state & reads)))) return E_INVALIDARG;
    if ((state & D3D12_RESOURCE_STATE_RENDER_TARGET) && !(desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET)) return E_INVALIDARG;
    if ((state & D3D12_RESOURCE_STATE_UNORDERED_ACCESS) && !(desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS)) return E_INVALIDARG;
    if ((state & (D3D12_RESOURCE_STATE_DEPTH_READ | D3D12_RESOURCE_STATE_DEPTH_WRITE)) &&
        !(desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL)) return E_INVALIDARG;
    if ((desc.Flags & D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE) &&
        (state & (D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE))) return E_INVALIDARG;
    if (desc.Dimension == D3D12_RESOURCE_DIMENSION_BUFFER &&
        (state & (D3D12_RESOURCE_STATE_DEPTH_READ | D3D12_RESOURCE_STATE_DEPTH_WRITE | D3D12_RESOURCE_STATE_RENDER_TARGET |
                  D3D12_RESOURCE_STATE_RESOLVE_SOURCE | D3D12_RESOURCE_STATE_RESOLVE_DEST))) return E_INVALIDARG;
    if (properties.Type == D3D12_HEAP_TYPE_UPLOAD && (state != D3D12_RESOURCE_STATE_GENERIC_READ ||
        (desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS))) return E_INVALIDARG;
    if (properties.Type == D3D12_HEAP_TYPE_READBACK && (state != D3D12_RESOURCE_STATE_COPY_DEST ||
        (desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS))) return E_INVALIDARG;
    return S_OK;
}

class Heap final : public Object<ID3D12Heap>, public ID3DMMetalHeap {
public:
    Heap(ID3D12Device *device, id<MTLHeap> metal, const D3D12_HEAP_DESC &desc) : device_(device), metal_(metal), desc_(desc) { device_->AddRef(); }
    ~Heap() override { device_->Release(); }
    ULONG STDMETHODCALLTYPE AddRef() override { return Object::AddRef(); }
    ULONG STDMETHODCALLTYPE Release() override { return Object::Release(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (out && iid == __uuidof(ID3DMMetalHeap)) { AddRef(); *out = static_cast<ID3DMMetalHeap *>(this); return S_OK; }
        return query<IUnknown, ID3D12Object, ID3D12DeviceChild, ID3D12Pageable, ID3D12Heap>(iid, out);
    }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID name, UINT *size, void *data) override { return data_.get(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID name, UINT size, const void *data) override { return data_.set(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID name, const IUnknown *object) override { return data_.set_interface(name, object); }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR name) override {
        metal_.label = name ? [[NSString alloc] initWithBytes:name length:wcslen(name) * sizeof(WCHAR) encoding:NSUTF32LittleEndianStringEncoding] : nil;
        return data_.set(WKPDID_D3DDebugObjectNameW, name ? (UINT)((wcslen(name) + 1) * sizeof(WCHAR)) : 0, name);
    }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID iid, void **out) override { return device_->QueryInterface(iid, out); }
    D3D12_HEAP_DESC STDMETHODCALLTYPE GetDesc() override { return desc_; }
    void *STDMETHODCALLTYPE MetalHeap() override { return (__bridge void *)metal_; }
private:
    ID3D12Device *device_;
    id<MTLHeap> metal_;
    D3D12_HEAP_DESC desc_;
    PrivateData data_;
};

class Resource final : public Object<ID3D12Resource>, public ID3DMMetalBuffer, public ID3DMMetalTexture {
public:
    Resource(ID3D12Device *device, ID3D12Heap *heap, const Layout &layout, const D3D12_HEAP_PROPERTIES &properties,
             D3D12_HEAP_FLAGS flags, id<MTLBuffer> buffer, id<MTLTexture> texture)
        : device_(device), heap_(heap), desc_(layout.desc), properties_(properties), flags_(flags), buffer_(buffer), texture_(texture),
          format_(layout.format) {
        device_->AddRef();
        if (heap_) heap_->AddRef();
        if (buffer_) {
            std::lock_guard lock(address_mutex);
            addresses.emplace(buffer_.gpuAddress, AddressEntry{device_, buffer_, desc_.Width});
        }
    }
    ~Resource() override {
        if (buffer_) release_resource_descriptors(device_, buffer_);
        if (texture_) release_resource_descriptors(device_, texture_);
        if (buffer_) {
            std::lock_guard lock(address_mutex);
            auto [first, last] = addresses.equal_range(buffer_.gpuAddress);
            for (auto it = first; it != last; ++it) {
                if (it->second.buffer == buffer_) { addresses.erase(it); break; }
            }
        }
        if (heap_) heap_->Release();
        device_->Release();
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return Object::AddRef(); }
    ULONG STDMETHODCALLTYPE Release() override { return Object::Release(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (out && iid == __uuidof(ID3DMMetalBuffer) && desc_.Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) { AddRef(); *out = static_cast<ID3DMMetalBuffer *>(this); return S_OK; }
        if (out && iid == __uuidof(ID3DMMetalTexture) && desc_.Dimension != D3D12_RESOURCE_DIMENSION_BUFFER) { AddRef(); *out = static_cast<ID3DMMetalTexture *>(this); return S_OK; }
        return query<IUnknown, ID3D12Object, ID3D12DeviceChild, ID3D12Pageable, ID3D12Resource>(iid, out);
    }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID name, UINT *size, void *data) override { return data_.get(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID name, UINT size, const void *data) override { return data_.set(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID name, const IUnknown *object) override { return data_.set_interface(name, object); }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR name) override {
        NSString *text = name ? [[NSString alloc] initWithBytes:name length:wcslen(name) * sizeof(WCHAR) encoding:NSUTF32LittleEndianStringEncoding] : nil;
        buffer_.label = text;
        texture_.label = text;
        return data_.set(WKPDID_D3DDebugObjectNameW, name ? (UINT)((wcslen(name) + 1) * sizeof(WCHAR)) : 0, name);
    }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID iid, void **out) override { return device_->QueryInterface(iid, out); }
    HRESULT STDMETHODCALLTYPE Map(UINT subresource, const D3D12_RANGE *range, void **out) override {
        if (out) *out = nullptr;
        const HRESULT reason = device_->GetDeviceRemovedReason();
        if (FAILED(reason)) return reason;
        if (!cpu_visible() || subresource >= subresource_count()) return E_INVALIDARG;
        if (buffer_) {
            if (range && (range->Begin > range->End || range->End > desc_.Width)) return E_INVALIDARG;
            std::atomic_thread_fence(std::memory_order_acquire);
            if (out) *out = buffer_.contents;
            return S_OK;
        }
        // Opaque texture layouts have no linear pointer; Map(nullptr) enables Read/WriteToSubresource.
        return out ? E_INVALIDARG : S_OK;
    }
    void STDMETHODCALLTYPE Unmap(UINT, const D3D12_RANGE *) override { std::atomic_thread_fence(std::memory_order_release); }
    D3D12_RESOURCE_DESC STDMETHODCALLTYPE GetDesc() override { return desc_; }
    D3D12_GPU_VIRTUAL_ADDRESS STDMETHODCALLTYPE GetGPUVirtualAddress() override { return buffer_ ? buffer_.gpuAddress : 0; }
    HRESULT STDMETHODCALLTYPE WriteToSubresource(UINT subresource, const D3D12_BOX *box, const void *source, UINT row, UINT depth) override {
        return transfer(subresource, box, const_cast<void *>(source), row, depth, true);
    }
    HRESULT STDMETHODCALLTYPE ReadFromSubresource(void *destination, UINT row, UINT depth, UINT subresource, const D3D12_BOX *box) override {
        return transfer(subresource, box, destination, row, depth, false);
    }
    HRESULT STDMETHODCALLTYPE GetHeapProperties(D3D12_HEAP_PROPERTIES *properties, D3D12_HEAP_FLAGS *flags) override {
        if (properties) *properties = properties_;
        if (flags) *flags = flags_;
        return S_OK;
    }
    void *STDMETHODCALLTYPE MetalBuffer() override { return (__bridge void *)buffer_; }
    void *STDMETHODCALLTYPE MetalTexture() override { return (__bridge void *)texture_; }
private:
    bool cpu_visible() const { return buffer_ ? buffer_.storageMode == MTLStorageModeShared : texture_.storageMode == MTLStorageModeShared; }
    UINT subresource_count() const {
        if (buffer_) return 1;
        const UINT arrays = desc_.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D ? 1 : desc_.DepthOrArraySize;
        return desc_.MipLevels * arrays * format_.planes;
    }
    HRESULT transfer(UINT subresource, const D3D12_BOX *box, void *data, UINT row, UINT depth, bool write) {
        const HRESULT reason = device_->GetDeviceRemovedReason();
        if (FAILED(reason)) return reason;
        if (!data || !texture_ || !cpu_visible() || format_.depth || format_.planes != 1 || subresource >= subresource_count()) return E_INVALIDARG;
        const UINT mip = subresource % desc_.MipLevels;
        const UINT slice = subresource / desc_.MipLevels;
        const UINT width = std::max<UINT>(1, (UINT)desc_.Width >> mip), height = std::max<UINT>(1, desc_.Height >> mip);
        UINT layers = 1;
        if (desc_.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D) layers = std::max<UINT>(1, desc_.DepthOrArraySize >> mip);
        const D3D12_BOX region = box ? *box : D3D12_BOX{0, 0, 0, width, height, layers};
        if (region.left > region.right || region.top > region.bottom || region.front > region.back ||
            region.right > width || region.bottom > height || region.back > layers) return E_INVALIDARG;
        if (region.left == region.right || region.top == region.bottom || region.front == region.back) return S_OK;
        const UINT block = format_.block;
        if (region.left % block || region.top % block || (region.right % block && region.right != width) ||
            (region.bottom % block && region.bottom != height)) return E_INVALIDARG;
        const UINT bytes = ((region.right - region.left + block - 1) / block) * format_.bytes;
        const UINT rows = (region.bottom - region.top + block - 1) / block;
        if (row < bytes || (region.back - region.front > 1 && depth < (uint64_t)row * rows)) return E_INVALIDARG;
        const MTLRegion native = MTLRegionMake3D(region.left, region.top, region.front, region.right - region.left,
                                               region.bottom - region.top, region.back - region.front);
        if (write) {
            [texture_ replaceRegion:native mipmapLevel:mip slice:slice withBytes:data bytesPerRow:row bytesPerImage:depth];
            std::atomic_thread_fence(std::memory_order_release);
        } else {
            std::atomic_thread_fence(std::memory_order_acquire);
            [texture_ getBytes:data bytesPerRow:row bytesPerImage:depth fromRegion:native mipmapLevel:mip slice:slice];
        }
        return S_OK;
    }
    ID3D12Device *device_;
    ID3D12Heap *heap_;
    D3D12_RESOURCE_DESC desc_;
    D3D12_HEAP_PROPERTIES properties_;
    D3D12_HEAP_FLAGS flags_;
    id<MTLBuffer> buffer_;
    id<MTLTexture> texture_;
    FormatInfo format_;
    PrivateData data_;
};

template <class T> HRESULT return_object(T *object, REFIID iid, void **out) {
    if (!object) return E_OUTOFMEMORY;
    void *result = nullptr;
    const HRESULT hr = object->QueryInterface(iid, &result);
    object->Release();
    if (FAILED(hr)) return hr;
    if (!out) { ((IUnknown *)result)->Release(); return S_FALSE; }
    *out = result;
    return S_OK;
}
}

BufferAddress resolve_buffer_address(ID3D12Device *device, UINT64 address, UINT64 size) {
    std::lock_guard lock(address_mutex);
    for (auto it = addresses.upper_bound(address); it != addresses.begin();) {
        --it;
        const auto &entry = it->second;
        const UINT64 offset = address - it->first;
        if (entry.device == device && offset <= entry.size && size <= entry.size - offset) return {entry.buffer, offset};
    }
    return {};
}

HRESULT prepare_metal() {
    // Apple's driver reads this process-local setting when its first Metal device is opened.
    static const HRESULT result = setenv("AGX_SUPPORT_D24_S8", "1", 1) ? E_FAIL : S_OK;
    return result;
}

D3D12_RESOURCE_ALLOCATION_INFO allocation_info(id<MTLDevice> metal, UINT mask, UINT count, const D3D12_RESOURCE_DESC *descs) {
    if (mask > 1 || !count || !descs) return invalid_allocation;
    const MTLResourceOptions options = MTLResourceStorageModePrivate | MTLResourceHazardTrackingModeTracked;
    uint64_t size = 0, alignment = 0;
    for (UINT i = 0; i < count; ++i) {
        Layout layout;
        if (FAILED(resource_layout(metal, descs[i], options, layout))) return invalid_allocation;
        alignment = std::max(alignment, layout.allocation.Alignment);
        if (!align_up(size, layout.allocation.Alignment, size) || size > UINT64_MAX - layout.allocation.SizeInBytes) return invalid_allocation;
        size += layout.allocation.SizeInBytes;
    }
    if (!align_up(size, alignment, size)) return invalid_allocation;
    return {size, alignment};
}

D3D12_HEAP_PROPERTIES custom_heap_properties(UINT node, D3D12_HEAP_TYPE type) {
    if (node > 1) return {};
    return abstract_properties(type);
}

HRESULT create_heap(ID3D12Device *device, id<MTLDevice> metal, const D3D12_HEAP_DESC *input, REFIID iid, void **out) {
    if (out) *out = nullptr;
    if (!input) return E_INVALIDARG;
    D3D12_HEAP_DESC desc = *input;
    constexpr UINT supported = D3D12_HEAP_FLAG_DENY_BUFFERS | D3D12_HEAP_FLAG_DENY_RT_DS_TEXTURES | D3D12_HEAP_FLAG_DENY_NON_RT_DS_TEXTURES;
    if ((UINT)desc.Flags & ~supported) return DXGI_ERROR_UNSUPPORTED;
    if (!desc.Alignment) desc.Alignment = page;
    uint64_t native_size;
    if (!desc.SizeInBytes || (desc.Alignment != page && desc.Alignment != D3D12_DEFAULT_MSAA_RESOURCE_PLACEMENT_ALIGNMENT) ||
        !align_up(desc.SizeInBytes, desc.Alignment, native_size) || native_size > std::numeric_limits<NSUInteger>::max()) return E_INVALIDARG;
    MTLResourceOptions options;
    const HRESULT hr = normalize_properties(input->Properties, desc.Properties, options);
    if (FAILED(hr)) return hr;
    if ((desc.Properties.Type == D3D12_HEAP_TYPE_UPLOAD || desc.Properties.Type == D3D12_HEAP_TYPE_READBACK) &&
        (desc.Flags & D3D12_HEAP_FLAG_DENY_BUFFERS)) return E_INVALIDARG;
    if (!out) return return_object(new (std::nothrow) Heap(device, nil, desc), iid, nullptr);
    MTLHeapDescriptor *native = [MTLHeapDescriptor new];
    // D3D permits unaligned heap sizes; retain the public size and pad only Metal's backing allocation.
    native.size = native_size;
    native.resourceOptions = options;
    native.type = MTLHeapTypePlacement;
    id<MTLHeap> heap = [metal newHeapWithDescriptor:native];
    if (!heap) return E_OUTOFMEMORY;
    return return_object(new (std::nothrow) Heap(device, heap, desc), iid, out);
}

HRESULT create_committed_resource(ID3D12Device *device, id<MTLDevice> metal, const D3D12_HEAP_PROPERTIES *input,
    D3D12_HEAP_FLAGS flags, const D3D12_RESOURCE_DESC *desc, D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE *clear,
    REFIID iid, void **out) {
    if (out) *out = nullptr;
    if (!input || !desc) return E_INVALIDARG;
    D3D12_HEAP_PROPERTIES properties;
    MTLResourceOptions options;
    HRESULT hr = normalize_properties(*input, properties, options);
    if (FAILED(hr)) return hr;
    Layout layout;
    hr = resource_layout(metal, *desc, options, layout);
    if (FAILED(hr)) return hr;
    hr = validate_resource(properties, flags, layout, state, clear);
    if (FAILED(hr)) return hr;
    if (!out) return return_object(new (std::nothrow) Resource(device, nullptr, layout, properties, flags, nil, nil), iid, nullptr);
    id<MTLBuffer> buffer = nil;
    id<MTLTexture> texture = nil;
    if (desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) buffer = [metal newBufferWithLength:desc->Width options:options];
    else texture = [metal newTextureWithDescriptor:layout.texture];
    if (!buffer && !texture) return E_OUTOFMEMORY;
    return return_object(new (std::nothrow) Resource(device, nullptr, layout, properties, flags, buffer, texture), iid, out);
}

HRESULT create_placed_resource(ID3D12Device *device, id<MTLDevice> metal, ID3D12Heap *heap, UINT64 offset,
    const D3D12_RESOURCE_DESC *desc, D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE *clear, REFIID iid, void **out) {
    if (out) *out = nullptr;
    if (!heap || !desc) return E_INVALIDARG;
    IUnknown *owner = nullptr;
    const HRESULT queried = heap->GetDevice(__uuidof(IUnknown), (void **)&owner);
    if (FAILED(queried)) return E_INVALIDARG;
    const bool same = owner == static_cast<IUnknown *>(device);
    owner->Release();
    if (!same) return E_INVALIDARG;
    ID3DMMetalHeap *backing = nullptr;
    if (FAILED(heap->QueryInterface(__uuidof(ID3DMMetalHeap), (void **)&backing))) return E_INVALIDARG;
    id<MTLHeap> native = (__bridge id<MTLHeap>)backing->MetalHeap();
    backing->Release();
    if (!native || native.device.registryID != metal.registryID) return E_INVALIDARG;
    const D3D12_HEAP_DESC heap_desc = heap->GetDesc();
    D3D12_HEAP_PROPERTIES properties;
    MTLResourceOptions options;
    HRESULT hr = normalize_properties(heap_desc.Properties, properties, options);
    if (FAILED(hr)) return hr;
    Layout layout;
    hr = resource_layout(metal, *desc, options, layout);
    if (FAILED(hr)) return hr;
    hr = validate_resource(properties, heap_desc.Flags, layout, state, clear);
    if (FAILED(hr)) return hr;
    uint64_t logical_size = layout.allocation.SizeInBytes;
    if (desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) logical_size = desc->Width;
    if (offset % layout.allocation.Alignment || offset > heap_desc.SizeInBytes ||
        logical_size > heap_desc.SizeInBytes - offset || heap_desc.Alignment < layout.allocation.Alignment) return E_INVALIDARG;
    uint64_t physical;
    if (!align_up(offset, layout.native.align, physical) || physical > native.size || layout.native.size > native.size - physical)
        return E_INVALIDARG;
    if (!out) return return_object(new (std::nothrow) Resource(device, heap, layout, properties, heap_desc.Flags, nil, nil), iid, nullptr);
    id<MTLBuffer> buffer = nil;
    id<MTLTexture> texture = nil;
    if (desc->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) buffer = [native newBufferWithLength:desc->Width options:options offset:physical];
    else texture = [native newTextureWithDescriptor:layout.texture offset:physical];
    if (!buffer && !texture) return E_OUTOFMEMORY;
    return return_object(new (std::nothrow) Resource(device, heap, layout, properties, heap_desc.Flags, buffer, texture), iid, out);
}
}
