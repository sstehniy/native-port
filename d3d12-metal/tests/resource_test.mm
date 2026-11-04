#import <Metal/Metal.h>
#include "d3d12_metal.h"
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

static std::atomic<unsigned> checks;
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "resource_test:%d: %s\n", __LINE__, #value); std::exit(1); } ++checks; } while (0)
#define OK(value) CHECK((value) == S_OK)

static D3D12_RESOURCE_DESC buffer_desc(UINT64 width) {
    return {D3D12_RESOURCE_DIMENSION_BUFFER, 0, width, 1, 1, 1, DXGI_FORMAT_UNKNOWN, {1, 0}, D3D12_TEXTURE_LAYOUT_ROW_MAJOR, D3D12_RESOURCE_FLAG_NONE};
}
static D3D12_RESOURCE_DESC texture_desc(DXGI_FORMAT format, UINT width = 32, UINT height = 16) {
    return {D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, width, height, 1, 1, format, {1, 0}, D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_NONE};
}
static D3D12_HEAP_PROPERTIES properties(D3D12_HEAP_TYPE type) { return {type, D3D12_CPU_PAGE_PROPERTY_UNKNOWN, D3D12_MEMORY_POOL_UNKNOWN, 1, 1}; }
static ID3D12Resource *committed(ID3D12Device *device, const D3D12_RESOURCE_DESC &desc, D3D12_HEAP_TYPE type = D3D12_HEAP_TYPE_DEFAULT) {
    const auto heap = properties(type);
    D3D12_RESOURCE_STATES state = D3D12_RESOURCE_STATE_COMMON;
    if (type == D3D12_HEAP_TYPE_UPLOAD) state = D3D12_RESOURCE_STATE_GENERIC_READ;
    if (type == D3D12_HEAP_TYPE_READBACK) state = D3D12_RESOURCE_STATE_COPY_DEST;
    ID3D12Resource *result = nullptr;
    OK(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, state, nullptr, __uuidof(ID3D12Resource), (void **)&result));
    return result;
}
static id<MTLBuffer> metal_buffer(ID3D12Resource *resource) {
    ID3DMMetalBuffer *backing = nullptr;
    OK(resource->QueryInterface(__uuidof(ID3DMMetalBuffer), (void **)&backing));
    id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)backing->MetalBuffer();
    backing->Release();
    return buffer;
}
static id<MTLTexture> metal_texture(ID3D12Resource *resource) {
    ID3DMMetalTexture *backing = nullptr;
    OK(resource->QueryInterface(__uuidof(ID3DMMetalTexture), (void **)&backing));
    id<MTLTexture> texture = (__bridge id<MTLTexture>)backing->MetalTexture();
    backing->Release();
    return texture;
}
static void finish(id<MTLCommandBuffer> commands) {
    [commands commit]; [commands waitUntilCompleted]; CHECK(commands.status == MTLCommandBufferStatusCompleted);
}

