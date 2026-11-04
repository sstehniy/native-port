#pragma once
#include "common.h"

namespace d3dm {
void release_resource_descriptors(ID3D12Device *device, id<MTLResource> resource);
constexpr UINT descriptor_stride(D3D12_DESCRIPTOR_HEAP_TYPE type) {
    constexpr UINT sizes[] = {24, 24, 18, 18};
    return (UINT)type < 4 ? sizes[(UINT)type] : 0;
}
HRESULT create_descriptor_heap(ID3D12Device *device, id<MTLDevice> metal, const D3D12_DESCRIPTOR_HEAP_DESC *desc, REFIID iid, void **out);
void create_cbv(ID3D12Device *device, const D3D12_CONSTANT_BUFFER_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE dest);
void create_srv(ID3D12Device *device, ID3D12Resource *resource, const D3D12_SHADER_RESOURCE_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE dest);
void create_uav(ID3D12Device *device, ID3D12Resource *resource, ID3D12Resource *counter, const D3D12_UNORDERED_ACCESS_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE dest);
void create_rtv(ID3D12Device *device, ID3D12Resource *resource, const D3D12_RENDER_TARGET_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE dest);
void create_dsv(ID3D12Device *device, ID3D12Resource *resource, const D3D12_DEPTH_STENCIL_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE dest);
void create_sampler(ID3D12Device *device, id<MTLDevice> metal, const D3D12_SAMPLER_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE dest);
HRESULT make_sampler(id<MTLDevice> metal, const D3D12_SAMPLER_DESC &desc, id<MTLSamplerState> *out);
D3DMDescriptorView descriptor_view(ID3D12Device *device,D3D12_CPU_DESCRIPTOR_HANDLE handle,D3D12_DESCRIPTOR_HEAP_TYPE type);
D3D12_UNORDERED_ACCESS_VIEW_DESC clear_uav_desc(ID3D12Device *device,D3D12_CPU_DESCRIPTOR_HANDLE handle,ID3D12Resource *resource);
bool uav_gpu_handle(ID3D12DescriptorHeap *heap,UINT64 address,ID3D12Resource *resource);
D3D12_CONSTANT_BUFFER_VIEW_DESC table_cbv(ID3D12DescriptorHeap *heap,UINT64 address,UINT index);
void use_descriptor_heap(ID3D12DescriptorHeap *heap,id<MTLRenderCommandEncoder> render,id<MTLComputeCommandEncoder> compute,id residency);
bool use_descriptor_range(ID3D12DescriptorHeap *heap,UINT64 address,UINT first,UINT count,id<MTLRenderCommandEncoder> render,id<MTLComputeCommandEncoder> compute,id residency);
void copy_descriptors(ID3D12Device *device, UINT dest_count, const D3D12_CPU_DESCRIPTOR_HANDLE *dest, const UINT *dest_sizes,
    UINT src_count, const D3D12_CPU_DESCRIPTOR_HANDLE *src, const UINT *src_sizes, D3D12_DESCRIPTOR_HEAP_TYPE type);
}
