#include "pipeline.h"
#include "formats.h"
#include <array>
#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <new>
#include <string>
#include <unistd.h>

namespace d3dm {
namespace {
std::mutex archive_mutex;
id<MTLBinaryArchive> archive;
std::string archive_path;
bool archive_dirty=false;
bool archive_write_pending=false;
// Serial, so a scheduled write and a synchronous flush never overlap.
dispatch_queue_t archive_queue() {
    static dispatch_queue_t queue=dispatch_queue_create("d3dm.pipeline-archive",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
    return queue;
}
// Caller holds archive_mutex. Writes a sibling file and renames it, so an interrupted write
// (the game exits with _exit) never leaves a truncated archive at the cached path.
HRESULT write_archive_locked() {
    if (!archive_dirty || !archive) return S_OK;
    const std::string partial=archive_path+".partial.metalarc";
    NSError *error=nil;
    if (![archive serializeToURL:[NSURL fileURLWithPath:@(partial.c_str())] error:&error]) {
        std::fprintf(stderr,"pipeline archive write failed: %s\n",error.localizedDescription.UTF8String);unlink(partial.c_str());return E_FAIL;
    }
    if (rename(partial.c_str(),archive_path.c_str())) {
        std::fprintf(stderr,"pipeline archive write failed: %s\n",std::strerror(errno));unlink(partial.c_str());return E_FAIL;
    }
    archive_dirty=false;return S_OK;
}
id<MTLBinaryArchive> pipeline_archive(id<MTLDevice> metal) {
    if (!host.pipeline_archive) return nil;
    if (archive && archive_path==host.pipeline_archive) return archive;
    archive_path=host.pipeline_archive;archive_dirty=false;
    auto descriptor=[MTLBinaryArchiveDescriptor new];auto url=[NSURL fileURLWithPath:@(archive_path.c_str())];
    if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) descriptor.url=url;
    NSError *error=nil;archive=[metal newBinaryArchiveWithDescriptor:descriptor error:&error];
    if (!archive && descriptor.url) {
        std::fprintf(stderr,"pipeline archive rejected: %s\n",error.localizedDescription.UTF8String);
        descriptor.url=nil;archive=[metal newBinaryArchiveWithDescriptor:descriptor error:&error];
    }
    return archive;
}
class Pipeline final : public Object<ID3D12PipelineState>, public ID3DMPipeline {
public:
    Pipeline(ID3D12Device *device,ID3D12RootSignature *root):device_(device),root_(root) { device_->AddRef(); root_->AddRef(); }
    ~Pipeline() override { root_->Release(); device_->Release(); }
    ULONG STDMETHODCALLTYPE AddRef() override { return Object::AddRef(); }
    ULONG STDMETHODCALLTYPE Release() override { return Object::Release(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **out) override {
        if (out && iid==__uuidof(ID3DMPipeline)) { AddRef(); *out=static_cast<ID3DMPipeline *>(this); return S_OK; }
        return query<IUnknown,ID3D12Object,ID3D12DeviceChild,ID3D12Pageable,ID3D12PipelineState>(iid,out);
    }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID key,UINT *size,void *data) override { return data_.get(key,size,data); }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID key,UINT size,const void *data) override { return data_.set(key,size,data); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID key,const IUnknown *value) override { return data_.set_interface(key,value); }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR name) override { return data_.set(WKPDID_D3DDebugObjectNameW,name?(UINT)((wcslen(name)+1)*sizeof(WCHAR)):0,name); }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID iid,void **out) override { return device_->QueryInterface(iid,out); }
    HRESULT STDMETHODCALLTYPE GetCachedBlob(ID3DBlob **out) override { if (out) *out=nullptr; return E_NOTIMPL; }
    const void *STDMETHODCALLTYPE NativePipelineState() override { return &state_; }
    PipelineState state_;
