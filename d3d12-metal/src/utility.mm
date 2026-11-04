#include "utility.h"
#include "formats.h"
#include "utility_metallib.h"
#include <map>
#include <string>
#include <tuple>
#include <cstdio>
#include <cstdlib>

namespace d3dm {
namespace {
std::mutex utility_mutex;
std::map<uint64_t,id<MTLLibrary>> libraries;
std::map<std::pair<uint64_t,std::string>,id<MTLComputePipelineState>> pipelines;
std::map<std::tuple<uint64_t,NSUInteger,NSUInteger,NSUInteger>,id<MTLRenderPipelineState>> clears;
}
id<MTLFunction> utility_function(id<MTLDevice> metal,NSString *name) {
    std::lock_guard lock(utility_mutex);
    auto &library=libraries[metal.registryID];
    if (!library) {
        auto bytes=dispatch_data_create(d3dm_utility,d3dm_utility_len,nullptr,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError *error=nil;library=[metal newLibraryWithData:bytes error:&error];
        if (!library) { std::fprintf(stderr,"d3d12-metal utility library: %s\n",error.localizedDescription.UTF8String);std::abort(); }
    }
    auto function=[library newFunctionWithName:name];
    if (!function) { std::fprintf(stderr,"d3d12-metal utility function: %s\n",name.UTF8String);std::abort(); }
    return function;
}
id<MTLComputePipelineState> utility_compute(id<MTLDevice> metal,NSString *name) {
    auto function=utility_function(metal,name);
    std::lock_guard lock(utility_mutex);
    auto &pipeline=pipelines[{metal.registryID,name.UTF8String}];
    if (!pipeline) {
        NSError *error=nil;pipeline=[metal newComputePipelineStateWithFunction:function error:&error];
        if (!pipeline) { std::fprintf(stderr,"d3d12-metal utility pipeline: %s\n",error.localizedDescription.UTF8String);std::abort(); }
    }
    return pipeline;
}
id<MTLRenderPipelineState> utility_clear(id<MTLDevice> metal,MTLPixelFormat color,MTLPixelFormat depth,NSUInteger samples) {
    NSString *fragment=@"clear_color";
    switch (color) {
    case MTLPixelFormatR8Uint:case MTLPixelFormatRG8Uint:case MTLPixelFormatRGBA8Uint:
    case MTLPixelFormatR16Uint:case MTLPixelFormatRG16Uint:case MTLPixelFormatRGBA16Uint:
    case MTLPixelFormatR32Uint:case MTLPixelFormatRG32Uint:case MTLPixelFormatRGBA32Uint:case MTLPixelFormatRGB10A2Uint:fragment=@"clear_uint_color";break;
    case MTLPixelFormatR8Sint:case MTLPixelFormatRG8Sint:case MTLPixelFormatRGBA8Sint:
    case MTLPixelFormatR16Sint:case MTLPixelFormatRG16Sint:case MTLPixelFormatRGBA16Sint:
    case MTLPixelFormatR32Sint:case MTLPixelFormatRG32Sint:case MTLPixelFormatRGBA32Sint:fragment=@"clear_int_color";break;
    default:break;
    }
    auto vertex=utility_function(metal,@"clear_vertex"),pixel=utility_function(metal,fragment);
    std::lock_guard lock(utility_mutex);auto &pipeline=clears[{metal.registryID,color,depth,samples}];
    if (!pipeline) {
        auto desc=[MTLRenderPipelineDescriptor new];desc.vertexFunction=vertex;desc.inputPrimitiveTopology=MTLPrimitiveTopologyClassTriangle;
        if (color!=MTLPixelFormatInvalid) { desc.fragmentFunction=pixel;desc.colorAttachments[0].pixelFormat=color; }
        desc.rasterSampleCount=samples;desc.depthAttachmentPixelFormat=depth;
        if (depth==MTLPixelFormatDepth32Float_Stencil8 || depth==format_info(DXGI_FORMAT_D24_UNORM_S8_UINT).metal) desc.stencilAttachmentPixelFormat=depth;
        NSError *error=nil;pipeline=[metal newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!pipeline) { std::fprintf(stderr,"d3d12-metal partial clear pipeline: %s\n",error.localizedDescription.UTF8String);std::abort(); }
    }
    return pipeline;
}
}