static void buffers(ID3D12Device *device, id<MTLDevice> metal, id<MTLCommandQueue> queue) {
    const auto desc = buffer_desc(4097);
    const auto info = device->GetResourceAllocationInfo(0, 1, &desc);
    CHECK(info.Alignment == 65536 && info.SizeInBytes == 65536);
    ID3D12Resource *upload = committed(device, desc, D3D12_HEAP_TYPE_UPLOAD);
    ID3D12Resource *gpu = committed(device, desc);
    ID3D12Resource *readback = committed(device, desc, D3D12_HEAP_TYPE_READBACK);
    const auto u = metal_buffer(upload), g = metal_buffer(gpu), r = metal_buffer(readback);
    CHECK(u.storageMode == MTLStorageModeShared && u.cpuCacheMode == MTLCPUCacheModeWriteCombined);
    CHECK(g.storageMode == MTLStorageModePrivate && r.storageMode == MTLStorageModeShared && r.cpuCacheMode == MTLCPUCacheModeDefaultCache);
    CHECK(upload->GetGPUVirtualAddress() == u.gpuAddress && gpu->GetGPUVirtualAddress() == g.gpuAddress);
    CHECK(gpu->GetGPUVirtualAddress() && gpu->GetGPUVirtualAddress() % 256 == 0);
    void *first = nullptr, *second = nullptr;
    const D3D12_RANGE no_reads = {0, 0};
    OK(upload->Map(0, &no_reads, &first)); OK(upload->Map(0, nullptr, &second));
    CHECK(first == second && first == u.contents);
    for (unsigned i = 0; i < desc.Width; ++i) ((unsigned char *)first)[i] = (i * 37 + 9) & 255;
    upload->Unmap(0, nullptr);
    upload->Unmap(0, nullptr);
    void *denied = (void *)1;
    CHECK(gpu->Map(0, nullptr, &denied) == E_INVALIDARG && !denied);
    CHECK(upload->Map(1, nullptr, &denied) == E_INVALIDARG && !denied);
    const D3D12_RANGE beyond = {0, 4098};
    CHECK(upload->Map(0, &beyond, &denied) == E_INVALIDARG && !denied);
    OK(upload->Map(0, nullptr, nullptr)); upload->Unmap(0, nullptr);
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
    [blit copyFromBuffer:u sourceOffset:0 toBuffer:g destinationOffset:0 size:desc.Width];
    [blit copyFromBuffer:g sourceOffset:0 toBuffer:r destinationOffset:0 size:desc.Width];
    [blit endEncoding]; finish(commands);
    void *mapped = nullptr;
    OK(readback->Map(0, nullptr, &mapped)); CHECK(mapped == r.contents && !memcmp(first, mapped, desc.Width));
    readback->Unmap(0, nullptr);
    IUnknown *identity = nullptr;
    OK(gpu->QueryInterface(__uuidof(IUnknown), (void **)&identity)); CHECK(identity == static_cast<IUnknown *>(gpu)); identity->Release();
    ID3D12Device *owner = nullptr;
    OK(gpu->GetDevice(__uuidof(ID3D12Device), (void **)&owner)); CHECK(owner == device); owner->Release();
    D3D12_HEAP_PROPERTIES returned = {};
    D3D12_HEAP_FLAGS flags = D3D12_HEAP_FLAG_SHARED;
    OK(upload->GetHeapProperties(&returned, &flags)); CHECK(returned.Type == D3D12_HEAP_TYPE_UPLOAD && returned.CreationNodeMask == 1 && flags == 0);
    OK(upload->SetName(L"mapped upload")); CHECK([u.label isEqualToString:@"mapped upload"]);
    UINT bytes = 0;
    OK(upload->GetPrivateData(WKPDID_D3DDebugObjectNameW, &bytes, nullptr)); CHECK(bytes == sizeof(L"mapped upload"));
    const auto defaults = properties(D3D12_HEAP_TYPE_DEFAULT);
    CHECK(device->CreateCommittedResource(&defaults, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_COMMON, nullptr,
        __uuidof(ID3D12Resource), nullptr) == S_FALSE);
    CHECK(upload->Release() == 0 && gpu->Release() == 0 && readback->Release() == 0);
    CHECK(metal.hasUnifiedMemory);
}

static void unaligned_heaps(ID3D12Device *device) {
    D3D12_HEAP_DESC game = {134479872, properties(D3D12_HEAP_TYPE_DEFAULT), 4194304,
        D3D12_HEAP_FLAG_ALLOW_ONLY_NON_RT_DS_TEXTURES};
    ID3D12Heap *game_heap = nullptr;
    OK(device->CreateHeap(&game, __uuidof(ID3D12Heap), (void **)&game_heap));
    CHECK(game_heap->GetDesc().SizeInBytes == game.SizeInBytes);
    game_heap->Release();
    for (UINT64 alignment : {UINT64_C(0), UINT64_C(65536), UINT64_C(4194304)}) {
        for (UINT64 size : {UINT64_C(1), UINT64_C(1024), UINT64_C(65535), UINT64_C(65537)}) {
            D3D12_HEAP_DESC desc = {size, properties(D3D12_HEAP_TYPE_UPLOAD), alignment, D3D12_HEAP_FLAG_ALLOW_ONLY_BUFFERS};
            ID3D12Heap *heap = nullptr;
            OK(device->CreateHeap(&desc, __uuidof(ID3D12Heap), (void **)&heap));
            CHECK(heap->GetDesc().SizeInBytes == size);
            auto buffer = buffer_desc(1);
            ID3D12Resource *resource = nullptr;
            OK(device->CreatePlacedResource(heap, 0, &buffer, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
                __uuidof(ID3D12Resource), (void **)&resource));
            void *mapped = nullptr;
            OK(resource->Map(0, nullptr, &mapped));
            *(uint8_t *)mapped = 0x6d;
            CHECK(*(uint8_t *)mapped == 0x6d);
            resource->Unmap(0, nullptr);
            resource->Release();
            buffer.Width = size + 1;
            CHECK(device->CreatePlacedResource(heap, 0, &buffer, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
                __uuidof(ID3D12Resource), (void **)&resource) == E_INVALIDARG && !resource);
            heap->Release();
        }
    }
}

