#pragma once
#include "common.h"

namespace d3dm {
struct DescriptorUse { UINT parameter,first,count; };
struct PipelineState {
    id<MTLRenderPipelineState> render;
    id<MTLRenderPipelineState> specializedRender;
    UINT specializationParameter=0,specializationIndex=0,specializationOffset=0,specializationValue=0;
    id<MTLComputePipelineState> compute;
    id<MTLDepthStencilState> depth;
    D3D12_RASTERIZER_DESC rasterizer{};
    MTLPrimitiveType primitive=MTLPrimitiveTypeTriangle;
    MTLSize threads=MTLSizeMake(1,1,1);
    uint32_t vertexSlots=0;
    std::vector<DescriptorUse> descriptors;
    bool allDescriptors=false;
    UINT upscaleParameter=UINT_MAX,upscaleIndex=0;
};
HRESULT create_graphics_pipeline(ID3D12Device *device,id<MTLDevice> metal,const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc,REFIID iid,void **out);
HRESULT create_compute_pipeline(ID3D12Device *device,id<MTLDevice> metal,const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc,REFIID iid,void **out);
}
