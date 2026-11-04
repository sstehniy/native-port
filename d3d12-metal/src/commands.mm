#import <MetalFX/MetalFX.h>
#include "commands.h"
#include "descriptors.h"
#include "formats.h"
#include "pipeline.h"
#include "resources.h"
#include "utility.h"
#include <algorithm>
#include <array>
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <new>
#include <optional>
#include <tuple>
#include <ctime>

namespace d3dm {
namespace {
[[noreturn]] void unsupported(const char *method) { std::fprintf(stderr,"d3d12-metal command: %s\n",method);std::abort(); }
void require(bool valid,const char *message) { if (!valid) unsupported(message); }
bool list_type(D3D12_COMMAND_LIST_TYPE type) { return type>=D3D12_COMMAND_LIST_TYPE_DIRECT && type<=D3D12_COMMAND_LIST_TYPE_COPY; }
bool same_device(ID3D12Device *device,ID3D12DeviceChild *child) {
    if (!child) return false;ID3D12Device *owner=nullptr;
    const HRESULT hr=child->GetDevice(__uuidof(ID3D12Device),(void **)&owner);
    const bool same=SUCCEEDED(hr) && owner==device;if (owner) owner->Release();return same;
}
id<MTLBuffer> buffer(ID3D12Resource *resource) {
    ID3DMMetalBuffer *native=nullptr;require(resource && SUCCEEDED(resource->QueryInterface(__uuidof(ID3DMMetalBuffer),(void **)&native)),"expected native buffer");
    auto result=(__bridge id<MTLBuffer>)native->MetalBuffer();native->Release();return result;
}
id<MTLTexture> texture(ID3D12Resource *resource) {
    ID3DMMetalTexture *native=nullptr;require(resource && SUCCEEDED(resource->QueryInterface(__uuidof(ID3DMMetalTexture),(void **)&native)),"expected native texture");
    auto result=(__bridge id<MTLTexture>)native->MetalTexture();native->Release();return result;
}
template<class T> class Child : public Object<T> {
public:
    explicit Child(ID3D12Device *device):device(device) { device->AddRef(); }
    ~Child() override { device->Release(); }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID key,UINT *size,void *out) override { return data.get(key,size,out); }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID key,UINT size,const void *value) override { return data.set(key,size,value); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID key,const IUnknown *value) override { return data.set_interface(key,value); }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR name) override { return data.set(WKPDID_D3DDebugObjectNameW,name?(UINT)((wcslen(name)+1)*sizeof(WCHAR)):0,name); }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID iid,void **out) override { return device->QueryInterface(iid,out); }
    ID3D12Device *device;
    PrivateData data;
};
template<class T> HRESULT finish(T *value,REFIID iid,void **out) {
    void *result=nullptr;HRESULT hr=value->QueryInterface(iid,&result);
    if (SUCCEEDED(hr)) { if (out) *out=result;else { ((IUnknown *)result)->Release();hr=S_FALSE; } }
    value->Release();return hr;
}
class CommandList;
class Allocator final : public Child<ID3D12CommandAllocator> {
public:
    Allocator(ID3D12Device *device,D3D12_COMMAND_LIST_TYPE type):Child(device),type(type) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **out) override { return query<IUnknown,ID3D12Object,ID3D12DeviceChild,ID3D12Pageable,ID3D12CommandAllocator>(iid,out); }
    HRESULT STDMETHODCALLTYPE Reset() override;
    void detach(CommandList *list) { std::lock_guard guard(mutex);std::erase(lists,list); }
    D3D12_COMMAND_LIST_TYPE type;
    std::atomic<UINT> open{0};
    std::atomic<UINT64> generation{0};
    std::mutex mutex;
    std::vector<CommandList *> lists;
};
class Fence;
// One listener serves every fence wait; its blocks still run on the same concurrent global queue.
MTLSharedEventListener *fence_listener() {
    static MTLSharedEventListener *listener=[[MTLSharedEventListener alloc] initWithDispatchQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0)];
    return listener;
}
std::mutex fence_mutex;
std::multimap<ID3D12Device *,Fence *> device_fences;
class Fence final : public Child<ID3D12Fence> {
public:
    Fence(ID3D12Device *device,id<MTLDevice> metal,UINT64 value):Child(device),event([metal newSharedEvent]),last(value) {
        event.signaledValue=value;std::lock_guard lock(fence_mutex);device_fences.emplace(device,this);
        if (FAILED(device->GetDeviceRemovedReason())) event.signaledValue=UINT64_MAX;
    }
    ~Fence() override {
        std::lock_guard lock(fence_mutex);auto range=device_fences.equal_range(device);
        for (auto i=range.first;i!=range.second;++i) if (i->second==this) { device_fences.erase(i);break; }
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **out) override { return query<IUnknown,ID3D12Object,ID3D12DeviceChild,ID3D12Pageable,ID3D12Fence>(iid,out); }
    UINT64 STDMETHODCALLTYPE GetCompletedValue() override { return FAILED(device->GetDeviceRemovedReason())?UINT64_MAX:event.signaledValue; }
    HRESULT STDMETHODCALLTYPE SetEventOnCompletion(UINT64 value,HANDLE handle) override {
        const auto hooks=host;
        if (handle) {
            if (!hooks.duplicate_event || !hooks.signal_event || !hooks.close_handle) return DXGI_ERROR_UNSUPPORTED;
            HANDLE retained=hooks.duplicate_event(handle);if (!retained) return E_INVALIDARG;
            if (GetCompletedValue()>=value) { hooks.signal_event(retained);hooks.close_handle(retained);return S_OK; }
            [event notifyListener:fence_listener() atValue:value block:^(id<MTLSharedEvent>,uint64_t) { hooks.signal_event(retained);hooks.close_handle(retained); }];
        } else if (GetCompletedValue()<value) {
            dispatch_semaphore_t ready=dispatch_semaphore_create(0);
            [event notifyListener:fence_listener() atValue:value block:^(id<MTLSharedEvent>,uint64_t) { dispatch_semaphore_signal(ready); }];
            dispatch_semaphore_wait(ready,DISPATCH_TIME_FOREVER);
        }
        return S_OK;
    }
    HRESULT reserve(UINT64 value) {
        const HRESULT reason=device->GetDeviceRemovedReason();if (FAILED(reason)) return reason;
        if (value==UINT64_MAX) return E_INVALIDARG;
        // shortcut: timelines increase monotonically; use sequence tickets if a caller rewinds a fence.
        UINT64 previous=last.load();
        do { if (value<previous) return E_INVALIDARG; } while (!last.compare_exchange_weak(previous,value));
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Signal(UINT64 value) override { const HRESULT hr=reserve(value);if (FAILED(hr)) return hr;event.signaledValue=value;return S_OK; }
    id<MTLSharedEvent> event;
    std::atomic<UINT64> last;
};
struct Attachment {
    id<MTLTexture> texture;
    UINT depthPlane=0,depthCount=1;
    D3D12_DSV_FLAGS flags=D3D12_DSV_FLAG_NONE;
};
Attachment attachment(ID3D12Device *device,D3D12_CPU_DESCRIPTOR_HANDLE handle,D3D12_DESCRIPTOR_HEAP_TYPE type) {
    const auto view=descriptor_view(device,handle,type);
    require(view.resource,"null render attachment");return {(__bridge id<MTLTexture>)view.resource,view.depthPlane,view.depthCount,view.depthFlags};
}
struct RootArguments {
    ID3D12RootSignature *signature=nullptr;
    std::vector<uint8_t> bytes;
    const D3DMRootSignatureLayout *layout=nullptr;
    bool dirty=true;
    void set(ID3D12RootSignature *root) {
        if (signature==root) return;signature=root;dirty=true;bytes.clear();layout=nullptr;if (!root) return;
        ID3DMRootSignature *native=nullptr;require(SUCCEEDED(root->QueryInterface(__uuidof(ID3DMRootSignature),(void **)&native)),"foreign root signature");
        layout=native->GetLayout();bytes.resize(layout->argumentBufferSize);
        if (layout->staticSamplers) {
            const uint64_t address=((__bridge id<MTLBuffer>)layout->staticSamplers).gpuAddress;
            memcpy(bytes.data()+layout->staticSamplerOffset,&address,8);
        }
        native->Release();
    }
    void constants(UINT index,UINT offset,const std::vector<UINT> &values) {
        require(layout && index<layout->desc.NumParameters,"root constant index");const auto &p=layout->desc.pParameters[index];
        require(p.ParameterType==D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS && offset<=p.Constants.Num32BitValues && values.size()<=p.Constants.Num32BitValues-offset,"root constant range");
        if (!values.empty()) {
            auto *destination=bytes.data()+layout->parameterOffsets[index]+offset*4;
            if (memcmp(destination,values.data(),values.size()*4)) { memcpy(destination,values.data(),values.size()*4);dirty=true; }
        }
    }
    void address(UINT index,UINT64 address,D3D12_ROOT_PARAMETER_TYPE expected) {
        require(layout && index<layout->desc.NumParameters && layout->desc.pParameters[index].ParameterType==expected,"root address index/type");
        auto *destination=bytes.data()+layout->parameterOffsets[index];
        if (memcmp(destination,&address,8)) { memcpy(destination,&address,8);dirty=true; }
    }
};
using ClearKey=std::tuple<uintptr_t,NSUInteger,NSUInteger>;
ClearKey clear_key(id<MTLTexture> view,NSUInteger slice=0) {
    NSUInteger level=0;
    while (view.parentTexture) { level+=view.parentRelativeLevel;slice+=view.parentRelativeSlice;view=view.parentTexture; }
    return {(uintptr_t)(__bridge void *)view,level,slice};
}
bool same_attachment(const Attachment &a,const Attachment &b) {
    return a.depthPlane==b.depthPlane && a.depthCount==b.depthCount && a.flags==b.flags &&
        (a.texture==b.texture || (clear_key(a.texture)==clear_key(b.texture) &&
            a.texture.pixelFormat==b.texture.pixelFormat && a.texture.textureType==b.texture.textureType && a.texture.arrayLength==b.texture.arrayLength));
}
struct Clear { Attachment target;bool depth=false;D3D12_CLEAR_FLAGS flags{};std::array<float,4> color{};float z=1;UINT stencil=0;NSUInteger slice=0; };
bool cleared_attachment(const Attachment &attachment,const Clear &clear) {
    const auto [resource,mip,slice]=clear_key(attachment.texture);
    const auto [target,level,first]=clear_key(clear.target.texture);
    if (!resource || resource!=target || mip!=level || slice<first || slice-first>=clear.target.texture.arrayLength) return false;
    if (clear.target.texture.textureType==MTLTextureType3D)
        return attachment.depthPlane>=clear.target.depthPlane && attachment.depthPlane-clear.target.depthPlane<clear.target.depthCount;
    return true;
}
struct Resolve { ID3D12Resource *destination,*source;UINT destinationIndex,sourceIndex;DXGI_FORMAT format; };
struct ClearUAV {
    ID3D12Resource *resource;
    D3D12_GPU_DESCRIPTOR_HANDLE gpu;
    D3D12_UNORDERED_ACCESS_VIEW_DESC desc;
    id<MTLTexture> texture;
    std::array<UINT,4> values;
    std::vector<D3D12_RECT> rects;
    bool floating;
};
std::array<uint8_t,16> uint_pattern(DXGI_FORMAT format,const std::array<UINT,4> &values) {
    std::array<uint8_t,16> pattern{};const auto info=format_info(format);UINT bits=0;
    switch (info.family) {
    case DXGI_FORMAT_R32G32B32A32_TYPELESS:case DXGI_FORMAT_R32G32_TYPELESS:case DXGI_FORMAT_R32_TYPELESS:bits=32;break;
    case DXGI_FORMAT_R16G16B16A16_TYPELESS:case DXGI_FORMAT_R16G16_TYPELESS:case DXGI_FORMAT_R16_TYPELESS:bits=16;break;
    case DXGI_FORMAT_R8G8B8A8_TYPELESS:case DXGI_FORMAT_R8G8_TYPELESS:case DXGI_FORMAT_R8_TYPELESS:bits=8;break;
    case DXGI_FORMAT_R10G10B10A2_TYPELESS: {
        const UINT packed=(values[0]&1023)|((values[1]&1023)<<10)|((values[2]&1023)<<20)|((values[3]&3)<<30);
        memcpy(pattern.data(),&packed,4);return pattern;
    }
    case DXGI_FORMAT_R11G11B10_FLOAT: {
        const UINT packed=(values[0]&2047)|((values[1]&2047)<<11)|((values[2]&1023)<<22);
        memcpy(pattern.data(),&packed,4);return pattern;
    }
    default:unsupported("UAV integer clear format");
    }
    require(info.bytes && info.bytes<=16 && info.block==1,"UAV clear pixel width");
    for (UINT i=0;i<info.bytes/(bits/8);++i) memcpy(pattern.data()+i*(bits/8),&values[i],bits/8);
    return pattern;
}
class QueryHeap final : public Child<ID3D12QueryHeap> {
public:
    QueryHeap(ID3D12Device *device,D3D12_QUERY_HEAP_DESC desc):Child(device),desc(desc) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **out) override { return query<IUnknown,ID3D12Object,ID3D12DeviceChild,ID3D12Pageable,ID3D12QueryHeap>(iid,out); }
    void validate(D3D12_QUERY_TYPE type,UINT index,UINT count=1) {
        const bool timestamp=type==D3D12_QUERY_TYPE_TIMESTAMP;
        require(index<=desc.Count && count<=desc.Count-index &&
            ((timestamp && (desc.Type==D3D12_QUERY_HEAP_TYPE_TIMESTAMP || desc.Type==D3D12_QUERY_HEAP_TYPE_COPY_QUEUE_TIMESTAMP)) ||
             (!timestamp && desc.Type==D3D12_QUERY_HEAP_TYPE_OCCLUSION && (type==D3D12_QUERY_TYPE_OCCLUSION || type==D3D12_QUERY_TYPE_BINARY_OCCLUSION))),"query type/range");
    }
    D3D12_QUERY_HEAP_DESC desc;
    id<MTLCounterSampleBuffer> timestamps;
    id<MTLBuffer> visibility;
};
class Signature final : public Child<ID3D12CommandSignature> {
public:
    Signature(ID3D12Device *device,UINT stride,D3D12_INDIRECT_ARGUMENT_TYPE type):Child(device),stride(stride),type(type) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **out) override { return query<IUnknown,ID3D12Object,ID3D12DeviceChild,ID3D12Pageable,ID3D12CommandSignature>(iid,out); }
    UINT stride;
    D3D12_INDIRECT_ARGUMENT_TYPE type;
};