static void heaps(ID3D12Device *device) {
    unaligned_heaps(device);
    D3D12_HEAP_DESC desc = {131072, properties(D3D12_HEAP_TYPE_UPLOAD), 0, D3D12_HEAP_FLAG_ALLOW_ONLY_BUFFERS};
    ID3D12Heap *heap = nullptr;
    OK(device->CreateHeap(&desc, __uuidof(ID3D12Heap), (void **)&heap));
    const auto returned = heap->GetDesc();
    CHECK(returned.SizeInBytes == desc.SizeInBytes && returned.Alignment == 65536 && returned.Properties.Type == D3D12_HEAP_TYPE_UPLOAD);
    ID3D12Device *owner = nullptr;
    OK(heap->GetDevice(__uuidof(ID3D12Device), (void **)&owner)); CHECK(owner == device); owner->Release();
    OK(heap->SetName(L"shared placement"));
    ID3DMMetalHeap *backing = nullptr;
    OK(heap->QueryInterface(__uuidof(ID3DMMetalHeap), (void **)&backing));
    id<MTLHeap> native = (__bridge id<MTLHeap>)backing->MetalHeap();
    CHECK(native.type == MTLHeapTypePlacement && native.storageMode == MTLStorageModeShared && [native.label isEqualToString:@"shared placement"]);
    backing->Release();
    auto buffer = buffer_desc(256);
    ID3D12Resource *first = nullptr, *second = nullptr, *alias = nullptr;
    OK(device->CreatePlacedResource(heap, 0, &buffer, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, __uuidof(ID3D12Resource), (void **)&first));
    OK(device->CreatePlacedResource(heap, 65536, &buffer, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, __uuidof(ID3D12Resource), (void **)&second));
    OK(device->CreatePlacedResource(heap, 0, &buffer, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, __uuidof(ID3D12Resource), (void **)&alias));
    void *a = nullptr, *b = nullptr, *c = nullptr;
    OK(first->Map(0, nullptr, &a)); OK(second->Map(0, nullptr, &b)); OK(alias->Map(0, nullptr, &c));
    CHECK(c == a && (char *)b - (char *)a == 65536);
    CHECK(first->GetGPUVirtualAddress() == metal_buffer(first).gpuAddress && second->GetGPUVirtualAddress() == metal_buffer(second).gpuAddress);
    memset(a, 0x5a, 256); CHECK(((unsigned char *)c)[255] == 0x5a);
    first->Unmap(0, nullptr); second->Unmap(0, nullptr); alias->Unmap(0, nullptr);
    ID3D12Resource *invalid = (ID3D12Resource *)1;
    CHECK(device->CreatePlacedResource(heap, 1, &buffer, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, __uuidof(ID3D12Resource), (void **)&invalid) == E_INVALIDARG && !invalid);
    CHECK(device->CreatePlacedResource(heap, 131072, &buffer, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, __uuidof(ID3D12Resource), (void **)&invalid) == E_INVALIDARG && !invalid);
    auto texture = texture_desc(DXGI_FORMAT_R8G8B8A8_UNORM);
    CHECK(device->CreatePlacedResource(heap, 0, &texture, D3D12_RESOURCE_STATE_COMMON, nullptr, __uuidof(ID3D12Resource), (void **)&invalid) == E_INVALIDARG && !invalid);
    CHECK(heap->Release() == 3);
    CHECK(first->Release() == 0 && second->Release() == 0 && alias->Release() == 0);

    texture = texture_desc(DXGI_FORMAT_R16G16B16A16_FLOAT, 256, 256);
    texture.Alignment = 4096;
    const auto info = device->GetResourceAllocationInfo(0, 1, &texture);
    CHECK(info.Alignment == 4096 && info.SizeInBytes != UINT64_MAX);
    desc = {(4096 + info.SizeInBytes + 65535) & ~UINT64_C(65535), properties(D3D12_HEAP_TYPE_DEFAULT), 65536,
            D3D12_HEAP_FLAG_ALLOW_ONLY_NON_RT_DS_TEXTURES};
    OK(device->CreateHeap(&desc, __uuidof(ID3D12Heap), (void **)&heap));
    OK(device->CreatePlacedResource(heap, 4096, &texture, D3D12_RESOURCE_STATE_COMMON, nullptr, __uuidof(ID3D12Resource), (void **)&first));
    const auto placed = metal_texture(first);
    CHECK(placed.storageMode == MTLStorageModePrivate && placed.heapOffset >= 4096 && placed.heapOffset < 4096 + info.SizeInBytes);
    CHECK(first->GetGPUVirtualAddress() == 0);
    CHECK(first->Release() == 0 && heap->Release() == 0);
}