private:
    ID3D12Device *device_;
    ID3D12RootSignature *root_;
    PrivateData data_;
};
HRESULT shader(id<MTLDevice> metal,ID3D12RootSignature *root,D3D12_SHADER_BYTECODE code,UINT mask,D3DMShader &out) {
    if (!root || !code.pShaderBytecode || !code.BytecodeLength) return E_INVALIDARG;
    if (!host.load_shader) return DXGI_ERROR_UNSUPPORTED;
    ID3DMRootSignature *native=nullptr;
    HRESULT hr=root->QueryInterface(__uuidof(ID3DMRootSignature),(void **)&native);
    if (FAILED(hr)) return E_INVALIDARG;
    const auto &layout=*native->GetLayout();
    hr=host.load_shader((__bridge void *)metal,layout.serialized,layout.serializedSize,code.pShaderBytecode,code.BytecodeLength,mask,&out);
    native->Release();
    if (SUCCEEDED(hr) && (!out.library || !out.entryPoint || !out.reflection)) return E_INVALIDARG;
    return hr;
}
MTLVertexFormat vertex_format(DXGI_FORMAT f) {
    switch (f) {
    case DXGI_FORMAT_R32G32B32A32_FLOAT:return MTLVertexFormatFloat4;
    case DXGI_FORMAT_R32G32B32_FLOAT:return MTLVertexFormatFloat3;
    case DXGI_FORMAT_R32G32_FLOAT:return MTLVertexFormatFloat2;
    case DXGI_FORMAT_R32_FLOAT:return MTLVertexFormatFloat;
    case DXGI_FORMAT_R32G32B32A32_UINT:return MTLVertexFormatUInt4;
    case DXGI_FORMAT_R32G32B32_UINT:return MTLVertexFormatUInt3;
    case DXGI_FORMAT_R32G32_UINT:return MTLVertexFormatUInt2;
    case DXGI_FORMAT_R32_UINT:return MTLVertexFormatUInt;
    case DXGI_FORMAT_R16G16B16A16_FLOAT:return MTLVertexFormatHalf4;
    case DXGI_FORMAT_R16G16_FLOAT:return MTLVertexFormatHalf2;
    case DXGI_FORMAT_R16_FLOAT:return MTLVertexFormatHalf;
    case DXGI_FORMAT_R16G16B16A16_UNORM:return MTLVertexFormatUShort4Normalized;
    case DXGI_FORMAT_R16G16_UNORM:return MTLVertexFormatUShort2Normalized;
    case DXGI_FORMAT_R8G8B8A8_UNORM:return MTLVertexFormatUChar4Normalized;
    case DXGI_FORMAT_R8G8B8A8_UINT:return MTLVertexFormatUChar4;
    case DXGI_FORMAT_R10G10B10A2_UNORM:return MTLVertexFormatUInt1010102Normalized;
    case DXGI_FORMAT_R16G16B16A16_UINT:return MTLVertexFormatUShort4;
    case DXGI_FORMAT_R16G16_UINT:return MTLVertexFormatUShort2;
    default:return MTLVertexFormatInvalid;
    }
}
bool descriptor_usage(const D3DMShader &shader,PipelineState &state) {
    NSData *data=[NSData dataWithBytes:shader.reflection length:strlen(shader.reflection)];
    NSDictionary *json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return false;
    NSArray *resources=json[@"UsedResources"];
    if (!resources) { state.allDescriptors=true;return true; }
    if (![resources isKindOfClass:[NSArray class]]) return false;
    for (NSDictionary *resource in resources) {
        if (![resource isKindOfClass:[NSDictionary class]] || ![resource[@"isInGRS"] isKindOfClass:[NSNumber class]]) return false;
        if (![resource[@"isInGRS"] boolValue]) { state.allDescriptors=true;continue; }
        for (NSString *key in @[@"bindingIndex",@"tableStartIndex",@"tableLength"])
            if (![resource[key] isKindOfClass:[NSNumber class]] || [resource[key] unsignedLongLongValue]>UINT_MAX) return false;
        DescriptorUse use{[resource[@"bindingIndex"] unsignedIntValue],[resource[@"tableStartIndex"] unsignedIntValue],[resource[@"tableLength"] unsignedIntValue]};
        if (!use.count) continue;
        if (std::none_of(state.descriptors.begin(),state.descriptors.end(),[&](const auto &previous) { return previous.parameter==use.parameter && previous.first==use.first && previous.count==use.count; })) state.descriptors.push_back(use);
    }
    return true;
}
bool blend_factor(D3D12_BLEND factor,MTLBlendFactor &out) {
    switch (factor) {
    case D3D12_BLEND_ZERO:out=MTLBlendFactorZero;break;
    case D3D12_BLEND_ONE:out=MTLBlendFactorOne;break;
    case D3D12_BLEND_SRC_COLOR:out=MTLBlendFactorSourceColor;break;
    case D3D12_BLEND_INV_SRC_COLOR:out=MTLBlendFactorOneMinusSourceColor;break;
    case D3D12_BLEND_SRC_ALPHA:out=MTLBlendFactorSourceAlpha;break;
    case D3D12_BLEND_INV_SRC_ALPHA:out=MTLBlendFactorOneMinusSourceAlpha;break;
    case D3D12_BLEND_DEST_ALPHA:out=MTLBlendFactorDestinationAlpha;break;
    case D3D12_BLEND_INV_DEST_ALPHA:out=MTLBlendFactorOneMinusDestinationAlpha;break;
    case D3D12_BLEND_DEST_COLOR:out=MTLBlendFactorDestinationColor;break;
    case D3D12_BLEND_INV_DEST_COLOR:out=MTLBlendFactorOneMinusDestinationColor;break;
    case D3D12_BLEND_SRC_ALPHA_SAT:out=MTLBlendFactorSourceAlphaSaturated;break;
    case D3D12_BLEND_BLEND_FACTOR:out=MTLBlendFactorBlendColor;break;
    case D3D12_BLEND_INV_BLEND_FACTOR:out=MTLBlendFactorOneMinusBlendColor;break;
    case D3D12_BLEND_SRC1_COLOR:out=MTLBlendFactorSource1Color;break;
    case D3D12_BLEND_INV_SRC1_COLOR:out=MTLBlendFactorOneMinusSource1Color;break;
    case D3D12_BLEND_SRC1_ALPHA:out=MTLBlendFactorSource1Alpha;break;
    case D3D12_BLEND_INV_SRC1_ALPHA:out=MTLBlendFactorOneMinusSource1Alpha;break;
    default:return false;
    }
    return true;
}
HRESULT finish(Pipeline *pipeline,REFIID iid,void **out) {
    void *result=nullptr; HRESULT hr=pipeline->QueryInterface(iid,&result);
    if (SUCCEEDED(hr)) { if (out) *out=result; else { ((IUnknown *)result)->Release(); hr=S_FALSE; } }
    pipeline->Release(); return hr;
}
}