class SpatialUpscaler {
public:
    bool prepare(id<MTLDevice> metal,id<MTLTexture> input,id<MTLTexture> output) {
        if (input.sampleCount!=1 || output.sampleCount!=1 || input.arrayLength!=1 || output.arrayLength!=1 ||
            input.width>=output.width || input.height>=output.height || input.pixelFormat!=output.pixelFormat ||
            (input.pixelFormat!=MTLPixelFormatRGBA8Unorm_sRGB && input.pixelFormat!=MTLPixelFormatBGRA8Unorm_sRGB) ||
            ![MTLFXSpatialScalerDescriptor supportsDevice:metal]) return false;
        if (!scaler || scaler.inputWidth!=input.width || scaler.inputHeight!=input.height ||
            scaler.outputWidth!=output.width || scaler.outputHeight!=output.height || scaler.colorTextureFormat!=input.pixelFormat) {
            auto desc=[MTLFXSpatialScalerDescriptor new];
            desc.inputWidth=input.width;desc.inputHeight=input.height;
            desc.outputWidth=output.width;desc.outputHeight=output.height;
            desc.colorTextureFormat=input.pixelFormat;desc.outputTextureFormat=output.pixelFormat;
            desc.colorProcessingMode=MTLFXSpatialScalerColorProcessingModePerceptual;
            scaler=[desc newSpatialScalerWithDevice:metal];
            if (!scaler) return false;
            auto texture=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:output.pixelFormat width:output.width height:output.height mipmapped:NO];
            texture.storageMode=MTLStorageModePrivate;texture.usage=scaler.outputTextureUsage;
            scaled=[metal newTextureWithDescriptor:texture];
            if (!scaled) { scaler=nil;return false; }
            scaled.label=@"MetalFX spatial output";
            fprintf(stderr,"MetalFX spatial: %lux%lu -> %lux%lu\n",(unsigned long)input.width,(unsigned long)input.height,(unsigned long)output.width,(unsigned long)output.height);
        }
        if ((input.usage&scaler.colorTextureUsage)!=scaler.colorTextureUsage) return false;
        color=texture_2d(input);destination=texture_2d(output);
        return color && destination;
    }
    void encode(id<MTLCommandBuffer> commands,id<MTLFence> fence,bool wait) {
        scaler.colorTexture=color;scaler.outputTexture=scaled;
        scaler.inputContentWidth=color.width;scaler.inputContentHeight=color.height;scaler.fence=wait?fence:nil;
        [scaler encodeToCommandBuffer:commands];
        auto blit=[commands blitCommandEncoder];
        if (wait) [blit waitForFence:fence];
        [blit copyFromTexture:scaled sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                  sourceSize:MTLSizeMake(scaled.width,scaled.height,1) toTexture:destination destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [blit updateFence:fence];
        [blit endEncoding];
    }
private:
    static id<MTLTexture> texture_2d(id<MTLTexture> texture) {
        if (texture.textureType==MTLTextureType2D) return texture;
        if (texture.textureType!=MTLTextureType2DArray) return nil;
        return [texture newTextureViewWithPixelFormat:texture.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0,1) slices:NSMakeRange(0,1)];
    }
    id<MTLFXSpatialScaler> scaler;
    id<MTLTexture> scaled,color,destination;
};