struct Format { DXGI_FORMAT dxgi; MTLPixelFormat metal; unsigned block_bytes; };
static const Format compressed[] = {
    {DXGI_FORMAT_BC1_UNORM, MTLPixelFormatBC1_RGBA, 8}, {DXGI_FORMAT_BC1_UNORM_SRGB, MTLPixelFormatBC1_RGBA_sRGB, 8},
    {DXGI_FORMAT_BC2_UNORM, MTLPixelFormatBC2_RGBA, 16}, {DXGI_FORMAT_BC2_UNORM_SRGB, MTLPixelFormatBC2_RGBA_sRGB, 16},
    {DXGI_FORMAT_BC3_UNORM, MTLPixelFormatBC3_RGBA, 16}, {DXGI_FORMAT_BC3_UNORM_SRGB, MTLPixelFormatBC3_RGBA_sRGB, 16},
    {DXGI_FORMAT_BC4_UNORM, MTLPixelFormatBC4_RUnorm, 8}, {DXGI_FORMAT_BC4_SNORM, MTLPixelFormatBC4_RSnorm, 8},
    {DXGI_FORMAT_BC5_UNORM, MTLPixelFormatBC5_RGUnorm, 16}, {DXGI_FORMAT_BC5_SNORM, MTLPixelFormatBC5_RGSnorm, 16},
    {DXGI_FORMAT_BC6H_UF16, MTLPixelFormatBC6H_RGBUfloat, 16}, {DXGI_FORMAT_BC6H_SF16, MTLPixelFormatBC6H_RGBFloat, 16},
    {DXGI_FORMAT_BC7_UNORM, MTLPixelFormatBC7_RGBAUnorm, 16}, {DXGI_FORMAT_BC7_UNORM_SRGB, MTLPixelFormatBC7_RGBAUnorm_sRGB, 16}
};

static void formats(ID3D12Device *device, id<MTLDevice> metal, id<MTLCommandQueue> queue) {
    const Format plain[] = {
        {DXGI_FORMAT_R32G32B32A32_FLOAT, MTLPixelFormatRGBA32Float, 16}, {DXGI_FORMAT_R16G16B16A16_FLOAT, MTLPixelFormatRGBA16Float, 8},
        {DXGI_FORMAT_R32G32_FLOAT, MTLPixelFormatRG32Float, 8}, {DXGI_FORMAT_R11G11B10_FLOAT, MTLPixelFormatRG11B10Float, 4},
        {DXGI_FORMAT_R8G8B8A8_UNORM, MTLPixelFormatRGBA8Unorm, 4}, {DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, MTLPixelFormatRGBA8Unorm_sRGB, 4},
        {DXGI_FORMAT_R16G16_FLOAT, MTLPixelFormatRG16Float, 4}, {DXGI_FORMAT_R32_FLOAT, MTLPixelFormatR32Float, 4},
        {DXGI_FORMAT_R32_UINT, MTLPixelFormatR32Uint, 4}, {DXGI_FORMAT_R8G8_UNORM, MTLPixelFormatRG8Unorm, 2},
        {DXGI_FORMAT_R16_FLOAT, MTLPixelFormatR16Float, 2}, {DXGI_FORMAT_R8_UNORM, MTLPixelFormatR8Unorm, 1},
        {DXGI_FORMAT_B8G8R8A8_UNORM, MTLPixelFormatBGRA8Unorm, 4}, {DXGI_FORMAT_B8G8R8A8_UNORM_SRGB, MTLPixelFormatBGRA8Unorm_sRGB, 4},
        {DXGI_FORMAT_R16_UNORM, MTLPixelFormatR16Unorm, 2}, {DXGI_FORMAT_R10G10B10A2_UNORM, MTLPixelFormatRGB10A2Unorm, 4}
    };
    for (const auto &format : plain) {
        auto desc = texture_desc(format.dxgi);
        ID3D12Resource *resource = committed(device, desc);
        const auto texture = metal_texture(resource);
        CHECK(texture.pixelFormat == format.metal && texture.storageMode == MTLStorageModePrivate);
        CHECK(texture.width == 32 && texture.height == 16 && texture.textureType == MTLTextureType2DArray && texture.arrayLength == 1);
        CHECK(resource->Release() == 0);
    }
    for (const auto &format : compressed) {
        auto desc = texture_desc(format.dxgi, 8, 8);
        desc.Alignment = 4096;
        desc.DepthOrArraySize = 2;
        desc.MipLevels = 2;
        ID3D12Resource *resource = committed(device, desc);
        const auto texture = metal_texture(resource);
        CHECK(texture.pixelFormat == format.metal && texture.arrayLength == 2 && texture.mipmapLevelCount == 2);
        id<MTLBuffer> input = [metal newBufferWithLength:512 options:MTLResourceStorageModeShared];
        id<MTLBuffer> output = [metal newBufferWithLength:512 options:MTLResourceStorageModeShared];
        for (unsigned i = 0; i < 512; ++i) ((unsigned char *)input.contents)[i] = (i * 13 + 7) & 255;
        memset(output.contents, 0xa5, 512);
        id<MTLCommandBuffer> commands = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        [blit copyFromBuffer:input sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:512 sourceSize:MTLSizeMake(8, 8, 1)
                  toTexture:texture destinationSlice:1 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit copyFromTexture:texture sourceSlice:1 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1)
                    toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:512];
        [blit endEncoding]; finish(commands);
        CHECK(!memcmp(input.contents, output.contents, format.block_bytes * 2));
        CHECK(!memcmp((char *)input.contents + 256, (char *)output.contents + 256, format.block_bytes * 2));
        CHECK(resource->Release() == 0);
    }
}

