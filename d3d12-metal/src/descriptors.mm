#include "descriptors.h"
#include "resources.h"
#include "formats.h"
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <new>
#include <set>

namespace d3dm {
namespace {
void require(bool valid, const char *message) {
    if (valid) return;
    std::fprintf(stderr, "d3d12-metal descriptor: %s\n", message);
    std::abort();
}
struct UnorderedView { ID3D12Resource *resource;D3D12_UNORDERED_ACCESS_VIEW_DESC desc; };
struct Slot {
    D3D12_CONSTANT_BUFFER_VIEW_DESC cbv{};
    std::array<uint64_t, 3> packet{};
    id<MTLResource> resource;
    id<MTLTexture> counter;
    id<MTLSamplerState> sampler;
    UINT depthPlane = 0, depthCount = 1;
    D3D12_DSV_FLAGS depthFlags = D3D12_DSV_FLAG_NONE;
    MTLResourceUsage usage = MTLResourceUsageRead;
    std::shared_ptr<UnorderedView> unordered;
};
class DescriptorHeap;
std::mutex descriptor_mutex;
std::map<uintptr_t, DescriptorHeap *> heaps;

class DescriptorHeap final : public Object<ID3D12DescriptorHeap>, public ID3DMDescriptorHeap {
public:
    DescriptorHeap(ID3D12Device *device, const D3D12_DESCRIPTOR_HEAP_DESC &desc, id<MTLBuffer> table)
        : device(device), desc(desc), table(table), slots(desc.NumDescriptors) {
        device->AddRef();
        if (!table) bytes.resize((size_t)desc.NumDescriptors * descriptor_stride(desc.Type));
        std::lock_guard lock(descriptor_mutex);
        heaps.emplace(start(), this);
    }
    ~DescriptorHeap() override {
        { std::lock_guard lock(descriptor_mutex); heaps.erase(start()); }
        device->Release();
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return Object::AddRef(); }
    ULONG STDMETHODCALLTYPE Release() override { return Object::Release(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (out && iid == __uuidof(ID3DMDescriptorHeap)) { AddRef(); *out = static_cast<ID3DMDescriptorHeap *>(this); return S_OK; }
        return query<IUnknown, ID3D12Object, ID3D12DeviceChild, ID3D12Pageable, ID3D12DescriptorHeap>(iid, out);
    }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID name, UINT *size, void *data) override { return this->data.get(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID name, UINT size, const void *value) override { return data.set(name, size, value); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID name, const IUnknown *value) override { return data.set_interface(name, value); }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR name) override {
        table.label = name ? [[NSString alloc] initWithBytes:name length:wcslen(name) * sizeof(WCHAR) encoding:NSUTF32LittleEndianStringEncoding] : nil;
        return data.set(WKPDID_D3DDebugObjectNameW, name ? (UINT)((wcslen(name) + 1) * sizeof(WCHAR)) : 0, name);
    }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID iid, void **out) override { return device->QueryInterface(iid, out); }
    D3D12_DESCRIPTOR_HEAP_DESC STDMETHODCALLTYPE GetDesc() override { return desc; }
    D3D12_CPU_DESCRIPTOR_HANDLE STDMETHODCALLTYPE GetCPUDescriptorHandleForHeapStart() override { return {start()}; }
    D3D12_GPU_DESCRIPTOR_HANDLE STDMETHODCALLTYPE GetGPUDescriptorHandleForHeapStart() override {
        return {(desc.Flags & D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE) ? table.gpuAddress : 0};
    }
    void *STDMETHODCALLTYPE MetalDescriptorBuffer() override { return (__bridge void *)table; }
    HRESULT STDMETHODCALLTYPE GetView(UINT index, D3DMDescriptorView *out) override {
        if (!out) return E_POINTER;
        *out = {};
        std::lock_guard lock(descriptor_mutex);
        if (index >= slots.size()) return E_INVALIDARG;
        const auto &slot = slots[index];
        *out = {(__bridge void *)slot.resource, (__bridge void *)slot.counter, slot.depthPlane, slot.depthCount, slot.depthFlags};
        return S_OK;
    }
    uintptr_t start() const { return table ? (uintptr_t)table.contents : (uintptr_t)bytes.data(); }
    void store(UINT index, const Slot &slot) {
        const auto &previous=slots[index];
        resources_dirty |= previous.resource!=slot.resource || previous.counter!=slot.counter || previous.usage!=slot.usage;
        slots[index] = slot;
        if (slot.resource || slot.counter) occupied.insert(index); else occupied.erase(index);
        auto *destination = (uint8_t *)start() + (size_t)index * descriptor_stride(desc.Type);
        if (table) { std::memcpy(destination, slot.packet.data(), 24); return; }
        // Attachment handles have an 18-byte ABI, not the alignment of a host C++ struct.
        const uint64_t texture = ((id<MTLTexture>)slot.resource).gpuResourceID._impl;
        const uint16_t flags = slot.depthFlags;
        std::memcpy(destination, &texture, 8);
        std::memcpy(destination + 8, &slot.depthPlane, 4);
        std::memcpy(destination + 12, &slot.depthCount, 4);
        std::memcpy(destination + 16, &flags, 2);
    }
    ID3D12Device *device;
    D3D12_DESCRIPTOR_HEAP_DESC desc;
    id<MTLBuffer> table;
    std::vector<Slot> slots;
    std::set<UINT> occupied;
    bool resources_dirty=true;
    std::vector<id<MTLResource>> read_resources,write_resources;
    __weak id<MTLRenderCommandEncoder> resident_render=nil;
    __weak id<MTLComputeCommandEncoder> resident_compute=nil;
    __weak id resident_set=nil;
    std::vector<id<MTLResource>> allocations;
    // Reused by use_descriptor_heap's rebuild; guarded by descriptor_mutex.
    std::vector<std::pair<uintptr_t,MTLResourceUsage>> scratch;
private:
    std::vector<uint8_t> bytes;
    PrivateData data;
};
struct Location { DescriptorHeap *heap; UINT index; };
Location locate(ID3D12Device *device, D3D12_CPU_DESCRIPTOR_HANDLE handle, D3D12_DESCRIPTOR_HEAP_TYPE type, UINT count = 1) {
    auto it = heaps.upper_bound(handle.ptr);
    require(it != heaps.begin(), "unknown CPU handle");
    --it;
    auto *heap = it->second;
    const uintptr_t offset = handle.ptr - it->first;
    const UINT stride = descriptor_stride(type);
    require(stride && heap->device == device && heap->desc.Type == type && offset % stride == 0, "handle device/type/alignment mismatch");
    const size_t index = offset / stride;
    require(index <= heap->slots.size() && count <= heap->slots.size() - index, "descriptor range out of bounds");
    return {heap, (UINT)index};
}
void store(ID3D12Device *device, D3D12_CPU_DESCRIPTOR_HANDLE dest, D3D12_DESCRIPTOR_HEAP_TYPE type, const Slot &slot) {
    std::lock_guard lock(descriptor_mutex);
    const auto location = locate(device, dest, type);
    location.heap->store(location.index, slot);
}
void check_resource(ID3D12Device *device, ID3D12Resource *resource) {
    require(SUCCEEDED(device->GetDeviceRemovedReason()), "device removed");
    if (!resource) return;
    ID3D12Device *owner = nullptr;
    const HRESULT hr = resource->GetDevice(__uuidof(ID3D12Device), (void **)&owner);
    const bool valid = SUCCEEDED(hr) && owner == device;
    if (owner) owner->Release();
    require(valid, "resource belongs to another device");
}
id<MTLBuffer> buffer(ID3D12Resource *resource) {
    ID3DMMetalBuffer *native = nullptr;
    require(resource && SUCCEEDED(resource->QueryInterface(__uuidof(ID3DMMetalBuffer), (void **)&native)), "expected buffer resource");
    id<MTLBuffer> result = (__bridge id<MTLBuffer>)native->MetalBuffer();
    native->Release();
    return result;
}
id<MTLTexture> texture(ID3D12Resource *resource) {
    ID3DMMetalTexture *native = nullptr;
    require(resource && SUCCEEDED(resource->QueryInterface(__uuidof(ID3DMMetalTexture), (void **)&native)), "expected texture resource");
    id<MTLTexture> result = (__bridge id<MTLTexture>)native->MetalTexture();
    native->Release();
    return result;
}
Slot buffer_view(ID3D12Resource *resource, DXGI_FORMAT format, UINT64 first, UINT count, UINT stride, UINT flags, bool writable) {
    Slot slot;
    if (writable) slot.usage=MTLResourceUsageRead|MTLResourceUsageWrite;
    const bool raw = flags & 1;
    require((flags & ~1u) == 0 && (count || !resource), "invalid buffer view flags/count");
    FormatInfo info = format_info(format);
    if (raw) {
        require(format == DXGI_FORMAT_R32_TYPELESS && !stride, "raw view must use R32_TYPELESS");
        stride = 4;
    } else if (stride) {
        require(format == DXGI_FORMAT_UNKNOWN && stride % 4 == 0 && stride <= D3D12_REQ_MULTI_ELEMENT_STRUCTURE_SIZE_IN_BYTES,
                "invalid structured buffer stride/format");
    } else {
        require(info.metal != MTLPixelFormatInvalid && !info.typeless && !info.depth && !info.view_only && info.block == 1, "unsupported typed buffer format");
        stride = info.bytes;
    }
    require(first <= UINT64_MAX / stride, "buffer offset overflow");
    const UINT64 offset = first * stride, size = (UINT64)count * stride;
    require(size <= UINT32_MAX, "buffer metadata size exceeds converter ABI");
    if (!resource) return slot;
    const auto desc = resource->GetDesc();
    require(desc.Dimension == D3D12_RESOURCE_DIMENSION_BUFFER && offset <= desc.Width && size <= desc.Width - offset, "buffer view out of bounds");
    id<MTLBuffer> native = buffer(resource);
    slot.resource = native;
    slot.packet = {native.gpuAddress + offset, 0, size};
    if (!raw && format != DXGI_FORMAT_UNKNOWN) {
        const NSUInteger alignment = [native.device minimumTextureBufferAlignmentForPixelFormat:info.metal];
        const NSUInteger aligned = offset / alignment * alignment;
        const NSUInteger extra = offset - aligned;
        require(extra % stride == 0 && extra / stride <= 255, "typed buffer offset cannot be encoded");
        MTLTextureDescriptor *view = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:info.metal
            width:(size + extra) / stride resourceOptions:native.resourceOptions usage:writable ? MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite : MTLTextureUsageShaderRead];
        id<MTLTexture> typed = [native newTextureWithDescriptor:view offset:aligned bytesPerRow:size + extra];
        require(typed != nil, "Metal typed buffer view creation failed");
        slot.resource = typed;
        slot.packet[1] = typed.gpuResourceID._impl;
        slot.packet[2] |= (uint64_t)(extra / stride) << 32 | UINT64_C(1) << 63;
    }
    return slot;
}
struct TextureView {
    DXGI_FORMAT format;
    D3D12_RESOURCE_DIMENSION dimension;
    MTLTextureType type = MTLTextureType2DArray;
    UINT mip = 0, mips = 1, slice = 0, slices = 1, plane = 0;
    UINT depth = 0, depths = UINT32_MAX;
    bool multisample = false, cube = false;
    UINT mapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    float minLOD = 0;
};
MTLTextureSwizzle swizzle(UINT mapping, UINT component) {
    constexpr MTLTextureSwizzle values[] = {MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue,
        MTLTextureSwizzleAlpha, MTLTextureSwizzleZero, MTLTextureSwizzleOne};
    const UINT value = D3D12_DECODE_SHADER_4_COMPONENT_MAPPING(component, mapping);
    require(value < 6, "invalid shader component mapping");
    return values[value];
}
Slot texture_view(ID3D12Resource *resource, TextureView view, bool shader, bool depth) {
    Slot slot;
    if (view.format == DXGI_FORMAT_UNKNOWN && resource) view.format = resource->GetDesc().Format;
    const FormatInfo format = format_info(view.format);
    require(format.metal != MTLPixelFormatInvalid && !format.typeless, "unsupported/typeless texture view format");
    require(std::isfinite(view.minLOD) && view.minLOD >= 0, "invalid minimum LOD clamp");
    if (shader) require((view.mapping & ~0x1fffu) == 0 && (view.mapping & 0x1000), "invalid component mapping");
    if (!resource) return slot;
    const auto desc = resource->GetDesc();
    const auto source = format_info(desc.Format);
    require(desc.Dimension == view.dimension && source.family == format.family && (desc.SampleDesc.Count > 1) == view.multisample,
        "texture view dimension/format/sample mismatch");
    require(view.plane < source.planes, "invalid texture plane");
    if (format.view_only) {
        const bool stencil = view.format == DXGI_FORMAT_X24_TYPELESS_G8_UINT || view.format == DXGI_FORMAT_X32_TYPELESS_G8X24_UINT;
        require(view.plane == (UINT)stencil, "depth/stencil view plane mismatch");
    } else require(view.plane == 0, "invalid color/depth view plane");
    require(!depth || (format.depth && !format.view_only), "DSV requires a depth format");
    require(shader || depth || (!format.depth && !format.view_only && format.block == 1), "invalid render/UAV format");
    require(view.mip < desc.MipLevels, "texture mip out of bounds");
    if (view.mips == UINT32_MAX) view.mips = desc.MipLevels - view.mip;
    require(view.mips && view.mips <= desc.MipLevels - view.mip, "texture mip range out of bounds");
    const UINT slices = desc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D ? 1 : desc.DepthOrArraySize;
    require(view.slice < slices && view.slices && view.slices <= slices - view.slice, "texture array range out of bounds");
    if (view.cube) require(desc.Width == desc.Height && view.slice % 6 == 0 && view.slices % 6 == 0 && !view.multisample, "invalid cube view");
    if (desc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D) {
        const UINT count = std::max<UINT>(1, desc.DepthOrArraySize >> view.mip);
        require(view.depth < count, "3D depth slice out of bounds");
        if (view.depths == UINT32_MAX) view.depths = count - view.depth;
        require(view.depths && view.depths <= count - view.depth, "3D depth range out of bounds");
        slot.depthPlane = view.depth;
        slot.depthCount = view.depths;
        if (shader) require(view.depth == 0 && view.depths == count, "partial 3D UAV depth ranges are not supported by Metal shader views");
    }
    id<MTLTexture> native = texture(resource);
    MTLPixelFormat pixel = format.metal;
    if (native.pixelFormat == MTLPixelFormatDepth32Float && view.format == DXGI_FORMAT_R32_FLOAT) pixel = native.pixelFormat;
    if (native.pixelFormat == MTLPixelFormatDepth16Unorm && view.format == DXGI_FORMAT_R16_UNORM) pixel = native.pixelFormat;
    const auto channel = [&](UINT component) {
        const auto value = swizzle(view.mapping, component);
        if (shader && format.family == DXGI_FORMAT_B8G8R8X8_TYPELESS && value == MTLTextureSwizzleAlpha) return MTLTextureSwizzleOne;
        return value;
    };
    const MTLTextureSwizzleChannels channels = MTLTextureSwizzleChannelsMake(channel(0), channel(1), channel(2), channel(3));
    id<MTLTexture> result = [native newTextureViewWithPixelFormat:pixel textureType:view.type
        levels:NSMakeRange(view.mip, view.mips) slices:NSMakeRange(view.slice, view.slices) swizzle:channels];
    require(result != nil, "Metal texture view creation failed");
    slot.resource = result;
    slot.packet = {0, result.gpuResourceID._impl, std::bit_cast<uint32_t>(view.minLOD)};
    return slot;
}
TextureView default_view(ID3D12Resource *resource, bool shader) {
    require(resource != nullptr, "default view requires a resource");
    const auto desc = resource->GetDesc();
    TextureView view{desc.Format, desc.Dimension};
    view.slices = desc.DepthOrArraySize;
    if (shader) view.mips = desc.MipLevels;
    if (desc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D) { view.type = MTLTextureType3D; view.slices = 1; }
    view.multisample = desc.SampleDesc.Count > 1;
    if (view.multisample) view.type = MTLTextureType2DMultisampleArray;
    return view;
}
void require_flags(ID3D12Resource *resource, D3D12_RESOURCE_FLAGS flags) {
    if (resource) require((resource->GetDesc().Flags & flags) == flags, "resource lacks required view usage");
}
}

