#pragma once
#include "common.h"

namespace d3dm {
HRESULT create_root_signature(ID3D12Device *device, id<MTLDevice> metal, UINT node_mask,
    const void *blob, SIZE_T size, REFIID iid, void **out);
}