HRESULT create_graphics_pipeline(ID3D12Device *device,id<MTLDevice> metal,const D3D12_GRAPHICS_PIPELINE_STATE_DESC *d,REFIID iid,void **out) {
    if (out) *out=nullptr;
    if (!d || !d->pRootSignature || d->NodeMask>1 || d->NumRenderTargets>8 || !d->SampleDesc.Count || d->SampleDesc.Quality ||
        (d->InputLayout.NumElements && !d->InputLayout.pInputElementDescs)) return E_INVALIDARG;
    if (d->GS.BytecodeLength || d->HS.BytecodeLength || d->DS.BytecodeLength || d->StreamOutput.NumEntries || d->SampleMask!=UINT_MAX) return DXGI_ERROR_UNSUPPORTED;
    UINT mask=0;
    for (UINT i=0;i<d->NumRenderTargets;++i) {
        switch (d->RTVFormats[i]) {
        case DXGI_FORMAT_R8G8B8A8_UNORM:case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:case DXGI_FORMAT_R8G8_UNORM:case DXGI_FORMAT_R8_UNORM:
        case DXGI_FORMAT_B8G8R8A8_UNORM:case DXGI_FORMAT_B8G8R8X8_UNORM:case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB:mask|=1u<<i;break;
        default:break;
        }
    }
    D3DMShader vs{},ps{}; HRESULT hr=shader(metal,d->pRootSignature,d->VS,0,vs); if (FAILED(hr)) return hr;
    if (d->PS.BytecodeLength) { hr=shader(metal,d->pRootSignature,d->PS,mask,ps); if (FAILED(hr)) return hr; }
    auto descriptor=[MTLRenderPipelineDescriptor new];
    NSString *label=[(__bridge id<MTLLibrary>)vs.library label];if (label) descriptor.label=label;
    descriptor.vertexFunction=[(__bridge id<MTLLibrary>)vs.library newFunctionWithName:@(vs.entryPoint)];
    if (ps.library) descriptor.fragmentFunction=[(__bridge id<MTLLibrary>)ps.library newFunctionWithName:@(ps.entryPoint)];
    if (!descriptor.vertexFunction || (ps.library && !descriptor.fragmentFunction)) return E_INVALIDARG;
    descriptor.rasterSampleCount=d->SampleDesc.Count;
    descriptor.alphaToCoverageEnabled=d->BlendState.AlphaToCoverageEnable;
    switch (d->PrimitiveTopologyType) {
    case D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT:descriptor.inputPrimitiveTopology=MTLPrimitiveTopologyClassPoint;break;
    case D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE:descriptor.inputPrimitiveTopology=MTLPrimitiveTopologyClassLine;break;
    case D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE:descriptor.inputPrimitiveTopology=MTLPrimitiveTopologyClassTriangle;break;
    default:return DXGI_ERROR_UNSUPPORTED;
    }
    auto *pipeline=new(std::nothrow) Pipeline(device,d->pRootSignature); if (!pipeline) return E_OUTOFMEMORY;
    auto fail=[&](HRESULT reason) { pipeline->Release(); return reason; };
    if (!descriptor_usage(vs,pipeline->state_) || (ps.library && !descriptor_usage(ps,pipeline->state_))) return fail(E_INVALIDARG);
    if (d->InputLayout.NumElements) {
        NSData *data=[NSData dataWithBytes:vs.reflection length:strlen(vs.reflection)];
        NSDictionary *reflection=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *inputs=reflection[@"state"][@"vertex_inputs"];
        if (![inputs isKindOfClass:[NSArray class]]) return fail(E_INVALIDARG);
        auto vertices=[MTLVertexDescriptor vertexDescriptor]; std::array<UINT,32> next{};
        for (UINT i=0;i<d->InputLayout.NumElements;++i) {
            const auto &e=d->InputLayout.pInputElementDescs[i];
            if (!e.SemanticName || e.InputSlot>=25) return fail(E_INVALIDARG);
            const auto format=vertex_format(e.Format); UINT bytes=format_info(e.Format).bytes;
            if (e.Format==DXGI_FORMAT_R32G32B32_FLOAT || e.Format==DXGI_FORMAT_R32G32B32_UINT) bytes=12;
            if (format==MTLVertexFormatInvalid || !bytes) return fail(DXGI_ERROR_UNSUPPORTED);
            UINT offset=e.AlignedByteOffset;
            if (offset==D3D12_APPEND_ALIGNED_ELEMENT) offset=(next[e.InputSlot]+std::min(bytes,4u)-1)&~(std::min(bytes,4u)-1);
            next[e.InputSlot]=offset+bytes;
            NSString *semantic=[[NSString stringWithFormat:@"%s%u",e.SemanticName,e.SemanticIndex] lowercaseString];
            for (NSDictionary *input in inputs) {
                if (![input[@"name"] isEqual:semantic]) continue;
                const NSUInteger attribute=[input[@"index"] unsignedIntegerValue]+11;
                if (attribute>=31) return fail(DXGI_ERROR_UNSUPPORTED);
                vertices.attributes[attribute].format=format; vertices.attributes[attribute].offset=offset; vertices.attributes[attribute].bufferIndex=e.InputSlot+6;
                vertices.layouts[e.InputSlot+6].stride=MTLBufferLayoutStrideDynamic;
                if (e.InputSlotClass==D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA) vertices.layouts[e.InputSlot+6].stepFunction=MTLVertexStepFunctionPerVertex;
                else if (e.InputSlotClass==D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA) {
                    vertices.layouts[e.InputSlot+6].stepFunction=MTLVertexStepFunctionPerInstance; vertices.layouts[e.InputSlot+6].stepRate=e.InstanceDataStepRate;
                } else return fail(E_INVALIDARG);
                pipeline->state_.vertexSlots|=1u<<e.InputSlot;
            }
        }
        descriptor.vertexDescriptor=vertices;
    }
    for (UINT i=0;i<d->NumRenderTargets;++i) {
        auto color=descriptor.colorAttachments[i]; color.pixelFormat=format_info(d->RTVFormats[i]).metal;
        if (color.pixelFormat==MTLPixelFormatInvalid) return fail(DXGI_ERROR_UNSUPPORTED);
        const auto &b=d->BlendState.RenderTarget[d->BlendState.IndependentBlendEnable?i:0];
        if (b.LogicOpEnable) return fail(DXGI_ERROR_UNSUPPORTED);
        color.writeMask=MTLColorWriteMaskNone;
        if (b.RenderTargetWriteMask&1) color.writeMask|=MTLColorWriteMaskRed;
        if (b.RenderTargetWriteMask&2) color.writeMask|=MTLColorWriteMaskGreen;
        if (b.RenderTargetWriteMask&4) color.writeMask|=MTLColorWriteMaskBlue;
        if (b.RenderTargetWriteMask&8) color.writeMask|=MTLColorWriteMaskAlpha;
        color.blendingEnabled=b.BlendEnable;
        if (b.BlendEnable) {
            MTLBlendFactor src,dst,src_alpha,dst_alpha;
            if (!blend_factor(b.SrcBlend,src) || !blend_factor(b.DestBlend,dst) || !blend_factor(b.SrcBlendAlpha,src_alpha) || !blend_factor(b.DestBlendAlpha,dst_alpha) ||
                b.BlendOp<1 || b.BlendOp>5 || b.BlendOpAlpha<1 || b.BlendOpAlpha>5) return fail(E_INVALIDARG);
            color.sourceRGBBlendFactor=src; color.destinationRGBBlendFactor=dst;
            color.sourceAlphaBlendFactor=src_alpha; color.destinationAlphaBlendFactor=dst_alpha;
            color.rgbBlendOperation=(MTLBlendOperation)(b.BlendOp-1); color.alphaBlendOperation=(MTLBlendOperation)(b.BlendOpAlpha-1);
        }
    }
    auto depth=[MTLDepthStencilDescriptor new];
    if (d->DSVFormat!=DXGI_FORMAT_UNKNOWN) {
        const auto format=format_info(d->DSVFormat);
        if (!format.depth || format.metal==MTLPixelFormatInvalid) return fail(E_INVALIDARG);
        descriptor.depthAttachmentPixelFormat=format.metal;
        if (format.planes==2) descriptor.stencilAttachmentPixelFormat=format.metal;
    }
    const auto &s=d->DepthStencilState;
    if (s.DepthEnable && (s.DepthFunc<1 || s.DepthFunc>8 || s.DepthWriteMask>1)) return fail(E_INVALIDARG);
    depth.depthCompareFunction=MTLCompareFunctionAlways;
    if (s.DepthEnable) depth.depthCompareFunction=(MTLCompareFunction)(s.DepthFunc-1);
    depth.depthWriteEnabled=s.DepthEnable && s.DepthWriteMask==D3D12_DEPTH_WRITE_MASK_ALL;
    if (s.StencilEnable) {
        const D3D12_DEPTH_STENCILOP_DESC faces[]={s.FrontFace,s.BackFace};
        for (UINT i=0;i<2;++i) {
            const auto &f=faces[i];
            if (f.StencilFunc<1 || f.StencilFunc>8 || f.StencilFailOp<1 || f.StencilFailOp>8 || f.StencilDepthFailOp<1 || f.StencilDepthFailOp>8 || f.StencilPassOp<1 || f.StencilPassOp>8) return fail(E_INVALIDARG);
            auto face=[MTLStencilDescriptor new]; face.stencilCompareFunction=(MTLCompareFunction)(f.StencilFunc-1);
            face.stencilFailureOperation=(MTLStencilOperation)(f.StencilFailOp-1); face.depthFailureOperation=(MTLStencilOperation)(f.StencilDepthFailOp-1);face.depthStencilPassOperation=(MTLStencilOperation)(f.StencilPassOp-1);
            face.readMask=s.StencilReadMask; face.writeMask=s.StencilWriteMask;
            if (i==0) depth.frontFaceStencil=face; else depth.backFaceStencil=face;
        }
    }
    pipeline->state_.depth=[metal newDepthStencilStateWithDescriptor:depth];
    pipeline->state_.rasterizer=d->RasterizerState;
    if (host.spatial_upscale_source && d->NumRenderTargets==1 && d->SampleDesc.Count==1 &&
        !d->InputLayout.NumElements && !d->DepthStencilState.DepthEnable && !d->DepthStencilState.StencilEnable &&
        !d->BlendState.RenderTarget[0].BlendEnable && d->BlendState.RenderTarget[0].RenderTargetWriteMask==D3D12_COLOR_WRITE_ENABLE_ALL)
    {
        UINT parameter=UINT_MAX,index=0;
        if (host.spatial_upscale_source(d,&parameter,&index)) {
            pipeline->state_.upscaleParameter=parameter;pipeline->state_.upscaleIndex=index;
        }
    }
    NSError *error=nil;
    {
        std::lock_guard lock(archive_mutex);auto cache=pipeline_archive(metal);
        if (cache) {
            descriptor.binaryArchives=@[cache];
            pipeline->state_.render=[metal newRenderPipelineStateWithDescriptor:descriptor options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&error];
            if (!pipeline->state_.render) {
                std::fprintf(stderr,"pipeline archive miss: graphics %s\n",error.localizedDescription.UTF8String);
                if (![cache addRenderPipelineFunctionsWithDescriptor:descriptor error:&error]) return fail(E_FAIL);
                archive_dirty=true;
            }
        }
        if (!pipeline->state_.render) pipeline->state_.render=[metal newRenderPipelineStateWithDescriptor:descriptor error:&error];
    }
    if (!pipeline->state_.render || !pipeline->state_.depth) {
        std::fprintf(stderr,"d3d12-metal pipeline: %s\n",error.localizedDescription.UTF8String); return fail(E_INVALIDARG);
    }
    if (ps.specializedLibrary) {
        if (!ps.specializedEntryPoint) return fail(E_INVALIDARG);
        descriptor.fragmentFunction=[(__bridge id<MTLLibrary>)ps.specializedLibrary newFunctionWithName:@(ps.specializedEntryPoint)];
        NSString *label=[(__bridge id<MTLLibrary>)ps.specializedLibrary label];if (label) descriptor.label=label;
        if (!descriptor.fragmentFunction) return fail(E_INVALIDARG);
        std::lock_guard lock(archive_mutex);auto cache=pipeline_archive(metal);
        if (cache) {
            pipeline->state_.specializedRender=[metal newRenderPipelineStateWithDescriptor:descriptor options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&error];
            if (!pipeline->state_.specializedRender) {
                std::fprintf(stderr,"pipeline archive miss: specialized graphics %s\n",error.localizedDescription.UTF8String);
                if (![cache addRenderPipelineFunctionsWithDescriptor:descriptor error:&error]) return fail(E_FAIL);
                archive_dirty=true;
            }
        }
        if (!pipeline->state_.specializedRender) pipeline->state_.specializedRender=[metal newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline->state_.specializedRender) return fail(E_FAIL);
        pipeline->state_.specializationParameter=ps.specializationParameter;pipeline->state_.specializationIndex=ps.specializationIndex;
        pipeline->state_.specializationOffset=ps.specializationOffset;pipeline->state_.specializationValue=ps.specializationValue;
    }
    return finish(pipeline,iid,out);
}