class Replay {
public:
    Replay(ID3D12Device *device,id<MTLDevice> metal,id<MTLCommandBuffer> commands,SpatialUpscaler &upscaler,bool snapshotUploads):device(device),metal(metal),commands(commands),fence([metal newFence]),snapshotUploads(snapshotUploads),upscaler(upscaler) {
        if (@available(macOS 15.0,*)) {
            auto descriptor=[MTLResidencySetDescriptor new];descriptor.initialCapacity=64;
            residentSet=[metal newResidencySetWithDescriptor:descriptor error:nil];if (residentSet) [commands useResidencySet:residentSet];
        }
    }
    void end(bool final=false) {
        if (render) {
            require(!renderResolve,"render resolve planning interrupted");
            if (applied.deferredStores) {
                for (size_t i=0;i<applied.colors.size();++i) [render setColorStoreAction:applied.colorStores[i] atIndex:i];
                if (applied.depth.texture) {
                    [render setDepthStoreAction:applied.depthStore];
                    const auto format=applied.depth.texture.pixelFormat;
                    if (format==MTLPixelFormatDepth32Float_Stencil8 || format==format_info(DXGI_FORMAT_D24_UNORM_S8_UINT).metal) [render setStencilStoreAction:applied.stencilStore];
                }
            }
            if (!final) [render updateFence:fence afterStages:MTLRenderStageFragment];[render endEncoding];render=nil;applied={};graphics.dirty=true;haveFence=true;
        }
        if (compute) { if (!final) [compute updateFence:fence];[compute endEncoding];compute=nil;computeApplied={};computeRoot.dirty=true;haveFence=true; }
        if (blit) { if (!final) [blit updateFence:fence];[blit endEncoding];blit=nil;haveFence=true; }
    }
    id<MTLBlitCommandEncoder> copies() {
        if (!blit) { end();blit=[commands blitCommandEncoder];if (haveFence) [blit waitForFence:fence]; }return blit;
    }
    void clear(Clear value) {
        if (render) {
            bool overwritten=false;
            if (value.depth && cleared_attachment(applied.depth,value)) {
                if (value.flags&D3D12_CLEAR_FLAG_DEPTH) applied.depthStore=MTLStoreActionDontCare;
                if (value.flags&D3D12_CLEAR_FLAG_STENCIL) applied.stencilStore=MTLStoreActionDontCare;
                overwritten=true;
            }
            if (!value.depth) for (size_t i=0;i<applied.colors.size();++i) if (cleared_attachment(applied.colors[i],value)) {
                applied.colorStores[i]=MTLStoreActionDontCare;overwritten=true;
            }
            if (overwritten) end();
        } else end();
        for (NSUInteger slice=0;slice<value.target.texture.arrayLength;++slice) {
            auto pending=value;pending.slice=slice;const auto key=clear_key(value.target.texture,slice);
            auto previous=clears.find(key);
            if (pending.depth && previous!=clears.end() && previous->second.depth) {
                if (!(pending.flags&D3D12_CLEAR_FLAG_DEPTH)) pending.z=previous->second.z;
                if (!(pending.flags&D3D12_CLEAR_FLAG_STENCIL)) pending.stencil=previous->second.stencil;
                pending.flags=(D3D12_CLEAR_FLAGS)(pending.flags|previous->second.flags);
            }
            clears[key]=pending;
        }
        if (value.target.texture.textureType==MTLTextureType3D) flush_clears();
    }
    void flush_clears(id<MTLTexture> selected=nil) {
        const auto resource=std::get<0>(clear_key(selected));
        auto matches=[&](const auto &entry) { return !selected || std::get<0>(entry.first)==resource; };
        if (std::none_of(clears.begin(),clears.end(),matches)) return;end();
        for (auto it=clears.begin();it!=clears.end();) {
          if (!matches(*it)) { ++it;continue; }const auto &c=it->second;
          std::array<ClearKey,7> merged{};size_t mergedCount=0;
          const bool volume=c.target.texture.textureType==MTLTextureType3D;
          const NSUInteger layers=volume?c.target.depthCount:1;
          for (NSUInteger layer=0;layer<layers;++layer) {
            auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
            if (c.depth) {
                pass.depthAttachment.texture=c.target.texture;
                pass.depthAttachment.slice=c.slice;
                pass.depthAttachment.loadAction=(c.flags&D3D12_CLEAR_FLAG_DEPTH)?MTLLoadActionClear:MTLLoadActionLoad;
                pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=c.z;
                const bool stencil=c.target.texture.pixelFormat==MTLPixelFormatDepth32Float_Stencil8 || c.target.texture.pixelFormat==format_info(DXGI_FORMAT_D24_UNORM_S8_UINT).metal;
                if (stencil) { pass.stencilAttachment.texture=c.target.texture;pass.stencilAttachment.clearStencil=c.stencil;
                    pass.stencilAttachment.slice=c.slice;
                    pass.stencilAttachment.loadAction=(c.flags&D3D12_CLEAR_FLAG_STENCIL)?MTLLoadActionClear:MTLLoadActionLoad;pass.stencilAttachment.storeAction=MTLStoreActionStore; }
            } else {
                pass.colorAttachments[0].texture=c.target.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
                if (volume) pass.colorAttachments[0].depthPlane=c.target.depthPlane+layer;
                else pass.colorAttachments[0].slice=c.slice;
                pass.colorAttachments[0].clearColor=MTLClearColorMake(c.color[0],c.color[1],c.color[2],c.color[3]);
                // shortcut: batching may forgo a later clear-load fusion; add access lookahead only if measured bandwidth regresses.
                if (!volume) for (auto other=clears.begin();other!=clears.end() && mergedCount<merged.size();++other) {
                    const auto &v=other->second;const auto a=v.target.texture,b=c.target.texture;
                    if (other==it || v.depth || a.textureType!=b.textureType || a.width!=b.width || a.height!=b.height || a.sampleCount!=b.sampleCount) continue;
                    auto attachment=pass.colorAttachments[++mergedCount];attachment.texture=a;attachment.slice=v.slice;
                    attachment.loadAction=MTLLoadActionClear;attachment.storeAction=MTLStoreActionStore;
                    attachment.clearColor=MTLClearColorMake(v.color[0],v.color[1],v.color[2],v.color[3]);merged[mergedCount-1]=other->first;
                }
            }
            id<MTLRenderCommandEncoder> encoder=[commands renderCommandEncoderWithDescriptor:pass];
            if (haveFence) [encoder waitForFence:fence beforeStages:MTLRenderStageVertex];[encoder updateFence:fence afterStages:MTLRenderStageFragment];[encoder endEncoding];haveFence=true;
          }
          for (size_t i=0;i<mergedCount;++i) clears.erase(merged[i]);
          it=clears.erase(it);
        }
    }
    auto pending_clear(const Attachment &target) {
        auto found=clears.find(clear_key(target.texture));
        if (found!=clears.end() && found->second.target.texture.pixelFormat!=target.texture.pixelFormat) {
            flush_clears(target.texture);return clears.end();
        }
        return found;
    }
    void partial_clear(const Clear &value,const std::vector<D3D12_RECT> &rects) {
        flush_clears(value.target.texture);end();const auto target=value.target.texture;
        const bool stencil=target.pixelFormat==MTLPixelFormatDepth32Float_Stencil8 || target.pixelFormat==format_info(DXGI_FORMAT_D24_UNORM_S8_UINT).metal;
        const bool volume=target.textureType==MTLTextureType3D;const NSUInteger layers=volume?value.target.depthCount:target.arrayLength;
        auto pipeline=utility_clear(metal,value.depth?MTLPixelFormatInvalid:target.pixelFormat,value.depth?target.pixelFormat:MTLPixelFormatInvalid,target.sampleCount);
        auto desc=[MTLDepthStencilDescriptor new];desc.depthCompareFunction=MTLCompareFunctionAlways;desc.depthWriteEnabled=value.depth && (value.flags&D3D12_CLEAR_FLAG_DEPTH);
        if (value.depth && (value.flags&D3D12_CLEAR_FLAG_STENCIL)) {
            auto state=[MTLStencilDescriptor new];state.stencilCompareFunction=MTLCompareFunctionAlways;state.depthStencilPassOperation=MTLStencilOperationReplace;
            desc.frontFaceStencil=state;desc.backFaceStencil=state;
        }
        auto depth=[metal newDepthStencilStateWithDescriptor:desc];
        for (NSUInteger layer=0;layer<layers;++layer) {
            auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
            if (value.depth) {
                pass.depthAttachment.texture=target;pass.depthAttachment.slice=layer;pass.depthAttachment.loadAction=MTLLoadActionLoad;pass.depthAttachment.storeAction=MTLStoreActionStore;
                if (stencil) { pass.stencilAttachment.texture=target;pass.stencilAttachment.slice=layer;pass.stencilAttachment.loadAction=MTLLoadActionLoad;pass.stencilAttachment.storeAction=MTLStoreActionStore; }
            } else {
                pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionLoad;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
                if (volume) pass.colorAttachments[0].depthPlane=value.target.depthPlane+layer;else pass.colorAttachments[0].slice=layer;
            }
            render=[commands renderCommandEncoderWithDescriptor:pass];if (haveFence) [render waitForFence:fence beforeStages:MTLRenderStageVertex];
            [render setRenderPipelineState:pipeline];[render setDepthStencilState:depth];[render setStencilReferenceValue:value.stencil];[render setCullMode:MTLCullModeNone];
            [render setViewport:MTLViewport{0,0,(double)target.width,(double)target.height,0,1}];
            [render setVertexBytes:&value.z length:sizeof value.z atIndex:0];if (!value.depth) [render setFragmentBytes:value.color.data() length:16 atIndex:0];
            for (const auto &rect:rects) {
                const NSInteger x=std::clamp<NSInteger>(rect.left,0,target.width),y=std::clamp<NSInteger>(rect.top,0,target.height);
                const NSInteger right=std::clamp<NSInteger>(rect.right,x,target.width),bottom=std::clamp<NSInteger>(rect.bottom,y,target.height);
                if (x==right || y==bottom) continue;
                [render setScissorRect:MTLScissorRect{(NSUInteger)x,(NSUInteger)y,(NSUInteger)(right-x),(NSUInteger)(bottom-y)}];
                [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            }
            end();
        }
    }
    void targets(std::vector<Attachment> colors,Attachment depth) {
        bool same=colors.size()==applied.colors.size() && same_attachment(depth,applied.depth);
        if (same) for (size_t i=0;i<colors.size();++i) if (!same_attachment(colors[i],applied.colors[i])) same=false;
        applied.targetsChanged=!same;
        colors_=std::move(colors);depth_=depth;
    }
    bool resolve_source(id<MTLTexture> view,const Resolve &value) {
        if (view.sampleCount<=1 || view.arrayLength!=1 || view.pixelFormat!=format_info(value.format).metal) return false;
        NSUInteger mip=0,slice=0;
        while (view.parentTexture) { mip+=view.parentRelativeLevel;slice+=view.parentRelativeSlice;view=view.parentTexture; }
        const auto source=subresource(value.source,value.sourceIndex);
        return view==texture(value.source) && mip==source.mip && slice==source.slice;
    }
    id<MTLTexture> resolve_texture(ID3D12Resource *resource,DXGI_FORMAT format) {
        auto result=texture(resource);const auto pixel=format_info(format).metal;
        if (result.pixelFormat!=pixel) result=[result newTextureViewWithPixelFormat:pixel];
        require(result!=nil,"resolve format view");return result;
    }
    void validate_resolve(const Resolve &value) {
        const auto a=subresource(value.source,value.sourceIndex),b=subresource(value.destination,value.destinationIndex);
        const auto source=value.source->GetDesc(),destination=value.destination->GetDesc();const auto format=format_info(value.format);
        require(source.Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE2D && destination.Dimension==source.Dimension && source.SampleDesc.Count>1 && destination.SampleDesc.Count==1 &&
            a.size.width==b.size.width && a.size.height==b.size.height && format.metal!=MTLPixelFormatInvalid && !format.typeless && !format.depth && format.block==1 &&
            format.family==format_info(source.Format).family && format.family==format_info(destination.Format).family,"resolve samples/dimensions/format");
    }
    void resolve_destination(MTLRenderPassColorAttachmentDescriptor *color,const Resolve &value) {
        validate_resolve(value);
        const auto destination=subresource(value.destination,value.destinationIndex);
        color.resolveTexture=resolve_texture(value.destination,value.format);color.resolveLevel=destination.mip;color.resolveSlice=destination.slice;
    }
    void begin_render() {
        if (render && !applied.targetsChanged) return;
        end();auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
        if (activeQuery) { pass.visibilityResultBuffer=activeQuery->visibility;if (@available(macOS 26.0,*)) pass.visibilityResultType=MTLVisibilityResultTypeAccumulate; }
        for (size_t i=0;i<colors_.size();++i) {
            auto a=pass.colorAttachments[i];const auto &t=colors_[i];a.texture=t.texture;a.depthPlane=t.depthPlane;a.loadAction=MTLLoadActionLoad;a.storeAction=MTLStoreActionUnknown;applied.colorStores[i]=MTLStoreActionStore;
            auto found=pending_clear(t);
            if (found!=clears.end()) { const auto &v=found->second.color;a.loadAction=MTLLoadActionClear;a.clearColor=MTLClearColorMake(v[0],v[1],v[2],v[3]);clears.erase(found); }
            if (plannedResolve && !renderResolve && resolve_source(t.texture,*plannedResolve)) {
                flush_clears(texture(plannedResolve->destination));
                resolve_destination(a,*plannedResolve);applied.colorStores[i]=MTLStoreActionStoreAndMultisampleResolve;renderResolve=*plannedResolve;
            }
        }
        if (depth_.texture) {
            auto a=pass.depthAttachment;a.texture=depth_.texture;a.loadAction=MTLLoadActionLoad;a.storeAction=MTLStoreActionUnknown;
            const bool stencil=depth_.texture.pixelFormat==format_info(DXGI_FORMAT_D24_UNORM_S8_UINT).metal || depth_.texture.pixelFormat==MTLPixelFormatDepth32Float_Stencil8;
            if (stencil) { pass.stencilAttachment.texture=depth_.texture;pass.stencilAttachment.loadAction=MTLLoadActionLoad;pass.stencilAttachment.storeAction=MTLStoreActionUnknown; }
            auto found=pending_clear(depth_);
            if (found!=clears.end()) { const auto &c=found->second;
                if (c.flags&D3D12_CLEAR_FLAG_DEPTH) { a.loadAction=MTLLoadActionClear;a.clearDepth=c.z; }
                if (stencil && (c.flags&D3D12_CLEAR_FLAG_STENCIL)) { pass.stencilAttachment.loadAction=MTLLoadActionClear;pass.stencilAttachment.clearStencil=c.stencil; }
                clears.erase(found);
            }
        }
        render=[commands renderCommandEncoderWithDescriptor:pass];require(render!=nil,"render encoder creation");
        // Metal permits late store choices only for attachments created with Unknown.
        applied.deferredStores=true;
        applied.colors=colors_;applied.depth=depth_;applied.targetsChanged=false;
        if (haveFence) [render waitForFence:fence beforeStages:MTLRenderStageVertex];
    }
    const PipelineState &pipeline() {
        require(pso,"missing pipeline");
        if (cachedPso!=pso) {
            ID3DMPipeline *native=nullptr;
            require(SUCCEEDED(pso->QueryInterface(__uuidof(ID3DMPipeline),(void **)&native)),"foreign pipeline");
            cachedPipeline=(const PipelineState *)native->NativePipelineState();native->Release();cachedPso=pso;
        }
        return *cachedPipeline;
    }
    void residency(RootArguments &root,id<MTLRenderCommandEncoder> r,id<MTLComputeCommandEncoder> c) {
        require(root.layout,"missing root signature");
        const auto &state=pipeline();
        const auto flags=root.layout->desc.Flags;
        const bool directHeap=flags&(D3D12_ROOT_SIGNATURE_FLAG_CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED|D3D12_ROOT_SIGNATURE_FLAG_SAMPLER_HEAP_DIRECTLY_INDEXED);
        if (state.allDescriptors || directHeap) { for (auto *heap:heaps) use_descriptor_heap(heap,r,c,residentSet); }
        else for (const auto &use:state.descriptors) {
            if (use.parameter>=root.layout->desc.NumParameters) continue;
            if (root.layout->desc.pParameters[use.parameter].ParameterType!=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE) continue;
            UINT64 address=0;memcpy(&address,root.bytes.data()+root.layout->parameterOffsets[use.parameter],8);
            bool found=false;
            for (auto *heap:heaps) if (use_descriptor_range(heap,address,use.first,use.count,r,c,residentSet)) { found=true;break; }
            require(found,"root table is outside the bound descriptor heaps");
        }
        if (root.layout->staticSamplers) { auto resource=(__bridge id<MTLBuffer>)root.layout->staticSamplers;
            if (r) [r useResource:resource usage:MTLResourceUsageRead stages:MTLRenderStageVertex|MTLRenderStageFragment];if (c) [c useResource:resource usage:MTLResourceUsageRead]; }
        for (UINT i=0;i<root.layout->desc.NumParameters;++i) {
            const auto type=root.layout->desc.pParameters[i].ParameterType;
            if (type<D3D12_ROOT_PARAMETER_TYPE_CBV) continue;
            UINT64 address=0;memcpy(&address,root.bytes.data()+root.layout->parameterOffsets[i],8);if (!address) continue;
            auto resource=resolve_buffer_address(device,address,1).buffer;require(resource!=nil,"root buffer address");
            const auto usage=type==D3D12_ROOT_PARAMETER_TYPE_UAV?(MTLResourceUsageRead|MTLResourceUsageWrite):MTLResourceUsageRead;
            if (r) [r useResource:resource usage:usage stages:MTLRenderStageVertex|MTLRenderStageFragment];if (c) [c useResource:resource usage:usage];
        }
    }
    void bind_heaps() {
        if (render && applied.heaps==heaps) return;
        if (compute && computeApplied.heaps==heaps) return;
        for (auto *heap:heaps) {
            ID3DMDescriptorHeap *native=nullptr;require(SUCCEEDED(heap->QueryInterface(__uuidof(ID3DMDescriptorHeap),(void **)&native)),"foreign descriptor heap");
            auto table=(__bridge id<MTLBuffer>)native->MetalDescriptorBuffer();native->Release();
            const NSUInteger index=heap->GetDesc().Type==D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER?1:0;
            if (render) { [render setVertexBuffer:table offset:0 atIndex:index];[render setFragmentBuffer:table offset:0 atIndex:index]; }
            if (compute) [compute setBuffer:table offset:0 atIndex:index];
        }
        if (render) applied.heaps=heaps;
        if (compute) computeApplied.heaps=heaps;
    }
    MTLPrimitiveType primitive() {
        switch (topology) {
        case D3D_PRIMITIVE_TOPOLOGY_POINTLIST:return MTLPrimitiveTypePoint;
        case D3D_PRIMITIVE_TOPOLOGY_LINELIST:return MTLPrimitiveTypeLine;
        case D3D_PRIMITIVE_TOPOLOGY_LINESTRIP:return MTLPrimitiveTypeLineStrip;
        case D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST:return MTLPrimitiveTypeTriangle;
        case D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP:return MTLPrimitiveTypeTriangleStrip;
        default:unsupported("primitive topology");
        }
    }
    bool prepare_draw() {
        if (viewports.empty() || scissors.empty()) return false;
        const auto &state=pipeline();require(state.render!=nil,"graphics pipeline required");begin_render();
        const auto *previous=applied.pipeline;
        const auto &r=state.rasterizer;
        auto renderPipeline=state.render;
        const UINT parameter=state.specializationParameter;
        if (state.specializedRender && graphics.layout && parameter<graphics.layout->desc.NumParameters &&
            graphics.layout->desc.pParameters[parameter].ParameterType==D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE) {
            UINT64 table=0;memcpy(&table,graphics.bytes.data()+graphics.layout->parameterOffsets[parameter],8);
            D3D12_CONSTANT_BUFFER_VIEW_DESC cbv{};
            for (auto *heap:heaps) { cbv=table_cbv(heap,table,state.specializationIndex);if (cbv.BufferLocation) break; }
            const UINT64 offset=state.specializationOffset;
            if (cbv.BufferLocation && cbv.BufferLocation<=UINT64_MAX-offset && offset<=cbv.SizeInBytes && sizeof(UINT)<=cbv.SizeInBytes-offset) {
                UINT value=0;
                if (copied_value(cbv.BufferLocation+offset,value) && value==state.specializationValue) renderPipeline=state.specializedRender;
            }
        }
        if (renderPipeline!=applied.renderPipeline) { [render setRenderPipelineState:renderPipeline];applied.renderPipeline=renderPipeline; }
        if (!previous || state.depth!=previous->depth) [render setDepthStencilState:state.depth];
        if (!previous || r.CullMode!=previous->rasterizer.CullMode)
            [render setCullMode:r.CullMode==D3D12_CULL_MODE_NONE?MTLCullModeNone:(MTLCullMode)(r.CullMode-1)];
        if (!previous || r.FrontCounterClockwise!=previous->rasterizer.FrontCounterClockwise)
            [render setFrontFacingWinding:r.FrontCounterClockwise?MTLWindingCounterClockwise:MTLWindingClockwise];
        if (!previous || r.FillMode!=previous->rasterizer.FillMode)
            [render setTriangleFillMode:r.FillMode==D3D12_FILL_MODE_WIREFRAME?MTLTriangleFillModeLines:MTLTriangleFillModeFill];
        if (!previous || r.DepthClipEnable!=previous->rasterizer.DepthClipEnable)
            [render setDepthClipMode:r.DepthClipEnable?MTLDepthClipModeClip:MTLDepthClipModeClamp];
        if (!previous || r.DepthBias!=previous->rasterizer.DepthBias || r.SlopeScaledDepthBias!=previous->rasterizer.SlopeScaledDepthBias || r.DepthBiasClamp!=previous->rasterizer.DepthBiasClamp)
            [render setDepthBias:r.DepthBias slopeScale:r.SlopeScaledDepthBias clamp:r.DepthBiasClamp];
        applied.pipeline=&state;
        if (applied.stencil!=stencil) { [render setStencilReferenceValue:stencil];applied.stencil=stencil; }
        if (applied.blend!=blend) { [render setBlendColorRed:blend[0] green:blend[1] blue:blend[2] alpha:blend[3]];applied.blend=blend; }
        if (activeQuery) [render setVisibilityResultMode:queryType==D3D12_QUERY_TYPE_BINARY_OCCLUSION?MTLVisibilityResultModeBoolean:MTLVisibilityResultModeCounting offset:queryIndex*8ull];
        if (applied.viewports.size()!=viewports.size() || memcmp(applied.viewports.data(),viewports.data(),viewports.size()*sizeof(MTLViewport))) {
            [render setViewports:viewports.data() count:viewports.size()];applied.viewports=viewports;
        }
        auto target=depth_.texture;if (!colors_.empty()) target=colors_[0].texture;
        if (applied.width!=target.width || applied.height!=target.height || applied.scissors.size()!=scissors.size() || memcmp(applied.scissors.data(),scissors.data(),scissors.size()*sizeof(D3D12_RECT))) {
            std::array<MTLScissorRect,16> clipped{};
            for (size_t i=0;i<scissors.size();++i) {
                const auto &s=scissors[i];
                const NSInteger x=std::clamp<NSInteger>(s.left,0,target.width),y=std::clamp<NSInteger>(s.top,0,target.height);
                const NSInteger right=std::clamp<NSInteger>(s.right,x,target.width),bottom=std::clamp<NSInteger>(s.bottom,y,target.height);
                if (right==x || bottom==y) return false;clipped[i]={(NSUInteger)x,(NSUInteger)y,(NSUInteger)(right-x),(NSUInteger)(bottom-y)};
            }
            [render setScissorRects:clipped.data() count:scissors.size()];applied.scissors=scissors;applied.width=target.width;applied.height=target.height;
        }
        for (UINT i=0;i<vertex.size();++i) if (state.vertexSlots&(1u<<i)) {
            const auto &v=vertex[i],&previous=applied.vertex[i];
            if ((applied.vertexSlots&(1u<<i)) && v.BufferLocation==previous.BufferLocation && v.SizeInBytes==previous.SizeInBytes && v.StrideInBytes==previous.StrideInBytes) continue;
            auto source=resolve_buffer_address(device,v.BufferLocation,v.SizeInBytes);
            require(source.buffer!=nil,"vertex buffer address");[render setVertexBuffer:source.buffer offset:source.offset attributeStride:v.StrideInBytes atIndex:i+6];
            applied.vertex[i]=v;applied.vertexSlots|=1u<<i;
        }
        residency(graphics,render,nil);bind_heaps();
        if (graphics.dirty && !graphics.bytes.empty()) { [render setVertexBytes:graphics.bytes.data() length:graphics.bytes.size() atIndex:2];[render setFragmentBytes:graphics.bytes.data() length:graphics.bytes.size() atIndex:2]; }
        graphics.dirty=false;
        return true;
    }
    void draw(bool indexed,UINT count,UINT instances,UINT first,INT base,UINT first_instance) {
        // Approved fullscreen shaders do not consume instance IDs.
        if (!indexed && count==3 && instances==1 && !first && spatial_upscale()) return;
        if (!count || !instances || !prepare_draw()) return;
        const uint16_t index_type=index.Format==DXGI_FORMAT_R16_UINT?1:2;
        if (indexed) {
            require(index.Format==DXGI_FORMAT_R16_UINT || index.Format==DXGI_FORMAT_R32_UINT,"index format");
            const UINT params[]={count,instances,first,(UINT)base,first_instance};[render setVertexBytes:params length:sizeof params atIndex:4];[render setVertexBytes:&index_type length:2 atIndex:5];
            auto indices=resolve_buffer_address(device,index.BufferLocation,index.SizeInBytes);require(indices.buffer!=nil,"index buffer address");
            const NSUInteger width=index.Format==DXGI_FORMAT_R16_UINT?2:4;
            require((UINT64)first*width<=index.SizeInBytes && (UINT64)count*width<=index.SizeInBytes-(UINT64)first*width,"index buffer range");
            [render drawIndexedPrimitives:primitive() indexCount:count indexType:width==2?MTLIndexTypeUInt16:MTLIndexTypeUInt32 indexBuffer:indices.buffer indexBufferOffset:indices.offset+(NSUInteger)first*width instanceCount:instances baseVertex:base baseInstance:first_instance];
        } else {
            const UINT params[]={count,instances,first,first_instance};const uint16_t nonindexed=0;
            [render setVertexBytes:params length:sizeof params atIndex:4];[render setVertexBytes:&nonindexed length:2 atIndex:5];
            [render drawPrimitives:primitive() vertexStart:first vertexCount:count instanceCount:instances baseInstance:first_instance];
        }
    }
    bool spatial_upscale() {
        const auto &state=pipeline();const UINT parameter=state.upscaleParameter;
        if (parameter==UINT_MAX || !graphics.layout || parameter>=graphics.layout->desc.NumParameters ||
            colors_.size()!=1 || depth_.texture || activeQuery || viewports.size()!=1 || scissors.size()!=1) return false;
        const auto target=colors_[0].texture;const auto &v=viewports[0];const auto &s=scissors[0];
        if (v.originX || v.originY || v.width!=target.width || v.height!=target.height ||
            s.left>0 || s.top>0 || s.right<(LONG)target.width || s.bottom<(LONG)target.height ||
            graphics.layout->desc.pParameters[parameter].ParameterType!=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE) return false;
        UINT64 address=0;memcpy(&address,graphics.bytes.data()+graphics.layout->parameterOffsets[parameter],8);
        id<MTLTexture> source=nil;
        for (auto *heap:heaps) {
            const auto desc=heap->GetDesc();if (desc.Type!=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV) continue;
            const UINT64 start=heap->GetGPUDescriptorHandleForHeapStart().ptr;
            const UINT stride=descriptor_stride(desc.Type);
            if (address<start || (address-start)%stride) continue;
            const UINT64 slot=(address-start)/stride+state.upscaleIndex;
            if (slot>=desc.NumDescriptors) continue;
            ID3DMDescriptorHeap *native=nullptr;
            if (FAILED(heap->QueryInterface(__uuidof(ID3DMDescriptorHeap),(void **)&native))) continue;
            D3DMDescriptorView view{};const HRESULT hr=native->GetView((UINT)slot,&view);native->Release();
            id resource=(__bridge id)view.resource;
            if (SUCCEEDED(hr) && [resource conformsToProtocol:@protocol(MTLTexture)]) source=resource;
            break;
        }
        if (!source || !upscaler.prepare(metal,source,target)) return false;
        flush_clears(source);flush_clears(target);end();
        upscaler.encode(commands,fence,haveFence);haveFence=true;
        return true;
    }
    void prepare_compute() {
        const auto &state=pipeline();require(state.compute!=nil,"compute pipeline required");
        if (!compute) { end();compute=[commands computeCommandEncoder];if (haveFence) [compute waitForFence:fence]; }
        if (computeApplied.pipeline!=&state) { [compute setComputePipelineState:state.compute];computeApplied.pipeline=&state; }
        bind_heaps();residency(computeRoot,nil,compute);
        if (computeRoot.dirty && !computeRoot.bytes.empty()) [compute setBytes:computeRoot.bytes.data() length:computeRoot.bytes.size() atIndex:2];
        computeRoot.dirty=false;


    }
    void dispatch(UINT x,UINT y,UINT z) {
        if (!x || !y || !z) return;prepare_compute();const auto &state=pipeline();
        [compute dispatchThreadgroups:MTLSizeMake(x,y,z) threadsPerThreadgroup:state.threads];
    }
    void indirect(Signature *signature,UINT count,ID3D12Resource *arguments,UINT64 offset,ID3D12Resource *counter,UINT64 counter_offset) {
        if (!count) return;
        auto input=buffer(arguments);require(offset<=input.length && count<=(input.length-offset)/signature->stride,"indirect argument range");
        if (counter) {
            auto limit=buffer(counter);require(counter_offset%4==0 && counter_offset<=limit.length && limit.length-counter_offset>=4,"indirect counter range");
            const UINT64 bytes=(UINT64)count*signature->stride;require(bytes<=UINT_MAX,"indirect masked argument size");
            auto masked=[metal newBufferWithLength:bytes options:MTLResourceStorageModePrivate];require(masked!=nil,"indirect argument allocation");
            end();compute=[commands computeCommandEncoder];if (haveFence) [compute waitForFence:fence];
            auto state=utility_compute(metal,@"mask_indirect");[compute setComputePipelineState:state];
            [compute setBuffer:input offset:offset atIndex:0];[compute setBuffer:masked offset:0 atIndex:1];[compute setBuffer:limit offset:counter_offset atIndex:2];
            const UINT shape[]={count,signature->stride};[compute setBytes:shape length:sizeof shape atIndex:3];
            [compute dispatchThreads:MTLSizeMake(bytes,1,1) threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(256,state.maxTotalThreadsPerThreadgroup),1,1)];end();
            input=masked;offset=0;
        }
        for (UINT i=0;i<count;++i) {
            const UINT64 position=offset+(UINT64)i*signature->stride;
            if (signature->type==D3D12_INDIRECT_ARGUMENT_TYPE_DISPATCH) {
                prepare_compute();[compute dispatchThreadgroupsWithIndirectBuffer:input indirectBufferOffset:position threadsPerThreadgroup:pipeline().threads];continue;
            }
            if (!prepare_draw()) continue;
            [render setVertexBuffer:input offset:position atIndex:4];
            if (signature->type==D3D12_INDIRECT_ARGUMENT_TYPE_DRAW) {
                const uint16_t mode=0;[render setVertexBytes:&mode length:2 atIndex:5];
                [render drawPrimitives:primitive() indirectBuffer:input indirectBufferOffset:position];
            } else {
                require(index.Format==DXGI_FORMAT_R16_UINT || index.Format==DXGI_FORMAT_R32_UINT,"indirect index format");
                const uint16_t mode=index.Format==DXGI_FORMAT_R16_UINT?1:2;[render setVertexBytes:&mode length:2 atIndex:5];
                auto indices=resolve_buffer_address(device,index.BufferLocation,index.SizeInBytes);require(indices.buffer!=nil,"indirect index buffer");
                [render drawIndexedPrimitives:primitive() indexType:index.Format==DXGI_FORMAT_R16_UINT?MTLIndexTypeUInt16:MTLIndexTypeUInt32 indexBuffer:indices.buffer indexBufferOffset:indices.offset indirectBuffer:input indirectBufferOffset:position];
            }
        }
    }
    void barrier(const std::vector<D3D12_RESOURCE_BARRIER> &barriers) {
        for (const auto &b:barriers) {
            if (b.Type==D3D12_RESOURCE_BARRIER_TYPE_UAV && compute) { [compute memoryBarrierWithScope:MTLBarrierScopeBuffers|MTLBarrierScopeTextures];continue; }
            if (b.Type==D3D12_RESOURCE_BARRIER_TYPE_ALIASING) { clear_copied_uniforms();flush_clears();end();continue; }
            if (b.Type!=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION) continue;
            if (b.Flags==D3D12_RESOURCE_BARRIER_FLAG_BEGIN_ONLY) continue;
            if (b.Transition.StateBefore&D3D12_RESOURCE_STATE_RENDER_TARGET && b.Transition.StateAfter==D3D12_RESOURCE_STATE_RESOLVE_SOURCE && render) {
                const bool pending=renderResolve && renderResolve->source==b.Transition.pResource &&
                    (b.Transition.Subresource==D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES || b.Transition.Subresource==renderResolve->sourceIndex);
                if (pending) continue;
            }
            if (!clears.empty() && b.Transition.StateAfter!=D3D12_RESOURCE_STATE_RENDER_TARGET && b.Transition.StateAfter!=D3D12_RESOURCE_STATE_DEPTH_WRITE && b.Transition.pResource->GetDesc().Dimension!=D3D12_RESOURCE_DIMENSION_BUFFER)
                flush_clears(texture(b.Transition.pResource));
            if (render && (b.Transition.StateBefore&(D3D12_RESOURCE_STATE_RENDER_TARGET|D3D12_RESOURCE_STATE_DEPTH_WRITE))) {
                auto changed=texture(b.Transition.pResource);
                auto aliases=[&](const Attachment &attachment) {
                    if (!attachment.texture) return false;
                    auto target=attachment.texture;while (target.parentTexture) target=target.parentTexture;
                    return std::get<0>(clear_key(changed))==(uintptr_t)(__bridge void *)target || (changed.heap && changed.heap==target.heap);
                };
                if (aliases(applied.depth) || std::any_of(applied.colors.begin(),applied.colors.end(),aliases)) end();
            }
        }
    }
    void copy_buffer(ID3D12Resource *dst,UINT64 dst_offset,ID3D12Resource *src,UINT64 src_offset,UINT64 size) {
        auto a=buffer(src),b=buffer(dst);require(src_offset<=a.length && size<=a.length-src_offset && dst_offset<=b.length && size<=b.length-dst_offset,"buffer copy range");
        if (!size) return;
        [copies() copyFromBuffer:a sourceOffset:src_offset toBuffer:b destinationOffset:dst_offset size:size];
        const UINT64 address=b.gpuAddress+dst_offset;
        std::erase_if(copiedUniforms,[&](const auto &old) {
            if (old.first>=address+size || address>=old.first+old.second.size()) return false;
            copiedBytes-=old.second.size();return true;
        });
        if (!snapshotUploads || size>65536 || b.storageMode!=MTLStorageModePrivate || (dst->GetDesc().Flags&D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS)) return;
        D3D12_HEAP_PROPERTIES properties{};
        if (FAILED(src->GetHeapProperties(&properties,nullptr)) || properties.Type!=D3D12_HEAP_TYPE_UPLOAD) return;
        // A CBV is at most 64 KiB; bound this optional cache to 1 MiB per submission.
        if (size>(1u<<20)-copiedBytes) { snapshotUploads=false;clear_copied_uniforms();return; }
        auto &bytes=copiedUniforms[address];bytes.resize((size_t)size);memcpy(bytes.data(),(const uint8_t *)a.contents+src_offset,(size_t)size);copiedBytes+=(size_t)size;
    }
    void clear_copied_uniforms() { copiedUniforms.clear();copiedBytes=0; }
    bool copied_value(UINT64 address,UINT &value) {
        auto i=copiedUniforms.upper_bound(address);if (i==copiedUniforms.begin()) return false;--i;
        const UINT64 offset=address-i->first;
        if (offset>i->second.size() || sizeof value>i->second.size()-offset) return false;
        memcpy(&value,i->second.data()+offset,sizeof value);return true;
    }
    struct Subresource { UINT mip,slice,plane;MTLOrigin origin;MTLSize size; };
    Subresource subresource(ID3D12Resource *resource,UINT index) {
        const auto d=resource->GetDesc();const UINT arrays=d.Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE3D?1:d.DepthOrArraySize;
        require(d.MipLevels && index<(UINT64)d.MipLevels*arrays*format_info(d.Format).planes,"texture subresource index");
        const UINT mip=index%d.MipLevels;
        return {mip,(index/d.MipLevels)%arrays,index/(d.MipLevels*arrays),MTLOriginMake(0,0,0),
            MTLSizeMake(std::max<UINT64>(1,d.Width>>mip),std::max(1u,d.Height>>mip),d.Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE3D?std::max(1u,(UINT)d.DepthOrArraySize>>mip):1)};
    }
    MTLBlitOption plane_option(ID3D12Resource *resource,UINT plane) {
        if (format_info(resource->GetDesc().Format).planes!=2) return MTLBlitOptionNone;
        return plane?MTLBlitOptionStencilFromDepthStencil:MTLBlitOptionDepthFromDepthStencil;
    }
    void copy_texture(D3D12_TEXTURE_COPY_LOCATION dst,UINT x,UINT y,UINT z,D3D12_TEXTURE_COPY_LOCATION src,const D3D12_BOX *box) {
        if (dst.Type==D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT) clear_copied_uniforms();
        const bool from_texture=src.Type==D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,to_texture=dst.Type==D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        Subresource source{};MTLSize size;
        if (from_texture) { source=subresource(src.pResource,src.SubresourceIndex);size=source.size; }
        else size=MTLSizeMake(src.PlacedFootprint.Footprint.Width,src.PlacedFootprint.Footprint.Height,src.PlacedFootprint.Footprint.Depth);
        MTLOrigin origin=MTLOriginMake(0,0,0);
        if (box) { require(box->right>=box->left && box->bottom>=box->top && box->back>=box->front,"texture copy box");origin=MTLOriginMake(box->left,box->top,box->front);size=MTLSizeMake(box->right-box->left,box->bottom-box->top,box->back-box->front); }
        if (!size.width || !size.height || !size.depth) return;
        if (from_texture) flush_clears(texture(src.pResource));
        if (to_texture) flush_clears(texture(dst.pResource));
        if (from_texture && to_texture) {
            auto destination=subresource(dst.pResource,dst.SubresourceIndex);
            [copies() copyFromTexture:texture(src.pResource) sourceSlice:source.slice sourceLevel:source.mip sourceOrigin:origin sourceSize:size toTexture:texture(dst.pResource) destinationSlice:destination.slice destinationLevel:destination.mip destinationOrigin:MTLOriginMake(x,y,z)];
        } else if (!from_texture && to_texture) {
            auto destination=subresource(dst.pResource,dst.SubresourceIndex);const auto &p=src.PlacedFootprint;const auto info=format_info(p.Footprint.Format);
            require(info.bytes && info.block,"copy footprint format");const UINT64 image=(UINT64)p.Footprint.RowPitch*((p.Footprint.Height+info.block-1)/info.block);
            // D3D12 footprints round BC mips to blocks; Metal's region uses logical texels.
            if (info.block>1) {
                require(x<=destination.size.width && y<=destination.size.height,"compressed destination origin");
                require(size.width<=((destination.size.width-x+info.block-1)/info.block)*info.block && size.height<=((destination.size.height-y+info.block-1)/info.block)*info.block,"compressed destination range");
                size.width=std::min(size.width,destination.size.width-x);size.height=std::min(size.height,destination.size.height-y);
            }
            const UINT64 offset=p.Offset+origin.z*image+(origin.y/info.block)*p.Footprint.RowPitch+(origin.x/info.block)*info.bytes;
            [copies() copyFromBuffer:buffer(src.pResource) sourceOffset:offset sourceBytesPerRow:p.Footprint.RowPitch sourceBytesPerImage:image sourceSize:size toTexture:texture(dst.pResource) destinationSlice:destination.slice destinationLevel:destination.mip destinationOrigin:MTLOriginMake(x,y,z) options:plane_option(dst.pResource,destination.plane)];
        } else if (from_texture && !to_texture) {
            const auto &p=dst.PlacedFootprint;const auto info=format_info(p.Footprint.Format);require(info.bytes && info.block,"copy footprint format");
            const UINT64 image=(UINT64)p.Footprint.RowPitch*((p.Footprint.Height+info.block-1)/info.block),offset=p.Offset+z*image+(y/info.block)*p.Footprint.RowPitch+(x/info.block)*info.bytes;
            [copies() copyFromTexture:texture(src.pResource) sourceSlice:source.slice sourceLevel:source.mip sourceOrigin:origin sourceSize:size toBuffer:buffer(dst.pResource) destinationOffset:offset destinationBytesPerRow:p.Footprint.RowPitch destinationBytesPerImage:image options:plane_option(src.pResource,source.plane)];
        } else unsupported("buffer-to-buffer texture footprints");
    }
    void copy_resource(ID3D12Resource *dst,ID3D12Resource *src) {
        const auto d=src->GetDesc(),other=dst->GetDesc();require(d.Dimension==other.Dimension && d.Width==other.Width && d.Height==other.Height && d.DepthOrArraySize==other.DepthOrArraySize && d.MipLevels==other.MipLevels,"resource copy dimensions");
        if (d.Dimension==D3D12_RESOURCE_DIMENSION_BUFFER) { copy_buffer(dst,0,src,0,d.Width);return; }
        const UINT count=d.MipLevels*(d.Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE3D?1:d.DepthOrArraySize)*format_info(d.Format).planes;
        for (UINT i=0;i<count;++i) { D3D12_TEXTURE_COPY_LOCATION a{},b{};a.pResource=src;a.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;a.SubresourceIndex=i;b=a;b.pResource=dst;copy_texture(b,0,0,0,a,nullptr); }
    }
    void resolve(const Resolve &value) {
        validate_resolve(value);
        if (renderResolve) {
            require(renderResolve->source==value.source && renderResolve->sourceIndex==value.sourceIndex && renderResolve->destination==value.destination && renderResolve->destinationIndex==value.destinationIndex && renderResolve->format==value.format,"render resolve planning mismatch");
            renderResolve.reset();end();return;
        }
        const auto a=subresource(value.source,value.sourceIndex);
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];auto color=pass.colorAttachments[0];
        color.texture=resolve_texture(value.source,value.format);color.level=a.mip;color.slice=a.slice;color.loadAction=MTLLoadActionLoad;color.storeAction=MTLStoreActionStoreAndMultisampleResolve;
        for (auto it=clears.begin();it!=clears.end();++it) if (!it->second.depth && resolve_source(it->second.target.texture,value)) {
            const auto &v=it->second.color;color.loadAction=MTLLoadActionClear;color.clearColor=MTLClearColorMake(v[0],v[1],v[2],v[3]);clears.erase(it);break;
        }
        resolve_destination(color,value);flush_clears(texture(value.source));flush_clears(texture(value.destination));end();
        render=[commands renderCommandEncoderWithDescriptor:pass];if (haveFence) [render waitForFence:fence beforeStages:MTLRenderStageVertex];end();
    }
    void begin_query(QueryHeap *heap,D3D12_QUERY_TYPE type,UINT index) {
        require(!activeQuery && type!=D3D12_QUERY_TYPE_TIMESTAMP,"nested or timestamp BeginQuery");heap->validate(type,index);
        [copies() fillBuffer:heap->visibility range:NSMakeRange(index*8ull,8) value:0];end();
        activeQuery=heap;queryType=type;queryIndex=index;
    }
    void end_query(QueryHeap *heap,D3D12_QUERY_TYPE type,UINT index) {
        heap->validate(type,index);
        if (type!=D3D12_QUERY_TYPE_TIMESTAMP) {
            require(activeQuery==heap && queryType==type && queryIndex==index,"unmatched EndQuery");end();activeQuery=nullptr;return;
        }
        flush_clears();end();
        auto pass=[MTLBlitPassDescriptor blitPassDescriptor];auto sample=pass.sampleBufferAttachments[0];
        sample.sampleBuffer=heap->timestamps;sample.startOfEncoderSampleIndex=MTLCounterDontSample;sample.endOfEncoderSampleIndex=index;
        blit=[commands blitCommandEncoderWithDescriptor:pass];if (haveFence) [blit waitForFence:fence];end();
    }
    void resolve_queries(QueryHeap *heap,D3D12_QUERY_TYPE type,UINT first,UINT count,ID3D12Resource *destination,UINT64 offset) {
        clear_copied_uniforms();
        heap->validate(type,first,count);auto target=buffer(destination);
        require(offset%8==0 && offset<=target.length && (UINT64)count*8<=target.length-offset,"query resolve destination");
        if (!count) return;
        if (type==D3D12_QUERY_TYPE_TIMESTAMP) [copies() resolveCounters:heap->timestamps inRange:NSMakeRange(first,count) destinationBuffer:target destinationOffset:offset];
        else [copies() copyFromBuffer:heap->visibility sourceOffset:first*8ull toBuffer:target destinationOffset:offset size:count*8ull];
    }
    void fill(id<MTLBuffer> target,UINT64 offset,UINT64 bytes,const std::array<uint8_t,16> &pattern,UINT pattern_size) {
        require(bytes<=UINT_MAX && offset<=UINT_MAX && offset<=target.length && bytes<=target.length-offset,"UAV fill range");if (!bytes) return;
        end();compute=[commands computeCommandEncoder];if (haveFence) [compute waitForFence:fence];
        auto state=utility_compute(metal,@"fill_pattern");[compute setComputePipelineState:state];[compute setBuffer:target offset:0 atIndex:0];
        [compute setBytes:pattern.data() length:pattern.size() atIndex:1];const UINT shape[]={(UINT)bytes,pattern_size,(UINT)offset,0};[compute setBytes:shape length:sizeof shape atIndex:2];
        [compute dispatchThreads:MTLSizeMake(bytes,1,1) threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(256,state.maxTotalThreadsPerThreadgroup),1,1)];end();
    }
    void clear_uav(const ClearUAV &value) {
        bool bound=false;for (auto *heap:heaps) if (uav_gpu_handle(heap,value.gpu.ptr,value.resource)) bound=true;
        require(bound,"clear GPU UAV is outside bound heaps or references another resource");
        const auto &desc=value.desc;const bool isBuffer=desc.ViewDimension==D3D12_UAV_DIMENSION_BUFFER;
        const auto target=value.texture;UINT bytes=format_info(desc.Format).bytes;
        if (!isBuffer) flush_clears(target);
        if (isBuffer && (desc.Buffer.Flags&D3D12_BUFFER_UAV_FLAG_RAW)) bytes=4;
        require(bytes && (!isBuffer || !desc.Buffer.StructureByteStride),"UAV clear does not accept structured buffers");
        const NSUInteger width=isBuffer?desc.Buffer.NumElements:target.width,height=isBuffer?1:target.height;
        const bool volume=!isBuffer && target.textureType==MTLTextureType3D;
        NSUInteger layers=1;if (!isBuffer) layers=volume?target.depth:target.arrayLength;
        require(width<=INT_MAX && height<=INT_MAX,"UAV clear extent");
        std::array<uint8_t,16> pattern{};
        if (!value.floating) {
            if (isBuffer && (desc.Buffer.Flags&D3D12_BUFFER_UAV_FLAG_RAW)) memcpy(pattern.data(),value.values.data(),4);
            else pattern=uint_pattern(desc.Format,value.values);
        }
        const size_t count=std::max<size_t>(1,value.rects.size());
        for (size_t i=0;i<count;++i) {
            D3D12_RECT rect{0,0,(LONG)width,(LONG)height};if (!value.rects.empty()) rect=value.rects[i];
            const LONG x=std::clamp<LONG>(rect.left,0,width),y=std::clamp<LONG>(rect.top,0,height);
            const LONG right=std::clamp<LONG>(rect.right,x,width),bottom=std::clamp<LONG>(rect.bottom,y,height);
            if (x==right || y==bottom) continue;
            if (!value.floating && isBuffer) { fill(buffer(value.resource),(desc.Buffer.FirstElement+x)*bytes,(right-x)*bytes,pattern,bytes);continue; }
            if (!value.floating) {
                const NSUInteger pitch=((right-x)*bytes+255)&~NSUInteger(255),image=pitch*(bottom-y),depth=volume?layers:1;
                auto scratch=[metal newBufferWithLength:image*depth options:MTLResourceStorageModePrivate];require(scratch!=nil,"UAV clear staging allocation");fill(scratch,0,image*depth,pattern,bytes);
                for (NSUInteger slice=0;slice<(volume?1:layers);++slice)
                    [copies() copyFromBuffer:scratch sourceOffset:0 sourceBytesPerRow:pitch sourceBytesPerImage:image sourceSize:MTLSizeMake(right-x,bottom-y,depth) toTexture:target destinationSlice:slice destinationLevel:0 destinationOrigin:MTLOriginMake(x,y,0)];
                continue;
            }
            require(target!=nil,"float UAV clear requires a typed view");
            struct alignas(16) Region { UINT origin[4],size[4];float color[4]; } region{{(UINT)x,(UINT)y,0,0},{(UINT)(right-x),(UINT)(bottom-y),(UINT)layers,0},{}};
            memcpy(region.color,value.values.data(),16);
            NSString *kernel=@"clear_2d";MTLSize grid=MTLSizeMake(right-x,bottom-y,layers);
            if (isBuffer) { kernel=@"clear_buffer";region.origin[0]+=(desc.Buffer.FirstElement*bytes-target.bufferOffset)/bytes;grid=MTLSizeMake(right-x,1,1); }
            else if (volume) kernel=@"clear_3d";
            end();compute=[commands computeCommandEncoder];if (haveFence) [compute waitForFence:fence];
            auto state=utility_compute(metal,kernel);[compute setComputePipelineState:state];[compute setTexture:target atIndex:0];[compute setBytes:&region length:sizeof region atIndex:0];
            [compute dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(64,state.maxTotalThreadsPerThreadgroup),1,1)];end();
        }
    }
    // The final encoder has no fence consumer; Queue::commit still orders the complete submission.
    void finish(bool final=false) { flush_clears();end(final);if (@available(macOS 15.0,*)) [residentSet commit]; }
    ID3D12Device *device;
    id<MTLDevice> metal;
    QueryHeap *activeQuery=nullptr;
    D3D12_QUERY_TYPE queryType{};
    UINT queryIndex=0;
    id<MTLCommandBuffer> commands;
    id<MTLRenderCommandEncoder> render;
    id<MTLComputeCommandEncoder> compute;
    id<MTLBlitCommandEncoder> blit;
    id<MTLFence> fence;
    id residentSet;
    bool haveFence=false;
    bool snapshotUploads;
    std::map<UINT64,std::vector<uint8_t>> copiedUniforms;
    size_t copiedBytes=0;
    ID3D12PipelineState *pso=nullptr;
    ID3D12PipelineState *cachedPso=nullptr;
    const PipelineState *cachedPipeline=nullptr;
    struct AppliedComputeState {
        const PipelineState *pipeline=nullptr;
        std::vector<ID3D12DescriptorHeap *> heaps;
    } computeApplied;
    struct AppliedRenderState {
        id<MTLRenderPipelineState> renderPipeline;
        bool deferredStores=false;
        std::array<MTLStoreAction,8> colorStores{};
        MTLStoreAction depthStore=MTLStoreActionStore,stencilStore=MTLStoreActionStore;
        bool targetsChanged=false;
        std::vector<Attachment> colors;
        Attachment depth;
        const PipelineState *pipeline=nullptr;
        std::optional<UINT> stencil;
        std::optional<std::array<FLOAT,4>> blend;
        std::vector<MTLViewport> viewports;
        std::vector<D3D12_RECT> scissors;
        NSUInteger width=0,height=0;
        std::vector<ID3D12DescriptorHeap *> heaps;
        std::array<D3D12_VERTEX_BUFFER_VIEW,32> vertex{};
        UINT vertexSlots=0;
    } applied;
    RootArguments graphics,computeRoot;
    SpatialUpscaler &upscaler;
    std::vector<ID3D12DescriptorHeap *> heaps;
    std::vector<MTLViewport> viewports;
    std::vector<D3D12_RECT> scissors;
    std::array<D3D12_VERTEX_BUFFER_VIEW,32> vertex{};
    D3D12_INDEX_BUFFER_VIEW index{};
    D3D12_PRIMITIVE_TOPOLOGY topology=D3D_PRIMITIVE_TOPOLOGY_UNDEFINED;
    std::array<FLOAT,4> blend{1,1,1,1};UINT stencil=0;
    std::vector<Attachment> colors_;Attachment depth_;
    std::map<ClearKey,Clear> clears;
    const Resolve *plannedResolve=nullptr;
    std::optional<Resolve> renderResolve;
};

