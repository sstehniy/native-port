#import <Metal/Metal.h>
#define IR_PRIVATE_IMPLEMENTATION
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include <metal_irconverter_runtime.h>
#pragma clang diagnostic pop
#include "d3d12_metal.h"
#include <array>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

static std::atomic<unsigned> checks;
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "descriptor_test:%d: %s\n", __LINE__, #value); std::exit(1); } ++checks; } while (0)
#define OK(value) CHECK((value) == S_OK)
static ID3D12Resource *resource(ID3D12Device *device, D3D12_RESOURCE_DESC desc, bool cpu = false) {
    D3D12_HEAP_PROPERTIES props = {D3D12_HEAP_TYPE_DEFAULT, {}, {}, 1, 1};
    auto state = D3D12_RESOURCE_STATE_COMMON;
    if (cpu) { props.Type = D3D12_HEAP_TYPE_UPLOAD; state = D3D12_RESOURCE_STATE_GENERIC_READ; }
    ID3D12Resource *result = nullptr;
    const HRESULT hr = device->CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &desc, state, nullptr, __uuidof(ID3D12Resource), (void **)&result);
    if (FAILED(hr)) fprintf(stderr, "resource HRESULT=%08x dimension=%u format=%u flags=%u alignment=%llu size=%llu,%u,%u mips=%u samples=%u\n", (unsigned)hr,
        desc.Dimension, desc.Format, desc.Flags, desc.Alignment, desc.Width, desc.Height, desc.DepthOrArraySize, desc.MipLevels, desc.SampleDesc.Count);
    OK(hr);
    return result;
}
static D3D12_RESOURCE_DESC buffer_desc(UINT64 size, bool uav = false) {
    return {D3D12_RESOURCE_DIMENSION_BUFFER, 0, size, 1, 1, 1, DXGI_FORMAT_UNKNOWN, {1, 0}, D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
        uav ? D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS : D3D12_RESOURCE_FLAG_NONE};
}
static ID3D12DescriptorHeap *heap(ID3D12Device *device, D3D12_DESCRIPTOR_HEAP_TYPE type, UINT count = 32, bool visible = false) {
    D3D12_DESCRIPTOR_HEAP_DESC desc = {type, count, visible ? D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE : D3D12_DESCRIPTOR_HEAP_FLAG_NONE, 0};
    ID3D12DescriptorHeap *result = nullptr;
    OK(device->CreateDescriptorHeap(&desc, __uuidof(ID3D12DescriptorHeap), (void **)&result));
    return result;
}
static ID3DMDescriptorHeap *backing(ID3D12DescriptorHeap *heap) {
    ID3DMDescriptorHeap *native = nullptr;
    OK(heap->QueryInterface(__uuidof(ID3DMDescriptorHeap), (void **)&native));
    return native;
}
static D3D12_CPU_DESCRIPTOR_HANDLE handle(ID3D12DescriptorHeap *heap, UINT index) {
    const UINT stride = heap->GetDesc().Type >= D3D12_DESCRIPTOR_HEAP_TYPE_RTV ? 18 : 24;
    return {heap->GetCPUDescriptorHandleForHeapStart().ptr + (size_t)index * stride};
}
static IRDescriptorTableEntry packet(ID3D12DescriptorHeap *heap, UINT index) {
    auto *native = backing(heap);
    id<MTLBuffer> table = (__bridge id<MTLBuffer>)native->MetalDescriptorBuffer();
    CHECK(table && table.length == (size_t)heap->GetDesc().NumDescriptors * 24);
    IRDescriptorTableEntry result;
    memcpy(&result, (char *)table.contents + index * 24, 24);
    native->Release(); return result;
}
static D3DMDescriptorView view(ID3D12DescriptorHeap *heap, UINT index) {
    auto *native = backing(heap); D3DMDescriptorView result;
    OK(native->GetView(index, &result)); native->Release(); return result;
}
static void equal(const IRDescriptorTableEntry &a, const IRDescriptorTableEntry &b) { CHECK(!memcmp(&a, &b, sizeof a)); }
static void finish(id<MTLCommandBuffer> commands) { [commands commit]; [commands waitUntilCompleted]; CHECK(commands.status == MTLCommandBufferStatusCompleted); }
static id<MTLComputePipelineState> pipeline(id<MTLDevice> metal, NSString *source) {
    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new]; options.languageVersion = MTLLanguageVersion3_1;
    id<MTLLibrary> library = [metal newLibraryWithSource:source options:options error:&error];
    if (error) fprintf(stderr, "%s\n", error.description.UTF8String);
    CHECK(library != nil);
    id<MTLComputePipelineState> result = [metal newComputePipelineStateWithFunction:[library newFunctionWithName:@"test"] error:&error];
    if (error) fprintf(stderr, "%s\n", error.description.UTF8String);
    CHECK(result != nil); return result;
}
static void released_texture_storage(ID3D12Device *device) {
    auto *descriptors = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 2);
    __weak id<MTLTexture> released;
    @autoreleasepool {
        D3D12_RESOURCE_DESC desc = {D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, 64, 64, 1, 1,
            DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_NONE};
        auto *image = resource(device, desc);
        ID3DMMetalTexture *native = nullptr;
        OK(image->QueryInterface(__uuidof(ID3DMMetalTexture), (void **)&native));
        released = (__bridge id<MTLTexture>)native->MetalTexture();
        native->Release();
        device->CreateShaderResourceView(image, nullptr, handle(descriptors, 0));
        device->CopyDescriptorsSimple(1, handle(descriptors, 1), handle(descriptors, 0), D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        CHECK(image->Release() == 0);
    }
    CHECK(released == nil);
    descriptors->Release();
}