HRESULT create_compute_pipeline(ID3D12Device *device,id<MTLDevice> metal,const D3D12_COMPUTE_PIPELINE_STATE_DESC *d,REFIID iid,void **out) {
    if (out) *out=nullptr;
    if (!d || !d->pRootSignature || d->NodeMask>1) return E_INVALIDARG;
    D3DMShader cs{}; HRESULT hr=shader(metal,d->pRootSignature,d->CS,0,cs); if (FAILED(hr)) return hr;
    id<MTLFunction> function=[(__bridge id<MTLLibrary>)cs.library newFunctionWithName:@(cs.entryPoint)];
    if (!function || !cs.threads[0] || !cs.threads[1] || !cs.threads[2]) return E_INVALIDARG;
    auto *pipeline=new(std::nothrow) Pipeline(device,d->pRootSignature); if (!pipeline) return E_OUTOFMEMORY;
    if (!descriptor_usage(cs,pipeline->state_)) { pipeline->Release();return E_INVALIDARG; }
    NSError *error=nil;
    {
        std::lock_guard lock(archive_mutex);auto cache=pipeline_archive(metal);
        auto descriptor=[MTLComputePipelineDescriptor new];descriptor.computeFunction=function;
        NSString *label=[(__bridge id<MTLLibrary>)cs.library label];if (label) descriptor.label=label;
        if (cache) {
            descriptor.binaryArchives=@[cache];
            pipeline->state_.compute=[metal newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&error];
            if (!pipeline->state_.compute) {
                std::fprintf(stderr,"pipeline archive miss: compute %s\n",error.localizedDescription.UTF8String);
                if (![cache addComputePipelineFunctionsWithDescriptor:descriptor error:&error]) { pipeline->Release();return E_FAIL; }
                archive_dirty=true;
            }
        }
        if (!pipeline->state_.compute) pipeline->state_.compute=[metal newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
    }
    pipeline->state_.threads=MTLSizeMake(cs.threads[0],cs.threads[1],cs.threads[2]);
    if (!pipeline->state_.compute) {
        std::fprintf(stderr,"d3d12-metal compute pipeline: %s\n",error.localizedDescription.UTF8String); pipeline->Release(); return E_INVALIDARG;
    }
    return finish(pipeline,iid,out);
}
}

extern "C" HRESULT D3DMFlushPipelineArchive() {
    dispatch_sync(d3dm::archive_queue(),^{});  // Finish a scheduled write first.
    std::lock_guard lock(d3dm::archive_mutex);return d3dm::write_archive_locked();
}
extern "C" void D3DMSchedulePipelineArchiveFlush() {
    {
        std::lock_guard lock(d3dm::archive_mutex);
        if (!d3dm::archive_dirty || d3dm::archive_write_pending) return;
        d3dm::archive_write_pending=true;
    }
    dispatch_async(d3dm::archive_queue(),^{
        std::lock_guard lock(d3dm::archive_mutex);d3dm::archive_write_pending=false;d3dm::write_archive_locked();
    });
}