static void shapes_and_views(ID3D12Device *device) {
    auto desc = texture_desc(DXGI_FORMAT_R8G8B8A8_TYPELESS, 32, 32);
    desc.DepthOrArraySize = 12;
    desc.MipLevels = 0;
    ID3D12Resource *resource = committed(device, desc);
    CHECK(resource->GetDesc().MipLevels == 6);
    const auto texture = metal_texture(resource);
    id<MTLTexture> srgb = [texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    id<MTLTexture> integer = [texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Uint];
    id<MTLTexture> cube = [texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureTypeCube
                                                      levels:NSMakeRange(1, 2) slices:NSMakeRange(6, 6)];
    id<MTLTexture> cubes = [texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureTypeCubeArray
                                                       levels:NSMakeRange(0, 6) slices:NSMakeRange(0, 12)];
    CHECK(srgb && integer && cube && cubes);
    CHECK(cube.textureType == MTLTextureTypeCube && cube.width == 16 && cube.mipmapLevelCount == 2 && cubes.arrayLength == 2);
    CHECK(resource->Release() == 0);
    desc = texture_desc(DXGI_FORMAT_R16_FLOAT, 16, 8);
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE3D;
    desc.DepthOrArraySize = 4;
    desc.MipLevels = 0;
    resource = committed(device, desc);
    const auto volume = metal_texture(resource);
    CHECK(volume.textureType == MTLTextureType3D && volume.depth == 4 && volume.arrayLength == 1 && volume.mipmapLevelCount == 5);
    CHECK(resource->Release() == 0);
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE1D;
    desc.Height = 1;
    desc.DepthOrArraySize = 3;
    resource = committed(device, desc);
    CHECK(metal_texture(resource).height == 1 && metal_texture(resource).arrayLength == 3 && resource->GetDesc().Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE1D);
    CHECK(resource->Release() == 0);
}

static void cpu_textures(ID3D12Device *device) {
    auto desc = texture_desc(DXGI_FORMAT_R8G8B8A8_UNORM, 16, 8);
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE3D;
    desc.DepthOrArraySize = 4;
    desc.MipLevels = 2;
    const D3D12_HEAP_PROPERTIES custom = {D3D12_HEAP_TYPE_CUSTOM, D3D12_CPU_PAGE_PROPERTY_WRITE_BACK, D3D12_MEMORY_POOL_L0, 1, 1};
    ID3D12Resource *resource = nullptr;
    OK(device->CreateCommittedResource(&custom, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_COMMON, nullptr,
        __uuidof(ID3D12Resource), (void **)&resource));
    OK(resource->Map(1, nullptr, nullptr));
    void *pointer = (void *)1;
    CHECK(resource->Map(1, nullptr, &pointer) == E_INVALIDARG && !pointer);
    std::array<unsigned char, 1024> input, output;
    for (unsigned i = 0; i < input.size(); ++i) input[i] = (i * 19) & 255;
    output.fill(0);
    OK(resource->WriteToSubresource(1, nullptr, input.data(), 64, 256));
    OK(resource->ReadFromSubresource(output.data(), 64, 256, 1, nullptr));
    for (unsigned slice = 0; slice < 2; ++slice)
        for (unsigned row = 0; row < 4; ++row)
            CHECK(!memcmp(input.data() + slice * 256 + row * 64, output.data() + slice * 256 + row * 64, 32));
    const D3D12_BOX box = {2, 1, 1, 4, 3, 2};
    output.fill(0);
    OK(resource->ReadFromSubresource(output.data(), 32, 64, 1, &box));
    CHECK(!memcmp(output.data(), input.data() + 256 + 64 + 8, 8));
    CHECK(resource->ReadFromSubresource(output.data(), 1, 64, 1, &box) == E_INVALIDARG);
    CHECK(resource->WriteToSubresource(2, nullptr, input.data(), 64, 256) == E_INVALIDARG);
    const D3D12_BOX outside = {0, 0, 0, 99, 8, 4};
    CHECK(resource->WriteToSubresource(0, &outside, input.data(), 64, 256) == E_INVALIDARG);
    resource->Unmap(1, nullptr);
    CHECK(resource->Release() == 0);
}

static void atomic_texture(ID3D12Device *device, id<MTLDevice> metal, id<MTLCommandQueue> queue) {
    auto desc = texture_desc(DXGI_FORMAT_R32_UINT, 8, 8);
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    auto *resource = committed(device, desc);
    const auto texture = metal_texture(resource);
    const char *source = "#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void clear_counter(texture2d_array<uint, access::write> t [[texture(0)]]) { t.write(uint4(0), uint2(0), 0); }\n"
        "kernel void increment(texture2d_array<uint, access::read_write> t [[texture(0)]]) { t.atomic_fetch_add(uint2(0), 0, uint4(1)); }\n"
        "kernel void read_counter(texture2d_array<uint, access::read> t [[texture(0)]], device uint *out [[buffer(0)]]) { out[0] = t.read(uint2(0), 0).r; }\n";
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_1;
    NSError *error = nil;
    id<MTLLibrary> library = [metal newLibraryWithSource:@(source) options:options error:&error];
    if (!library) fprintf(stderr, "%s\n", error.description.UTF8String);
    CHECK(library);
    id<MTLBuffer> output = [metal newBufferWithLength:4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    const char *names[] = {"clear_counter", "increment", "read_counter"};
    for (unsigned stage = 0; stage < 3; ++stage) {
        id<MTLFunction> function = [library newFunctionWithName:@(names[stage])];
        id<MTLComputePipelineState> pipeline = [metal newComputePipelineStateWithFunction:function error:&error];
        CHECK(pipeline);
        id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
        [encoder setComputePipelineState:pipeline]; [encoder setTexture:texture atIndex:0];
        if (stage == 2) [encoder setBuffer:output offset:0 atIndex:0];
        const unsigned count = stage == 1 ? 16 : 1;
        [encoder dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(count, 1, 1)];
        [encoder endEncoding];
    }
    finish(commands);
    CHECK(*(const uint32_t *)output.contents == 16);
    CHECK(resource->Release() == 0);
}

static void depth_msaa(ID3D12Device *device, id<MTLDevice> metal, id<MTLCommandQueue> queue) {
    const auto heap = properties(D3D12_HEAP_TYPE_DEFAULT);
    const char *source = "#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void depth_read(depth2d_ms_array<float, access::read> depth [[texture(0)]], device float *out [[buffer(0)]]) { out[0] = depth.read(uint2(1,1), 0, 0); }\n"
        "kernel void color_read(texture2d_ms_array<float, access::read> color [[texture(0)]], device float4 *out [[buffer(0)]]) { out[0] = color.read(uint2(1,1), 0, 0); }\n"
        "kernel void stencil_read(texture2d_ms_array<uint, access::read> stencil [[texture(0)]], device uint *out [[buffer(0)]]) { out[0] = stencil.read(uint2(1,1), 0, 0).r; }\n";
    NSError *error = nil;
    id<MTLLibrary> library = [metal newLibraryWithSource:@(source) options:nil error:&error];
    if (!library) fprintf(stderr, "%s\n", error.description.UTF8String);
    CHECK(library);
    for (bool depth : {true, false}) {
        auto desc = texture_desc(DXGI_FORMAT_R11G11B10_FLOAT, 16, 16);
        desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        if (depth) { desc.Format = DXGI_FORMAT_R24G8_TYPELESS; desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL; }
        desc.SampleDesc.Count = 4;
        ID3D12Resource *resource = nullptr;
        D3D12_CLEAR_VALUE clear = {};
        clear.Format = depth ? DXGI_FORMAT_D24_UNORM_S8_UINT : DXGI_FORMAT_R11G11B10_FLOAT;
        if (depth) { clear.DepthStencil.Depth = 0.25; clear.DepthStencil.Stencil = 0x5a; }
        OK(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_COMMON, &clear,
            __uuidof(ID3D12Resource), (void **)&resource));
        const auto texture = metal_texture(resource);
        CHECK(texture.textureType == MTLTextureType2DMultisampleArray && texture.sampleCount == 4 && texture.storageMode == MTLStorageModePrivate);
        id<MTLTexture> view = [texture newTextureViewWithPixelFormat:texture.pixelFormat];
        CHECK(view);
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (depth) {
            pass.depthAttachment.texture = texture;
            pass.depthAttachment.loadAction = MTLLoadActionClear;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.depthAttachment.clearDepth = 0.25;
            pass.stencilAttachment.texture = texture;
            pass.stencilAttachment.loadAction = MTLLoadActionClear;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.clearStencil = 0x5a;
        } else {
            pass.colorAttachments[0].texture = view;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1);
        }
        id<MTLCommandBuffer> commands = [queue commandBuffer];
        [[commands renderCommandEncoderWithDescriptor:pass] endEncoding];
        id<MTLBuffer> output = [metal newBufferWithLength:16 options:MTLResourceStorageModeShared];
        id<MTLFunction> function = [library newFunctionWithName:depth ? @"depth_read" : @"color_read"];
        id<MTLComputePipelineState> pipeline = [metal newComputePipelineStateWithFunction:function error:&error];
        CHECK(pipeline);
        id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
        [encoder setComputePipelineState:pipeline]; [encoder setTexture:view atIndex:0]; [encoder setBuffer:output offset:0 atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [encoder endEncoding]; finish(commands);
        const float *values = (const float *)output.contents;
        CHECK(std::fabs(values[0] - 0.25f) < 0.000001f);
        if (!depth) CHECK(values[1] == 0.5f && values[2] == 0.75f);
        if (depth) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            id<MTLTexture> stencil = [texture newTextureViewWithPixelFormat:MTLPixelFormatX24_Stencil8];
#pragma clang diagnostic pop
            CHECK(stencil);
            function = [library newFunctionWithName:@"stencil_read"];
            pipeline = [metal newComputePipelineStateWithFunction:function error:&error];
            CHECK(pipeline);
            commands = [queue commandBuffer];
            encoder = [commands computeCommandEncoder];
            [encoder setComputePipelineState:pipeline]; [encoder setTexture:stencil atIndex:0]; [encoder setBuffer:output offset:0 atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [encoder endEncoding]; finish(commands);
            CHECK(*(const uint32_t *)output.contents == 0x5a);
        }
        CHECK(resource->Release() == 0);
    }
    auto desc = texture_desc(DXGI_FORMAT_R16_TYPELESS);
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
    auto *resource = committed(device, desc);
    CHECK(metal_texture(resource).pixelFormat == MTLPixelFormatDepth16Unorm);
    CHECK(resource->Release() == 0);
}

static void concurrent_resources(ID3D12Device *device) {
    std::vector<std::thread> workers;
    for (unsigned i = 0; i < 8; ++i) workers.emplace_back([device, i] {
        for (unsigned n = 0; n < 16; ++n) {
            auto *resource = committed(device, buffer_desc(256), D3D12_HEAP_TYPE_UPLOAD);
            void *data = nullptr;
            OK(resource->Map(0, nullptr, &data));
            memset(data, i + n, 256);
            CHECK(((unsigned char *)data)[255] == i + n);
            resource->Unmap(0, nullptr);
            CHECK(resource->Release() == 0);
        }
    });
    for (auto &worker : workers) worker.join();
}

static void validation(ID3D12Device *device) {
    auto desc = buffer_desc(64);
    const auto upload = properties(D3D12_HEAP_TYPE_UPLOAD), defaults = properties(D3D12_HEAP_TYPE_DEFAULT);
    ID3D12Resource *out = (ID3D12Resource *)1;
    CHECK(device->CreateCommittedResource(&upload, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_COMMON, nullptr,
        __uuidof(ID3D12Resource), (void **)&out) == E_INVALIDARG && !out);
    CHECK(device->CreateCommittedResource(&defaults, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_RENDER_TARGET, nullptr,
        __uuidof(ID3D12Resource), (void **)&out) == E_INVALIDARG && !out);
    const auto conflicting = (D3D12_RESOURCE_STATES)(D3D12_RESOURCE_STATE_COPY_DEST | D3D12_RESOURCE_STATE_COPY_SOURCE);
    CHECK(device->CreateCommittedResource(&defaults, D3D12_HEAP_FLAG_NONE, &desc, conflicting, nullptr,
        __uuidof(ID3D12Resource), (void **)&out) == E_INVALIDARG && !out);
    desc.Width = UINT64_MAX;
    CHECK(device->GetResourceAllocationInfo(0, 1, &desc).SizeInBytes == UINT64_MAX);
    CHECK(device->CreateCommittedResource(&defaults, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_COMMON, nullptr,
        __uuidof(ID3D12Resource), (void **)&out) == E_INVALIDARG && !out);
    desc = texture_desc(DXGI_FORMAT_R8G8B8A8_UNORM);
    CHECK(device->CreateCommittedResource(&upload, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
        __uuidof(ID3D12Resource), (void **)&out) == E_INVALIDARG && !out);
    desc.Format = DXGI_FORMAT_R24_UNORM_X8_TYPELESS;
    CHECK(device->GetResourceAllocationInfo(0, 1, &desc).SizeInBytes == UINT64_MAX);
    desc = texture_desc(DXGI_FORMAT_BC1_UNORM);
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    CHECK(device->GetResourceAllocationInfo(0, 1, &desc).SizeInBytes == UINT64_MAX);
    desc = texture_desc(DXGI_FORMAT_R8G8B8A8_UNORM);
    desc.MipLevels = 15;
    CHECK(device->GetResourceAllocationInfo(0, 1, &desc).SizeInBytes == UINT64_MAX);
    D3D12_HEAP_DESC invalid = {0, defaults, 65536, D3D12_HEAP_FLAG_NONE};
    ID3D12Heap *heap = (ID3D12Heap *)1;
    CHECK(device->CreateHeap(&invalid, __uuidof(ID3D12Heap), (void **)&heap) == E_INVALIDARG && !heap);
    invalid.SizeInBytes = 65536; invalid.Properties.Type = D3D12_HEAP_TYPE_CUSTOM;
    CHECK(device->CreateHeap(&invalid, __uuidof(ID3D12Heap), (void **)&heap) == E_INVALIDARG && !heap);
    D3D12_RESOURCE_DESC batch[] = {buffer_desc(64), texture_desc(DXGI_FORMAT_R8G8B8A8_UNORM, 16, 16), buffer_desc(64)};
    batch[1].Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET; batch[1].SampleDesc.Count = 4;
    const auto info = device->GetResourceAllocationInfo(0, 3, batch);
    CHECK(info.Alignment == 4194304 && info.SizeInBytes == 12582912);
    const auto custom = device->GetCustomHeapProperties(0, D3D12_HEAP_TYPE_READBACK);
    CHECK(custom.Type == D3D12_HEAP_TYPE_CUSTOM && custom.CPUPageProperty == D3D12_CPU_PAGE_PROPERTY_WRITE_BACK && custom.MemoryPoolPreference == D3D12_MEMORY_POOL_L0);
}

static void coherent_heaps() {
    static bool coherent = false;
    D3DMHost host = {};
    host.check_feature = [](D3D12_FEATURE feature, void *data, UINT size) -> HRESULT {
        if (feature == D3D12_FEATURE_FEATURE_LEVELS && size == sizeof(D3D12_FEATURE_DATA_FEATURE_LEVELS)) {
            ((D3D12_FEATURE_DATA_FEATURE_LEVELS *)data)->MaxSupportedFeatureLevel = D3D_FEATURE_LEVEL_12_0;
            return S_OK;
        }
        if (feature == D3D12_FEATURE_ARCHITECTURE1 && size == sizeof(D3D12_FEATURE_DATA_ARCHITECTURE1)) {
            *(D3D12_FEATURE_DATA_ARCHITECTURE1 *)data = {0, TRUE, TRUE, coherent, FALSE};
            return S_OK;
        }
        return E_INVALIDARG;
    };
    D3DMSetHost(&host);
    for (bool cache_coherent : {false, true}) {
        coherent = cache_coherent;
        ID3D12Device *device = nullptr;
        OK(D3DMCreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, __uuidof(ID3D12Device), (void **)&device));
        const auto defaults = device->GetCustomHeapProperties(0, D3D12_HEAP_TYPE_DEFAULT);
        const auto upload = device->GetCustomHeapProperties(0, D3D12_HEAP_TYPE_UPLOAD);
        CHECK(defaults.MemoryPoolPreference == D3D12_MEMORY_POOL_L0);
        const auto expected = coherent ? D3D12_CPU_PAGE_PROPERTY_WRITE_BACK : D3D12_CPU_PAGE_PROPERTY_WRITE_COMBINE;
        CHECK(upload.CPUPageProperty == expected);
        auto *resource = committed(device, buffer_desc(256), D3D12_HEAP_TYPE_UPLOAD);
        const auto cache = coherent ? MTLCPUCacheModeDefaultCache : MTLCPUCacheModeWriteCombined;
        CHECK(metal_buffer(resource).cpuCacheMode == cache);
        CHECK(resource->Release() == 0 && device->Release() == 0);
    }
}

