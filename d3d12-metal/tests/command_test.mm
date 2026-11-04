#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>
#include "../src/descriptors.h"
#include "root_signature_fixture.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <future>
#include <memory>
#include <thread>

static unsigned checks;
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"command_test:%d: %s\n",__LINE__,#x);std::exit(1); } ++checks; } while (0)
#define OK(x) CHECK((x)==S_OK)
static id<MTLLibrary> shaders;
static const char source[]=R"(
#include <metal_stdlib>
using namespace metal;
struct Vertex { float2 position [[attribute(11)]];float4 color [[attribute(12)]]; };
struct Varying { float4 position [[position]];float4 color; };
vertex Varying vs(Vertex v [[stage_in]]) { return {float4(v.position,0,1),v.color}; }
fragment float4 ps(Varying v [[stage_in]]) { return v.color; }
fragment float4 guard_ps() { return float4(0,0,1,1); }
fragment float4 specialized_ps() { return float4(1,0,0,1); }
struct Descriptor { device uint *value;ulong texture;ulong metadata; };
struct Image { ulong unused [[id(0)]];texture2d_array<float> image [[id(1)]];ulong metadata [[id(2)]]; };
fragment float4 textured_ps(Varying v [[stage_in]],device const Image *images [[buffer(0)]]) { auto color=v.color;color.r+=images[0].image.read(uint2(1,0),0).r;return color; }
fragment float4 state_ps(constant float4 &color [[buffer(2)]],device const Image *images [[buffer(0)]]) { return float4(images[0].image.read(uint2(1,0),0).r,color.gba); }
struct Fullscreen { float4 position [[position]];float2 uv; };
vertex Fullscreen fullscreen_vs(uint id [[vertex_id]]) {
    const float2 positions[]={float2(-1,1),float2(3,1),float2(-1,-3)};
    float2 p=positions[id];return {float4(p,0,1),float2((p.x+1)*.5,(1-p.y)*.5)};
}
fragment float4 copy_ps(Fullscreen v [[stage_in]],device const Image *images [[buffer(0)]]) {
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    return images[0].image.sample(linear,v.uv,0);
}
struct Root { uint values[3];uint pad;device uint *input;ulong unused;device uint *output;device Descriptor *table;uint tail; };
kernel void cs(constant Root &r [[buffer(2)]],uint i [[thread_position_in_grid]]) { r.output[i]=r.input[i]+r.table[0].value[i]+r.values[0]+r.tail; }
kernel void direct_cs(constant Root &r [[buffer(2)]],device Descriptor *heap [[buffer(0)]],uint i [[thread_position_in_grid]]) { auto images=reinterpret_cast<device const Image *>(heap);r.output[i]=r.input[i]+heap[3].value[i]+r.values[0]+r.tail+uint(round(images[2].image.read(uint2(i,0),0).r*255)); }
)";
static ID3D12Resource *resource(ID3D12Device *device,D3D12_HEAP_TYPE type,D3D12_RESOURCE_DESC desc) {
    D3D12_HEAP_PROPERTIES props{type,D3D12_CPU_PAGE_PROPERTY_UNKNOWN,D3D12_MEMORY_POOL_UNKNOWN,1,1};
    auto state=D3D12_RESOURCE_STATE_COMMON;
    if (type==D3D12_HEAP_TYPE_UPLOAD) state=D3D12_RESOURCE_STATE_GENERIC_READ;
    if (type==D3D12_HEAP_TYPE_READBACK) state=D3D12_RESOURCE_STATE_COPY_DEST;
    ID3D12Resource *out=nullptr;OK(device->CreateCommittedResource(&props,D3D12_HEAP_FLAG_NONE,&desc,state,nullptr,__uuidof(ID3D12Resource),(void **)&out));return out;
}
static ID3D12Resource *buffer(ID3D12Device *device,D3D12_HEAP_TYPE type,UINT64 size,D3D12_RESOURCE_FLAGS flags=D3D12_RESOURCE_FLAG_NONE) {
    return resource(device,type,{D3D12_RESOURCE_DIMENSION_BUFFER,0,size,1,1,1,DXGI_FORMAT_UNKNOWN,{1,0},D3D12_TEXTURE_LAYOUT_ROW_MAJOR,flags});
}
static void *map(ID3D12Resource *resource) { void *out=nullptr;OK(resource->Map(0,nullptr,&out));return out; }
struct Commands {
    ID3D12CommandQueue *queue=nullptr;ID3D12CommandAllocator *allocator=nullptr;ID3D12GraphicsCommandList *list=nullptr;ID3D12Fence *fence=nullptr;UINT64 value=0;
    Commands(ID3D12Device *device,D3D12_COMMAND_LIST_TYPE type=D3D12_COMMAND_LIST_TYPE_DIRECT) {
        D3D12_COMMAND_QUEUE_DESC desc{type,0,D3D12_COMMAND_QUEUE_FLAG_NONE,0};
        OK(device->CreateCommandQueue(&desc,__uuidof(ID3D12CommandQueue),(void **)&queue));
        OK(device->CreateCommandAllocator(type,__uuidof(ID3D12CommandAllocator),(void **)&allocator));
        OK(device->CreateCommandList(0,type,allocator,nullptr,__uuidof(ID3D12GraphicsCommandList),(void **)&list));
        OK(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,__uuidof(ID3D12Fence),(void **)&fence));
    }
    void submit() { OK(list->Close());ID3D12CommandList *base=list;queue->ExecuteCommandLists(1,&base);OK(queue->Signal(fence,++value)); }
    void wait() { OK(fence->SetEventOnCompletion(value,nullptr));CHECK(fence->GetCompletedValue()==value); }
    void reset() { OK(allocator->Reset());OK(list->Reset(allocator,nullptr)); }
    ~Commands() { list->Release();allocator->Release();queue->Release();fence->Release(); }
};
static unsigned residency_declarations,compute_root_sets;
static IMP residency_original,compute_root_original;
static void count_compute_root(id object,SEL selector,const void *bytes,NSUInteger length,NSUInteger index) {
    if (index==2) ++compute_root_sets;((void (*)(id,SEL,const void *,NSUInteger,NSUInteger))compute_root_original)(object,selector,bytes,length,index);
}
static void count_residency(id object,SEL selector,id<MTLResource> const *resources,NSUInteger count,MTLResourceUsage usage) {
    ++residency_declarations;
    ((void (*)(id,SEL,id<MTLResource> const *,NSUInteger,MTLResourceUsage))residency_original)(object,selector,resources,count,usage);
}
struct ComputeUseCounter {
    Method method,root_method;
    explicit ComputeUseCounter(ID3D12CommandQueue *queue) {
        ID3DMMetalQueue *native=nullptr;OK(queue->QueryInterface(__uuidof(ID3DMMetalQueue),(void **)&native));
        auto commands=[(__bridge id<MTLCommandQueue>)native->MetalCommandQueue() commandBuffer];native->Release();
        auto encoder=[commands computeCommandEncoder];method=class_getInstanceMethod([encoder class],@selector(useResources:count:usage:));CHECK(method);[encoder endEncoding];
        root_method=class_getInstanceMethod([encoder class],@selector(setBytes:length:atIndex:));CHECK(root_method);
        residency_declarations=compute_root_sets=0;residency_original=method_setImplementation(method,(IMP)count_residency);
        compute_root_original=method_setImplementation(root_method,(IMP)count_compute_root);
    }
    ~ComputeUseCounter() { method_setImplementation(method,residency_original);method_setImplementation(root_method,compute_root_original); }
};
static void descriptor_membership(ID3D12Device *device,bool benchmark=false) {
    Commands c(device,D3D12_COMMAND_LIST_TYPE_COMPUTE);
    ComputeUseCounter count(c.queue);
    ID3D12DescriptorHeap *heap=nullptr;
    D3D12_DESCRIPTOR_HEAP_DESC desc{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,4096,D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,0};
    OK(device->CreateDescriptorHeap(&desc,__uuidof(ID3D12DescriptorHeap),(void **)&heap));
    auto *first=buffer(device,D3D12_HEAP_TYPE_DEFAULT,1024,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    auto *second=buffer(device,D3D12_HEAP_TYPE_DEFAULT,1024,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    D3D12_SHADER_RESOURCE_VIEW_DESC srv{};srv.ViewDimension=D3D12_SRV_DIMENSION_BUFFER;
    srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;srv.Buffer.NumElements=64;srv.Buffer.StructureByteStride=4;
    auto handle=heap->GetCPUDescriptorHandleForHeapStart();const UINT stride=device->GetDescriptorHandleIncrementSize(desc.Type);
    for (UINT i=0;i<desc.NumDescriptors;++i) device->CreateShaderResourceView(first,&srv,{handle.ptr+i*stride});
    ID3DMMetalQueue *native=nullptr;OK(c.queue->QueryInterface(__uuidof(ID3DMMetalQueue),(void **)&native));
    auto commands=[(__bridge id<MTLCommandQueue>)native->MetalCommandQueue() commandBuffer];native->Release();
    auto encoder=[commands computeCommandEncoder];
    d3dm::use_descriptor_heap(heap,nil,encoder,nil);CHECK(residency_declarations==1);
    std::vector<double> times;
    for (UINT trial=0;trial<(benchmark?9u:1u);++trial) {
        const auto begin=std::chrono::steady_clock::now();
        for (UINT i=0;i<1024;++i) {
            srv.Buffer.FirstElement=i%2;srv.Buffer.NumElements=64-i%2;
            device->CreateShaderResourceView(first,&srv,handle);d3dm::use_descriptor_heap(heap,nil,encoder,nil);
        }
        times.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count());
    }
    if (!benchmark) CHECK(residency_declarations==1);
    const UINT before=residency_declarations;
    device->CreateShaderResourceView(second,&srv,handle);d3dm::use_descriptor_heap(heap,nil,encoder,nil);CHECK(residency_declarations==before+1);
    D3D12_UNORDERED_ACCESS_VIEW_DESC uav{};uav.ViewDimension=D3D12_UAV_DIMENSION_BUFFER;uav.Buffer.NumElements=64;uav.Buffer.StructureByteStride=4;
    device->CreateUnorderedAccessView(second,nullptr,&uav,handle);d3dm::use_descriptor_heap(heap,nil,encoder,nil);CHECK(residency_declarations==before+3);
    auto *counter=buffer(device,D3D12_HEAP_TYPE_DEFAULT,4096,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    device->CreateUnorderedAccessView(second,counter,&uav,handle);d3dm::use_descriptor_heap(heap,nil,encoder,nil);CHECK(residency_declarations==before+5);
    [encoder endEncoding];
    if (benchmark) { std::sort(times.begin(),times.end());printf("Descriptor updates CPU ms (1024 writes, 4096 slots, 9 trials): median=%.3f min=%.3f max=%.3f\n",times[4],times.front(),times.back()); }
    counter->Release();first->Release();second->Release();heap->Release();
}
static ID3D12RootSignature *root(ID3D12Device *device,const void *data,SIZE_T size) {
    ID3D12RootSignature *out=nullptr;OK(device->CreateRootSignature(0,data,size,__uuidof(ID3D12RootSignature),(void **)&out));return out;
}
static ID3D12CommandSignature *signature(ID3D12Device *device,D3D12_INDIRECT_ARGUMENT_TYPE type,UINT size) {
    D3D12_INDIRECT_ARGUMENT_DESC arg{};arg.Type=type;D3D12_COMMAND_SIGNATURE_DESC desc{size,1,&arg,0};
    ID3D12CommandSignature *out=nullptr;OK(device->CreateCommandSignature(&desc,nullptr,__uuidof(ID3D12CommandSignature),(void **)&out));return out;
}
struct HeapImage {
    ID3D12Heap *heap=nullptr;
    ID3D12Resource *texture=nullptr,*pixels=nullptr;
    HeapImage(ID3D12Device *device,ID3D12GraphicsCommandList *list,D3D12_CPU_DESCRIPTOR_HANDLE handle) {
        D3D12_HEAP_DESC h{65536,{D3D12_HEAP_TYPE_DEFAULT,D3D12_CPU_PAGE_PROPERTY_UNKNOWN,D3D12_MEMORY_POOL_UNKNOWN,1,1},65536,D3D12_HEAP_FLAG_ALLOW_ONLY_NON_RT_DS_TEXTURES};
        OK(device->CreateHeap(&h,__uuidof(ID3D12Heap),(void **)&heap));
        D3D12_RESOURCE_DESC d{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,8,1,2,1,DXGI_FORMAT_R8_UNORM,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_NONE};
        OK(device->CreatePlacedResource(heap,0,&d,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,__uuidof(ID3D12Resource),(void **)&texture));
        pixels=buffer(device,D3D12_HEAP_TYPE_UPLOAD,1024);auto *bytes=(unsigned char *)map(pixels);memset(bytes,0xee,1024);for (UINT i=0;i<8;++i) bytes[512+i]=i;
        for (UINT slice=0;slice<2;++slice) {
            D3D12_TEXTURE_COPY_LOCATION a{},b{};a.pResource=pixels;a.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;a.PlacedFootprint={slice*512ull,{DXGI_FORMAT_R8_UNORM,8,1,1,256}};
            b.pResource=texture;b.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;b.SubresourceIndex=slice;list->CopyTextureRegion(&b,0,0,0,&a,nullptr);
        }
        D3D12_RESOURCE_BARRIER ready{};ready.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;ready.Transition={texture,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_ALL_SHADER_RESOURCE};list->ResourceBarrier(1,&ready);
        D3D12_SHADER_RESOURCE_VIEW_DESC view{};view.Format=d.Format;view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2DARRAY;view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;view.Texture2DArray={0,1,1,1,0,0};
        device->CreateShaderResourceView(texture,&view,handle);
    }
    ~HeapImage() { pixels->Release();texture->Release();heap->Release(); }
};
static void compressed_mips(ID3D12Device *device) {
    Commands c(device,D3D12_COMMAND_LIST_TYPE_COPY);
    D3D12_RESOURCE_DESC desc{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,4,4,1,3,DXGI_FORMAT_BC1_UNORM,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_NONE};
    auto *texture=resource(device,D3D12_HEAP_TYPE_DEFAULT,desc);
    auto *upload=buffer(device,D3D12_HEAP_TYPE_UPLOAD,1536),*readback=buffer(device,D3D12_HEAP_TYPE_READBACK,1536);
    auto *input=(unsigned char *)map(upload),*output=(unsigned char *)map(readback);memset(input,0xa7,1536);memset(output,0,1536);
    for (UINT i=0;i<3;++i) {
        for (UINT j=0;j<8;++j) input[i*512+j]=(unsigned char)(i*17+j);
        D3D12_TEXTURE_COPY_LOCATION src{},dst{};src.pResource=upload;src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        src.PlacedFootprint={i*512ull,{DXGI_FORMAT_BC1_UNORM,4,4,1,256}};dst.pResource=texture;dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;dst.SubresourceIndex=i;
        c.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);src.pResource=readback;c.list->CopyTextureRegion(&src,0,0,0,&dst,nullptr);
    }
    c.submit();c.wait();for (UINT i=0;i<3;++i) CHECK(!memcmp(input+i*512,output+i*512,8));
    texture->Release();upload->Release();readback->Release();
}
static void compute(ID3D12Device *device,bool direct=false,bool bounded=false) {
    Commands c(device,D3D12_COMMAND_LIST_TYPE_COMPUTE),copy(device,D3D12_COMMAND_LIST_TYPE_COPY);
    std::unique_ptr<ComputeUseCounter> uses;if (direct) uses=std::make_unique<ComputeUseCounter>(c.queue);
    std::vector<UINT> serialized(std::begin(root_mixed),std::end(root_mixed));
    if (direct && !bounded) serialized[16]=D3D12_ROOT_SIGNATURE_FLAG_CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED;
    auto *r=root(device,serialized.data(),serialized.size()*4);const unsigned char code=direct?4:3;
    D3D12_COMPUTE_PIPELINE_STATE_DESC desc{};desc.pRootSignature=r;desc.CS={&code,1};ID3D12PipelineState *pso=nullptr;
    OK(device->CreateComputePipelineState(&desc,__uuidof(ID3D12PipelineState),(void **)&pso));
    auto *input=buffer(device,D3D12_HEAP_TYPE_UPLOAD,256),*output=buffer(device,D3D12_HEAP_TYPE_DEFAULT,256,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS),*second=buffer(device,D3D12_HEAP_TYPE_DEFAULT,256,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS),*readback=buffer(device,D3D12_HEAP_TYPE_READBACK,256);
    auto *values=(UINT *)map(input);for (UINT i=0;i<8;++i) values[i]=i*11;
    ID3D12DescriptorHeap *heap=nullptr;D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,5,D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&heap));
    D3D12_SHADER_RESOURCE_VIEW_DESC srv{};srv.ViewDimension=D3D12_SRV_DIMENSION_BUFFER;srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;srv.Buffer.NumElements=64;srv.Buffer.StructureByteStride=4;
    auto handle=heap->GetCPUDescriptorHandleForHeapStart();if (direct) handle.ptr+=3*device->GetDescriptorHandleIncrementSize(hd.Type);
    device->CreateShaderResourceView(input,&srv,handle);
    std::unique_ptr<HeapImage> image;
    if (direct) { auto view=heap->GetCPUDescriptorHandleForHeapStart();view.ptr+=2*device->GetDescriptorHandleIncrementSize(hd.Type);image=std::make_unique<HeapImage>(device,c.list,view); }
    c.list->SetDescriptorHeaps(1,&heap);
    c.list->SetComputeRootSignature(r);c.list->SetPipelineState(pso);UINT constants[]={7,0,0};
    c.list->SetComputeRootDescriptorTable(4,heap->GetGPUDescriptorHandleForHeapStart());
    c.list->SetComputeRoot32BitConstants(0,3,constants,0);constants[0]=999;
    c.list->SetComputeRoot32BitConstant(5,13,0);c.list->SetComputeRootConstantBufferView(1,input->GetGPUVirtualAddress());c.list->SetComputeRootUnorderedAccessView(3,output->GetGPUVirtualAddress());
    c.list->Dispatch(2,1,1);
    D3D12_RESOURCE_BARRIER barrier{};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_UAV;barrier.UAV.pResource=output;c.list->ResourceBarrier(1,&barrier);
    c.list->Dispatch(2,1,1);c.list->ResourceBarrier(1,&barrier);
    c.list->SetComputeRootConstantBufferView(1,output->GetGPUVirtualAddress());c.list->SetComputeRootUnorderedAccessView(3,second->GetGPUVirtualAddress());
    auto *args=buffer(device,D3D12_HEAP_TYPE_UPLOAD,256),*counter=buffer(device,D3D12_HEAP_TYPE_DEFAULT,256);const UINT groups[]={2,1,1};memcpy(map(args),groups,sizeof groups);
    ((UINT *)map(args))[16]=1;((UINT *)map(args))[17]=0;c.list->CopyBufferRegion(counter,0,args,64,8);
    auto *sig=signature(device,D3D12_INDIRECT_ARGUMENT_TYPE_DISPATCH,sizeof groups);c.list->ExecuteIndirect(sig,1,args,0,counter,0);
    c.list->SetComputeRootConstantBufferView(1,second->GetGPUVirtualAddress());c.list->ExecuteIndirect(sig,1,args,0,counter,4);
    UINT declarations=3;if (@available(macOS 15.0,*)) declarations=0;
    c.submit();if (direct) { printf("Descriptor residency declarations=%u, root uploads=%u (3 encoders, 4 dispatches)\n",residency_declarations,compute_root_sets);CHECK(residency_declarations==declarations);CHECK(compute_root_sets==3); }
    OK(copy.queue->Wait(c.fence,c.value));copy.list->CopyBufferRegion(readback,0,second,0,32);copy.submit();copy.wait();
    const UINT stride=direct?35:33;const auto *result=(const UINT *)map(readback);for (UINT i=0;i<8;++i) { if (result[i]!=i*stride+40) fprintf(stderr,"compute direct=%d index=%u got=%u expected=%u\n",direct,i,result[i],i*stride+40);CHECK(result[i]==i*stride+40); }
    device->CreateShaderResourceView(output,&srv,handle);
    if (direct) {
        D3D12_SHADER_RESOURCE_VIEW_DESC view{};view.Format=DXGI_FORMAT_R8_UNORM;view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2DARRAY;
        view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;view.Texture2DArray={0,1,0,1,0,0};
        auto destination=heap->GetCPUDescriptorHandleForHeapStart();destination.ptr+=2*device->GetDescriptorHandleIncrementSize(hd.Type);
        device->CreateShaderResourceView(image->texture,&view,destination);
    }
    residency_declarations=0;
    c.reset();copy.reset();c.list->SetDescriptorHeaps(1,&heap);c.list->SetComputeRootSignature(r);c.list->SetPipelineState(pso);
    c.list->SetComputeRootDescriptorTable(4,heap->GetGPUDescriptorHandleForHeapStart());c.list->SetComputeRoot32BitConstant(0,11,0);c.list->SetComputeRoot32BitConstant(5,13,0);
    c.list->SetComputeRootConstantBufferView(1,input->GetGPUVirtualAddress());c.list->SetComputeRootUnorderedAccessView(3,second->GetGPUVirtualAddress());c.list->Dispatch(2,1,1);
    c.submit();if (direct) CHECK(residency_declarations==(declarations?1:0));
    OK(copy.queue->Wait(c.fence,c.value));copy.list->CopyBufferRegion(readback,0,second,0,32);copy.submit();copy.wait();
    for (UINT i=0;i<8;++i) CHECK(result[i]==(direct?i*34+282:i*stride+44));
    args->Release();counter->Release();sig->Release();heap->Release();input->Release();output->Release();second->Release();readback->Release();pso->Release();r->Release();
}
static void depth_planes(ID3D12Device *device) {
    Commands c(device);
    auto *depth=resource(device,D3D12_HEAP_TYPE_DEFAULT,{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,4,3,2,1,DXGI_FORMAT_D32_FLOAT_S8X24_UINT,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL});
    auto *readback=buffer(device,D3D12_HEAP_TYPE_READBACK,8192);
    ID3D12DescriptorHeap *heap=nullptr;D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_DSV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&heap));
    auto handle=heap->GetCPUDescriptorHandleForHeapStart();device->CreateDepthStencilView(depth,nullptr,handle);
    c.list->ClearDepthStencilView(handle,(D3D12_CLEAR_FLAGS)(D3D12_CLEAR_FLAG_DEPTH|D3D12_CLEAR_FLAG_STENCIL),.375f,0xa5,0,nullptr);
    const D3D12_RECT depthRect{0,0,2,2},stencilRect{1,1,4,3};
    c.list->ClearDepthStencilView(handle,D3D12_CLEAR_FLAG_DEPTH,.625f,0,1,&depthRect);
    c.list->ClearDepthStencilView(handle,D3D12_CLEAR_FLAG_STENCIL,0,0x36,1,&stencilRect);
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT layouts[4]{};UINT64 total=0;const auto desc=depth->GetDesc();device->GetCopyableFootprints(&desc,0,4,0,layouts,nullptr,nullptr,&total);CHECK(total<=8192);
    auto *result=(unsigned char *)map(readback);memset(result,0x91,8192);
    for (UINT plane=0;plane<4;++plane) {
        D3D12_TEXTURE_COPY_LOCATION src{},dst{};src.pResource=depth;src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;src.SubresourceIndex=plane;
        dst.pResource=readback;dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=layouts[plane];
        c.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
    }
    c.submit();c.wait();
    for (UINT layer=0;layer<2;++layer) for (UINT y=0;y<3;++y) for (UINT x=0;x<4;++x) {
        float z=0;memcpy(&z,result+layouts[layer].Offset+y*layouts[layer].Footprint.RowPitch+x*4,4);CHECK(z==(x<2 && y<2?.625f:.375f));
        CHECK(result[layouts[layer+2].Offset+y*layouts[layer+2].Footprint.RowPitch+x]==(x>=1 && y>=1?0x36:0xa5));
    }
    depth->Release();readback->Release();heap->Release();
}
static void uav_clears(ID3D12Device *device) {
    ID3D12DescriptorHeap *cpu=nullptr,*gpu=nullptr;
    D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};
    OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&cpu));hd.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&gpu));
    const auto handle=cpu->GetCPUDescriptorHandleForHeapStart();const auto visible=gpu->GetCPUDescriptorHandleForHeapStart();
    const UINT integers[]={1,2,3,4},replacement[]={9,17,31,127};const FLOAT floats[]={.25f,-.5f,1.25f,4},changed[]={1,2,3,4};
    for (UINT floating=0;floating<2;++floating) for (UINT shape=0;shape<3;++shape) {
        Commands c(device);
        const auto dimension=(D3D12_RESOURCE_DIMENSION)(D3D12_RESOURCE_DIMENSION_TEXTURE1D+shape);
        D3D12_RESOURCE_DESC desc{dimension,0,4,shape?3u:1u,2,1,floating?DXGI_FORMAT_R32G32B32A32_FLOAT:DXGI_FORMAT_R8G8B8A8_UNORM,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS};
        auto *target=resource(device,D3D12_HEAP_TYPE_DEFAULT,desc);
        D3D12_UNORDERED_ACCESS_VIEW_DESC view{};view.Format=desc.Format;
        if (shape==0) { view.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE1DARRAY;view.Texture1DArray.ArraySize=2; }
        else if (shape==1) { view.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE2DARRAY;view.Texture2DArray.ArraySize=2; }
        else { view.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE3D;view.Texture3D.WSize=2; }
        device->CreateUnorderedAccessView(target,nullptr,&view,handle);device->CopyDescriptorsSimple(1,visible,handle,hd.Type);
        c.list->SetDescriptorHeaps(1,&gpu);const D3D12_RECT rect{1,0,3,(LONG)desc.Height};
        if (floating) {
            c.list->ClearUnorderedAccessViewFloat(gpu->GetGPUDescriptorHandleForHeapStart(),handle,target,floats,0,nullptr);
            c.list->ClearUnorderedAccessViewFloat(gpu->GetGPUDescriptorHandleForHeapStart(),handle,target,changed,1,&rect);
        } else {
            c.list->ClearUnorderedAccessViewUint(gpu->GetGPUDescriptorHandleForHeapStart(),handle,target,integers,0,nullptr);
            c.list->ClearUnorderedAccessViewUint(gpu->GetGPUDescriptorHandleForHeapStart(),handle,target,replacement,1,&rect);
        }
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT layouts[2]{};UINT64 total=0;const UINT count=shape==2?1:2;
        device->GetCopyableFootprints(&desc,0,count,0,layouts,nullptr,nullptr,&total);auto *readback=buffer(device,D3D12_HEAP_TYPE_READBACK,total);
        for (UINT i=0;i<count;++i) {
            D3D12_TEXTURE_COPY_LOCATION from{},to{};from.pResource=target;from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;from.SubresourceIndex=i;
            to.pResource=readback;to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint=layouts[i];c.list->CopyTextureRegion(&to,0,0,0,&from,nullptr);
        }
        c.submit();c.wait();const auto *pixels=(const unsigned char *)map(readback);
        for (UINT i=0;i<count;++i) for (UINT z=0;z<layouts[i].Footprint.Depth;++z) for (UINT y=0;y<desc.Height;++y) for (UINT x=0;x<4;++x) {
            const auto *pixel=pixels+layouts[i].Offset+(z*desc.Height+y)*layouts[i].Footprint.RowPitch+x*(floating?16:4);
            const bool inside=x>=1 && x<3;
            if (floating) CHECK(!memcmp(pixel,inside?changed:floats,16));
            else for (UINT channel=0;channel<4;++channel) CHECK(pixel[channel]==(inside?replacement[channel]:integers[channel]));
        }
        target->Release();readback->Release();
    }
    for (UINT floating=0;floating<2;++floating) {
        Commands c(device);auto *target=buffer(device,D3D12_HEAP_TYPE_DEFAULT,256,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS),*upload=buffer(device,D3D12_HEAP_TYPE_UPLOAD,256),*readback=buffer(device,D3D12_HEAP_TYPE_READBACK,256);
        memset(map(upload),0x91,256);c.list->CopyBufferRegion(target,0,upload,0,256);
        D3D12_UNORDERED_ACCESS_VIEW_DESC view{};view.ViewDimension=D3D12_UAV_DIMENSION_BUFFER;view.Buffer.FirstElement=3;view.Buffer.NumElements=12;
        view.Format=DXGI_FORMAT_R32_TYPELESS;view.Buffer.Flags=D3D12_BUFFER_UAV_FLAG_RAW;
        if (floating) { view.Format=DXGI_FORMAT_R32_FLOAT;view.Buffer.Flags=D3D12_BUFFER_UAV_FLAG_NONE; }
        device->CreateUnorderedAccessView(target,nullptr,&view,handle);device->CopyDescriptorsSimple(1,visible,handle,hd.Type);c.list->SetDescriptorHeaps(1,&gpu);
        const D3D12_RECT rect{2,0,6,1};const UINT word[]={0x12345678,2,3,4};
        if (floating) c.list->ClearUnorderedAccessViewFloat(gpu->GetGPUDescriptorHandleForHeapStart(),handle,target,floats,1,&rect);
        else c.list->ClearUnorderedAccessViewUint(gpu->GetGPUDescriptorHandleForHeapStart(),handle,target,word,1,&rect);
        c.list->CopyBufferRegion(readback,0,target,0,256);c.submit();c.wait();const auto *pixels=(const unsigned char *)map(readback);
        for (UINT offset=0;offset<256;offset+=4) {
            if (offset>=20 && offset<36) CHECK(!memcmp(pixels+offset,floating?(const void *)floats:(const void *)word,4));
            else for (UINT j=0;j<4;++j) CHECK(pixels[offset+j]==0x91);
        }
        target->Release();upload->Release();readback->Release();
    }
    cpu->Release();gpu->Release();
}
static void integer_clears(ID3D12Device *device) {
    Commands c(device);
    auto *target=resource(device,D3D12_HEAP_TYPE_DEFAULT,{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,4,2,1,1,DXGI_FORMAT_R32G32B32A32_UINT,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET});
    auto *readback=buffer(device,D3D12_HEAP_TYPE_READBACK,512);ID3D12DescriptorHeap *heap=nullptr;
    D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_RTV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&heap));
    auto handle=heap->GetCPUDescriptorHandleForHeapStart();device->CreateRenderTargetView(target,nullptr,handle);
    const FLOAT full[]={1,2,3,4},partial[]={-1,5.75f,INFINITY,NAN};const D3D12_RECT rect{1,0,3,1};
    c.list->ClearRenderTargetView(handle,full,0,nullptr);c.list->ClearRenderTargetView(handle,partial,1,&rect);
    D3D12_TEXTURE_COPY_LOCATION from{},to{};from.pResource=target;from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    to.pResource=readback;to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint={0,{DXGI_FORMAT_R32G32B32A32_UINT,4,2,1,256}};c.list->CopyTextureRegion(&to,0,0,0,&from,nullptr);
    c.submit();c.wait();const auto *pixels=(const UINT *)map(readback);const UINT initial[]={1,2,3,4},changed[]={0,5,UINT_MAX,0};
    for (UINT y=0;y<2;++y) for (UINT x=0;x<4;++x) CHECK(!memcmp(pixels+y*64+x*4,y==0 && x>=1 && x<3?changed:initial,16));
    heap->Release();target->Release();readback->Release();
}
static ID3D12PipelineState *graphics_pipeline(ID3D12Device *device,ID3D12RootSignature *r,UINT samples=1,bool textured=false,bool stateful=false,unsigned char pixel=0) {
    const unsigned char vs=1;unsigned char ps=2;
    if (stateful) ps=6;
    else if (textured) ps=5;
    if (pixel) ps=pixel;
    const D3D12_INPUT_ELEMENT_DESC inputs[]={{"POSITION",0,DXGI_FORMAT_R32G32_FLOAT,2,0,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0},{"COLOR",0,DXGI_FORMAT_R8G8B8A8_UNORM,2,8,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0}};
    D3D12_GRAPHICS_PIPELINE_STATE_DESC desc{};desc.pRootSignature=r;desc.VS={&vs,1};desc.PS={&ps,1};desc.InputLayout={inputs,2};desc.SampleMask=UINT_MAX;
    desc.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;desc.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;desc.RasterizerState.DepthClipEnable=TRUE;
    desc.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;desc.NumRenderTargets=1;desc.RTVFormats[0]=DXGI_FORMAT_R8G8B8A8_UNORM;desc.SampleDesc.Count=samples;
    desc.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_RED|D3D12_COLOR_WRITE_ENABLE_BLUE;
    if (stateful) {
        auto &blend=desc.BlendState.RenderTarget[0];blend.RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
        blend.BlendEnable=TRUE;blend.SrcBlend=D3D12_BLEND_BLEND_FACTOR;blend.DestBlend=D3D12_BLEND_ZERO;blend.BlendOp=D3D12_BLEND_OP_ADD;
        blend.SrcBlendAlpha=D3D12_BLEND_ONE;blend.DestBlendAlpha=D3D12_BLEND_ZERO;blend.BlendOpAlpha=D3D12_BLEND_OP_ADD;
    }
    ID3D12PipelineState *pso=nullptr;OK(device->CreateGraphicsPipelineState(&desc,__uuidof(ID3D12PipelineState),(void **)&pso));return pso;
}
static void recording_lifetime(ID3D12Device *device) {
    ID3D12CommandAllocator *second=nullptr;
    {
        Commands c(device);
        __weak id<MTLTexture> released;
        auto record=[&] { @autoreleasepool {
            auto *target=resource(device,D3D12_HEAP_TYPE_DEFAULT,{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,32,32,1,1,DXGI_FORMAT_R8G8B8A8_UNORM,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET});
            ID3DMMetalTexture *native=nullptr;
            OK(target->QueryInterface(__uuidof(ID3DMMetalTexture),(void **)&native));
            released=(__bridge id<MTLTexture>)native->MetalTexture();native->Release();
            ID3D12DescriptorHeap *rtv=nullptr;
            const D3D12_DESCRIPTOR_HEAP_DESC desc{D3D12_DESCRIPTOR_HEAP_TYPE_RTV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};
            OK(device->CreateDescriptorHeap(&desc,__uuidof(ID3D12DescriptorHeap),(void **)&rtv));
            const auto handle=rtv->GetCPUDescriptorHandleForHeapStart();device->CreateRenderTargetView(target,nullptr,handle);
            const FLOAT black[]={0,0,0,1};c.list->ClearRenderTargetView(handle,black,0,nullptr);
            OK(c.list->Close());target->Release();rtv->Release();
        } };
        record();
        @autoreleasepool { CHECK(released!=nil); }
        OK(c.allocator->Reset());
        @autoreleasepool { CHECK(released==nil); }
        OK(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,__uuidof(ID3D12CommandAllocator),(void **)&second));
        OK(c.list->Reset(second,nullptr));record();
        OK(c.allocator->Reset());
        @autoreleasepool { CHECK(released!=nil); }
        OK(second->Reset());
        @autoreleasepool { CHECK(released==nil); }
    }
    OK(second->Reset());second->Release();
}