HRESULT create_descriptor_heap(ID3D12Device *device, id<MTLDevice> metal, const D3D12_DESCRIPTOR_HEAP_DESC *desc, REFIID iid, void **out) {
    if (out) *out = nullptr;
    if (!desc || !descriptor_stride(desc->Type) || !desc->NumDescriptors || desc->NodeMask > 1 ||
        (desc->Flags & ~D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE)) return E_INVALIDARG;
    const bool shader = desc->Flags & D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    if (shader && desc->Type >= D3D12_DESCRIPTOR_HEAP_TYPE_RTV) return E_INVALIDARG;
    if (shader && desc->Type == D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER && desc->NumDescriptors > D3D12_MAX_SHADER_VISIBLE_SAMPLER_HEAP_SIZE) return E_INVALIDARG;
    if (shader && desc->Type == D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV && desc->NumDescriptors > D3D12_MAX_SHADER_VISIBLE_DESCRIPTOR_HEAP_SIZE_TIER_2) return E_INVALIDARG;
    const NSUInteger size = (NSUInteger)desc->NumDescriptors * descriptor_stride(desc->Type);
    if (size > metal.maxBufferLength) return E_OUTOFMEMORY;
    if (!out) {
        const bool supported = iid == __uuidof(IUnknown) || iid == __uuidof(ID3D12Object) || iid == __uuidof(ID3D12DeviceChild) ||
            iid == __uuidof(ID3D12Pageable) || iid == __uuidof(ID3D12DescriptorHeap) || iid == __uuidof(ID3DMDescriptorHeap);
        return supported ? S_FALSE : E_NOINTERFACE;
    }
    id<MTLBuffer> table = nil;
    if (desc->Type <= D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER) {
        table = [metal newBufferWithLength:size options:MTLResourceStorageModeShared];
        if (!table) return E_OUTOFMEMORY;
        std::memset(table.contents, 0, size);
    }
    auto *heap = new (std::nothrow) DescriptorHeap(device, *desc, table);
    if (!heap) return E_OUTOFMEMORY;
    void *result = nullptr;
    const HRESULT hr = heap->QueryInterface(iid, &result);
    heap->Release();
    if (FAILED(hr)) return hr;
    *out = result;
    return S_OK;
}
void create_cbv(ID3D12Device *device, const D3D12_CONSTANT_BUFFER_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE dest) {
    check_resource(device, nullptr);
    Slot slot;
    if (desc && desc->BufferLocation) {
        require(desc->BufferLocation % 256 == 0 && desc->SizeInBytes && desc->SizeInBytes % 256 == 0 && desc->SizeInBytes <= 65536,
            "invalid constant buffer alignment/size");
        const auto address = resolve_buffer_address(device, desc->BufferLocation, desc->SizeInBytes);
        require(address.buffer != nil, "constant buffer GPU address is not a live resource range");
        slot.resource = address.buffer;
        slot.packet = {desc->BufferLocation, 0, desc->SizeInBytes};
        slot.cbv = *desc;
    }
    store(device, dest, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, slot);
}
void create_srv(ID3D12Device *device, ID3D12Resource *resource, const D3D12_SHADER_RESOURCE_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE dest) {
    check_resource(device, resource);
    if (resource) require(!(resource->GetDesc().Flags & D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE), "resource denies SRV access");
    if (desc && desc->ViewDimension == D3D12_SRV_DIMENSION_BUFFER) {
        require(desc->Shader4ComponentMapping == D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING, "buffer component swizzle is unsupported");
        store(device, dest, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, buffer_view(resource, desc->Format,
            desc->Buffer.FirstElement, desc->Buffer.NumElements, desc->Buffer.StructureByteStride, desc->Buffer.Flags, false));
        return;
    }
    auto view = desc ? TextureView{desc->Format, D3D12_RESOURCE_DIMENSION_TEXTURE2D} : default_view(resource, true);
    if (desc) {
        view.mapping = desc->Shader4ComponentMapping;
        switch (desc->ViewDimension) {
        case D3D12_SRV_DIMENSION_TEXTURE1D:
            view.dimension = D3D12_RESOURCE_DIMENSION_TEXTURE1D; view.mip = desc->Texture1D.MostDetailedMip; view.mips = desc->Texture1D.MipLevels; view.minLOD = desc->Texture1D.ResourceMinLODClamp; break;
        case D3D12_SRV_DIMENSION_TEXTURE1DARRAY:
            view.dimension = D3D12_RESOURCE_DIMENSION_TEXTURE1D; view.mip = desc->Texture1DArray.MostDetailedMip; view.mips = desc->Texture1DArray.MipLevels;
            view.slice = desc->Texture1DArray.FirstArraySlice; view.slices = desc->Texture1DArray.ArraySize; view.minLOD = desc->Texture1DArray.ResourceMinLODClamp; break;
        case D3D12_SRV_DIMENSION_TEXTURE2D:
            view.mip = desc->Texture2D.MostDetailedMip; view.mips = desc->Texture2D.MipLevels; view.plane = desc->Texture2D.PlaneSlice; view.minLOD = desc->Texture2D.ResourceMinLODClamp; break;
        case D3D12_SRV_DIMENSION_TEXTURE2DARRAY:
            view.mip = desc->Texture2DArray.MostDetailedMip; view.mips = desc->Texture2DArray.MipLevels; view.plane = desc->Texture2DArray.PlaneSlice;
            view.slice = desc->Texture2DArray.FirstArraySlice; view.slices = desc->Texture2DArray.ArraySize; view.minLOD = desc->Texture2DArray.ResourceMinLODClamp; break;
        case D3D12_SRV_DIMENSION_TEXTURE2DMS: view.multisample = true; view.type = MTLTextureType2DMultisampleArray; break;
        case D3D12_SRV_DIMENSION_TEXTURE2DMSARRAY:
            view.multisample = true; view.type = MTLTextureType2DMultisampleArray; view.slice = desc->Texture2DMSArray.FirstArraySlice; view.slices = desc->Texture2DMSArray.ArraySize; break;
        case D3D12_SRV_DIMENSION_TEXTURE3D:
            view.dimension = D3D12_RESOURCE_DIMENSION_TEXTURE3D; view.type = MTLTextureType3D;
            view.mip = desc->Texture3D.MostDetailedMip; view.mips = desc->Texture3D.MipLevels; view.minLOD = desc->Texture3D.ResourceMinLODClamp; break;
        case D3D12_SRV_DIMENSION_TEXTURECUBE:
            view.cube = true; view.type = MTLTextureTypeCubeArray; view.slices = 6;
            view.mip = desc->TextureCube.MostDetailedMip; view.mips = desc->TextureCube.MipLevels; view.minLOD = desc->TextureCube.ResourceMinLODClamp; break;
        case D3D12_SRV_DIMENSION_TEXTURECUBEARRAY:
            require(desc->TextureCubeArray.NumCubes <= UINT32_MAX / 6, "cube count overflow");
            view.cube = true; view.type = MTLTextureTypeCubeArray; view.slice = desc->TextureCubeArray.First2DArrayFace; view.slices = desc->TextureCubeArray.NumCubes * 6;
            view.mip = desc->TextureCubeArray.MostDetailedMip; view.mips = desc->TextureCubeArray.MipLevels; view.minLOD = desc->TextureCubeArray.ResourceMinLODClamp; break;
        default: require(false, "unsupported SRV dimension");
        }
    }
    store(device, dest, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, texture_view(resource, view, true, false));
}
void create_uav(ID3D12Device *device, ID3D12Resource *resource, ID3D12Resource *counter, const D3D12_UNORDERED_ACCESS_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE dest) {
    check_resource(device, resource); check_resource(device, counter);
    require_flags(resource, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    if (desc && desc->ViewDimension == D3D12_UAV_DIMENSION_BUFFER) {
        Slot slot = buffer_view(resource, desc->Format, desc->Buffer.FirstElement, desc->Buffer.NumElements,
            desc->Buffer.StructureByteStride, desc->Buffer.Flags, true);
        slot.unordered=std::make_shared<UnorderedView>(resource,*desc);
        if (counter) {
            require(resource && desc->Buffer.StructureByteStride && desc->Format == DXGI_FORMAT_UNKNOWN && !desc->Buffer.Flags &&
                desc->Buffer.CounterOffsetInBytes % D3D12_UAV_COUNTER_PLACEMENT_ALIGNMENT == 0, "invalid structured UAV counter");
            require_flags(counter, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
            const auto counter_desc = counter->GetDesc();
            const UINT64 offset = desc->Buffer.CounterOffsetInBytes;
            require(counter_desc.Dimension == D3D12_RESOURCE_DIMENSION_BUFFER && offset <= counter_desc.Width && 4 <= counter_desc.Width - offset, "counter out of bounds");
            id<MTLBuffer> native = buffer(counter);
            auto *view = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:1 resourceOptions:native.resourceOptions
                usage:MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite];
            slot.counter = [native newTextureWithDescriptor:view offset:offset bytesPerRow:4];
            require(slot.counter != nil, "Metal counter view creation failed");
            slot.packet[1] = slot.counter.gpuResourceID._impl;
        } else require(desc->Buffer.CounterOffsetInBytes == 0, "counter offset without counter resource");
        store(device, dest, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, slot);
        return;
    }
    require(!counter, "texture UAV cannot have a counter");
    auto view = desc ? TextureView{desc->Format, D3D12_RESOURCE_DIMENSION_TEXTURE2D} : default_view(resource, false);
    if (desc) {
        switch (desc->ViewDimension) {
        case D3D12_UAV_DIMENSION_TEXTURE1D: view.dimension = D3D12_RESOURCE_DIMENSION_TEXTURE1D; view.mip = desc->Texture1D.MipSlice; break;
        case D3D12_UAV_DIMENSION_TEXTURE1DARRAY:
            view.dimension = D3D12_RESOURCE_DIMENSION_TEXTURE1D; view.mip = desc->Texture1DArray.MipSlice;
            view.slice = desc->Texture1DArray.FirstArraySlice; view.slices = desc->Texture1DArray.ArraySize; break;
        case D3D12_UAV_DIMENSION_TEXTURE2D: view.mip = desc->Texture2D.MipSlice; view.plane = desc->Texture2D.PlaneSlice; break;
        case D3D12_UAV_DIMENSION_TEXTURE2DARRAY:
            view.mip = desc->Texture2DArray.MipSlice; view.plane = desc->Texture2DArray.PlaneSlice;
            view.slice = desc->Texture2DArray.FirstArraySlice; view.slices = desc->Texture2DArray.ArraySize; break;
        case D3D12_UAV_DIMENSION_TEXTURE3D:
            view.dimension = D3D12_RESOURCE_DIMENSION_TEXTURE3D; view.type = MTLTextureType3D; view.mip = desc->Texture3D.MipSlice;
            view.depth = desc->Texture3D.FirstWSlice; view.depths = desc->Texture3D.WSize; break;
        default: require(false, "unsupported UAV dimension");
        }
    }
    Slot slot=texture_view(resource,view,true,false);
    slot.usage=MTLResourceUsageRead|MTLResourceUsageWrite;
    D3D12_UNORDERED_ACCESS_VIEW_DESC clear{};
    if (desc) clear=*desc;
    else {
        clear.Format=view.format;
        if (view.dimension==D3D12_RESOURCE_DIMENSION_TEXTURE1D) clear.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE1DARRAY;
        else if (view.dimension==D3D12_RESOURCE_DIMENSION_TEXTURE3D) clear.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE3D;
        else clear.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE2DARRAY;
    }
    if (clear.Format==DXGI_FORMAT_UNKNOWN && resource) clear.Format=resource->GetDesc().Format;
    slot.unordered=std::make_shared<UnorderedView>(resource,clear);
    store(device,dest,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,slot);
}
void create_rtv(ID3D12Device *device, ID3D12Resource *resource, const D3D12_RENDER_TARGET_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE dest) {
    check_resource(device, resource); require_flags(resource, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
    auto view = desc ? TextureView{desc->Format, D3D12_RESOURCE_DIMENSION_TEXTURE2D} : default_view(resource, false);
    if (desc) {
        if (view.format == DXGI_FORMAT_UNKNOWN && resource) view.format = resource->GetDesc().Format;
        switch (desc->ViewDimension) {
        case D3D12_RTV_DIMENSION_TEXTURE1D: view.dimension = D3D12_RESOURCE_DIMENSION_TEXTURE1D; view.mip = desc->Texture1D.MipSlice; break;
        case D3D12_RTV_DIMENSION_TEXTURE1DARRAY:
            view.dimension = D3D12_RESOURCE_DIMENSION_TEXTURE1D; view.mip = desc->Texture1DArray.MipSlice;
            view.slice = desc->Texture1DArray.FirstArraySlice; view.slices = desc->Texture1DArray.ArraySize; break;
        case D3D12_RTV_DIMENSION_TEXTURE2D: view.mip = desc->Texture2D.MipSlice; view.plane = desc->Texture2D.PlaneSlice; break;
        case D3D12_RTV_DIMENSION_TEXTURE2DARRAY:
            view.mip = desc->Texture2DArray.MipSlice; view.plane = desc->Texture2DArray.PlaneSlice;
            view.slice = desc->Texture2DArray.FirstArraySlice; view.slices = desc->Texture2DArray.ArraySize; break;
        case D3D12_RTV_DIMENSION_TEXTURE2DMS: view.multisample = true; view.type = MTLTextureType2DMultisampleArray; break;
        case D3D12_RTV_DIMENSION_TEXTURE2DMSARRAY:
            view.multisample = true; view.type = MTLTextureType2DMultisampleArray;
            view.slice = desc->Texture2DMSArray.FirstArraySlice; view.slices = desc->Texture2DMSArray.ArraySize; break;
        case D3D12_RTV_DIMENSION_TEXTURE3D:
            view.dimension = D3D12_RESOURCE_DIMENSION_TEXTURE3D; view.type = MTLTextureType3D; view.mip = desc->Texture3D.MipSlice;
            view.depth = desc->Texture3D.FirstWSlice; view.depths = desc->Texture3D.WSize; break;
        default: require(false, "unsupported RTV dimension (buffer RTVs require a render-copy path)");
        }
    }
    store(device, dest, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, texture_view(resource, view, false, false));
}
void create_dsv(ID3D12Device *device, ID3D12Resource *resource, const D3D12_DEPTH_STENCIL_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE dest) {
    check_resource(device, resource); require_flags(resource, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL);
    auto view = desc ? TextureView{desc->Format, D3D12_RESOURCE_DIMENSION_TEXTURE2D} : default_view(resource, false);
    D3D12_DSV_FLAGS flags = D3D12_DSV_FLAG_NONE;
    if (desc) {
        if (view.format == DXGI_FORMAT_UNKNOWN && resource) view.format = resource->GetDesc().Format;
        flags = desc->Flags;
        require(!(flags & ~(D3D12_DSV_FLAG_READ_ONLY_DEPTH | D3D12_DSV_FLAG_READ_ONLY_STENCIL)), "invalid DSV flags");
        switch (desc->ViewDimension) {
        case D3D12_DSV_DIMENSION_TEXTURE1D: view.dimension = D3D12_RESOURCE_DIMENSION_TEXTURE1D; view.mip = desc->Texture1D.MipSlice; break;
        case D3D12_DSV_DIMENSION_TEXTURE1DARRAY:
            view.dimension = D3D12_RESOURCE_DIMENSION_TEXTURE1D; view.mip = desc->Texture1DArray.MipSlice;
            view.slice = desc->Texture1DArray.FirstArraySlice; view.slices = desc->Texture1DArray.ArraySize; break;
        case D3D12_DSV_DIMENSION_TEXTURE2D: view.mip = desc->Texture2D.MipSlice; break;
        case D3D12_DSV_DIMENSION_TEXTURE2DARRAY:
            view.mip = desc->Texture2DArray.MipSlice; view.slice = desc->Texture2DArray.FirstArraySlice; view.slices = desc->Texture2DArray.ArraySize; break;
        case D3D12_DSV_DIMENSION_TEXTURE2DMS: view.multisample = true; view.type = MTLTextureType2DMultisampleArray; break;
        case D3D12_DSV_DIMENSION_TEXTURE2DMSARRAY:
            view.multisample = true; view.type = MTLTextureType2DMultisampleArray; view.slice = desc->Texture2DMSArray.FirstArraySlice; view.slices = desc->Texture2DMSArray.ArraySize; break;
        default: require(false, "unsupported DSV dimension");
        }
    }
    Slot slot = texture_view(resource, view, false, true);
    slot.depthFlags = flags;
    store(device, dest, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, slot);
}
void create_sampler(ID3D12Device *device, id<MTLDevice> metal, const D3D12_SAMPLER_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE dest) {
    check_resource(device, nullptr);
    id<MTLSamplerState> state;
    require(desc && SUCCEEDED(make_sampler(metal, *desc, &state)), "invalid or unsupported sampler");
    Slot slot;
    slot.sampler = state;
    // The converter applies bias from metadata; applying it to the Metal sampler too would double it.
    slot.packet = {slot.sampler.gpuResourceID._impl, 0, std::bit_cast<uint32_t>(desc->MipLODBias)};
    store(device, dest, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, slot);
}
HRESULT make_sampler(id<MTLDevice> metal, const D3D12_SAMPLER_DESC &value, id<MTLSamplerState> *out) {
    *out = nil;
    const auto *desc = &value;
    if (!std::isfinite(desc->MipLODBias) || !std::isfinite(desc->MinLOD) || !std::isfinite(desc->MaxLOD) || desc->MinLOD > desc->MaxLOD ||
        desc->MipLODBias < D3D12_MIP_LOD_BIAS_MIN || desc->MipLODBias > D3D12_MIP_LOD_BIAS_MAX) return E_INVALIDARG;
    const UINT filter = desc->Filter;
    if ((filter & ~0x1d5u) || D3D12_DECODE_MIN_FILTER(filter) > 1 || D3D12_DECODE_MAG_FILTER(filter) > 1 ||
        D3D12_DECODE_MIP_FILTER(filter) > 1 || ((filter & D3D12_ANISOTROPIC_FILTERING_BIT) && !D3D12_DECODE_IS_ANISOTROPIC_FILTER(filter))) return E_INVALIDARG;
    auto *sampler = [MTLSamplerDescriptor new];
    sampler.supportArgumentBuffers = YES;
    sampler.minFilter = D3D12_DECODE_MIN_FILTER(filter) == D3D12_FILTER_TYPE_LINEAR ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    sampler.magFilter = D3D12_DECODE_MAG_FILTER(filter) == D3D12_FILTER_TYPE_LINEAR ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    sampler.mipFilter = D3D12_DECODE_MIP_FILTER(filter) == D3D12_FILTER_TYPE_LINEAR ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
    if (D3D12_DECODE_IS_ANISOTROPIC_FILTER(filter)) {
        if (desc->MaxAnisotropy < 1 || desc->MaxAnisotropy > 16) return E_INVALIDARG;
        sampler.maxAnisotropy = desc->MaxAnisotropy;
    }
    const auto address = [](D3D12_TEXTURE_ADDRESS_MODE mode) {
        switch (mode) {
        case D3D12_TEXTURE_ADDRESS_MODE_WRAP: return MTLSamplerAddressModeRepeat;
        case D3D12_TEXTURE_ADDRESS_MODE_MIRROR: return MTLSamplerAddressModeMirrorRepeat;
        case D3D12_TEXTURE_ADDRESS_MODE_CLAMP: return MTLSamplerAddressModeClampToEdge;
        case D3D12_TEXTURE_ADDRESS_MODE_BORDER: return MTLSamplerAddressModeClampToBorderColor;
        case D3D12_TEXTURE_ADDRESS_MODE_MIRROR_ONCE: return MTLSamplerAddressModeMirrorClampToEdge;
        default: return MTLSamplerAddressModeClampToEdge;
        }
    };
    if (desc->AddressU < 1 || desc->AddressU > 5 || desc->AddressV < 1 || desc->AddressV > 5 || desc->AddressW < 1 || desc->AddressW > 5) return E_INVALIDARG;
    sampler.sAddressMode = address(desc->AddressU); sampler.tAddressMode = address(desc->AddressV); sampler.rAddressMode = address(desc->AddressW);
    if (desc->AddressU == D3D12_TEXTURE_ADDRESS_MODE_BORDER || desc->AddressV == D3D12_TEXTURE_ADDRESS_MODE_BORDER || desc->AddressW == D3D12_TEXTURE_ADDRESS_MODE_BORDER) {
        const auto *c = desc->BorderColor;
        if (c[0] == 0 && c[1] == 0 && c[2] == 0 && c[3] == 0) sampler.borderColor = MTLSamplerBorderColorTransparentBlack;
        else if (c[0] == 0 && c[1] == 0 && c[2] == 0 && c[3] == 1) sampler.borderColor = MTLSamplerBorderColorOpaqueBlack;
        else if (c[0] == 1 && c[1] == 1 && c[2] == 1 && c[3] == 1) sampler.borderColor = MTLSamplerBorderColorOpaqueWhite;
        else return DXGI_ERROR_UNSUPPORTED;
    }
    const auto reduction = D3D12_DECODE_FILTER_REDUCTION(filter);
    if (reduction == D3D12_FILTER_REDUCTION_TYPE_COMPARISON) {
        if (desc->ComparisonFunc < D3D12_COMPARISON_FUNC_NEVER || desc->ComparisonFunc > D3D12_COMPARISON_FUNC_ALWAYS) return E_INVALIDARG;
        sampler.compareFunction = (MTLCompareFunction)(desc->ComparisonFunc - 1);
    } else if (reduction >= D3D12_FILTER_REDUCTION_TYPE_MINIMUM) {
        if (@available(macOS 26.0, *)) {
            if (![metal supportsFamily:MTLGPUFamilyApple10]) return DXGI_ERROR_UNSUPPORTED;
            sampler.reductionMode = reduction == D3D12_FILTER_REDUCTION_TYPE_MINIMUM ? MTLSamplerReductionModeMinimum : MTLSamplerReductionModeMaximum;
        } else return DXGI_ERROR_UNSUPPORTED;
    }
    sampler.lodMinClamp = std::max(0.f, desc->MinLOD); sampler.lodMaxClamp = std::max(0.f, desc->MaxLOD);
    *out = [metal newSamplerStateWithDescriptor:sampler];
    return *out ? S_OK : E_OUTOFMEMORY;
}
void copy_descriptors(ID3D12Device *device, UINT dest_count, const D3D12_CPU_DESCRIPTOR_HANDLE *dest, const UINT *dest_sizes,
    UINT src_count, const D3D12_CPU_DESCRIPTOR_HANDLE *src, const UINT *src_sizes, D3D12_DESCRIPTOR_HEAP_TYPE type) {
    check_resource(device, nullptr);
    require(descriptor_stride(type) && (!dest_count || dest) && (!src_count || src), "invalid descriptor copy ranges");
    std::lock_guard lock(descriptor_mutex);
    std::vector<Slot> snapshot;
    for (UINT i = 0; i < src_count; ++i) {
        const UINT count = src_sizes ? src_sizes[i] : 1;
        if (!count) continue;
        const auto location = locate(device, src[i], type, count);
        require(!(location.heap->desc.Flags & D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE), "copy source must be CPU-only");
        snapshot.insert(snapshot.end(), location.heap->slots.begin() + location.index, location.heap->slots.begin() + location.index + count);
    }
    size_t total = 0;
    for (UINT i = 0; i < dest_count; ++i) {
        const UINT count = dest_sizes ? dest_sizes[i] : 1;
        if (count) locate(device, dest[i], type, count);
        require(count <= SIZE_MAX - total, "copy count overflow"); total += count;
    }
    require(total == snapshot.size(), "descriptor copy source/destination counts differ");
    size_t offset = 0;
    for (UINT i = 0; i < dest_count; ++i) {
        const UINT count = dest_sizes ? dest_sizes[i] : 1;
        if (!count) continue;
        const auto location = locate(device, dest[i], type, count);
        for (UINT j = 0; j < count; ++j) location.heap->store(location.index + j, snapshot[offset++]);
    }
}
D3DMDescriptorView descriptor_view(ID3D12Device *device,D3D12_CPU_DESCRIPTOR_HANDLE handle,D3D12_DESCRIPTOR_HEAP_TYPE type) {
    std::lock_guard lock(descriptor_mutex);
    const auto location=locate(device,handle,type);const auto &slot=location.heap->slots[location.index];
    return {(__bridge void *)slot.resource,(__bridge void *)slot.counter,slot.depthPlane,slot.depthCount,slot.depthFlags};
}
D3D12_UNORDERED_ACCESS_VIEW_DESC clear_uav_desc(ID3D12Device *device,D3D12_CPU_DESCRIPTOR_HANDLE handle,ID3D12Resource *resource) {
    std::lock_guard lock(descriptor_mutex);const auto location=locate(device,handle,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    const auto &view=location.heap->slots[location.index].unordered;
    require(!(location.heap->desc.Flags&D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE) && view && view->resource==resource,"clear CPU UAV/resource mismatch");
    return view->desc;
}
bool uav_gpu_handle(ID3D12DescriptorHeap *value,UINT64 address,ID3D12Resource *resource) {
    auto *heap=static_cast<DescriptorHeap *>(value);auto table=heap->table;
    if (!table || heap->desc.Type!=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV || address<table.gpuAddress || address-table.gpuAddress>=table.length || (address-table.gpuAddress)%24) return false;
    std::lock_guard lock(descriptor_mutex);const auto &view=heap->slots[(address-table.gpuAddress)/24].unordered;
    return view && view->resource==resource;
}
void release_resource_descriptors(ID3D12Device *device, id<MTLResource> resource) {
    if (!resource) return;
    auto references = [&](id<MTLResource> view) {
        if (view == resource) return true;
        if (![view conformsToProtocol:@protocol(MTLTexture)]) return false;
        id<MTLTexture> texture = (id<MTLTexture>)view;
        while (texture) {
            if (texture == resource || texture.buffer == resource) return true;
            texture = texture.parentTexture;
        }
        return false;
    };
    std::lock_guard lock(descriptor_mutex);
    for (const auto &[address, heap] : heaps) {
        if (heap->device != device) continue;
        bool changed = false;
        for (auto it = heap->occupied.begin(); it != heap->occupied.end();) {
            const UINT index = *it++;
            const auto &slot = heap->slots[index];
            if (references(slot.resource) || references(slot.counter)) {
                heap->store(index, {});
                changed = true;
            }
        }
        if (changed) {
            // Encoded command buffers retain in-flight storage; descriptors must not retain dead resources.
            heap->read_resources.clear(); heap->write_resources.clear(); heap->allocations.clear();
            heap->resident_render = nil; heap->resident_compute = nil; heap->resident_set = nil;
        }
    }
}
void use_descriptor_heap(ID3D12DescriptorHeap *value,id<MTLRenderCommandEncoder> render,id<MTLComputeCommandEncoder> compute,id residency) {
    auto *heap=static_cast<DescriptorHeap *>(value);
    std::lock_guard lock(descriptor_mutex);
    if (heap->resources_dirty) {
        // Address-ordered unique resources with merged usage, as a std::map would give, without per-slot node allocation.
        auto &resources=heap->scratch;resources.clear();resources.reserve(2*heap->occupied.size());
        for (UINT index:heap->occupied) {
            const auto &slot=heap->slots[index];
            if (slot.resource) resources.emplace_back((uintptr_t)(__bridge void *)slot.resource,slot.usage);
            if (slot.counter) resources.emplace_back((uintptr_t)(__bridge void *)slot.counter,MTLResourceUsageRead|MTLResourceUsageWrite);
        }
        std::sort(resources.begin(),resources.end(),[](const auto &a,const auto &b) { return a.first<b.first; });
        size_t unique=0;
        for (size_t i=0;i<resources.size();++i) {
            if (unique && resources[unique-1].first==resources[i].first) resources[unique-1].second|=resources[i].second;
            else resources[unique++]=resources[i];
        }
        resources.resize(unique);
        heap->read_resources.clear();heap->write_resources.clear();
        for (const auto &[address,usage]:resources) {
            auto &group=(usage&MTLResourceUsageWrite)?heap->write_resources:heap->read_resources;
            group.push_back((__bridge id<MTLResource>)(void *)address);
        }
        heap->resources_dirty=false;
        heap->resident_render=nil;heap->resident_compute=nil;heap->resident_set=nil;
        if (@available(macOS 15.0,*)) {
            heap->allocations.clear();heap->allocations.push_back(heap->table);
            for (const auto &[address,usage]:resources) {
                // Keep texture views themselves; heap-only residency returned zero texels in the GPU regression.
                heap->allocations.push_back((__bridge id<MTLResource>)(void *)address);
            }
        }
    }
    if (@available(macOS 15.0,*)) {
        if (residency) {
            if (heap->resident_set!=residency) {
                [residency addAllocations:heap->allocations.data() count:heap->allocations.size()];heap->resident_set=residency;
            }
            return;
        }
    }
    const bool bind_render=render && heap->resident_render!=render,bind_compute=compute && heap->resident_compute!=compute;
    if (!bind_render && !bind_compute) return;
    // Declarations cover subsequent commands in this encoder; weak references cannot retain it or reuse a stale address.
    if (bind_render) [render useResource:heap->table usage:MTLResourceUsageRead stages:MTLRenderStageVertex|MTLRenderStageFragment];
    if (bind_compute) [compute useResource:heap->table usage:MTLResourceUsageRead];
    for (UINT writable=0;writable<2;++writable) {
        const auto &resources=writable?heap->write_resources:heap->read_resources;
        if (resources.empty()) continue;
        const auto usage=writable?(MTLResourceUsageRead|MTLResourceUsageWrite):MTLResourceUsageRead;
        if (bind_render) [render useResources:resources.data() count:resources.size() usage:usage stages:MTLRenderStageVertex|MTLRenderStageFragment];
        if (bind_compute) [compute useResources:resources.data() count:resources.size() usage:usage];
    }
    if (bind_render) heap->resident_render=render;
    if (bind_compute) heap->resident_compute=compute;
}
D3D12_CONSTANT_BUFFER_VIEW_DESC table_cbv(ID3D12DescriptorHeap *value,UINT64 address,UINT index) {
    auto *heap=static_cast<DescriptorHeap *>(value);auto table=heap->table;
    if (heap->desc.Type!=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV || !table || address<table.gpuAddress ||
        address-table.gpuAddress>=table.length || (address-table.gpuAddress)%24) return {};
    const UINT64 slot=(address-table.gpuAddress)/24+index;
    std::lock_guard lock(descriptor_mutex);
    if (slot>=heap->slots.size()) return {};
    return heap->slots[slot].cbv;
}
bool use_descriptor_range(ID3D12DescriptorHeap *value,UINT64 address,UINT first,UINT count,id<MTLRenderCommandEncoder> render,id<MTLComputeCommandEncoder> compute,id residency) {
    auto *heap=static_cast<DescriptorHeap *>(value);auto table=heap->table;
    if (!table || address<table.gpuAddress || address-table.gpuAddress>=table.length || (address-table.gpuAddress)%24) return false;
    const UINT64 begin=(address-table.gpuAddress)/24+first;
    if (begin==0 && count>=heap->slots.size()) { use_descriptor_heap(value,render,compute,residency);return true; }
    std::lock_guard lock(descriptor_mutex);
    if (render) [render useResource:table usage:MTLResourceUsageRead stages:MTLRenderStageVertex|MTLRenderStageFragment];
    if (compute) [compute useResource:table usage:MTLResourceUsageRead];
    if (begin>=heap->slots.size()) return true;
    const UINT64 end=std::min<UINT64>(begin+count,heap->slots.size());
    for (auto i=heap->occupied.lower_bound((UINT)begin);i!=heap->occupied.end() && *i<end;++i) {
        const auto &slot=heap->slots[*i];id<MTLResource> resources[]={slot.resource,slot.counter};
        for (id<MTLResource> resource:resources) {
            if (!resource) continue;
            auto usage=slot.usage;if (resource==slot.counter) usage=MTLResourceUsageRead|MTLResourceUsageWrite;
            if (render) [render useResource:resource usage:usage stages:MTLRenderStageVertex|MTLRenderStageFragment];
            if (compute) [compute useResource:resource usage:usage];
        }
    }
    return true;
}
}