static void heap_contract(ID3D12Device *device) {
    const UINT strides[] = {24,24,18,18};
    for (UINT t = 0; t < 4; ++t) {
        auto type = (D3D12_DESCRIPTOR_HEAP_TYPE)t;
        CHECK(device->GetDescriptorHandleIncrementSize(type) == strides[t]);
        auto *h = heap(device, type); const auto desc = h->GetDesc();
        CHECK(desc.Type == type && desc.NumDescriptors == 32 && desc.Flags == 0 && desc.NodeMask == 0);
        CHECK(h->GetGPUDescriptorHandleForHeapStart().ptr == 0 && handle(h, 1).ptr - handle(h, 0).ptr == strides[t]);
        ID3D12Device *owner = nullptr; OK(h->GetDevice(__uuidof(ID3D12Device), (void **)&owner)); CHECK(owner == device); owner->Release();
        IUnknown *identity = nullptr; OK(h->QueryInterface(__uuidof(IUnknown), (void **)&identity)); CHECK(identity == (IUnknown *)h); identity->Release();
        OK(h->SetName(L"descriptor heap")); UINT size = 0; OK(h->GetPrivateData(WKPDID_D3DDebugObjectNameW, &size, nullptr)); CHECK(size == sizeof(L"descriptor heap"));
        auto *native = backing(h); D3DMDescriptorView invalid{}; CHECK(native->GetView(32, &invalid) == E_INVALIDARG);
        CHECK(native->GetView(0, nullptr) == E_POINTER); native->Release(); CHECK(h->Release() == 0);
    }
    D3D12_DESCRIPTOR_HEAP_DESC desc = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1, D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, 0};
    ID3D12DescriptorHeap *out = (ID3D12DescriptorHeap *)1;
    CHECK(device->CreateDescriptorHeap(&desc, __uuidof(ID3D12DescriptorHeap), (void **)&out) == E_INVALIDARG && !out);
    desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER; desc.NumDescriptors = 2049;
    CHECK(device->CreateDescriptorHeap(&desc, __uuidof(ID3D12DescriptorHeap), (void **)&out) == E_INVALIDARG && !out);
    desc.NumDescriptors = 0; CHECK(device->CreateDescriptorHeap(&desc, __uuidof(ID3D12DescriptorHeap), (void **)&out) == E_INVALIDARG);
    desc.NumDescriptors = 1; desc.NodeMask = 2; CHECK(device->CreateDescriptorHeap(&desc, __uuidof(ID3D12DescriptorHeap), (void **)&out) == E_INVALIDARG);
    desc.NodeMask = 0; CHECK(device->CreateDescriptorHeap(&desc, __uuidof(ID3D12DescriptorHeap), nullptr) == S_FALSE);
    CHECK(device->CreateDescriptorHeap(&desc, __uuidof(ID3D12Resource), (void **)&out) == E_NOINTERFACE && !out);
    CHECK(device->CreateDescriptorHeap(nullptr, __uuidof(ID3D12DescriptorHeap), (void **)&out) == E_INVALIDARG && !out);
}
static void buffers(ID3D12Device *device, id<MTLDevice> metal, id<MTLCommandQueue> queue) {
    auto *cpu = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto *gpu = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 32, true);
    auto *data = resource(device, buffer_desc(4096), true);
    void *mapped = nullptr; OK(data->Map(0, nullptr, &mapped));
    for (unsigned i = 0; i < 1024; ++i) ((uint32_t *)mapped)[i] = 1000 + i;
    data->Unmap(0, nullptr);
    const D3D12_CONSTANT_BUFFER_VIEW_DESC cbv = {data->GetGPUVirtualAddress() + 256, 512};
    device->CreateConstantBufferView(&cbv, handle(cpu, 0));
    IRDescriptorTableEntry expected; IRDescriptorTableSetBuffer(&expected, cbv.BufferLocation, 512); equal(packet(cpu, 0), expected);
    D3D12_SHADER_RESOURCE_VIEW_DESC srv{}; srv.ViewDimension = D3D12_SRV_DIMENSION_BUFFER; srv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    srv.Format = DXGI_FORMAT_R32_TYPELESS; srv.Buffer = {3, 32, 0, D3D12_BUFFER_SRV_FLAG_RAW};
    device->CreateShaderResourceView(data, &srv, handle(cpu, 1));
    srv.Format = DXGI_FORMAT_UNKNOWN; srv.Buffer = {2, 8, 16, D3D12_BUFFER_SRV_FLAG_NONE};
    device->CreateShaderResourceView(data, &srv, handle(cpu, 2));
    srv.Format = DXGI_FORMAT_R32_UINT; srv.Buffer = {3, 32, 0, D3D12_BUFFER_SRV_FLAG_NONE};
    device->CreateShaderResourceView(data, &srv, handle(cpu, 3));
    id<MTLTexture> typed = (__bridge id<MTLTexture>)view(cpu, 3).resource;
    CHECK(typed.textureType == MTLTextureTypeTextureBuffer && typed.pixelFormat == MTLPixelFormatR32Uint);
    IRBufferView reference{typed.buffer, 12, 128, typed, (uint32_t)((12 - typed.bufferOffset) / 4), true};
    IRDescriptorTableSetBufferView(&expected, &reference); equal(packet(cpu, 3), expected);
    device->CreateConstantBufferView(nullptr, handle(cpu, 4)); equal(packet(cpu, 4), {});
    device->CreateShaderResourceView(nullptr, &srv, handle(cpu, 5)); equal(packet(cpu, 5), {});
    device->CopyDescriptorsSimple(6, handle(gpu, 0), handle(cpu, 0), D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    for (UINT i = 0; i < 6; ++i) equal(packet(gpu, i), packet(cpu, i));
    D3D12_CPU_DESCRIPTOR_HANDLE starts[] = {handle(cpu, 2), handle(cpu, 0)}, destinations[] = {handle(cpu, 10), handle(cpu, 13)};
    UINT sizes[] = {2, 1};
    device->CopyDescriptors(2, destinations, sizes, 2, starts, sizes, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    equal(packet(cpu, 10), packet(cpu, 2)); equal(packet(cpu, 11), packet(cpu, 3)); equal(packet(cpu, 13), packet(cpu, 0));
    device->CopyDescriptors(2, destinations, nullptr, 2, starts, nullptr, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    equal(packet(cpu, 13), packet(cpu, 0));
    UINT zero = 0; D3D12_CPU_DESCRIPTOR_HANDLE bad{};
    device->CopyDescriptors(1, &bad, &zero, 1, &bad, &zero, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto *counter = resource(device, buffer_desc(8192, true)); auto *append = resource(device, buffer_desc(1024, true));
    D3D12_UNORDERED_ACCESS_VIEW_DESC uav{}; uav.ViewDimension = D3D12_UAV_DIMENSION_BUFFER;
    uav.Buffer = {2, 16, 16, 4096, D3D12_BUFFER_UAV_FLAG_NONE};
    device->CreateUnorderedAccessView(append, counter, &uav, handle(cpu, 6));
    const auto append_view = view(cpu, 6); id<MTLTexture> count = (__bridge id<MTLTexture>)append_view.counter;
    CHECK(count && count.bufferOffset == 4096 && count.width == 1);
    reference = {(__bridge id<MTLBuffer>)append_view.resource, 32, 256, count, 0, false};
    IRDescriptorTableSetBufferView(&expected, &reference); equal(packet(cpu, 6), expected);
    device->CopyDescriptorsSimple(1, handle(gpu, 6), handle(cpu, 6), D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto *native = backing(gpu); id<MTLBuffer> table = (__bridge id<MTLBuffer>)native->MetalDescriptorBuffer();
    CHECK(gpu->GetGPUDescriptorHandleForHeapStart().ptr == table.gpuAddress);
    auto program = pipeline(metal, @R"(
#include <metal_stdlib>
using namespace metal;
struct Entry { device uint *data [[id(0)]]; texture_buffer<uint, access::read_write> image [[id(1)]]; ulong md [[id(2)]]; };
kernel void test(device const Entry *table [[buffer(0)]], device uint *out [[buffer(1)]]) {
    out[0] = table[0].data[0]; out[1] = table[1].data[1]; out[2] = table[2].data[0];
    uint offset = uint((table[3].md >> 32) & 255); out[3] = table[3].image.read(offset + 1).x;
    table[6].image.write(uint4(17), 0u); table[6].data[0] = 42;
    out[4] = uint(table[0].md); out[5] = uint(table[3].md >> 63);
})");
    auto output = [metal newBufferWithLength:24 options:MTLResourceStorageModeShared];
    auto commands = [queue commandBuffer]; auto encoder = [commands computeCommandEncoder];
    [encoder setComputePipelineState:program]; [encoder setBuffer:table offset:0 atIndex:0]; [encoder setBuffer:output offset:0 atIndex:1];
    for (UINT i : {0u,1u,2u,3u,6u}) {
        auto v = view(gpu, i); [encoder useResource:(__bridge id<MTLResource>)v.resource usage:MTLResourceUsageRead | MTLResourceUsageWrite];
        if (v.counter) [encoder useResource:(__bridge id<MTLResource>)v.counter usage:MTLResourceUsageRead | MTLResourceUsageWrite];
    }
    [encoder dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [encoder endEncoding];
    auto readback = [metal newBufferWithLength:8 options:MTLResourceStorageModeShared];
    auto blit = [commands blitCommandEncoder];
    [blit copyFromBuffer:count.buffer sourceOffset:4096 toBuffer:readback destinationOffset:0 size:4];
    [blit copyFromBuffer:(__bridge id<MTLBuffer>)append_view.resource sourceOffset:32 toBuffer:readback destinationOffset:4 size:4];
    [blit endEncoding]; finish(commands);
    const uint32_t wanted[] = {1064,1004,1008,1004,512,1}; CHECK(!memcmp(output.contents, wanted, sizeof wanted));
    CHECK(((uint32_t *)readback.contents)[0] == 17 && ((uint32_t *)readback.contents)[1] == 42);
    CHECK(data->Release() == 0 && append->Release() == 0 && counter->Release() == 0);
    native->Release(); cpu->Release(); gpu->Release();
}
static void textures(ID3D12Device *device, id<MTLDevice> metal, id<MTLCommandQueue> queue) {
    auto *cpu = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto *gpu = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 32, true);
    auto *samplers = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, 32, true);
    auto *sampler_cpu = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
    D3D12_RESOURCE_DESC desc = {D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, 8, 8, 2, 3, DXGI_FORMAT_R8G8B8A8_TYPELESS, {1,0}, D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET};
    auto *image = resource(device, desc);
    D3D12_SHADER_RESOURCE_VIEW_DESC srv{}; srv.Format = DXGI_FORMAT_R8G8B8A8_UNORM; srv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2DARRAY;
    srv.Shader4ComponentMapping = D3D12_ENCODE_SHADER_4_COMPONENT_MAPPING(2,1,0,5); srv.Texture2DArray = {1,2,1,1,0,0.75f};
    device->CreateShaderResourceView(image, &srv, handle(cpu, 2));
    id<MTLTexture> tex = (__bridge id<MTLTexture>)view(cpu, 2).resource;
    CHECK(tex.width == 4 && tex.height == 4 && tex.mipmapLevelCount == 2 && tex.arrayLength == 1 && tex.parentRelativeSlice == 1 && tex.parentRelativeLevel == 1);
    IRDescriptorTableEntry expected; IRDescriptorTableSetTexture(&expected, tex, 0.75f, 0); equal(packet(cpu, 2), expected);
    auto *rtvs = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_RENDER_TARGET_VIEW_DESC rtv{}; rtv.Format = DXGI_FORMAT_R8G8B8A8_UNORM; rtv.ViewDimension = D3D12_RTV_DIMENSION_TEXTURE2DARRAY; rtv.Texture2DArray = {1,1,1,0};
    device->CreateRenderTargetView(image, &rtv, handle(rtvs, 1));
    device->CopyDescriptorsSimple(1, handle(rtvs, 3), handle(rtvs, 1), D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    CHECK(view(rtvs, 1).resource == view(rtvs, 3).resource);
    id<MTLTexture> attachment = (__bridge id<MTLTexture>)view(rtvs, 3).resource;
    auto commands = [queue commandBuffer]; auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = attachment; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = MTLClearColorMake(0.2,0.4,0.8,0.5);
    [[commands renderCommandEncoderWithDescriptor:pass] endEncoding]; finish(commands);
    D3D12_SAMPLER_DESC sampler{}; sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP; sampler.MaxLOD = 100; sampler.MipLODBias = 0.25f;
    device->CreateSampler(&sampler, handle(sampler_cpu, 0));
    device->CopyDescriptorsSimple(1, handle(samplers, 0), handle(sampler_cpu, 0), D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
    CHECK(packet(samplers, 0).gpuVA && packet(samplers, 0).textureViewID == 0 && packet(samplers, 0).metadata == 0x3e800000);
    device->CopyDescriptorsSimple(1, handle(gpu, 7), handle(cpu, 2), D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    auto *ng = backing(gpu), *ns = backing(samplers);
    id<MTLBuffer> table = (__bridge id<MTLBuffer>)ng->MetalDescriptorBuffer(), stable = (__bridge id<MTLBuffer>)ns->MetalDescriptorBuffer();
    auto program = pipeline(metal, @R"(
#include <metal_stdlib>
using namespace metal;
struct Image { ulong unused [[id(0)]]; texture2d_array<float> texture [[id(1)]]; ulong md [[id(2)]]; };
struct Sampler { sampler state [[id(0)]]; ulong unused [[id(1)]]; ulong md [[id(2)]]; };
kernel void test(device const Image *images [[buffer(0)]], device const Sampler *samplers [[buffer(1)]], device float4 *out [[buffer(2)]]) {
    uint index = uint(out[0].x);
    out[0] = images[index].texture.sample(samplers[0].state, float2(0.5), 0, level(0));
    out[1] = float4(as_type<float>(uint(images[index].md)), as_type<float>(uint(samplers[0].md)), 0, 0);
})");
    auto output = [metal newBufferWithLength:32 options:MTLResourceStorageModeShared];
    ((float *)output.contents)[0] = 7;
    commands = [queue commandBuffer]; auto encoder = [commands computeCommandEncoder];
    [encoder setComputePipelineState:program]; [encoder setBuffer:table offset:0 atIndex:0]; [encoder setBuffer:stable offset:0 atIndex:1]; [encoder setBuffer:output offset:0 atIndex:2];
    [encoder useResource:tex usage:MTLResourceUsageRead];
    [encoder dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [encoder endEncoding]; finish(commands);
    const float *out = (float *)output.contents;
    CHECK(fabs(out[0] - 0.8f) < 0.005 && fabs(out[1] - 0.4f) < 0.005 && fabs(out[2] - 0.2f) < 0.005 && out[3] == 1);
    CHECK(out[4] == 0.75f && out[5] == 0.25f);
    desc.Format = DXGI_FORMAT_R24G8_TYPELESS; desc.DepthOrArraySize = 2; desc.MipLevels = 1; desc.SampleDesc.Count = 4; desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
    auto *depth = resource(device, desc); auto *dsvs = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_DSV);
    D3D12_DEPTH_STENCIL_VIEW_DESC dsv{}; dsv.Format = DXGI_FORMAT_D24_UNORM_S8_UINT; dsv.ViewDimension = D3D12_DSV_DIMENSION_TEXTURE2DMSARRAY;
    dsv.Texture2DMSArray = {1,1}; dsv.Flags = D3D12_DSV_FLAG_READ_ONLY_STENCIL;
    device->CreateDepthStencilView(depth, &dsv, handle(dsvs, 1));
    device->CopyDescriptorsSimple(1, handle(dsvs, 3), handle(dsvs, 1), D3D12_DESCRIPTOR_HEAP_TYPE_DSV);
    auto dv = view(dsvs, 3); id<MTLTexture> dt = (__bridge id<MTLTexture>)dv.resource;
    CHECK(dt.sampleCount == 4 && dt.parentRelativeSlice == 1 && dt.arrayLength == 1 && dv.depthFlags == D3D12_DSV_FLAG_READ_ONLY_STENCIL);
    commands = [queue commandBuffer]; pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture = dt; pass.depthAttachment.loadAction = MTLLoadActionClear; pass.depthAttachment.storeAction = MTLStoreActionStore; pass.depthAttachment.clearDepth = 0.625;
    [[commands renderCommandEncoderWithDescriptor:pass] endEncoding]; finish(commands);
    ng->Release(); ns->Release();
    CHECK(image->Release() == 0 && depth->Release() == 0);
    cpu->Release(); gpu->Release(); samplers->Release(); sampler_cpu->Release(); rtvs->Release(); dsvs->Release();
}
static void sampler_filters(ID3D12Device *device, id<MTLDevice> metal, id<MTLCommandQueue> queue) {
    auto *images = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 8, true);
    auto *samplers = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, 16, true);
    D3D12_RESOURCE_DESC desc = {D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,2,2,1,1,DXGI_FORMAT_R32G32B32A32_FLOAT,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_NONE};
    auto *image = resource(device, desc);
    device->CreateShaderResourceView(image, nullptr, handle(images,0));
    id<MTLTexture> tex = (__bridge id<MTLTexture>)view(images,0).resource;
    auto upload = [metal newBufferWithLength:512 options:MTLResourceStorageModeShared];
    float *p = (float *)upload.contents; p[0]=0.1f; p[4]=0.3f; p[64]=0.6f; p[68]=0.9f; p[3]=p[7]=p[67]=p[71]=1;
    auto commands = [queue commandBuffer]; auto blit = [commands blitCommandEncoder];
    [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:512 sourceSize:MTLSizeMake(2,2,1) toTexture:tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding]; finish(commands);
    D3D12_SAMPLER_DESC sampler{}; sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP; sampler.MaxLOD = 100;
    device->CreateSampler(&sampler, handle(samplers,0));
    device->CreateSampler(&sampler, handle(samplers,2)); device->CreateSampler(&sampler, handle(samplers,3));
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT; device->CreateSampler(&sampler, handle(samplers,1));
    bool reduction = false;
    if (@available(macOS 26.0, *)) reduction = [metal supportsFamily:MTLGPUFamilyApple10];
    if (reduction) {
        sampler.Filter = D3D12_FILTER_MINIMUM_MIN_MAG_MIP_LINEAR; device->CreateSampler(&sampler, handle(samplers,2));
        sampler.Filter = D3D12_FILTER_MAXIMUM_MIN_MAG_MIP_LINEAR; device->CreateSampler(&sampler, handle(samplers,3));
    }
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT; sampler.AddressU = D3D12_TEXTURE_ADDRESS_MODE_BORDER;
    const float borders[][4] = {{0,0,0,0},{0,0,0,1},{1,1,1,1}};
    for (UINT i = 0; i < 3; ++i) { memcpy(sampler.BorderColor,borders[i],16); device->CreateSampler(&sampler,handle(samplers,4+i)); }
    sampler.AddressU = D3D12_TEXTURE_ADDRESS_MODE_WRAP; device->CreateSampler(&sampler, handle(samplers,7));
    sampler.AddressU = D3D12_TEXTURE_ADDRESS_MODE_MIRROR; device->CreateSampler(&sampler, handle(samplers,8));
    sampler.AddressU = D3D12_TEXTURE_ADDRESS_MODE_MIRROR_ONCE; device->CreateSampler(&sampler, handle(samplers,9));
    sampler.Filter = D3D12_FILTER_ANISOTROPIC; sampler.MaxAnisotropy = 8; device->CreateSampler(&sampler, handle(samplers,10));
    desc.Format = DXGI_FORMAT_D32_FLOAT; desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
    auto *depth = resource(device,desc); auto *dsvs = heap(device,D3D12_DESCRIPTOR_HEAP_TYPE_DSV);
    device->CreateDepthStencilView(depth,nullptr,handle(dsvs,0));
    D3D12_SHADER_RESOURCE_VIEW_DESC srv{}; srv.Format = DXGI_FORMAT_R32_FLOAT; srv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
    srv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; srv.Texture2D.MipLevels = 1;
    device->CreateShaderResourceView(depth,&srv,handle(images,1));
    id<MTLTexture> depth_view = (__bridge id<MTLTexture>)view(images,1).resource;
    auto pass = [MTLRenderPassDescriptor renderPassDescriptor]; pass.depthAttachment.texture = (__bridge id<MTLTexture>)view(dsvs,0).resource;
    pass.depthAttachment.loadAction = MTLLoadActionClear; pass.depthAttachment.storeAction = MTLStoreActionStore; pass.depthAttachment.clearDepth = 0.625;
    commands = [queue commandBuffer]; [[commands renderCommandEncoderWithDescriptor:pass] endEncoding]; finish(commands);
    sampler.Filter = D3D12_FILTER_COMPARISON_MIN_MAG_MIP_POINT; sampler.AddressU = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.ComparisonFunc = D3D12_COMPARISON_FUNC_GREATER_EQUAL; device->CreateSampler(&sampler,handle(samplers,11));
    sampler.ComparisonFunc = D3D12_COMPARISON_FUNC_LESS; device->CreateSampler(&sampler,handle(samplers,12));
    auto program = pipeline(metal,@R"(
#include <metal_stdlib>
using namespace metal;
struct Image { ulong unused [[id(0)]]; texture2d_array<float> image [[id(1)]]; ulong md [[id(2)]]; };
struct Depth { ulong unused [[id(0)]]; depth2d_array<float> image [[id(1)]]; ulong md [[id(2)]]; };
struct Sampler { sampler value [[id(0)]]; ulong unused [[id(1)]], md [[id(2)]]; };
kernel void test(device const Image *images [[buffer(0)]], device const Sampler *s [[buffer(1)]], device float *out [[buffer(2)]]) {
    for (uint i=0;i<4;++i) out[i]=images[0].image.sample(s[i].value,float2(0.5),0,level(0)).x;
    for (uint i=4;i<7;++i) { auto c=images[0].image.sample(s[i].value,float2(-0.25,0.25),0,level(0)); out[i]=c.x; out[i+3]=c.w; }
    out[10]=images[0].image.sample(s[7].value,float2(-0.25,0.25),0,level(0)).x;
    out[11]=images[0].image.sample(s[8].value,float2(-0.25,0.25),0,level(0)).x;
    out[12]=images[0].image.sample(s[9].value,float2(-1.25,0.25),0,level(0)).x;
    out[13]=images[0].image.sample(s[10].value,float2(0.5),0,level(0)).x;
    device const Depth *d=reinterpret_cast<device const Depth *>(images);
    out[14]=d[1].image.sample_compare(s[11].value,float2(0.5),0,0.75);
    out[15]=d[1].image.sample_compare(s[12].value,float2(0.5),0,0.75);
})");
    auto *ni=backing(images), *ns=backing(samplers); auto output=[metal newBufferWithLength:64 options:MTLResourceStorageModeShared];
    commands=[queue commandBuffer]; auto encoder=[commands computeCommandEncoder]; [encoder setComputePipelineState:program];
    [encoder setBuffer:(__bridge id<MTLBuffer>)ni->MetalDescriptorBuffer() offset:0 atIndex:0];
    [encoder setBuffer:(__bridge id<MTLBuffer>)ns->MetalDescriptorBuffer() offset:0 atIndex:1]; [encoder setBuffer:output offset:0 atIndex:2];
    [encoder useResource:tex usage:MTLResourceUsageRead]; [encoder useResource:depth_view usage:MTLResourceUsageRead];
    [encoder dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [encoder endEncoding]; finish(commands);
    const float expected[]={0.475f,0.9f,0.1f,0.9f,0,0,1,0,1,1,0.3f,0.1f,0.3f,0.475f,1,0};
    const float *values=(const float *)output.contents;
    for (unsigned i=0;i<16;++i) {
        if (!reduction && (i==2 || i==3)) continue;
        if (fabs(values[i]-expected[i])>=0.005f) fprintf(stderr,"sampler %u: actual=%f expected=%f\n",i,values[i],expected[i]);
        CHECK(fabs(values[i]-expected[i])<0.005f);
    }
    ni->Release(); ns->Release(); image->Release(); depth->Release(); images->Release(); samplers->Release(); dsvs->Release();
}
static void dimensional_views(ID3D12Device *device, id<MTLDevice> metal, id<MTLCommandQueue> queue) {
    auto *images=heap(device,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,8,true);
    auto *samplers=heap(device,D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER,8,true);
    auto *rtvs=heap(device,D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_RESOURCE_DESC desc{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,4,4,12,1,DXGI_FORMAT_R8G8B8A8_UNORM,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET};
    auto *cube=resource(device,desc);
    D3D12_SHADER_RESOURCE_VIEW_DESC srv{}; srv.Format=desc.Format; srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    srv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURECUBEARRAY; srv.TextureCubeArray={0,1,6,1,0};
    device->CreateShaderResourceView(cube,&srv,handle(images,0));
    id<MTLTexture> cube_view=(__bridge id<MTLTexture>)view(images,0).resource;
    CHECK(cube_view.textureType==MTLTextureTypeCubeArray && cube_view.arrayLength==1 && cube_view.parentRelativeSlice==6);
    D3D12_RENDER_TARGET_VIEW_DESC rtv{}; rtv.Format=desc.Format; rtv.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2DARRAY; rtv.Texture2DArray={0,6,1,0};
    device->CreateRenderTargetView(cube,&rtv,handle(rtvs,0));
    auto pass=[MTLRenderPassDescriptor renderPassDescriptor]; pass.colorAttachments[0].texture=(__bridge id<MTLTexture>)view(rtvs,0).resource;
    pass.colorAttachments[0].loadAction=MTLLoadActionClear; pass.colorAttachments[0].storeAction=MTLStoreActionStore; pass.colorAttachments[0].clearColor=MTLClearColorMake(0.25,0.5,0.75,1);
    auto commands=[queue commandBuffer]; [[commands renderCommandEncoderWithDescriptor:pass] endEncoding]; finish(commands);
    desc={D3D12_RESOURCE_DIMENSION_TEXTURE3D,0,2,2,2,1,DXGI_FORMAT_R32_FLOAT,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS};
    auto *volume=resource(device,desc); device->CreateShaderResourceView(volume,nullptr,handle(images,1));
    D3D12_UNORDERED_ACCESS_VIEW_DESC uav{}; uav.Format=DXGI_FORMAT_R32_FLOAT; uav.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE3D; uav.Texture3D={0,0,UINT32_MAX};
    device->CreateUnorderedAccessView(volume,nullptr,&uav,handle(images,2));
    id<MTLTexture> volume_view=(__bridge id<MTLTexture>)view(images,1).resource;
    CHECK(volume_view.textureType==MTLTextureType3D && view(images,2).depthCount==2);
    auto upload=[metal newBufferWithLength:1024 options:MTLResourceStorageModeShared];
    for (unsigned i=0;i<256;++i) ((float *)upload.contents)[i]=0.625f;
    commands=[queue commandBuffer]; auto blit=[commands blitCommandEncoder];
    [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:512 sourceSize:MTLSizeMake(2,2,2) toTexture:volume_view destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding]; finish(commands);
    desc={D3D12_RESOURCE_DIMENSION_TEXTURE1D,0,4,1,2,1,DXGI_FORMAT_B8G8R8X8_UNORM,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET};
    auto *line=resource(device,desc);
    srv={}; srv.Format=desc.Format; srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; srv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE1DARRAY; srv.Texture1DArray={0,1,1,1,0};
    device->CreateShaderResourceView(line,&srv,handle(images,3));
    rtv={}; rtv.Format=desc.Format; rtv.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE1DARRAY; rtv.Texture1DArray={0,1,1};
    device->CreateRenderTargetView(line,&rtv,handle(rtvs,1));
    pass=[MTLRenderPassDescriptor renderPassDescriptor]; pass.colorAttachments[0].texture=(__bridge id<MTLTexture>)view(rtvs,1).resource;
    pass.colorAttachments[0].loadAction=MTLLoadActionClear; pass.colorAttachments[0].storeAction=MTLStoreActionStore; pass.colorAttachments[0].clearColor=MTLClearColorMake(0.4,0.2,0.8,0);
    commands=[queue commandBuffer]; [[commands renderCommandEncoderWithDescriptor:pass] endEncoding]; finish(commands);
    D3D12_SAMPLER_DESC sampler{}; sampler.Filter=D3D12_FILTER_MIN_MAG_MIP_POINT; sampler.AddressU=sampler.AddressV=sampler.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP; sampler.MaxLOD=100;
    device->CreateSampler(&sampler,handle(samplers,0));
    auto program=pipeline(metal,@R"(
#include <metal_stdlib>
using namespace metal;
struct Cube { ulong unused [[id(0)]]; texturecube_array<float> image [[id(1)]]; ulong md [[id(2)]]; };
struct Volume { ulong unused [[id(0)]]; texture3d<float> image [[id(1)]]; ulong md [[id(2)]]; };
struct Line { ulong unused [[id(0)]]; texture2d_array<float> image [[id(1)]]; ulong md [[id(2)]]; };
struct Sampler { sampler value [[id(0)]]; ulong unused [[id(1)]], md [[id(2)]]; };
kernel void test(device const Cube *images [[buffer(0)]], device const Sampler *s [[buffer(1)]], device float *out [[buffer(2)]]) {
    out[0]=images[0].image.sample(s[0].value,float3(1,0,0),0,level(0)).x;
    out[1]=reinterpret_cast<device const Volume *>(images)[1].image.read(uint3(1,1,1)).x;
    auto line=reinterpret_cast<device const Line *>(images)[3].image.sample(s[0].value,float2(0.5),0,level(0));
    out[2]=line.x; out[3]=line.w;
})");
    auto *ni=backing(images), *ns=backing(samplers); auto output=[metal newBufferWithLength:16 options:MTLResourceStorageModeShared];
    commands=[queue commandBuffer]; auto encoder=[commands computeCommandEncoder]; [encoder setComputePipelineState:program];
    [encoder setBuffer:(__bridge id<MTLBuffer>)ni->MetalDescriptorBuffer() offset:0 atIndex:0];
    [encoder setBuffer:(__bridge id<MTLBuffer>)ns->MetalDescriptorBuffer() offset:0 atIndex:1]; [encoder setBuffer:output offset:0 atIndex:2];
    for (UINT i:{0u,1u,3u}) [encoder useResource:(__bridge id<MTLResource>)view(images,i).resource usage:MTLResourceUsageRead];
    [encoder dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [encoder endEncoding]; finish(commands);
    const float *values=(const float *)output.contents; CHECK(fabs(values[0]-0.25f)<0.005 && values[1]==0.625f && fabs(values[2]-0.4f)<0.005 && values[3]==1);
    ni->Release(); ns->Release(); cube->Release(); volume->Release(); line->Release(); images->Release(); samplers->Release(); rtvs->Release();
}
#ifdef D3DM_DESCRIPTOR_CASES
#include D3DM_DESCRIPTOR_CASES
static void captured(ID3D12Device *device) {
    for (const auto &desc : descriptor_heap_cases) {
        ID3D12DescriptorHeap *h = nullptr;
        OK(device->CreateDescriptorHeap(&desc,__uuidof(ID3D12DescriptorHeap),(void **)&h));
        const auto returned=h->GetDesc(); CHECK(!memcmp(&returned,&desc,sizeof desc)); h->Release();
    }
    ID3D12DescriptorHeap *targets[] = {heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV), heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV), heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_DSV)};
    auto *constant = resource(device,buffer_desc(65536),true);
    for (UINT size : descriptor_cbv_sizes) {
        const D3D12_CONSTANT_BUFFER_VIEW_DESC cbv{constant->GetGPUVirtualAddress(),size};
        device->CreateConstantBufferView(&cbv,handle(targets[0],0));
        IRDescriptorTableEntry expected; IRDescriptorTableSetBuffer(&expected,cbv.BufferLocation,size); equal(packet(targets[0],0),expected);
    }
    constant->Release();
    for (const auto &entry : descriptor_cases) {
        D3D12_RESOURCE_DESC desc{}; memcpy(&desc, entry.resource, sizeof desc);
        ID3D12Resource *image = entry.has_resource ? resource(device, desc) : nullptr;
        if (entry.kind == 2) { D3D12_SHADER_RESOURCE_VIEW_DESC d; memcpy(&d, entry.view, sizeof d); device->CreateShaderResourceView(image, &d, handle(targets[0], 0)); }
        if (entry.kind == 3) { D3D12_UNORDERED_ACCESS_VIEW_DESC d; memcpy(&d, entry.view, sizeof d); device->CreateUnorderedAccessView(image, nullptr, &d, handle(targets[0], 0)); }
        if (entry.kind == 4) { D3D12_RENDER_TARGET_VIEW_DESC d; memcpy(&d, entry.view, sizeof d); device->CreateRenderTargetView(image, &d, handle(targets[1], 0)); }
        if (entry.kind == 5) { D3D12_DEPTH_STENCIL_VIEW_DESC d; memcpy(&d, entry.view, sizeof d); device->CreateDepthStencilView(image, &d, handle(targets[2], 0)); }
        if (entry.kind <= 3) CHECK(packet(targets[0], 0).metadata == entry.metadata);
        if (image) CHECK(image->Release() == 0);
    }
    for (auto *target : targets) target->Release();
    printf("descriptor_test: %zu captured view cases passed\n", std::size(descriptor_cases));
}
#endif
int main(int argc, char **argv) {
    @autoreleasepool {
        D3DMHost host{};
        host.check_feature = [](D3D12_FEATURE f, void *data, UINT size) -> HRESULT {
            if (f != D3D12_FEATURE_FEATURE_LEVELS || size != sizeof(D3D12_FEATURE_DATA_FEATURE_LEVELS)) return E_INVALIDARG;
            ((D3D12_FEATURE_DATA_FEATURE_LEVELS *)data)->MaxSupportedFeatureLevel = D3D_FEATURE_LEVEL_12_2; return S_OK;
        };
        D3DMSetHost(&host); ID3D12Device *device = nullptr;
        OK(D3DMCreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, __uuidof(ID3D12Device), (void **)&device));
        if (argc > 1) {
            auto *h = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 2);
            if (!strcmp(argv[1], "misaligned")) device->CreateConstantBufferView(nullptr, {handle(h, 0).ptr + 1});
            if (!strcmp(argv[1], "overflow")) device->CopyDescriptorsSimple(3, handle(h, 0), handle(h, 0), D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            if (!strcmp(argv[1], "stale")) { auto old = handle(h, 0); h->Release(); device->CreateConstantBufferView(nullptr, old); }
            if (!strcmp(argv[1], "gpu-source")) { auto *g = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 2, true); device->CopyDescriptorsSimple(1, handle(h,0), handle(g,0), D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV); }
            if (!strcmp(argv[1], "dead-cbv")) {
                auto *data = resource(device,buffer_desc(256),true);
                D3D12_CONSTANT_BUFFER_VIEW_DESC cbv{data->GetGPUVirtualAddress(),256};
                device->CreateConstantBufferView(&cbv,handle(h,0)); data->Release();
                device->CreateConstantBufferView(&cbv,handle(h,1));
            }
            if (!strcmp(argv[1], "minmax")) {
                id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
                if (@available(macOS 26.0, *)) { if ([metal supportsFamily:MTLGPUFamilyApple10]) return 77; }
                auto *s = heap(device,D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
                D3D12_SAMPLER_DESC desc{}; desc.Filter=D3D12_FILTER_MINIMUM_MIN_MAG_MIP_LINEAR;
                desc.AddressU=desc.AddressV=desc.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP; desc.MaxLOD=100;
                device->CreateSampler(&desc,handle(s,0));
            }
            return 99;
        }
        id<MTLDevice> metal = MTLCreateSystemDefaultDevice(); auto queue = [metal newCommandQueue];
        released_texture_storage(device); heap_contract(device); buffers(device, metal, queue); textures(device, metal, queue); sampler_filters(device, metal, queue); dimensional_views(device, metal, queue);
#ifdef D3DM_DESCRIPTOR_CASES
        captured(device);
#endif
        std::vector<std::thread> workers;
        for (unsigned i = 0; i < 8; ++i) workers.emplace_back([&] { @autoreleasepool {
            auto *h = heap(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            for (unsigned j = 0; j < 100; ++j) device->CreateConstantBufferView(nullptr, handle(h, j % 32));
            CHECK(h->Release() == 0);
        } });
        for (auto &worker : workers) worker.join();
        CHECK(device->Release() == 0);
        printf("descriptor_test: %u checks passed\n", checks.load());
    }
}