static void shader_specialization(ID3D12Device *device) {
    Commands c(device);
    const UINT serialized[]={0x43425844,0,0,0,0,1,108,1,36,0x30535452,64,1,1,24,0,64,
        D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,0,0,36,1,44,2,1,0,0,1};
    auto *r=root(device,serialized,sizeof serialized);auto *pso=graphics_pipeline(device,r,1,false,false,9);
    ID3D12DescriptorHeap *heap=nullptr,*rtv=nullptr,*staging=nullptr;
    D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,3,D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,0};
    OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&heap));
    hd.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_NONE;hd.NumDescriptors=1;OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&staging));
    hd={D3D12_DESCRIPTOR_HEAP_TYPE_RTV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&rtv));
    auto *target=resource(device,D3D12_HEAP_TYPE_DEFAULT,{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,16,1,1,1,DXGI_FORMAT_R8G8B8A8_UNORM,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET});
    auto handle=rtv->GetCPUDescriptorHandleForHeapStart();device->CreateRenderTargetView(target,nullptr,handle);
    auto *upload=buffer(device,D3D12_HEAP_TYPE_UPLOAD,768),*gpu=buffer(device,D3D12_HEAP_TYPE_DEFAULT,256);
    auto *unknown=buffer(device,D3D12_HEAP_TYPE_DEFAULT,256),*writable=buffer(device,D3D12_HEAP_TYPE_DEFAULT,256,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    auto *readback=buffer(device,D3D12_HEAP_TYPE_READBACK,256);auto *data=(UINT *)map(upload);memset(data,0,768);data[1]=1;data[65]=0x01000001;data[129]=2;
    auto cpu=heap->GetCPUDescriptorHandleForHeapStart();auto table=heap->GetGPUDescriptorHandleForHeapStart();
    const UINT stride=device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    D3D12_CONSTANT_BUFFER_VIEW_DESC cbv{gpu->GetGPUVirtualAddress(),256};device->CreateConstantBufferView(&cbv,{cpu.ptr+stride});device->CreateConstantBufferView(&cbv,staging->GetCPUDescriptorHandleForHeapStart());
    cbv.BufferLocation=writable->GetGPUVirtualAddress();device->CreateConstantBufferView(&cbv,{cpu.ptr+2*stride});
    const float vertices[]={-1,-1,0,0,3,-1,0,0,-1,3,0,0};auto *vb=buffer(device,D3D12_HEAP_TYPE_UPLOAD,sizeof vertices);memcpy(map(vb),vertices,sizeof vertices);
    D3D12_VERTEX_BUFFER_VIEW vertex{vb->GetGPUVirtualAddress(),sizeof vertices,16};const D3D12_VIEWPORT viewport{0,0,16,1,0,1};
    auto draw=[&](UINT x,bool second=false) {
        c.list->SetPipelineState(pso);c.list->SetGraphicsRootSignature(r);c.list->SetDescriptorHeaps(1,&heap);
        c.list->SetGraphicsRootDescriptorTable(0,{table.ptr+(second?stride:0)});c.list->OMSetRenderTargets(1,&handle,FALSE,nullptr);
        c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);c.list->IASetVertexBuffers(2,1,&vertex);c.list->RSSetViewports(1,&viewport);
        const D3D12_RECT scissor{(LONG)x,0,(LONG)x+1,1};c.list->RSSetScissorRects(1,&scissor);c.list->DrawInstanced(3,1,0,0);
    };
    auto submit=[&] {
        D3D12_TEXTURE_COPY_LOCATION from{},to{};from.pResource=target;from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        to.pResource=readback;to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint={0,{DXGI_FORMAT_R8G8B8A8_UNORM,16,1,1,256}};
        c.list->CopyTextureRegion(&to,0,0,0,&from,nullptr);c.submit();
    };
    auto pixel=[&](UINT x,bool specialized) { const auto *p=(const unsigned char *)map(readback)+4*x;if (p[0]!=(specialized?255:0) || p[2]!=(specialized?0:255)) fprintf(stderr,"specialization pixel %u mismatch\n",x);CHECK(p[0]==(specialized?255:0) && p[2]==(specialized?0:255)); };
    const FLOAT black[]={0,0,0,1};c.list->ClearRenderTargetView(handle,black,0,nullptr);
    c.list->CopyBufferRegion(unknown,0,upload,512,256);c.list->CopyBufferRegion(gpu,0,upload,0,256);draw(0);
    c.list->CopyBufferRegion(gpu,4,unknown,4,4);draw(1);
    c.list->CopyBufferRegion(gpu,0,upload,0,256);draw(2);
    D3D12_RESOURCE_BARRIER alias{};alias.Type=D3D12_RESOURCE_BARRIER_TYPE_ALIASING;c.list->ResourceBarrier(1,&alias);draw(3);
    c.list->CopyBufferRegion(gpu,0,upload,512,256);draw(4);c.list->CopyBufferRegion(gpu,0,upload,0,256);draw(5);
    c.list->CopyBufferRegion(writable,0,upload,0,256);draw(6,true);submit();c.wait();
    for (UINT i=0;i<7;++i) pixel(i,i==0 || i==2 || i==5);
    c.reset();draw(7);submit();c.wait();pixel(7,false);
    c.reset();device->CopyDescriptorsSimple(1,{cpu.ptr+2*stride},staging->GetCPUDescriptorHandleForHeapStart(),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    c.list->CopyBufferRegion(gpu,0,upload,0,256);draw(8,true);submit();c.wait();pixel(8,true);
    ID3D12Fence *gate=nullptr;OK(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,__uuidof(ID3D12Fence),(void **)&gate));OK(c.queue->Wait(gate,1));
    c.reset();c.list->CopyBufferRegion(gpu,0,upload,0,256);draw(9);submit();data[1]=0;OK(gate->Signal(1));c.wait();pixel(9,false);
    c.reset();data[1]=1;c.list->CopyBufferRegion(gpu,0,upload,0,256);draw(10);submit();c.wait();pixel(10,true);
    c.reset();cbv.BufferLocation=upload->GetGPUVirtualAddress();device->CreateConstantBufferView(&cbv,{cpu.ptr+2*stride});draw(11,true);submit();c.wait();pixel(11,false);
    auto *bigUpload=buffer(device,D3D12_HEAP_TYPE_UPLOAD,131072),*bigGPU=buffer(device,D3D12_HEAP_TYPE_DEFAULT,2u<<20);
    auto *bigData=(UINT *)map(bigUpload);memset(bigData,0,131072);bigData[1]=1;cbv.BufferLocation=bigGPU->GetGPUVirtualAddress();device->CreateConstantBufferView(&cbv,{cpu.ptr+2*stride});
    c.reset();c.list->CopyBufferRegion(bigGPU,0,bigUpload,0,131072);draw(12,true);submit();c.wait();pixel(12,false);
    c.reset();for (UINT i=0;i<17;++i) c.list->CopyBufferRegion(bigGPU,i*65536ull,bigUpload,0,65536);draw(13,true);submit();c.wait();pixel(13,false);
    c.reset();cbv.BufferLocation=gpu->GetGPUVirtualAddress();device->CreateConstantBufferView(&cbv,{cpu.ptr+2*stride});c.list->CopyBufferRegion(gpu,0,upload,256,256);draw(14,true);submit();c.wait();pixel(14,false);
    c.reset();device->CreateConstantBufferView(nullptr,{cpu.ptr+2*stride});draw(15,true);submit();c.wait();pixel(15,false);
    bigUpload->Release();bigGPU->Release();gate->Release();readback->Release();vb->Release();upload->Release();gpu->Release();unknown->Release();writable->Release();target->Release();heap->Release();rtv->Release();staging->Release();pso->Release();r->Release();
}
static void graphics(ID3D12Device *device) {
    Commands c(device);std::vector<UINT> serialized(std::begin(root_empty),std::end(root_empty));serialized[16]|=D3D12_ROOT_SIGNATURE_FLAG_CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED;
    auto *r=root(device,serialized.data(),serialized.size()*4);auto *pso=graphics_pipeline(device,r,1,true);
    ID3D12DescriptorHeap *shader_heap=nullptr;D3D12_DESCRIPTOR_HEAP_DESC shader_desc{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,0};OK(device->CreateDescriptorHeap(&shader_desc,__uuidof(ID3D12DescriptorHeap),(void **)&shader_heap));
    HeapImage image(device,c.list,shader_heap->GetCPUDescriptorHandleForHeapStart());c.list->SetDescriptorHeaps(1,&shader_heap);
    auto *target=resource(device,D3D12_HEAP_TYPE_DEFAULT,{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,64,32,1,1,DXGI_FORMAT_R8G8B8A8_UNORM,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET});
    ID3D12DescriptorHeap *heap=nullptr;D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_RTV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&heap));
    auto handle=heap->GetCPUDescriptorHandleForHeapStart();device->CreateRenderTargetView(target,nullptr,handle);
    struct Vertex { float x,y;unsigned char color[4];UINT padding; };const Vertex vertices[]={{-1,-1,{50,100,200,255},0},{3,-1,{50,100,200,255},0},{-1,3,{50,100,200,255},0}};
    auto *vb=buffer(device,D3D12_HEAP_TYPE_UPLOAD,256),*ib=buffer(device,D3D12_HEAP_TYPE_UPLOAD,256),*args=buffer(device,D3D12_HEAP_TYPE_UPLOAD,256),*counter=buffer(device,D3D12_HEAP_TYPE_DEFAULT,256),*readback=buffer(device,D3D12_HEAP_TYPE_READBACK,512+256*32+40);
    ID3D12QueryHeap *timestamps=nullptr,*occlusion=nullptr;
    D3D12_QUERY_HEAP_DESC qd{D3D12_QUERY_HEAP_TYPE_TIMESTAMP,2,0};OK(device->CreateQueryHeap(&qd,__uuidof(ID3D12QueryHeap),(void **)&timestamps));
    qd.Type=D3D12_QUERY_HEAP_TYPE_OCCLUSION;qd.Count=3;OK(device->CreateQueryHeap(&qd,__uuidof(ID3D12QueryHeap),(void **)&occlusion));
    c.list->EndQuery(timestamps,D3D12_QUERY_TYPE_TIMESTAMP,0);
    memcpy(map(vb),vertices,sizeof vertices);const uint16_t indices[]={0,1,2};memcpy(map(ib),indices,sizeof indices);
    const D3D12_DRAW_INDEXED_ARGUMENTS indirect{3,1,0,0,0};memcpy(map(args),&indirect,sizeof indirect);auto *sig=signature(device,D3D12_INDIRECT_ARGUMENT_TYPE_DRAW_INDEXED,sizeof indirect);
    ((UINT *)map(args))[16]=1;((UINT *)map(args))[17]=0;
    c.list->CopyBufferRegion(counter,0,args,64,8);
    auto *pixels=(unsigned char *)map(readback);memset(pixels,0x91,512+256*32);
    c.list->SetPipelineState(pso);c.list->SetGraphicsRootSignature(r);c.list->OMSetRenderTargets(1,&handle,FALSE,nullptr);FLOAT clear[]={.1f,.2f,.3f,.4f};c.list->ClearRenderTargetView(handle,clear,0,nullptr);clear[1]=1;
    D3D12_VIEWPORT viewport{0,0,64,32,0,1};D3D12_RECT scissor{0,0,64,32};c.list->RSSetViewports(1,&viewport);c.list->RSSetScissorRects(1,&scissor);c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    D3D12_VERTEX_BUFFER_VIEW view{vb->GetGPUVirtualAddress(),sizeof vertices,sizeof(Vertex)};D3D12_INDEX_BUFFER_VIEW index{ib->GetGPUVirtualAddress(),sizeof indices,DXGI_FORMAT_R16_UINT};c.list->IASetVertexBuffers(2,1,&view);c.list->IASetIndexBuffer(&index);
    c.list->BeginQuery(occlusion,D3D12_QUERY_TYPE_OCCLUSION,0);
    c.list->DrawIndexedInstanced(3,1,0,0,0);
    D3D12_RESOURCE_BARRIER alias{};alias.Type=D3D12_RESOURCE_BARRIER_TYPE_ALIASING;c.list->ResourceBarrier(1,&alias);
    c.list->ExecuteIndirect(sig,1,args,0,counter,0);c.list->ExecuteIndirect(sig,1,args,0,counter,4);c.list->EndQuery(occlusion,D3D12_QUERY_TYPE_OCCLUSION,0);
    c.list->BeginQuery(occlusion,D3D12_QUERY_TYPE_BINARY_OCCLUSION,1);
    c.list->DrawIndexedInstanced(3,1,0,0,0);c.list->ResourceBarrier(1,&alias);c.list->DrawIndexedInstanced(3,1,0,0,0);
    c.list->EndQuery(occlusion,D3D12_QUERY_TYPE_BINARY_OCCLUSION,1);
    c.list->BeginQuery(occlusion,D3D12_QUERY_TYPE_BINARY_OCCLUSION,2);c.list->EndQuery(occlusion,D3D12_QUERY_TYPE_BINARY_OCCLUSION,2);
    c.list->EndQuery(timestamps,D3D12_QUERY_TYPE_TIMESTAMP,1);
    c.list->ResolveQueryData(timestamps,D3D12_QUERY_TYPE_TIMESTAMP,0,2,readback,512+256*32);
    c.list->ResolveQueryData(occlusion,D3D12_QUERY_TYPE_OCCLUSION,0,3,readback,512+256*32+16);
    const FLOAT partialColor[]={.5f,.25f,0,1};const D3D12_RECT partialRect{5,7,12,14};c.list->ClearRenderTargetView(handle,partialColor,1,&partialRect);
    D3D12_TEXTURE_COPY_LOCATION src{},dst{};src.pResource=target;src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;dst.pResource=readback;dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint={512,{DXGI_FORMAT_R8G8B8A8_UNORM,64,32,1,256}};
    c.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);c.submit();c.wait();
    for (unsigned i=0;i<512;++i) CHECK(pixels[i]==0x91);
    for (UINT y=0;y<32;++y) for (UINT x=0;x<64;++x) {
        const auto *pixel=pixels+512+y*256+x*4;
        if (x>=5 && x<12 && y>=7 && y<14) CHECK(pixel[0]==128 && pixel[1]==64 && pixel[2]==0 && pixel[3]==255);
        else CHECK(pixel[0]==51 && pixel[1]==51 && pixel[2]==200 && pixel[3]==102);
    }
    const auto *queries=(const UINT64 *)(pixels+512+256*32);
    CHECK(queries[0]>0 && queries[1]>=queries[0] && queries[1]!=UINT64_MAX);CHECK(queries[2]==64*32*2 && queries[3]==1 && queries[4]==0);
    timestamps->Release();occlusion->Release();
    sig->Release();vb->Release();ib->Release();args->Release();counter->Release();readback->Release();heap->Release();shader_heap->Release();target->Release();pso->Release();r->Release();
}
static unsigned render_passes;
static IMP render_original;
static id<MTLRenderCommandEncoder> count_render(id object,SEL selector,MTLRenderPassDescriptor *pass) {
    ++render_passes;
    return ((id<MTLRenderCommandEncoder> (*)(id,SEL,MTLRenderPassDescriptor *))render_original)(object,selector,pass);
}
struct PassCounter {
    Method method;
    explicit PassCounter(ID3D12CommandQueue *queue) {
        ID3DMMetalQueue *native=nullptr;OK(queue->QueryInterface(__uuidof(ID3DMMetalQueue),(void **)&native));
        auto commands=[(__bridge id<MTLCommandQueue>)native->MetalCommandQueue() commandBuffer];native->Release();
        method=class_getInstanceMethod([commands class],@selector(renderCommandEncoderWithDescriptor:));CHECK(method);
        render_passes=0;render_original=method_setImplementation(method,(IMP)count_render);
    }
    ~PassCounter() { method_setImplementation(method,render_original); }
};
static void array_clears(ID3D12Device *device) {
    Commands c(device);auto *r=root(device,root_empty,sizeof root_empty);auto *pso=graphics_pipeline(device,r);
    D3D12_RESOURCE_DESC desc{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,8,4,4,2,DXGI_FORMAT_R8G8B8A8_TYPELESS,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET};
    auto *target=resource(device,D3D12_HEAP_TYPE_DEFAULT,desc);
    ID3D12DescriptorHeap *heap=nullptr;D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_RTV,7,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&heap));
    const auto base=heap->GetCPUDescriptorHandleForHeapStart();const UINT stride=device->GetDescriptorHandleIncrementSize(hd.Type);
    auto handle=[&](UINT index) { return D3D12_CPU_DESCRIPTOR_HANDLE{base.ptr+index*stride}; };
    D3D12_RENDER_TARGET_VIEW_DESC view{};view.Format=DXGI_FORMAT_R8G8B8A8_UNORM;view.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2DARRAY;view.Texture2DArray.ArraySize=4;
    const FLOAT clear[]={.2f,.4f,.6f,1},replacement[]={.8f,.5f,.25f,1},gamma[]={.25f,.5f,.75f,1};
    for (UINT mip=0;mip<2;++mip) { view.Texture2DArray.MipSlice=mip;device->CreateRenderTargetView(target,&view,handle(mip));c.list->ClearRenderTargetView(handle(mip),clear,0,nullptr); }
    view.Texture2DArray.ArraySize=1;
    for (UINT slice=0;slice<4;++slice) { view.Texture2DArray.FirstArraySlice=slice;device->CreateRenderTargetView(target,&view,handle(slice+2)); }
    c.list->ClearRenderTargetView(handle(3),replacement,0,nullptr);
    view.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;view.Texture2DArray.FirstArraySlice=2;device->CreateRenderTargetView(target,&view,handle(6));c.list->ClearRenderTargetView(handle(6),gamma,0,nullptr);
    struct Vertex { float x,y;UINT color,pad; };const Vertex vertices[]={{-1,-1,0xff0000ff,0},{3,-1,0xff0000ff,0},{-1,3,0xff0000ff,0}};
    auto *vb=buffer(device,D3D12_HEAP_TYPE_UPLOAD,sizeof vertices);memcpy(map(vb),vertices,sizeof vertices);
    auto *scratch=buffer(device,D3D12_HEAP_TYPE_DEFAULT,sizeof vertices);c.list->CopyBufferRegion(scratch,0,vb,0,sizeof vertices);
    c.list->SetPipelineState(pso);c.list->SetGraphicsRootSignature(r);c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    const D3D12_VERTEX_BUFFER_VIEW vertex{vb->GetGPUVirtualAddress(),sizeof vertices,sizeof(Vertex)};c.list->IASetVertexBuffers(2,1,&vertex);
    const D3D12_VIEWPORT viewport{0,0,4,2,0,1};const D3D12_RECT scissor{0,0,2,2};c.list->RSSetViewports(1,&viewport);c.list->RSSetScissorRects(1,&scissor);
    for (UINT slice=0;slice<3;++slice) { const auto h=handle(slice+2);c.list->OMSetRenderTargets(1,&h,FALSE,nullptr);c.list->DrawInstanced(3,1,0,0); }
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT layouts[8]{};UINT64 total=0;device->GetCopyableFootprints(&desc,0,8,0,layouts,nullptr,nullptr,&total);auto *readback=buffer(device,D3D12_HEAP_TYPE_READBACK,total);
    for (UINT sub=0;sub<8;++sub) { D3D12_TEXTURE_COPY_LOCATION from{},to{};from.pResource=target;from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;from.SubresourceIndex=sub;to.pResource=readback;to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint=layouts[sub];c.list->CopyTextureRegion(&to,0,0,0,&from,nullptr); }
    unsigned count=0;{ PassCounter counter(c.queue);c.submit();c.wait();count=render_passes; }
    const auto *pixels=(const unsigned char *)map(readback);
    for (UINT sub=0;sub<8;++sub) for (UINT y=0;y<layouts[sub].Footprint.Height;++y) for (UINT x=0;x<layouts[sub].Footprint.Width;++x) {
        const auto *p=pixels+layouts[sub].Offset+y*layouts[sub].Footprint.RowPitch+x*4;const UINT slice=sub/2;
        std::array<UINT,4> expected{51,102,153,255};
        if (sub%2 && slice==1) expected={204,128,64,255};
        if (sub%2 && slice==2) expected={137,188,225,255};
        if (sub%2 && slice<3 && x<2) { expected[0]=255;expected[2]=0; }
        for (UINT channel=0;channel<4;++channel) CHECK(p[channel]==expected[channel]);
    }
    printf("Array clear/render passes=%u\n",count);CHECK(count<=9);
    c.reset();
    const Vertex overwriteVertices[]={{-1,-1,0xffff0000,0},{3,-1,0xffff0000,0},{-1,3,0xffff0000,0}};memcpy(map(vb),overwriteVertices,sizeof overwriteVertices);
    auto drawSlice=[&](D3D12_RECT clip) { const auto h=handle(3);c.list->SetPipelineState(pso);c.list->SetGraphicsRootSignature(r);c.list->OMSetRenderTargets(1,&h,FALSE,nullptr);c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);c.list->IASetVertexBuffers(2,1,&vertex);c.list->RSSetViewports(1,&viewport);c.list->RSSetScissorRects(1,&clip);c.list->DrawInstanced(3,1,0,0); };
    auto copySlice=[&](UINT sub,UINT image) { D3D12_TEXTURE_COPY_LOCATION from{},to{};from.pResource=target;from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;from.SubresourceIndex=sub;to.pResource=readback;to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint=layouts[image];c.list->CopyTextureRegion(&to,0,0,0,&from,nullptr); };
    drawSlice(scissor);c.list->ClearRenderTargetView(handle(4),replacement,0,nullptr);drawSlice({2,0,4,2});copySlice(3,3);
    drawSlice(scissor);const FLOAT overwrite[]={.6f,.4f,.2f,1};c.list->ClearRenderTargetView(handle(3),overwrite,0,nullptr);drawSlice(scissor);copySlice(3,1);copySlice(5,5);
    { PassCounter counter(c.queue);c.submit();c.wait();printf("Clear overwrite and preserved read passes=%u\n",render_passes);CHECK(render_passes==4); }
    for (UINT y=0;y<2;++y) for (UINT x=0;x<4;++x) {
        const auto *old=pixels+layouts[3].Offset+y*layouts[3].Footprint.RowPitch+x*4,*now=pixels+layouts[1].Offset+y*layouts[1].Footprint.RowPitch+x*4,*other=pixels+layouts[5].Offset+y*layouts[5].Footprint.RowPitch+x*4;
        CHECK(old[0]==0 && old[1]==128 && old[2]==255 && old[3]==255);
        CHECK(now[0]==(x<2?0:153) && now[1]==102 && now[2]==(x<2?255:51) && now[3]==255);
        CHECK(other[0]==204 && other[1]==128 && other[2]==64 && other[3]==255);
    }
    c.reset();
    std::vector<UINT> serialized(std::begin(root_empty),std::end(root_empty));serialized.back()=D3D12_ROOT_SIGNATURE_FLAG_CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED;
    auto *sampleRoot=root(device,serialized.data(),serialized.size()*4);auto *samplePipeline=graphics_pipeline(device,sampleRoot,1,true);
    ID3D12DescriptorHeap *srv=nullptr;hd={D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&srv));
    D3D12_SHADER_RESOURCE_VIEW_DESC sampled{};sampled.Format=DXGI_FORMAT_R8G8B8A8_UNORM;sampled.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2DARRAY;sampled.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;sampled.Texture2DArray={1,1,3,1,0,0};device->CreateShaderResourceView(target,&sampled,srv->GetCPUDescriptorHandleForHeapStart());
    const FLOAT changed[]={.6f,.4f,.2f,1};c.list->ClearRenderTargetView(handle(5),changed,0,nullptr);
    D3D12_RESOURCE_BARRIER ready{};ready.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;ready.Transition={target,7,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE};c.list->ResourceBarrier(1,&ready);
    const Vertex blue[]={{-1,-1,0xffff0000,0},{3,-1,0xffff0000,0},{-1,3,0xffff0000,0}};memcpy(map(vb),blue,sizeof blue);
    c.list->SetPipelineState(samplePipeline);c.list->SetGraphicsRootSignature(sampleRoot);c.list->SetDescriptorHeaps(1,&srv);
    c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);c.list->IASetVertexBuffers(2,1,&vertex);c.list->RSSetViewports(1,&viewport);c.list->RSSetScissorRects(1,&scissor);
    const auto destination=handle(2);c.list->OMSetRenderTargets(1,&destination,FALSE,nullptr);c.list->DrawInstanced(3,1,0,0);
    D3D12_TEXTURE_COPY_LOCATION from{},to{};from.pResource=target;from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;from.SubresourceIndex=1;to.pResource=readback;to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint=layouts[1];c.list->CopyTextureRegion(&to,0,0,0,&from,nullptr);
    c.submit();c.wait();for (UINT y=0;y<2;++y) for (UINT x=0;x<2;++x) { const auto *p=pixels+layouts[1].Offset+y*layouts[1].Footprint.RowPitch+x*4;CHECK(p[0]==153 && p[1]==102 && p[2]==255 && p[3]==255); }
    samplePipeline->Release();sampleRoot->Release();srv->Release();
    readback->Release();vb->Release();scratch->Release();heap->Release();target->Release();pso->Release();r->Release();
}
static void attachment_clears(ID3D12Device *device) {
  for (bool split:{true,false}) {
    Commands c(device);std::array<ID3D12Resource *,10> targets{};
    auto *r=root(device,root_mixed,sizeof root_mixed);c.list->SetGraphicsRootSignature(r);
    ID3D12DescriptorHeap *heap=nullptr;D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_RTV,10,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&heap));
    auto *readback=buffer(device,D3D12_HEAP_TYPE_READBACK,10240);std::array<D3D12_RESOURCE_BARRIER,10> reads{};
    for (UINT i=0;i<targets.size();++i) {
        DXGI_FORMAT format=DXGI_FORMAT_R8G8B8A8_UNORM;if (i%2) format=DXGI_FORMAT_R32_UINT;
        UINT width=4;if (i==9) width=2;
        targets[i]=resource(device,D3D12_HEAP_TYPE_DEFAULT,{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,width,4,1,1,format,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET});
        auto handle=heap->GetCPUDescriptorHandleForHeapStart();handle.ptr+=i*device->GetDescriptorHandleIncrementSize(hd.Type);device->CreateRenderTargetView(targets[i],nullptr,handle);
        D3D12_RESOURCE_BARRIER ready{};ready.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;ready.Transition={targets[i],0,D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_RENDER_TARGET};c.list->ResourceBarrier(1,&ready);
        FLOAT color[]={.25f,.5f,.75f,1};if (i%2) color[0]=float(i+7);c.list->ClearRenderTargetView(handle,color,0,nullptr);
        reads[i].Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;reads[i].Transition={targets[i],0,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE};
    }
    if (split) { for (const auto &read:reads) { c.list->ResourceBarrier(1,&read);const UINT value=7;c.list->SetGraphicsRoot32BitConstants(0,1,&value,0); } }
    else c.list->ResourceBarrier(reads.size(),reads.data());
    for (UINT i=0;i<targets.size();++i) {
        D3D12_TEXTURE_COPY_LOCATION from{},to{};from.pResource=targets[i];from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;to.pResource=readback;to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint={i*1024ull,{targets[i]->GetDesc().Format,(UINT)targets[i]->GetDesc().Width,4,1,256}};c.list->CopyTextureRegion(&to,0,0,0,&from,nullptr);
    }
    unsigned count=0;{ PassCounter counter(c.queue);c.submit();c.wait();count=render_passes; }
    const auto *pixels=(const unsigned char *)map(readback);
    for (UINT i=0;i<targets.size();++i) for (UINT y=0;y<4;++y) for (UINT x=0;x<targets[i]->GetDesc().Width;++x) {
        const auto *p=pixels+i*1024+y*256+x*4;
        if (i%2) { UINT value;memcpy(&value,p,4);CHECK(value==i+7); }
        else CHECK(p[0]==64 && p[1]==128 && p[2]==191 && p[3]==255);
    }
    printf("Batched attachment clear passes=%u split=%u\n",count,split);CHECK(count==3);
    for (auto *target:targets) target->Release();readback->Release();heap->Release();r->Release();
  }
}
static unsigned pipeline_sets,viewport_sets,scissor_sets,heap_sets,root_sets,vertex_sets;
static IMP pipeline_original,viewport_original,scissor_original,heap_original,root_original,vertex_original;
static void count_root(id object,SEL selector,const void *bytes,NSUInteger length,NSUInteger index) {
    if (index==2) ++root_sets;((void (*)(id,SEL,const void *,NSUInteger,NSUInteger))root_original)(object,selector,bytes,length,index);
}
static void count_vertex(id object,SEL selector,id<MTLBuffer> buffer,NSUInteger offset,NSUInteger stride,NSUInteger index) {
    if (index>=6) ++vertex_sets;((void (*)(id,SEL,id<MTLBuffer>,NSUInteger,NSUInteger,NSUInteger))vertex_original)(object,selector,buffer,offset,stride,index);
}
static void count_pipeline(id object,SEL selector,id<MTLRenderPipelineState> state) {
    ++pipeline_sets;((void (*)(id,SEL,id<MTLRenderPipelineState>))pipeline_original)(object,selector,state);
}
static void count_viewports(id object,SEL selector,const MTLViewport *values,NSUInteger count) {
    ++viewport_sets;((void (*)(id,SEL,const MTLViewport *,NSUInteger))viewport_original)(object,selector,values,count);
}
static void count_scissors(id object,SEL selector,const MTLScissorRect *values,NSUInteger count) {
    ++scissor_sets;((void (*)(id,SEL,const MTLScissorRect *,NSUInteger))scissor_original)(object,selector,values,count);
}
static void count_heap(id object,SEL selector,id<MTLBuffer> buffer,NSUInteger offset,NSUInteger index) {
    if (index<2) ++heap_sets;((void (*)(id,SEL,id<MTLBuffer>,NSUInteger,NSUInteger))heap_original)(object,selector,buffer,offset,index);
}
struct RenderStateCounter {
    std::array<Method,6> methods;
    explicit RenderStateCounter(ID3D12CommandQueue *queue) {
        ID3DMMetalQueue *native=nullptr;OK(queue->QueryInterface(__uuidof(ID3DMMetalQueue),(void **)&native));
        auto commands=[(__bridge id<MTLCommandQueue>)native->MetalCommandQueue() commandBuffer];native->Release();
        auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];desc.usage=MTLTextureUsageRenderTarget;
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=[commands.device newTextureWithDescriptor:desc];
        auto encoder=[commands renderCommandEncoderWithDescriptor:pass];auto cls=[encoder class];[encoder endEncoding];
        methods={class_getInstanceMethod(cls,@selector(setRenderPipelineState:)),class_getInstanceMethod(cls,@selector(setViewports:count:)),class_getInstanceMethod(cls,@selector(setScissorRects:count:)),class_getInstanceMethod(cls,@selector(setVertexBuffer:offset:atIndex:)),class_getInstanceMethod(cls,@selector(setVertexBytes:length:atIndex:)),class_getInstanceMethod(cls,@selector(setVertexBuffer:offset:attributeStride:atIndex:))};
        for (auto method:methods) CHECK(method);
        pipeline_sets=viewport_sets=scissor_sets=heap_sets=root_sets=vertex_sets=0;
        pipeline_original=method_setImplementation(methods[0],(IMP)count_pipeline);viewport_original=method_setImplementation(methods[1],(IMP)count_viewports);
        scissor_original=method_setImplementation(methods[2],(IMP)count_scissors);heap_original=method_setImplementation(methods[3],(IMP)count_heap);
        root_original=method_setImplementation(methods[4],(IMP)count_root);vertex_original=method_setImplementation(methods[5],(IMP)count_vertex);
    }
    ~RenderStateCounter() {
        method_setImplementation(methods[0],pipeline_original);method_setImplementation(methods[1],viewport_original);
        method_setImplementation(methods[2],scissor_original);method_setImplementation(methods[3],heap_original);
        method_setImplementation(methods[4],root_original);method_setImplementation(methods[5],vertex_original);
    }
};
static void draw_state(ID3D12Device *device,bool benchmark=false) {
    Commands c(device);
    const UINT serialized[]={0x43425844,0,0,0,0,1,92,1,36,0x30535452,48,1,1,24,0,48,
        D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT|D3D12_ROOT_SIGNATURE_FLAG_CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED,1,0,36,0,0,4};
    auto *r=root(device,serialized,sizeof serialized);auto *pso=graphics_pipeline(device,r,1,false,true),*plain=graphics_pipeline(device,r);
    std::array<ID3D12DescriptorHeap *,2> heaps{};D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,0};
    for (auto &heap:heaps) OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&heap));
    HeapImage image(device,c.list,heaps[0]->GetCPUDescriptorHandleForHeapStart()),other(device,c.list,heaps[1]->GetCPUDescriptorHandleForHeapStart());
    ((unsigned char *)map(other.pixels))[513]=255;
    std::array<ID3D12Resource *,2> targets{};std::array<D3D12_CPU_DESCRIPTOR_HANDLE,2> handles{};
    ID3D12DescriptorHeap *rtv=nullptr;hd={D3D12_DESCRIPTOR_HEAP_TYPE_RTV,2,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&rtv));
    for (UINT i=0;i<2;++i) {
        targets[i]=resource(device,D3D12_HEAP_TYPE_DEFAULT,{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,16u>>i,4,1,1,DXGI_FORMAT_R8G8B8A8_UNORM,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET});
        handles[i]=rtv->GetCPUDescriptorHandleForHeapStart();handles[i].ptr+=i*device->GetDescriptorHandleIncrementSize(hd.Type);device->CreateRenderTargetView(targets[i],nullptr,handles[i]);
    }
    struct Vertex { float x,y;UINT color,padding; };const Vertex vertices[]={{-1,-1,0xffff0000,0},{3,-1,0xffff0000,0},{-1,3,0xffff0000,0}};
    auto *vb=buffer(device,D3D12_HEAP_TYPE_UPLOAD,sizeof vertices),*readback=buffer(device,D3D12_HEAP_TYPE_READBACK,2048);memcpy(map(vb),vertices,sizeof vertices);
    D3D12_VERTEX_BUFFER_VIEW vertex{vb->GetGPUVirtualAddress(),sizeof vertices,sizeof(Vertex)};
    const FLOAT white[]={1,1,1,1},blue[]={0,0,1,1},black[]={0,0,0,1},half[]={.5f,.5f,.5f,1};
    D3D12_VIEWPORT viewport{0,0,16,4,0,1};D3D12_RECT scissor{-2,-2,20,6};
    auto setup=[&] {
        c.list->SetPipelineState(pso);c.list->SetGraphicsRootSignature(r);c.list->SetGraphicsRoot32BitConstants(0,4,blue,0);c.list->SetDescriptorHeaps(1,&heaps[0]);
        c.list->OMSetRenderTargets(1,&handles[0],FALSE,nullptr);c.list->ClearRenderTargetView(handles[0],black,0,nullptr);
        c.list->RSSetViewports(1,&viewport);c.list->RSSetScissorRects(1,&scissor);c.list->OMSetBlendFactor(white);c.list->OMSetStencilRef(7);
        c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);c.list->IASetVertexBuffers(2,1,&vertex);
    };
    setup();c.list->DrawInstanced(3,1,0,0);
    ID3D12CommandAllocator *allocator=nullptr;ID3D12GraphicsCommandList *bundle=nullptr;
    OK(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_BUNDLE,__uuidof(ID3D12CommandAllocator),(void **)&allocator));
    OK(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_BUNDLE,allocator,nullptr,__uuidof(ID3D12GraphicsCommandList),(void **)&bundle));
    D3D12_VIEWPORT narrow{0,0,8,4,0,1};bundle->RSSetViewports(1,&narrow);
    D3D12_RECT middle{4,0,12,4};bundle->RSSetScissorRects(1,&middle);bundle->OMSetBlendFactor(half);bundle->OMSetStencilRef(9);bundle->SetDescriptorHeaps(1,&heaps[1]);bundle->DrawInstanced(3,1,0,0);OK(bundle->Close());
    for (UINT i=0;i<8;++i) c.list->DrawInstanced(3,1,0,0);
    c.list->ExecuteBundle(bundle);c.list->DrawInstanced(3,1,0,0);
    c.list->SetPipelineState(plain);c.list->DrawInstanced(3,1,0,0);c.list->SetPipelineState(pso);c.list->DrawInstanced(3,1,0,0);
    const D3D12_RECT empty{20,0,22,4};c.list->RSSetScissorRects(1,&empty);c.list->DrawInstanced(3,1,0,0);
    c.list->RSSetScissorRects(1,&scissor);c.list->OMSetRenderTargets(1,&handles[1],FALSE,nullptr);c.list->ClearRenderTargetView(handles[1],black,0,nullptr);c.list->DrawInstanced(3,1,0,0);
    const D3D12_RECT patch{0,0,2,4};c.list->ClearRenderTargetView(handles[1],black,1,&patch);c.list->DrawInstanced(3,1,0,0);
    auto copy=[&](UINT i) {
        D3D12_TEXTURE_COPY_LOCATION from{},to{};from.pResource=targets[i];from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        to.pResource=readback;to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint={i*1024ull,{DXGI_FORMAT_R8G8B8A8_UNORM,16u>>i,4,1,256}};c.list->CopyTextureRegion(&to,0,0,0,&from,nullptr);
    };
    copy(1);c.list->SetGraphicsRoot32BitConstants(0,4,white,0);c.list->DrawInstanced(3,1,0,0);copy(0);copy(1);
    { RenderStateCounter count(c.queue);c.submit();c.wait();
        printf("Draw state calls: pipeline=%u viewport=%u scissor=%u heap=%u root=%u vertex=%u\n",pipeline_sets,viewport_sets,scissor_sets,heap_sets,root_sets,vertex_sets);
        if (!benchmark) { CHECK(pipeline_sets<=7);CHECK(viewport_sets<=5);CHECK(scissor_sets<=6);CHECK(heap_sets<=5);CHECK(root_sets<=5);CHECK(vertex_sets<=5); }
    }
    const auto *pixels=(const unsigned char *)map(readback);
    for (UINT i=0;i<2;++i) for (UINT y=0;y<4;++y) for (UINT x=0;x<(16u>>i);++x) {
        const auto *p=pixels+i*1024+y*256+x*4;
        if (i==0) CHECK(p[0]==(x>=4 && x<8?128:1) && p[1]==0 && p[2]==(x>=4 && x<8?128:255) && p[3]==255);
        else CHECK(p[0]==128 && p[1]==128 && p[2]==128 && p[3]==255);
    }
    c.reset();setup();c.list->DrawInstanced(3,1,0,0);
    D3D12_RESOURCE_BARRIER unrelated{};unrelated.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    unrelated.Transition={targets[1],D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE};
    c.list->ResourceBarrier(1,&unrelated);
    c.list->OMSetRenderTargets(1,&handles[1],FALSE,nullptr);
    device->CreateRenderTargetView(targets[0],nullptr,handles[0]);c.list->OMSetRenderTargets(1,&handles[0],FALSE,nullptr);c.list->DrawInstanced(3,1,0,0);copy(0);
    { PassCounter count(c.queue);c.submit();c.wait();printf("Equivalent attachment views passes=%u\n",render_passes);if (!benchmark) CHECK(render_passes==1); }
    for (UINT y=0;y<4;++y) for (UINT x=0;x<16;++x) {
        const auto *p=pixels+y*256+x*4;CHECK(p[0]==1 && p[1]==0 && p[2]==255 && p[3]==255);
    }
    c.reset();setup();c.list->DrawInstanced(3,1,0,0);
    unrelated.Transition.pResource=targets[0];c.list->ResourceBarrier(1,&unrelated);
    std::swap(unrelated.Transition.StateBefore,unrelated.Transition.StateAfter);c.list->ResourceBarrier(1,&unrelated);
    c.list->DrawInstanced(3,1,0,0);copy(0);
    { PassCounter count(c.queue);c.submit();c.wait();CHECK(render_passes==2); }
    for (UINT y=0;y<4;++y) for (UINT x=0;x<16;++x) {
        const auto *p=pixels+y*256+x*4;CHECK(p[0]==1 && p[1]==0 && p[2]==255 && p[3]==255);
    }
    c.reset();setup();c.list->DrawInstanced(3,1,0,0);c.list->ClearState(nullptr);copy(0);c.submit();c.wait();
    for (UINT y=0;y<4;++y) for (UINT x=0;x<16;++x) {
        const auto *p=pixels+y*256+x*4;CHECK(p[0]==1 && p[1]==0 && p[2]==255 && p[3]==255);
    }
    if (benchmark) {
        std::vector<double> times;
        for (UINT trial=0;trial<9;++trial) {
            c.reset();setup();
            for (UINT i=0;i<1024;++i) { if (i%32==0) c.list->OMSetStencilRef(i/32);c.list->DrawInstanced(3,1,0,0); }
            const auto begin=std::chrono::steady_clock::now();c.submit();
            times.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count());c.wait();
        }
        std::sort(times.begin(),times.end());printf("Draw replay CPU ms (1024 draws, 9 trials): median=%.3f min=%.3f max=%.3f\n",times[4],times.front(),times.back());
    }
    bundle->Release();allocator->Release();vb->Release();readback->Release();rtv->Release();for (auto *target:targets) target->Release();for (auto *heap:heaps) heap->Release();plain->Release();pso->Release();r->Release();
}
static void raster_depth_state(ID3D12Device *device) {
    Commands c(device);auto *r=root(device,root_empty,sizeof root_empty);
    std::array<ID3D12PipelineState *,5> pipelines{};const unsigned char vs=1,ps=2;
    const D3D12_INPUT_ELEMENT_DESC inputs[]={{"POSITION",0,DXGI_FORMAT_R32G32_FLOAT,2,0,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0},{"COLOR",0,DXGI_FORMAT_R8G8B8A8_UNORM,2,8,D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,0}};
    for (UINT i=0;i<pipelines.size();++i) {
        D3D12_GRAPHICS_PIPELINE_STATE_DESC d{};d.pRootSignature=r;d.VS={&vs,1};d.PS={&ps,1};d.InputLayout={inputs,2};d.SampleMask=UINT_MAX;
        d.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;d.NumRenderTargets=1;d.RTVFormats[0]=DXGI_FORMAT_R8G8B8A8_UNORM;d.DSVFormat=DXGI_FORMAT_D32_FLOAT_S8X24_UINT;d.SampleDesc.Count=1;
        d.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
        d.RasterizerState.FillMode=i==4?D3D12_FILL_MODE_WIREFRAME:D3D12_FILL_MODE_SOLID;d.RasterizerState.CullMode=(i==2 || i==3)?D3D12_CULL_MODE_BACK:D3D12_CULL_MODE_NONE;
        d.RasterizerState.FrontCounterClockwise=i==3;d.RasterizerState.DepthClipEnable=TRUE;
        auto &depth=d.DepthStencilState;depth.DepthEnable=TRUE;depth.DepthFunc=i==1?D3D12_COMPARISON_FUNC_NEVER:D3D12_COMPARISON_FUNC_LESS;
        depth.StencilEnable=TRUE;depth.StencilReadMask=255;depth.FrontFace={D3D12_STENCIL_OP_KEEP,D3D12_STENCIL_OP_KEEP,D3D12_STENCIL_OP_KEEP,D3D12_COMPARISON_FUNC_EQUAL};depth.BackFace=depth.FrontFace;
        OK(device->CreateGraphicsPipelineState(&d,__uuidof(ID3D12PipelineState),(void **)&pipelines[i]));
    }
    auto *target=resource(device,D3D12_HEAP_TYPE_DEFAULT,{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,64,8,1,1,DXGI_FORMAT_R8G8B8A8_UNORM,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET});
    auto *depth=resource(device,D3D12_HEAP_TYPE_DEFAULT,{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,64,8,1,1,DXGI_FORMAT_D32_FLOAT_S8X24_UINT,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL});
    ID3D12DescriptorHeap *rtv=nullptr,*dsv=nullptr;D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_RTV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&rtv));
    hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_DSV;OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&dsv));
    auto colorHandle=rtv->GetCPUDescriptorHandleForHeapStart(),depthHandle=dsv->GetCPUDescriptorHandleForHeapStart();device->CreateRenderTargetView(target,nullptr,colorHandle);device->CreateDepthStencilView(depth,nullptr,depthHandle);
    const FLOAT black[]={0,0,0,1};c.list->ClearRenderTargetView(colorHandle,black,0,nullptr);c.list->ClearDepthStencilView(depthHandle,(D3D12_CLEAR_FLAGS)(D3D12_CLEAR_FLAG_DEPTH|D3D12_CLEAR_FLAG_STENCIL),.5f,7,0,nullptr);
    c.list->OMSetRenderTargets(1,&colorHandle,FALSE,&depthHandle);c.list->SetGraphicsRootSignature(r);c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    struct Vertex { float x,y;UINT color,padding; };const Vertex vertices[]={{-1,-1,0xffff0000,0},{3,-1,0xffff0000,0},{-1,3,0xffff0000,0}};
    auto *vb=buffer(device,D3D12_HEAP_TYPE_UPLOAD,sizeof vertices),*readback=buffer(device,D3D12_HEAP_TYPE_READBACK,2048);memcpy(map(vb),vertices,sizeof vertices);
    D3D12_VERTEX_BUFFER_VIEW vertex{vb->GetGPUVirtualAddress(),sizeof vertices,sizeof(Vertex)};c.list->IASetVertexBuffers(2,1,&vertex);
    const UINT states[]={0,0,1,0,2,3,4,0};
    for (UINT i=0;i<8;++i) {
        D3D12_VIEWPORT viewport{float(i*8),0,8,8,0,1};D3D12_RECT scissor{LONG(i*8),0,LONG(i*8+8),8};
        c.list->RSSetViewports(1,&viewport);c.list->RSSetScissorRects(1,&scissor);c.list->SetPipelineState(pipelines[states[i]]);c.list->OMSetStencilRef(i==1?9:7);c.list->DrawInstanced(3,1,0,0);
    }
    D3D12_TEXTURE_COPY_LOCATION from{},to{};from.pResource=target;from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;to.pResource=readback;to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint={0,{DXGI_FORMAT_R8G8B8A8_UNORM,64,8,1,256}};
    c.list->CopyTextureRegion(&to,0,0,0,&from,nullptr);c.submit();c.wait();const auto *pixels=(const unsigned char *)map(readback);
    auto blue=[&](UINT stripe) { return pixels[4*256+(stripe*8+3)*4+2]; };
    CHECK(blue(0)==255 && blue(1)==0 && blue(2)==0 && blue(3)==255);CHECK(blue(4)+blue(5)==255);CHECK(blue(6)==0 && blue(7)==255);
    for (auto aspect:{D3D12_CLEAR_FLAG_DEPTH,D3D12_CLEAR_FLAG_STENCIL}) {
        c.reset();c.list->ClearRenderTargetView(colorHandle,black,0,nullptr);
        c.list->ClearDepthStencilView(depthHandle,(D3D12_CLEAR_FLAGS)(D3D12_CLEAR_FLAG_DEPTH|D3D12_CLEAR_FLAG_STENCIL),aspect==D3D12_CLEAR_FLAG_DEPTH?.5f:0.f,aspect==D3D12_CLEAR_FLAG_DEPTH?5:3,0,nullptr);
        c.list->OMSetRenderTargets(1,&colorHandle,FALSE,&depthHandle);c.list->SetPipelineState(pipelines[0]);c.list->SetGraphicsRootSignature(r);c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);c.list->IASetVertexBuffers(2,1,&vertex);
        const D3D12_VIEWPORT viewport{0,0,64,8,0,1};const D3D12_RECT scissor{0,0,64,8};c.list->RSSetViewports(1,&viewport);c.list->RSSetScissorRects(1,&scissor);
        c.list->OMSetStencilRef(9);c.list->DrawInstanced(3,1,0,0);
        c.list->ClearDepthStencilView(depthHandle,aspect,.25f,7,0,nullptr);c.list->OMSetStencilRef(aspect==D3D12_CLEAR_FLAG_DEPTH?5:7);c.list->DrawInstanced(3,1,0,0);
        c.list->CopyTextureRegion(&to,0,0,0,&from,nullptr);c.submit();c.wait();
        const UINT expectedBlue=aspect==D3D12_CLEAR_FLAG_DEPTH?255:0;
        for (UINT y=0;y<8;++y) for (UINT x=0;x<64;++x) { const auto *p=pixels+y*256+x*4;CHECK(p[0]==0 && p[1]==0 && p[2]==expectedBlue && p[3]==255); }
    }
    for (auto *pso:pipelines) pso->Release();vb->Release();readback->Release();target->Release();depth->Release();rtv->Release();dsv->Release();r->Release();
}
static void msaa(ID3D12Device *device) {
    Commands c(device);auto *r=root(device,root_empty,sizeof root_empty);auto *pso=graphics_pipeline(device,r,4);
    const auto format=DXGI_FORMAT_R8G8B8A8_UNORM;
    D3D12_RESOURCE_DESC desc{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,8,4,2,1,DXGI_FORMAT_R8G8B8A8_TYPELESS,{4,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET};
    auto *target=resource(device,D3D12_HEAP_TYPE_DEFAULT,desc);
    desc.Width=16;desc.Height=8;desc.MipLevels=2;desc.SampleDesc.Count=1;
    auto *a=resource(device,D3D12_HEAP_TYPE_DEFAULT,desc),*b=resource(device,D3D12_HEAP_TYPE_DEFAULT,desc),*readback=buffer(device,D3D12_HEAP_TYPE_READBACK,3072);
    ID3D12DescriptorHeap *heap=nullptr;D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_RTV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&heap));
    auto handle=heap->GetCPUDescriptorHandleForHeapStart();D3D12_RENDER_TARGET_VIEW_DESC view{};view.Format=format;view.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2DMSARRAY;view.Texture2DMSArray={1,1};device->CreateRenderTargetView(target,&view,handle);
    auto *pixels=(unsigned char *)map(readback);
    auto copy=[&](ID3D12Resource *from,UINT image) {
        D3D12_TEXTURE_COPY_LOCATION src{},dst{};src.pResource=from;src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;src.SubresourceIndex=3;
        dst.pResource=readback;dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint={image*1024ull,{format,8,4,1,256}};
        c.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
    };
    auto check=[&](UINT image,UINT x,UINT y,UINT red,UINT green,UINT blue,UINT alpha) {
        const auto *p=pixels+image*1024+y*256+x*4;CHECK(p[0]==red && p[1]==green && p[2]==blue && p[3]==alpha);
    };
    const FLOAT clear[]={.25f,.5f,.75f,1};c.list->ClearRenderTargetView(handle,clear,0,nullptr);
    c.list->ResolveSubresource(a,3,target,1,format);c.list->ResolveSubresource(b,3,target,1,format);copy(a,0);copy(b,1);
    { PassCounter count(c.queue);c.submit();c.wait();printf("MSAA clear and repeated resolve passes=%u\n",render_passes);CHECK(render_passes==2); }
    for (UINT i=0;i<2;++i) for (UINT y=0;y<4;++y) for (UINT x=0;x<8;++x) check(i,x,y,64,128,191,255);
    struct Vertex { float x,y;unsigned char color[4];UINT padding; };
    const Vertex vertices[]={{-1,-1,{50,100,200,255},0},{3,-1,{50,100,200,255},0},{-1,3,{50,100,200,255},0},
        {-1,-1,{180,90,20,77},0},{3,-1,{180,90,20,77},0},{-1,3,{180,90,20,77},0}};
    auto *vb=buffer(device,D3D12_HEAP_TYPE_UPLOAD,256);memcpy(map(vb),vertices,sizeof vertices);
    D3D12_RESOURCE_BARRIER transition{};transition.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;transition.Transition={target,1,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_RESOLVE_SOURCE};
    auto draw=[&](UINT first,UINT width) {
        c.list->SetPipelineState(pso);c.list->SetGraphicsRootSignature(r);c.list->OMSetRenderTargets(1,&handle,FALSE,nullptr);
        D3D12_VIEWPORT viewport{0,0,8,4,0,1};D3D12_RECT scissor{0,0,(LONG)width,4};c.list->RSSetViewports(1,&viewport);c.list->RSSetScissorRects(1,&scissor);c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        D3D12_VERTEX_BUFFER_VIEW vertex{vb->GetGPUVirtualAddress(),sizeof vertices,sizeof(Vertex)};c.list->IASetVertexBuffers(2,1,&vertex);c.list->DrawInstanced(3,1,first,0);
    };
    c.reset();const FLOAT drawClear[]={.1f,.2f,.3f,.4f};c.list->ClearRenderTargetView(handle,drawClear,0,nullptr);draw(0,8);c.list->ResourceBarrier(1,&transition);c.list->ResolveSubresource(a,3,target,1,format);
    std::swap(transition.Transition.StateBefore,transition.Transition.StateAfter);c.list->ResourceBarrier(1,&transition);draw(3,4);
    std::swap(transition.Transition.StateBefore,transition.Transition.StateAfter);c.list->ResourceBarrier(1,&transition);c.list->ResolveSubresource(b,3,target,1,format);copy(a,0);copy(b,1);
    { PassCounter count(c.queue);c.submit();c.wait();printf("MSAA continued drawing passes=%u\n",render_passes);CHECK(render_passes==2); }
    for (UINT y=0;y<4;++y) for (UINT x=0;x<8;++x) { check(0,x,y,50,51,200,102);check(1,x,y,x<4?180:50,51,x<4?20:200,102); }
    c.reset();c.list->ClearRenderTargetView(handle,clear,0,nullptr);draw(3,8);copy(a,2);
    c.list->ResolveSubresource(a,3,target,1,format);c.list->ResolveSubresource(b,3,target,1,format);copy(a,0);copy(b,1);
    { PassCounter count(c.queue);c.submit();c.wait();printf("MSAA interrupted drawing passes=%u\n",render_passes);CHECK(render_passes==3); }
    for (UINT y=0;y<4;++y) for (UINT x=0;x<8;++x) { check(2,x,y,50,51,200,102);for (UINT i=0;i<2;++i) check(i,x,y,180,128,20,255); }
    c.reset();view.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;device->CreateRenderTargetView(target,&view,handle);
    c.list->ClearRenderTargetView(handle,clear,0,nullptr);c.list->ResolveSubresource(a,3,target,1,view.Format);copy(a,0);c.submit();c.wait();
    for (UINT y=0;y<4;++y) for (UINT x=0;x<8;++x) check(0,x,y,137,188,225,255);
    c.reset();view.Format=format;view.Texture2DMSArray={0,2};device->CreateRenderTargetView(target,&view,handle);c.list->ClearRenderTargetView(handle,clear,0,nullptr);
    view.Texture2DMSArray={1,1};device->CreateRenderTargetView(target,&view,handle);draw(0,8);
    transition.Transition={target,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_RESOLVE_SOURCE};c.list->ResourceBarrier(1,&transition);
    c.list->ResolveSubresource(a,3,target,1,format);c.list->ResolveSubresource(b,3,target,0,format);copy(a,0);copy(b,1);c.submit();c.wait();
    for (UINT y=0;y<4;++y) for (UINT x=0;x<8;++x) { check(0,x,y,50,128,200,255);check(1,x,y,64,128,191,255); }
    vb->Release();heap->Release();target->Release();a->Release();b->Release();readback->Release();pso->Release();r->Release();
}
static void spatial_upscaling(ID3D12Device *device) {
    Commands c(device);
    ID3DMMetalQueue *nativeQueue=nullptr;OK(c.queue->QueryInterface(__uuidof(ID3DMMetalQueue),(void **)&nativeQueue));
    id<MTLCommandQueue> queue=(__bridge id<MTLCommandQueue>)nativeQueue->MetalCommandQueue();nativeQueue->Release();
    CHECK([MTLFXSpatialScalerDescriptor supportsDevice:queue.device]);
    auto texture=[](ID3D12Resource *resource) {
        ID3DMMetalTexture *native=nullptr;OK(resource->QueryInterface(__uuidof(ID3DMMetalTexture),(void **)&native));
        id<MTLTexture> result=(__bridge id<MTLTexture>)native->MetalTexture();native->Release();
        return [result newTextureViewWithPixelFormat:result.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0,1) slices:NSMakeRange(0,1)];
    };
    auto read=[&](id<MTLTexture> image) {
        auto bytes=[queue.device newBufferWithLength:image.width*image.height*4 options:MTLResourceStorageModeShared];
        auto commands=[queue commandBuffer];auto blit=[commands blitCommandEncoder];
        [blit copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(image.width,image.height,1)
                     toBuffer:bytes destinationOffset:0 destinationBytesPerRow:image.width*4 destinationBytesPerImage:image.width*image.height*4];
        [blit endEncoding];[commands commit];[commands waitUntilCompleted];CHECK(commands.status==MTLCommandBufferStatusCompleted);
        const auto *data=(const unsigned char *)bytes.contents;return std::vector<unsigned char>(data,data+bytes.length);
    };
    auto *r=root(device,root_mixed,sizeof root_mixed);const unsigned char vs=7,ps=8;
    D3D12_GRAPHICS_PIPELINE_STATE_DESC desc{};desc.pRootSignature=r;desc.VS={&vs,1};desc.PS={&ps,1};desc.SampleMask=UINT_MAX;
    desc.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;desc.NumRenderTargets=1;desc.RTVFormats[0]=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;desc.SampleDesc.Count=1;
    desc.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;desc.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;
    desc.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
    ID3D12PipelineState *pso=nullptr;OK(device->CreateGraphicsPipelineState(&desc,__uuidof(ID3D12PipelineState),(void **)&pso));
    auto *input=resource(device,D3D12_HEAP_TYPE_DEFAULT,{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,64,32,1,1,DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET});
    auto source=texture(input);auto upload=[queue.device newBufferWithLength:64*32*4 options:MTLResourceStorageModeShared];
    auto *pixels=(unsigned char *)upload.contents;
    for (UINT y=0;y<32;++y) for (UINT x=0;x<64;++x) {
        const UINT i=(y*64+x)*4;pixels[i]=((x/3+y/3)%2)*255;pixels[i+1]=(x*7+y*11)%256;pixels[i+2]=x>y?200:25;pixels[i+3]=255;
    }
    auto commands=[queue commandBuffer];auto blit=[commands blitCommandEncoder];
    [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:8192 sourceSize:MTLSizeMake(64,32,1)
              toTexture:source destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];[commands commit];[commands waitUntilCompleted];CHECK(commands.status==MTLCommandBufferStatusCompleted);
    ID3D12DescriptorHeap *srv=nullptr,*rtv=nullptr;
    D3D12_DESCRIPTOR_HEAP_DESC hd{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,1,D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&srv));
    D3D12_SHADER_RESOURCE_VIEW_DESC view{};view.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2DARRAY;view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;view.Texture2DArray={0,1,0,1,0,0};
    device->CreateShaderResourceView(input,&view,srv->GetCPUDescriptorHandleForHeapStart());
    hd={D3D12_DESCRIPTOR_HEAP_TYPE_RTV,1,D3D12_DESCRIPTOR_HEAP_FLAG_NONE,0};OK(device->CreateDescriptorHeap(&hd,__uuidof(ID3D12DescriptorHeap),(void **)&rtv));
    const auto handle=rtv->GetCPUDescriptorHandleForHeapStart();
    unsigned iteration=0;
    for (UINT width:{128u,128u,192u,64u}) {
        if (c.value) c.reset();
        const UINT height=width/2;
        auto *output=resource(device,D3D12_HEAP_TYPE_DEFAULT,{D3D12_RESOURCE_DIMENSION_TEXTURE2D,0,width,height,1,1,DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET});
        auto destination=texture(output);device->CreateRenderTargetView(output,nullptr,handle);
        const FLOAT red[]={1,0,0,1};
        // The repeated-size case has no earlier encoder; its later overlay still needs ordering.
        if (iteration++!=1) c.list->ClearRenderTargetView(handle,red,0,nullptr);
        c.list->SetPipelineState(pso);c.list->SetGraphicsRootSignature(r);c.list->SetDescriptorHeaps(1,&srv);
        c.list->SetGraphicsRootDescriptorTable(4,srv->GetGPUDescriptorHandleForHeapStart());c.list->OMSetRenderTargets(1,&handle,FALSE,nullptr);
        D3D12_VIEWPORT viewport{0,0,(FLOAT)width,(FLOAT)height,0,1};D3D12_RECT scissor{-10,-10,16384,16384};
        c.list->RSSetViewports(1,&viewport);c.list->RSSetScissorRects(1,&scissor);c.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);c.list->DrawInstanced(3,1,0,0x3f800000);
        const D3D12_RECT overlay{0,0,8,8};c.list->ClearRenderTargetView(handle,red,1,&overlay);c.submit();c.wait();
        std::vector<unsigned char> expected;
        if (width==64) expected=std::vector<unsigned char>(pixels,pixels+8192);
        else {
            auto scale=[MTLFXSpatialScalerDescriptor new];scale.inputWidth=64;scale.inputHeight=32;scale.outputWidth=width;scale.outputHeight=height;
            scale.colorTextureFormat=source.pixelFormat;scale.outputTextureFormat=destination.pixelFormat;scale.colorProcessingMode=MTLFXSpatialScalerColorProcessingModePerceptual;
            auto reference=[scale newSpatialScalerWithDevice:queue.device];CHECK(reference!=nil);
            auto target=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:destination.pixelFormat width:width height:height mipmapped:NO];
            target.storageMode=MTLStorageModePrivate;target.usage=reference.outputTextureUsage;auto image=[queue.device newTextureWithDescriptor:target];
            reference.colorTexture=source;reference.outputTexture=image;reference.inputContentWidth=64;reference.inputContentHeight=32;
            auto cmd=[queue commandBuffer];[reference encodeToCommandBuffer:cmd];[cmd commit];[cmd waitUntilCompleted];CHECK(cmd.status==MTLCommandBufferStatusCompleted);
            expected=read(image);
        }
        const auto actual=read(destination);
        for (UINT y=0;y<height;++y) for (UINT x=0;x<width;++x) for (UINT channel=0;channel<4;++channel) {
            const UINT i=(y*width+x)*4+channel;int want=expected[i];if (x<8 && y<8) want=(channel==0 || channel==3)?255:0;
            CHECK(std::abs((int)actual[i]-want)<=2);
        }
        output->Release();
    }
    pso->Release();r->Release();srv->Release();rtv->Release();input->Release();
}