int main() {
    @autoreleasepool {
        D3DMHost host = {};
        host.check_feature = [](D3D12_FEATURE feature, void *data, UINT size) -> HRESULT {
            if (feature != D3D12_FEATURE_FEATURE_LEVELS || !data || size != sizeof(D3D12_FEATURE_DATA_FEATURE_LEVELS)) return E_INVALIDARG;
            id<MTLDevice> first = MTLCreateSystemDefaultDevice();
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CHECK(first.depth24Stencil8PixelFormatSupported);
#pragma clang diagnostic pop
            ((D3D12_FEATURE_DATA_FEATURE_LEVELS *)data)->MaxSupportedFeatureLevel = D3D_FEATURE_LEVEL_12_0;
            return S_OK;
        };
        D3DMSetHost(&host);
        ID3D12Device *device = nullptr;
        OK(D3DMCreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, __uuidof(ID3D12Device), (void **)&device));
        id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [metal newCommandQueue];
        buffers(device, metal, queue);
        heaps(device);
        formats(device, metal, queue);
        atomic_texture(device, metal, queue);
        shapes_and_views(device);
        cpu_textures(device);
        depth_msaa(device, metal, queue);
        validation(device);
        concurrent_resources(device);
        ID3DMDeviceStatus *status = nullptr;
        OK(device->QueryInterface(__uuidof(ID3DMDeviceStatus), (void **)&status));
        status->RecordError(DXGI_ERROR_DEVICE_REMOVED); status->Release();
        auto desc = buffer_desc(256);
        const auto heap = properties(D3D12_HEAP_TYPE_DEFAULT);
        ID3D12Resource *out = (ID3D12Resource *)1;
        CHECK(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_COMMON, nullptr,
            __uuidof(ID3D12Resource), (void **)&out) == DXGI_ERROR_DEVICE_REMOVED && !out);
        CHECK(device->Release() == 0);
        coherent_heaps();
        printf("resource_test: %u checks passed; GPU buffer/BC transfers, heaps/aliasing, formats/views, 3D CPU access, exact D24S8/MSAA and 128 concurrent creations passed\n", checks.load());
    }
}
