#pragma once
#include "common.h"

namespace d3dm {
HRESULT prepare_metal();
struct BufferAddress { id<MTLBuffer> buffer; UINT64 offset; };
BufferAddress resolve_buffer_address(ID3D12Device *device, UINT64 address, UINT64 size);
D3D12_RESOURCE_ALLOCATION_INFO allocation_info(id<MTLDevice> metal, UINT mask, UINT count, const D3D12_RESOURCE_DESC *descs);
D3D12_HEAP_PROPERTIES custom_heap_properties(UINT node, D3D12_HEAP_TYPE type);
HRESULT create_heap(ID3D12Device *device, id<MTLDevice> metal, const D3D12_HEAP_DESC *desc, REFIID iid, void **out);
HRESULT create_committed_resource(ID3D12Device *device, id<MTLDevice> metal, const D3D12_HEAP_PROPERTIES *properties,
    D3D12_HEAP_FLAGS flags, const D3D12_RESOURCE_DESC *desc, D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE *clear,
    REFIID iid, void **out);
HRESULT create_placed_resource(ID3D12Device *device, id<MTLDevice> metal, ID3D12Heap *heap, UINT64 offset,
    const D3D12_RESOURCE_DESC *desc, D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE *clear, REFIID iid, void **out);
}