static void removed(ID3D12Device *device) {
    ID3D12Fence *fence=nullptr;OK(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,__uuidof(ID3D12Fence),(void **)&fence));
    std::promise<HRESULT> done;auto future=done.get_future();std::thread waiter([&] { done.set_value(fence->SetEventOnCompletion(10,nullptr)); });
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    ID3DMDeviceStatus *status=nullptr;OK(device->QueryInterface(__uuidof(ID3DMDeviceStatus),(void **)&status));status->RecordError(DXGI_ERROR_DEVICE_HUNG);status->Release();
    CHECK(future.wait_for(std::chrono::seconds(5))==std::future_status::ready);OK(future.get());waiter.join();CHECK(fence->GetCompletedValue()==UINT64_MAX);fence->Release();
    D3D12_QUERY_HEAP_DESC desc{D3D12_QUERY_HEAP_TYPE_TIMESTAMP,1,0};ID3D12QueryHeap *heap=(ID3D12QueryHeap *)1;
    CHECK(device->CreateQueryHeap(&desc,__uuidof(ID3D12QueryHeap),(void **)&heap)==DXGI_ERROR_DEVICE_HUNG && !heap);
}
static void footprints(ID3D12Device *device,const char *path) {
    NSData *data=[NSData dataWithContentsOfFile:@(path)];CHECK(data);
    NSArray *cases=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];CHECK([cases isKindOfClass:[NSArray class]]);
    for (NSDictionary *row in cases) {
        D3D12_RESOURCE_DESC desc{(D3D12_RESOURCE_DIMENSION)[row[@"dim"] unsignedIntValue],0,[row[@"width"] unsignedLongLongValue],[row[@"height"] unsignedIntValue],(UINT16)[row[@"depth"] unsignedIntValue],(UINT16)[row[@"mips"] unsignedIntValue],(DXGI_FORMAT)[row[@"format"] unsignedIntValue],{1,0},D3D12_TEXTURE_LAYOUT_UNKNOWN,(D3D12_RESOURCE_FLAGS)[row[@"flags"] unsignedIntValue]};
        if (desc.Dimension==D3D12_RESOURCE_DIMENSION_BUFFER) desc.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        const UINT count=[row[@"count"] unsignedIntValue];CHECK(count<=64);
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT layouts[64]{};UINT rows[64]{};UINT64 sizes[64]{},total=0;
        device->GetCopyableFootprints(&desc,[row[@"first"] unsignedIntValue],count,[row[@"base"] unsignedLongLongValue],layouts,rows,sizes,&total);
        const UINT64 expected=strtoull([row[@"total"] UTF8String],nullptr,10);
        if (total!=expected) fprintf(stderr,"footprint mismatch: %s\n",row.description.UTF8String);
        CHECK(total==expected);
        if (total==UINT64_MAX) continue;
        for (UINT i=0;i<count;++i) {
            NSArray *want=row[@"layouts"][i];const auto &p=layouts[i];
            const UINT64 got[]={p.Offset,(UINT64)p.Footprint.Format,p.Footprint.Width,p.Footprint.Height,p.Footprint.Depth,p.Footprint.RowPitch,rows[i],sizes[i]};
            for (UINT j=0;j<8;++j) CHECK(got[j]==[want[j] unsignedLongLongValue]);
        }
    }
}
int main(int argc,const char **argv) { @autoreleasepool {
    D3DMHost host{};host.check_feature=[](D3D12_FEATURE f,void *data,UINT size)->HRESULT { if (f!=D3D12_FEATURE_FEATURE_LEVELS || size!=sizeof(D3D12_FEATURE_DATA_FEATURE_LEVELS)) return E_INVALIDARG;((D3D12_FEATURE_DATA_FEATURE_LEVELS *)data)->MaxSupportedFeatureLevel=D3D_FEATURE_LEVEL_12_2;return S_OK; };
    host.load_shader=[](void *,const void *,SIZE_T,const void *code,SIZE_T size,UINT,D3DMShader *out)->HRESULT {
        if (size!=1) return E_INVALIDARG;const unsigned tag=*(const unsigned char *)code;if (tag<1 || tag>9) return E_INVALIDARG;
        const char *entries[]={"vs","ps","cs","direct_cs","textured_ps","state_ps","fullscreen_vs","copy_ps","guard_ps"};
        *out={(__bridge void *)shaders,entries[tag-1],"{\"state\":{\"vertex_inputs\":[{\"name\":\"position0\",\"index\":0},{\"name\":\"color0\",\"index\":1}]}}",{4,1,1}};
        if(tag==3 || tag==4 || tag==7 || tag==8) out->reflection="{\"UsedResources\":[{\"isInGRS\":true,\"bindingIndex\":4,\"tableStartIndex\":0,\"tableLength\":1}],\"state\":{}}";
        if(tag==4) out->reflection="{\"UsedResources\":[{\"isInGRS\":true,\"bindingIndex\":4,\"tableStartIndex\":2,\"tableLength\":2}],\"state\":{}}";
        if(tag==9) { out->specializedLibrary=(__bridge void *)shaders;out->specializedEntryPoint="specialized_ps";out->specializationIndex=1;out->specializationOffset=4;out->specializationValue=1; }
        return S_OK;
    };
    host.spatial_upscale_source=[](const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc,UINT *parameter,UINT *index) {
        if (desc->VS.BytecodeLength!=1 || desc->PS.BytecodeLength!=1 || *(const unsigned char *)desc->VS.pShaderBytecode!=7 || *(const unsigned char *)desc->PS.pShaderBytecode!=8) return false;
        *parameter=4;*index=0;return true;
    };
    D3DMSetHost(&host);ID3D12Device *device=nullptr;OK(D3DMCreateDevice(nullptr,D3D_FEATURE_LEVEL_12_0,__uuidof(ID3D12Device),(void **)&device));
    NSError *error=nil;shaders=[MTLCreateSystemDefaultDevice() newLibraryWithSource:@(source) options:nil error:&error];CHECK(shaders!=nil);
    if (argc==3 && !strcmp(argv[1],"footprints")) footprints(device,argv[2]);
    else if (argc==2 && !strcmp(argv[1],"bc")) compressed_mips(device);
    else if (argc==2 && !strcmp(argv[1],"removed")) removed(device);
    else if (argc==2 && !strcmp(argv[1],"metalfx")) spatial_upscaling(device);
    else if (argc==2 && !strcmp(argv[1],"msaa")) msaa(device);
    else if (argc==2 && !strcmp(argv[1],"clears")) { array_clears(device);attachment_clears(device); }
    else if (argc==2 && !strcmp(argv[1],"heap")) compute(device,true);
    else if (argc==2 && !strcmp(argv[1],"bounded")) compute(device,true,true);
    else if (argc==2 && !strcmp(argv[1],"membership")) descriptor_membership(device);
    else if (argc==2 && !strcmp(argv[1],"state")) { draw_state(device);raster_depth_state(device); }
    else if (argc==2 && !strcmp(argv[1],"specialization")) shader_specialization(device);
    else if (argc==2 && !strcmp(argv[1],"lifetime")) recording_lifetime(device);
    else if (argc==2 && !strcmp(argv[1],"ordering")) { compute(device,true,true);graphics(device);array_clears(device);attachment_clears(device); }
    else if (argc==2 && !strcmp(argv[1],"benchmark")) { draw_state(device,true);descriptor_membership(device,true);raster_depth_state(device); }
    else { recording_lifetime(device);shader_specialization(device);spatial_upscaling(device);compressed_mips(device);depth_planes(device);uav_clears(device);integer_clears(device);compute(device);compute(device,true);graphics(device);array_clears(device);attachment_clears(device);draw_state(device);descriptor_membership(device);raster_depth_state(device);msaa(device);removed(device); }
    device->Release();printf("command_test: %u checks passed\n",checks);return 0;
}}
