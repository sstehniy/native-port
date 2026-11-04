#pragma once
#include "common.h"

namespace d3dm {
void signal_removed_fences(ID3D12Device *device);
HRESULT create_command_allocator(ID3D12Device *device,D3D12_COMMAND_LIST_TYPE type,REFIID iid,void **out);
HRESULT create_command_list(ID3D12Device *device,id<MTLDevice> metal,UINT node,D3D12_COMMAND_LIST_TYPE type,ID3D12CommandAllocator *allocator,ID3D12PipelineState *initial,REFIID iid,void **out);
HRESULT create_command_queue(ID3D12Device *device,id<MTLDevice> metal,const D3D12_COMMAND_QUEUE_DESC *desc,REFIID iid,void **out);
HRESULT create_fence(ID3D12Device *device,id<MTLDevice> metal,UINT64 value,D3D12_FENCE_FLAGS flags,REFIID iid,void **out);
HRESULT create_query_heap(ID3D12Device *device,id<MTLDevice> metal,const D3D12_QUERY_HEAP_DESC *desc,REFIID iid,void **out);
HRESULT create_command_signature(ID3D12Device *device,const D3D12_COMMAND_SIGNATURE_DESC *desc,ID3D12RootSignature *root,REFIID iid,void **out);
void copyable_footprints(const D3D12_RESOURCE_DESC *desc,UINT first,UINT count,UINT64 offset,D3D12_PLACED_SUBRESOURCE_FOOTPRINT *layouts,UINT *rows,UINT64 *row_sizes,UINT64 *total);
}