class CommandList final : public Child<ID3D12GraphicsCommandList6> {
public:
    struct Boundary {
        size_t operation;
        std::optional<Resolve> resolve;
        std::vector<D3D12_RESOURCE_TRANSITION_BARRIER> transitions;
    };
    struct ResolveRange { size_t first,last;Resolve resolve; };
    CommandList(ID3D12Device *device,D3D12_COMMAND_LIST_TYPE type):Child(device),type(type) {}
    ~CommandList() override { if (allocator) { allocator->detach(this);if (open) --allocator->open;allocator->Release(); } }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **out) override {
        return query<IUnknown,ID3D12Object,ID3D12DeviceChild,ID3D12CommandList,ID3D12GraphicsCommandList,ID3D12GraphicsCommandList1,ID3D12GraphicsCommandList2,ID3D12GraphicsCommandList3,ID3D12GraphicsCommandList4,ID3D12GraphicsCommandList5,ID3D12GraphicsCommandList6>(iid,out);
    }
    D3D12_COMMAND_LIST_TYPE STDMETHODCALLTYPE GetType() override { return type; }
    HRESULT begin(ID3D12CommandAllocator *value,ID3D12PipelineState *initial) {
        if (open) return E_FAIL;
        if (!same_device(device,value) || (initial && !same_device(device,initial))) return E_INVALIDARG;
        auto *next=static_cast<Allocator *>(value);
        if (next->type!=type) return E_INVALIDARG;
        if (next->open.fetch_add(1)!=0) { --next->open;return E_INVALIDARG; }
        next->AddRef();if (allocator) { allocator->detach(this);allocator->Release(); } allocator=next;
        { std::lock_guard guard(allocator->mutex);allocator->lists.push_back(this); }
        generation=allocator->generation.load();discard_recording();open=true;
        if (initial) add([=](Replay &r) { r.pso=initial; });
        return S_OK;
    }
    void add(std::function<void(Replay &)> operation,bool keepsRender=false) {
        require(open,"recording a closed list");if (!keepsRender) boundaries.push_back({operations.size(),{}, {}});operations.push_back(std::move(operation));
    }
    void discard_recording() { operations.clear();boundaries.clear();resolveRanges.clear(); }
    void replay(Replay &r) {
        require(!open && allocator && generation==allocator->generation.load(),"executing invalidated/open list");
        size_t range=0;
        for (size_t i=0;i<operations.size();++i) {
            while (range<resolveRanges.size() && i>resolveRanges[range].last) ++range;
            r.plannedResolve=nullptr;if (range<resolveRanges.size() && i>=resolveRanges[range].first) r.plannedResolve=&resolveRanges[range].resolve;
            operations[i](r);
        }
        r.plannedResolve=nullptr;
    }
    HRESULT STDMETHODCALLTYPE Close() override {
        if (!open) return E_FAIL;
        // Metal requires an attached resolve destination to be written when the pass ends.
        for (size_t i=0;i<boundaries.size();++i) if (boundaries[i].resolve) {
            const auto &value=*boundaries[i].resolve;size_t first=i;
            while (first && !boundaries[first-1].transitions.empty()) {
                const auto &transitions=boundaries[first-1].transitions;
                const bool compatible=std::all_of(transitions.begin(),transitions.end(),[&](const auto &t) { return t.pResource==value.source && (t.Subresource==value.sourceIndex || t.Subresource==D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES); });
                if (!compatible) break;--first;
            }
            resolveRanges.push_back({first?boundaries[first-1].operation+1:0,boundaries[i].operation,value});
        }
        open=false;--allocator->open;return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Reset(ID3D12CommandAllocator *a0,ID3D12PipelineState *a1) override { return begin(a0,a1); }
    void STDMETHODCALLTYPE ClearState(ID3D12PipelineState *a0) override { add([=](Replay &r) { r.finish();r.pso=a0;r.graphics.set(nullptr);r.computeRoot.set(nullptr);r.vertex={};r.index={};r.viewports.clear();r.scissors.clear();r.blend={1,1,1,1};r.stencil=0;r.heaps.clear();r.targets({},{}); }); }
    void STDMETHODCALLTYPE DrawInstanced(UINT a0,UINT a1,UINT a2,UINT a3) override { require(type==D3D12_COMMAND_LIST_TYPE_DIRECT || type==D3D12_COMMAND_LIST_TYPE_BUNDLE,"draw list type");add([=](Replay &r) { r.draw(false,a0,a1,a2,0,a3); },true); }
    void STDMETHODCALLTYPE DrawIndexedInstanced(UINT a0,UINT a1,UINT a2,INT a3,UINT a4) override { require(type==D3D12_COMMAND_LIST_TYPE_DIRECT || type==D3D12_COMMAND_LIST_TYPE_BUNDLE,"draw list type");add([=](Replay &r) { r.draw(true,a0,a1,a2,a3,a4); },true); }
    void STDMETHODCALLTYPE Dispatch(UINT a0,UINT a1,UINT a2) override { require(type==D3D12_COMMAND_LIST_TYPE_DIRECT || type==D3D12_COMMAND_LIST_TYPE_COMPUTE,"dispatch list type");add([=](Replay &r) { r.dispatch(a0,a1,a2); }); }
    void STDMETHODCALLTYPE CopyBufferRegion(ID3D12Resource *a0,UINT64 a1,ID3D12Resource *a2,UINT64 a3,UINT64 a4) override { require(same_device(device,a0) && same_device(device,a2),"copy buffer device");add([=](Replay &r) { r.copy_buffer(a0,a1,a2,a3,a4); }); }
    void STDMETHODCALLTYPE CopyTextureRegion(const D3D12_TEXTURE_COPY_LOCATION *a0,UINT a1,UINT a2,UINT a3,const D3D12_TEXTURE_COPY_LOCATION *a4,const D3D12_BOX *a5) override { require(a0 && a4 && same_device(device,a0->pResource) && same_device(device,a4->pResource),"copy texture device");auto dst=*a0,src=*a4;D3D12_BOX box{};const bool boxed=a5!=nullptr;if (boxed) box=*a5;add([=](Replay &r) { r.copy_texture(dst,a1,a2,a3,src,boxed?&box:nullptr); }); }
    void STDMETHODCALLTYPE CopyResource(ID3D12Resource *a0,ID3D12Resource *a1) override { require(same_device(device,a0) && same_device(device,a1),"copy resource device");add([=](Replay &r) { r.copy_resource(a0,a1); }); }
    void STDMETHODCALLTYPE CopyTiles(ID3D12Resource *a0,const D3D12_TILED_RESOURCE_COORDINATE *a1,const D3D12_TILE_REGION_SIZE *a2,ID3D12Resource *a3,UINT64 a4,D3D12_TILE_COPY_FLAGS a5) override { unsupported("CopyTiles"); }
    void STDMETHODCALLTYPE ResolveSubresource(ID3D12Resource *a0,UINT a1,ID3D12Resource *a2,UINT a3,DXGI_FORMAT a4) override { require(same_device(device,a0) && same_device(device,a2),"resolve device");Resolve value{a0,a2,a1,a3,a4};add([=](Replay &r) { r.resolve(value); });boundaries.back().resolve=value; }
    void STDMETHODCALLTYPE IASetPrimitiveTopology(D3D12_PRIMITIVE_TOPOLOGY a0) override { add([=](Replay &r) { r.topology=a0; },true); }
    void STDMETHODCALLTYPE RSSetViewports(UINT a0,const D3D12_VIEWPORT *a1) override { require(a0<=16 && (!a0 || a1),"viewport count");std::vector<MTLViewport> values;for (UINT i=0;i<a0;++i) values.push_back({a1[i].TopLeftX,a1[i].TopLeftY,a1[i].Width,a1[i].Height,a1[i].MinDepth,a1[i].MaxDepth});add([=](Replay &r) { r.viewports=values; },true); }
    void STDMETHODCALLTYPE RSSetScissorRects(UINT a0,const D3D12_RECT *a1) override { require(a0<=16 && (!a0 || a1),"scissor count");std::vector<D3D12_RECT> values;if (a0) values.assign(a1,a1+a0);add([=](Replay &r) { r.scissors=values; },true); }
    void STDMETHODCALLTYPE OMSetBlendFactor(const FLOAT a0[ 4 ]) override { std::array<FLOAT,4> values{1,1,1,1};if (a0) memcpy(values.data(),a0,16);add([=](Replay &r) { r.blend=values; },true); }
    void STDMETHODCALLTYPE OMSetStencilRef(UINT a0) override { add([=](Replay &r) { r.stencil=a0&255u; },true); }
    void STDMETHODCALLTYPE SetPipelineState(ID3D12PipelineState *a0) override { require(same_device(device,a0),"pipeline device");add([=](Replay &r) { r.pso=a0; },true); }
    void STDMETHODCALLTYPE ResourceBarrier(UINT a0,const D3D12_RESOURCE_BARRIER *a1) override {
        require(!a0 || a1,"barrier pointer");std::vector<D3D12_RESOURCE_BARRIER> values;if (a0) values.assign(a1,a1+a0);
        bool breaks=false,resolveOnly=true;std::vector<D3D12_RESOURCE_TRANSITION_BARRIER> transitions;
        for (const auto &b:values) {
            if (b.Type==D3D12_RESOURCE_BARRIER_TYPE_ALIASING) { breaks=true;resolveOnly=false; }
            if (b.Type!=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION || b.Flags==D3D12_RESOURCE_BARRIER_FLAG_BEGIN_ONLY) continue;
            if (!(b.Transition.StateBefore&(D3D12_RESOURCE_STATE_RENDER_TARGET|D3D12_RESOURCE_STATE_DEPTH_WRITE))) continue;
            breaks=true;
            if (b.Transition.StateBefore==D3D12_RESOURCE_STATE_RENDER_TARGET && b.Transition.StateAfter==D3D12_RESOURCE_STATE_RESOLVE_SOURCE) transitions.push_back(b.Transition);
            else resolveOnly=false;
        }
        add([=](Replay &r) { r.barrier(values); },!breaks);
        if (breaks && resolveOnly) boundaries.back().transitions=std::move(transitions);
    }
    void STDMETHODCALLTYPE ExecuteBundle(ID3D12GraphicsCommandList *a0) override { require(type==D3D12_COMMAND_LIST_TYPE_DIRECT && same_device(device,a0),"bundle device/type");auto *bundle=static_cast<CommandList *>(a0);require(bundle->type==D3D12_COMMAND_LIST_TYPE_BUNDLE,"expected bundle");add([=](Replay &r) { bundle->replay(r); }); }
    void STDMETHODCALLTYPE SetDescriptorHeaps(UINT a0,ID3D12DescriptorHeap *const *a1) override { require(a0<=2 && (!a0 || a1),"descriptor heap count");std::vector<ID3D12DescriptorHeap *> values;for (UINT i=0;i<a0;++i) { require(same_device(device,a1[i]) && (a1[i]->GetDesc().Flags&D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE),"descriptor heap device/visibility");values.push_back(a1[i]); }add([=](Replay &r) { r.heaps=values; },true); }
    void STDMETHODCALLTYPE SetComputeRootSignature(ID3D12RootSignature *a0) override { require(!a0 || same_device(device,a0),"root device");add([=](Replay &r) { r.computeRoot.set(a0); },true); }
    void STDMETHODCALLTYPE SetGraphicsRootSignature(ID3D12RootSignature *a0) override { require(!a0 || same_device(device,a0),"root device");add([=](Replay &r) { r.graphics.set(a0); },true); }
    void STDMETHODCALLTYPE SetComputeRootDescriptorTable(UINT a0,D3D12_GPU_DESCRIPTOR_HANDLE a1) override { add([=](Replay &r) { r.computeRoot.address(a0,a1.ptr,D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE); },true); }
    void STDMETHODCALLTYPE SetGraphicsRootDescriptorTable(UINT a0,D3D12_GPU_DESCRIPTOR_HANDLE a1) override { add([=](Replay &r) { r.graphics.address(a0,a1.ptr,D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE); },true); }
    void STDMETHODCALLTYPE SetComputeRoot32BitConstant(UINT a0,UINT a1,UINT a2) override { SetComputeRoot32BitConstants(a0,1,&a1,a2); }
    void STDMETHODCALLTYPE SetGraphicsRoot32BitConstant(UINT a0,UINT a1,UINT a2) override { SetGraphicsRoot32BitConstants(a0,1,&a1,a2); }
    void STDMETHODCALLTYPE SetComputeRoot32BitConstants(UINT a0,UINT a1,const void *a2,UINT a3) override { require(a1<=64 && a3<=64-a1 && (!a1 || a2),"root constant data/range");std::vector<UINT> values(a1);if (a1) memcpy(values.data(),a2,a1*4);add([=](Replay &r) { r.computeRoot.constants(a0,a3,values); },true); }
    void STDMETHODCALLTYPE SetGraphicsRoot32BitConstants(UINT a0,UINT a1,const void *a2,UINT a3) override { require(a1<=64 && a3<=64-a1 && (!a1 || a2),"root constant data/range");std::vector<UINT> values(a1);if (a1) memcpy(values.data(),a2,a1*4);add([=](Replay &r) { r.graphics.constants(a0,a3,values); },true); }
    void STDMETHODCALLTYPE SetComputeRootConstantBufferView(UINT a0,D3D12_GPU_VIRTUAL_ADDRESS a1) override { add([=](Replay &r) { r.computeRoot.address(a0,a1,D3D12_ROOT_PARAMETER_TYPE_CBV); },true); }
    void STDMETHODCALLTYPE SetGraphicsRootConstantBufferView(UINT a0,D3D12_GPU_VIRTUAL_ADDRESS a1) override { add([=](Replay &r) { r.graphics.address(a0,a1,D3D12_ROOT_PARAMETER_TYPE_CBV); },true); }
    void STDMETHODCALLTYPE SetComputeRootShaderResourceView(UINT a0,D3D12_GPU_VIRTUAL_ADDRESS a1) override { add([=](Replay &r) { r.computeRoot.address(a0,a1,D3D12_ROOT_PARAMETER_TYPE_SRV); },true); }
    void STDMETHODCALLTYPE SetGraphicsRootShaderResourceView(UINT a0,D3D12_GPU_VIRTUAL_ADDRESS a1) override { add([=](Replay &r) { r.graphics.address(a0,a1,D3D12_ROOT_PARAMETER_TYPE_SRV); },true); }
    void STDMETHODCALLTYPE SetComputeRootUnorderedAccessView(UINT a0,D3D12_GPU_VIRTUAL_ADDRESS a1) override { add([=](Replay &r) { r.computeRoot.address(a0,a1,D3D12_ROOT_PARAMETER_TYPE_UAV); },true); }
    void STDMETHODCALLTYPE SetGraphicsRootUnorderedAccessView(UINT a0,D3D12_GPU_VIRTUAL_ADDRESS a1) override { add([=](Replay &r) { r.graphics.address(a0,a1,D3D12_ROOT_PARAMETER_TYPE_UAV); },true); }
    void STDMETHODCALLTYPE IASetIndexBuffer(const D3D12_INDEX_BUFFER_VIEW *a0) override { D3D12_INDEX_BUFFER_VIEW value{};if (a0) value=*a0;add([=](Replay &r) { r.index=value; },true); }
    void STDMETHODCALLTYPE IASetVertexBuffers(UINT a0,UINT a1,const D3D12_VERTEX_BUFFER_VIEW *a2) override { require(a0<=32 && a1<=32-a0,"vertex buffer slots");std::vector<D3D12_VERTEX_BUFFER_VIEW> values(a1);if (a2 && a1) memcpy(values.data(),a2,a1*sizeof *a2);add([=](Replay &r) { std::copy(values.begin(),values.end(),r.vertex.begin()+a0); },true); }
    void STDMETHODCALLTYPE SOSetTargets(UINT a0,UINT a1,const D3D12_STREAM_OUTPUT_BUFFER_VIEW *a2) override { unsupported("SOSetTargets"); }
    void STDMETHODCALLTYPE OMSetRenderTargets(UINT a0,const D3D12_CPU_DESCRIPTOR_HANDLE *a1,WINBOOL a2,const D3D12_CPU_DESCRIPTOR_HANDLE *a3) override { require(a0<=8 && (!a0 || a1),"render target count");std::vector<Attachment> colors;for (UINT i=0;i<a0;++i) { auto handle=a1[a2?0:i];if (a2) handle.ptr+=i*descriptor_stride(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);colors.push_back(attachment(device,handle,D3D12_DESCRIPTOR_HEAP_TYPE_RTV)); }Attachment depth;if (a3) depth=attachment(device,*a3,D3D12_DESCRIPTOR_HEAP_TYPE_DSV);add([=](Replay &r) { r.targets(colors,depth); }); }
    void STDMETHODCALLTYPE ClearDepthStencilView(D3D12_CPU_DESCRIPTOR_HANDLE a0,D3D12_CLEAR_FLAGS a1,FLOAT a2,UINT8 a3,UINT a4,const D3D12_RECT *a5) override { require(!a4 || a5,"depth clear rectangles");Clear value;value.target=attachment(device,a0,D3D12_DESCRIPTOR_HEAP_TYPE_DSV);value.depth=true;value.flags=a1;value.z=a2;value.stencil=a3;std::vector<D3D12_RECT> rects;if (a4) rects.assign(a5,a5+a4);add([=](Replay &r) { if (rects.empty()) r.clear(value);else r.partial_clear(value,rects); }); }
    void STDMETHODCALLTYPE ClearRenderTargetView(D3D12_CPU_DESCRIPTOR_HANDLE a0,const FLOAT a1[4],UINT a2,const D3D12_RECT *a3) override { require(a1 && (!a2 || a3),"render target clear arguments");Clear value;value.target=attachment(device,a0,D3D12_DESCRIPTOR_HEAP_TYPE_RTV);memcpy(value.color.data(),a1,16);std::vector<D3D12_RECT> rects;if (a2) rects.assign(a3,a3+a2);add([=](Replay &r) { if (rects.empty()) r.clear(value);else r.partial_clear(value,rects); }); }
    void record_uav_clear(D3D12_GPU_DESCRIPTOR_HANDLE gpu,D3D12_CPU_DESCRIPTOR_HANDLE cpu,ID3D12Resource *resource,const void *values,UINT count,const D3D12_RECT *rects,bool floating) {
        require(values && (!count || rects) && same_device(device,resource),"UAV clear arguments/device");
        ClearUAV value{};value.resource=resource;value.gpu=gpu;value.desc=clear_uav_desc(device,cpu,resource);value.floating=floating;
        const bool raw=value.desc.ViewDimension==D3D12_UAV_DIMENSION_BUFFER && (value.desc.Buffer.Flags&D3D12_BUFFER_UAV_FLAG_RAW);
        if (!raw) value.texture=(__bridge id<MTLTexture>)descriptor_view(device,cpu,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV).resource;
        memcpy(value.values.data(),values,16);if (count) value.rects.assign(rects,rects+count);
        add([=](Replay &r) { r.clear_uav(value); });
    }
    void STDMETHODCALLTYPE ClearUnorderedAccessViewUint(D3D12_GPU_DESCRIPTOR_HANDLE a0,D3D12_CPU_DESCRIPTOR_HANDLE a1,ID3D12Resource *a2,const UINT a3[4],UINT a4,const D3D12_RECT *a5) override { record_uav_clear(a0,a1,a2,a3,a4,a5,false); }
    void STDMETHODCALLTYPE ClearUnorderedAccessViewFloat(D3D12_GPU_DESCRIPTOR_HANDLE a0,D3D12_CPU_DESCRIPTOR_HANDLE a1,ID3D12Resource *a2,const FLOAT a3[4],UINT a4,const D3D12_RECT *a5) override { record_uav_clear(a0,a1,a2,a3,a4,a5,true); }
    void STDMETHODCALLTYPE DiscardResource(ID3D12Resource *a0,const D3D12_DISCARD_REGION *a1) override { unsupported("DiscardResource"); }
    void STDMETHODCALLTYPE BeginQuery(ID3D12QueryHeap *a0,D3D12_QUERY_TYPE a1,UINT a2) override { require(same_device(device,a0),"query heap device");add([=](Replay &r) { r.begin_query(static_cast<QueryHeap *>(a0),a1,a2); }); }
    void STDMETHODCALLTYPE EndQuery(ID3D12QueryHeap *a0,D3D12_QUERY_TYPE a1,UINT a2) override { require(same_device(device,a0),"query heap device");add([=](Replay &r) { r.end_query(static_cast<QueryHeap *>(a0),a1,a2); }); }
    void STDMETHODCALLTYPE ResolveQueryData(ID3D12QueryHeap *a0,D3D12_QUERY_TYPE a1,UINT a2,UINT a3,ID3D12Resource *a4,UINT64 a5) override { require(same_device(device,a0) && same_device(device,a4),"query resolve device");add([=](Replay &r) { r.resolve_queries(static_cast<QueryHeap *>(a0),a1,a2,a3,a4,a5); }); }
    void STDMETHODCALLTYPE SetPredication(ID3D12Resource *a0,UINT64 a1,D3D12_PREDICATION_OP a2) override { unsupported("SetPredication"); }
    void STDMETHODCALLTYPE SetMarker(UINT a0,const void *a1,UINT a2) override { (void)a0;(void)a1;(void)a2; }
    void STDMETHODCALLTYPE BeginEvent(UINT a0,const void *a1,UINT a2) override { (void)a0;(void)a1;(void)a2; }
    void STDMETHODCALLTYPE EndEvent() override {  }
    void STDMETHODCALLTYPE ExecuteIndirect(ID3D12CommandSignature *a0,UINT a1,ID3D12Resource *a2,UINT64 a3,ID3D12Resource *a4,UINT64 a5) override { require(same_device(device,a0) && same_device(device,a2) && (!a4 || same_device(device,a4)),"indirect device");add([=](Replay &r) { r.indirect(static_cast<Signature *>(a0),a1,a2,a3,a4,a5); }); }
    void STDMETHODCALLTYPE AtomicCopyBufferUINT(ID3D12Resource *a0,UINT64 a1,ID3D12Resource *a2,UINT64 a3,UINT a4,ID3D12Resource *const *a5,const D3D12_SUBRESOURCE_RANGE_UINT64 *a6) override { unsupported("AtomicCopyBufferUINT"); }
    void STDMETHODCALLTYPE AtomicCopyBufferUINT64(ID3D12Resource *a0,UINT64 a1,ID3D12Resource *a2,UINT64 a3,UINT a4,ID3D12Resource *const *a5,const D3D12_SUBRESOURCE_RANGE_UINT64 *a6) override { unsupported("AtomicCopyBufferUINT64"); }
    void STDMETHODCALLTYPE OMSetDepthBounds(FLOAT a0,FLOAT a1) override { unsupported("OMSetDepthBounds"); }
    void STDMETHODCALLTYPE SetSamplePositions(UINT a0,UINT a1,D3D12_SAMPLE_POSITION *a2) override { unsupported("SetSamplePositions"); }
    void STDMETHODCALLTYPE ResolveSubresourceRegion(ID3D12Resource *a0,UINT a1,UINT a2,UINT a3,ID3D12Resource *a4,UINT a5,D3D12_RECT *a6,DXGI_FORMAT a7,D3D12_RESOLVE_MODE a8) override { unsupported("ResolveSubresourceRegion"); }
    void STDMETHODCALLTYPE SetViewInstanceMask(UINT a0) override { unsupported("SetViewInstanceMask"); }
    void STDMETHODCALLTYPE WriteBufferImmediate(UINT a0,const D3D12_WRITEBUFFERIMMEDIATE_PARAMETER *a1,const D3D12_WRITEBUFFERIMMEDIATE_MODE *a2) override { unsupported("WriteBufferImmediate"); }
    void STDMETHODCALLTYPE SetProtectedResourceSession(ID3D12ProtectedResourceSession *a0) override { unsupported("SetProtectedResourceSession"); }
    void STDMETHODCALLTYPE BeginRenderPass(UINT a0,const D3D12_RENDER_PASS_RENDER_TARGET_DESC *a1,const D3D12_RENDER_PASS_DEPTH_STENCIL_DESC *a2,D3D12_RENDER_PASS_FLAGS a3) override { unsupported("BeginRenderPass"); }
    void STDMETHODCALLTYPE EndRenderPass() override { unsupported("EndRenderPass"); }
    void STDMETHODCALLTYPE InitializeMetaCommand(ID3D12MetaCommand *a0,const void *a1,SIZE_T a2) override { unsupported("InitializeMetaCommand"); }
    void STDMETHODCALLTYPE ExecuteMetaCommand(ID3D12MetaCommand *a0,const void *a1,SIZE_T a2) override { unsupported("ExecuteMetaCommand"); }
    void STDMETHODCALLTYPE BuildRaytracingAccelerationStructure(const D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC *a0,UINT a1,const D3D12_RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_DESC *a2) override { unsupported("BuildRaytracingAccelerationStructure"); }
    void STDMETHODCALLTYPE EmitRaytracingAccelerationStructurePostbuildInfo(const D3D12_RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_DESC *a0,UINT a1,const D3D12_GPU_VIRTUAL_ADDRESS *a2) override { unsupported("EmitRaytracingAccelerationStructurePostbuildInfo"); }
    void STDMETHODCALLTYPE CopyRaytracingAccelerationStructure(D3D12_GPU_VIRTUAL_ADDRESS a0,D3D12_GPU_VIRTUAL_ADDRESS a1,D3D12_RAYTRACING_ACCELERATION_STRUCTURE_COPY_MODE a2) override { unsupported("CopyRaytracingAccelerationStructure"); }
    void STDMETHODCALLTYPE SetPipelineState1(ID3D12StateObject *a0) override { unsupported("SetPipelineState1"); }
    void STDMETHODCALLTYPE DispatchRays(const D3D12_DISPATCH_RAYS_DESC *a0) override { unsupported("DispatchRays"); }
    void STDMETHODCALLTYPE RSSetShadingRate(D3D12_SHADING_RATE a0,const D3D12_SHADING_RATE_COMBINER *a1) override { unsupported("RSSetShadingRate"); }
    void STDMETHODCALLTYPE RSSetShadingRateImage(ID3D12Resource *a0) override { unsupported("RSSetShadingRateImage"); }
    void STDMETHODCALLTYPE DispatchMesh(UINT a0,UINT a1,UINT a2) override { unsupported("DispatchMesh"); }
    D3D12_COMMAND_LIST_TYPE type;
    Allocator *allocator=nullptr;
    UINT64 generation=0;
    bool open=false;
    std::vector<std::function<void(Replay &)>> operations;
    std::vector<Boundary> boundaries;
    std::vector<ResolveRange> resolveRanges;
};

HRESULT Allocator::Reset() {
    std::lock_guard guard(mutex);
    if (open.load()) return E_FAIL;
    ++generation;
    // Encoded Metal commands own their storage; invalid recordings can release captured views.
    for (auto *list:lists) list->discard_recording();
    return S_OK;
}

class Queue final : public Child<ID3D12CommandQueue>,public ID3DMMetalQueue {
public:
    Queue(ID3D12Device *device,id<MTLDevice> metal,const D3D12_COMMAND_QUEUE_DESC &desc):Child(device),metal(metal),queue([metal newCommandQueue]),order([metal newSharedEvent]),desc(desc) {}
    ULONG STDMETHODCALLTYPE AddRef() override { return Object<ID3D12CommandQueue>::AddRef(); }
    ULONG STDMETHODCALLTYPE Release() override { return Object<ID3D12CommandQueue>::Release(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **out) override {
        if (out && iid==__uuidof(ID3DMMetalQueue)) { AddRef();*out=static_cast<ID3DMMetalQueue *>(this);return S_OK; }
        return query<IUnknown,ID3D12Object,ID3D12DeviceChild,ID3D12Pageable,ID3D12CommandQueue>(iid,out);
    }
    void *STDMETHODCALLTYPE MetalCommandQueue() override { return (__bridge void *)queue; }
    id<MTLCommandBuffer> next_buffer() {
        // Separate D3D12 submissions finish in order, including indirect resources without Metal hazard tracking.
        auto commands=[queue commandBuffer];if (ticket) [commands encodeWaitForEvent:order value:ticket];return commands;
    }
    void commit(id<MTLCommandBuffer> commands) {
        require(ticket<UINT64_MAX-1,"queue sequence exhausted");[commands encodeSignalEvent:order value:++ticket];
        track_device_errors(static_cast<ID3D12CommandQueue *>(this),commands);auto event=order;
        [commands addCompletedHandler:^(id<MTLCommandBuffer> done) { if (done.status==MTLCommandBufferStatusError) event.signaledValue=UINT64_MAX; }];
        [commands commit];
    }
    void STDMETHODCALLTYPE ExecuteCommandLists(UINT count,ID3D12CommandList *const *lists) override { @autoreleasepool {
        require(!count || lists,"null command lists");if (FAILED(device->GetDeviceRemovedReason())) return;
        std::lock_guard lock(mutex);
        std::erase_if(uploadWaits,[](const auto &wait) { return wait.first.signaledValue>=wait.second; });
        auto commands=next_buffer();Replay replay(device,metal,commands,upscaler,uploadWaits.empty());
        for (UINT i=0;i<count;++i) {
            require(same_device(device,lists[i]),"foreign command list");auto *list=static_cast<CommandList *>(lists[i]);
            require(list->type==desc.Type || (desc.Type==D3D12_COMMAND_LIST_TYPE_DIRECT && list->type==D3D12_COMMAND_LIST_TYPE_COMPUTE),"command list queue type");
            list->replay(replay);
        }
        replay.finish(true);commit(commands);
    }}
    HRESULT STDMETHODCALLTYPE Signal(ID3D12Fence *value,UINT64 number) override { @autoreleasepool {
        if (!same_device(device,value)) return E_INVALIDARG;
        const HRESULT reason=device->GetDeviceRemovedReason();if (FAILED(reason)) return reason;
        auto *f=static_cast<Fence *>(value);HRESULT hr=f->reserve(number);if (FAILED(hr)) return hr;
        std::lock_guard lock(mutex);auto commands=next_buffer();auto event=f->event;
        [commands encodeSignalEvent:event value:number];
        [commands addCompletedHandler:^(id<MTLCommandBuffer> done) { if (done.status==MTLCommandBufferStatusError) event.signaledValue=UINT64_MAX; }];
        commit(commands);return S_OK;
    }}
    HRESULT STDMETHODCALLTYPE Wait(ID3D12Fence *value,UINT64 number) override { @autoreleasepool {
        if (!same_device(device,value)) return E_INVALIDARG;
        const HRESULT reason=device->GetDeviceRemovedReason();if (FAILED(reason)) return reason;
        std::lock_guard lock(mutex);auto commands=next_buffer();[commands encodeWaitForEvent:static_cast<Fence *>(value)->event value:number];
        // A future fence permits CPU upload writes after ExecuteCommandLists (ID3D12Resource::Map).
        uploadWaits.emplace_back(static_cast<Fence *>(value)->event,number);
        commit(commands);return S_OK;
    }}
    HRESULT STDMETHODCALLTYPE GetTimestampFrequency(UINT64 *frequency) override { if (!frequency) return E_POINTER;*frequency=1000000000;return S_OK; }
    HRESULT STDMETHODCALLTYPE GetClockCalibration(UINT64 *gpu,UINT64 *cpu) override {
        if (!gpu || !cpu) return E_POINTER;MTLTimestamp sampled_cpu=0,sampled_gpu=0;[metal sampleTimestamps:&sampled_cpu gpuTimestamp:&sampled_gpu];
        *gpu=sampled_gpu;*cpu=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);return S_OK;
    }
    D3D12_COMMAND_QUEUE_DESC STDMETHODCALLTYPE GetDesc() override { return desc; }
    void STDMETHODCALLTYPE SetMarker(UINT,const void *,UINT) override {}
    void STDMETHODCALLTYPE BeginEvent(UINT,const void *,UINT) override {}
    void STDMETHODCALLTYPE EndEvent() override {}
    void STDMETHODCALLTYPE UpdateTileMappings(ID3D12Resource *,UINT,const D3D12_TILED_RESOURCE_COORDINATE *,const D3D12_TILE_REGION_SIZE *,ID3D12Heap *,UINT,const D3D12_TILE_RANGE_FLAGS *,const UINT *,const UINT *,D3D12_TILE_MAPPING_FLAGS) override { unsupported("UpdateTileMappings"); }
    void STDMETHODCALLTYPE CopyTileMappings(ID3D12Resource *,const D3D12_TILED_RESOURCE_COORDINATE *,ID3D12Resource *,const D3D12_TILED_RESOURCE_COORDINATE *,const D3D12_TILE_REGION_SIZE *,D3D12_TILE_MAPPING_FLAGS) override { unsupported("CopyTileMappings"); }
    id<MTLDevice> metal;
    id<MTLCommandQueue> queue;
    id<MTLSharedEvent> order;
    UINT64 ticket=0;
    D3D12_COMMAND_QUEUE_DESC desc;
    SpatialUpscaler upscaler;
    std::vector<std::pair<id<MTLSharedEvent>,UINT64>> uploadWaits;
    std::mutex mutex;
};
}
void signal_removed_fences(ID3D12Device *device) {
    std::lock_guard lock(fence_mutex);const auto range=device_fences.equal_range(device);
    for (auto i=range.first;i!=range.second;++i) i->second->event.signaledValue=UINT64_MAX;
}
HRESULT create_command_allocator(ID3D12Device *device,D3D12_COMMAND_LIST_TYPE type,REFIID iid,void **out) {
    if (out) *out=nullptr;if (!list_type(type)) return E_INVALIDARG;
    auto *value=new(std::nothrow) Allocator(device,type);if (!value) return E_OUTOFMEMORY;return finish(value,iid,out);
}
HRESULT create_command_list(ID3D12Device *device,id<MTLDevice>,UINT node,D3D12_COMMAND_LIST_TYPE type,ID3D12CommandAllocator *allocator,ID3D12PipelineState *initial,REFIID iid,void **out) {
    if (out) *out=nullptr;if (node>1 || !list_type(type)) return E_INVALIDARG;
    auto *value=new(std::nothrow) CommandList(device,type);if (!value) return E_OUTOFMEMORY;
    const HRESULT hr=value->begin(allocator,initial);if (FAILED(hr)) { value->Release();return hr; }return finish(value,iid,out);
}
HRESULT create_command_queue(ID3D12Device *device,id<MTLDevice> metal,const D3D12_COMMAND_QUEUE_DESC *desc,REFIID iid,void **out) {
    if (out) *out=nullptr;
    if (!desc || !list_type(desc->Type) || desc->Type==D3D12_COMMAND_LIST_TYPE_BUNDLE || desc->NodeMask>1 || desc->Flags!=D3D12_COMMAND_QUEUE_FLAG_NONE) return E_INVALIDARG;
    auto *value=new(std::nothrow) Queue(device,metal,*desc);if (!value) return E_OUTOFMEMORY;
    if (!value->queue || !value->order) { value->Release();return E_OUTOFMEMORY; }return finish(value,iid,out);
}
HRESULT create_fence(ID3D12Device *device,id<MTLDevice> metal,UINT64 value,D3D12_FENCE_FLAGS flags,REFIID iid,void **out) {
    if (out) *out=nullptr;if (flags!=D3D12_FENCE_FLAG_NONE || value==UINT64_MAX) return E_INVALIDARG;
    auto *fence=new(std::nothrow) Fence(device,metal,value);if (!fence) return E_OUTOFMEMORY;
    if (!fence->event) { fence->Release();return E_OUTOFMEMORY; }return finish(fence,iid,out);
}
HRESULT create_command_signature(ID3D12Device *device,const D3D12_COMMAND_SIGNATURE_DESC *desc,ID3D12RootSignature *root,REFIID iid,void **out) {
    if (out) *out=nullptr;
    if (!desc || !desc->pArgumentDescs || desc->NumArgumentDescs!=1 || desc->NodeMask>1 || root) return E_INVALIDARG;
    const auto type=desc->pArgumentDescs[0].Type;UINT size=0;
    switch (type) {
    case D3D12_INDIRECT_ARGUMENT_TYPE_DRAW:size=sizeof(D3D12_DRAW_ARGUMENTS);break;
    case D3D12_INDIRECT_ARGUMENT_TYPE_DRAW_INDEXED:size=sizeof(D3D12_DRAW_INDEXED_ARGUMENTS);break;
    case D3D12_INDIRECT_ARGUMENT_TYPE_DISPATCH:size=sizeof(D3D12_DISPATCH_ARGUMENTS);break;
    default:return DXGI_ERROR_UNSUPPORTED;
    }
    if (desc->ByteStride<size || desc->ByteStride%4) return E_INVALIDARG;
    auto *value=new(std::nothrow) Signature(device,desc->ByteStride,type);if (!value) return E_OUTOFMEMORY;return finish(value,iid,out);
}
HRESULT create_query_heap(ID3D12Device *device,id<MTLDevice> metal,const D3D12_QUERY_HEAP_DESC *desc,REFIID iid,void **out) {
    if (out) *out=nullptr;
    if (!desc || !desc->Count || desc->Count>65536 || desc->NodeMask>1) return E_INVALIDARG;
    if (desc->Type!=D3D12_QUERY_HEAP_TYPE_TIMESTAMP && desc->Type!=D3D12_QUERY_HEAP_TYPE_COPY_QUEUE_TIMESTAMP && desc->Type!=D3D12_QUERY_HEAP_TYPE_OCCLUSION) return DXGI_ERROR_UNSUPPORTED;
    auto *heap=new(std::nothrow) QueryHeap(device,*desc);if (!heap) return E_OUTOFMEMORY;
    if (desc->Type==D3D12_QUERY_HEAP_TYPE_OCCLUSION) {
        if (@available(macOS 26.0,*)) heap->visibility=[metal newBufferWithLength:desc->Count*8ull options:MTLResourceStorageModePrivate];
    } else {
        auto buffer=[MTLCounterSampleBufferDescriptor new];buffer.sampleCount=desc->Count;buffer.storageMode=MTLStorageModePrivate;
        for (id<MTLCounterSet> set in metal.counterSets) if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) { buffer.counterSet=set;break; }
        if (buffer.counterSet && [metal supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) heap->timestamps=[metal newCounterSampleBufferWithDescriptor:buffer error:nil];
    }
    if (!heap->timestamps && !heap->visibility) { heap->Release();return DXGI_ERROR_UNSUPPORTED; }
    return finish(heap,iid,out);
}
void copyable_footprints(const D3D12_RESOURCE_DESC *d,UINT first,UINT count,UINT64 offset,D3D12_PLACED_SUBRESOURCE_FOOTPRINT *layouts,UINT *rows,UINT64 *sizes,UINT64 *total) {
    if (total) *total=UINT64_MAX;
    if (!d || !d->Width || !d->Height || !d->DepthOrArraySize || d->Dimension<D3D12_RESOURCE_DIMENSION_BUFFER || d->Dimension>D3D12_RESOURCE_DIMENSION_TEXTURE3D) return;
    const auto info=format_info(d->Format);
    const bool is_buffer=d->Dimension==D3D12_RESOURCE_DIMENSION_BUFFER;
    const UINT arrays=d->Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE3D?1:d->DepthOrArraySize;
    UINT64 largest=std::max(d->Width,(UINT64)d->Height);
    if (d->Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE3D) largest=std::max(largest,(UINT64)d->DepthOrArraySize);
    const UINT mips=d->MipLevels?d->MipLevels:(UINT)std::bit_width(largest);
    if (mips>64) return;
    const UINT64 subresources=is_buffer?1:(UINT64)mips*arrays*info.planes;
    if ((!is_buffer && !info.bytes) || first>subresources || count>subresources-first) return;
    const UINT64 base=offset;UINT64 end=0;
    for (UINT i=0;i<count;++i) {
        const UINT mip=(first+i)%mips,plane=is_buffer?0:(first+i)/(mips*arrays);
        const UINT block=is_buffer?1:info.block;
        const UINT64 width=(std::max<UINT64>(1,d->Width>>mip)+block-1)/block*block;
        if (width>UINT_MAX) return;
        const UINT height=(std::max<UINT64>(1,(UINT64)d->Height>>mip)+block-1)/block*block;
        const UINT depth=d->Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE3D?(UINT)std::max<UINT64>(1,(UINT64)d->DepthOrArraySize>>mip):1;
        UINT bytes=is_buffer?1:info.bytes;DXGI_FORMAT format=d->Format;UINT alignment=256;
        if (!is_buffer && info.planes==2) { bytes=plane?1:4;format=plane?DXGI_FORMAT_R8_TYPELESS:DXGI_FORMAT_R32_TYPELESS;alignment=512; }
        const UINT nrows=height/block;const UINT64 row=width/block*bytes,pitch=(row+alignment-1)&~UINT64(alignment-1);
        if (pitch>UINT_MAX || pitch>UINT64_MAX/nrows/depth) return;
        if (end>UINT64_MAX-511) return;
        offset=(end+511)&~UINT64_C(511);const UINT64 size=pitch*((UINT64)nrows*depth-1)+row;
        if (size>UINT64_MAX-offset || base>UINT64_MAX-offset-size) return;
        if (layouts) layouts[i]={base+offset,{format,(UINT)width,height,depth,(UINT)pitch}};
        if (rows) rows[i]=nrows;if (sizes) sizes[i]=row;end=offset+size;
    }
    if (total) *total=end;
}
}
