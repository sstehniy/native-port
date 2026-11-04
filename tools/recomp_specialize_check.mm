#import <Metal/Metal.h>
#include <array>
#include <cassert>
#include <cstdio>
#include <cstring>

static id<MTLFunction> function(id<MTLDevice> device,const char *base) {
    NSString *path=@(base);NSData *bytes=[NSData dataWithContentsOfFile:[path stringByAppendingPathExtension:@"metallib"]];assert(bytes);
    dispatch_data_t data=dispatch_data_create(bytes.bytes,bytes.length,nullptr,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *error=nil;auto library=[device newLibraryWithData:data error:&error];assert(library);
    NSDictionary *json=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[path stringByAppendingPathExtension:@"json"]] options:0 error:nil];
    auto result=[library newFunctionWithName:json[@"EntryPoint"]];assert(result);return result;
}

int main(int argc,const char **argv) { @autoreleasepool {
    assert(argc==3);auto device=MTLCreateSystemDefaultDevice();assert(device);auto queue=[device newCommandQueue];
    NSError *error=nil;
    auto vertex=[device newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;vertex float4 vs(uint i [[vertex_id]]) { const float2 p[]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],0,1); }" options:nil error:&error];assert(vertex);
    std::array<id<MTLRenderPipelineState>,2> pipelines;
    std::array<id<MTLTexture>,2> targets;
    for (unsigned i=0;i<2;++i) {
        auto pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[vertex newFunctionWithName:@"vs"];pd.fragmentFunction=function(device,argv[i+1]);pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA32Float;
        pipelines[i]=[device newRenderPipelineStateWithDescriptor:pd error:&error];assert(pipelines[i]);
        auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget;
        targets[i]=[device newTextureWithDescriptor:td];assert(targets[i]);
    }
    auto upload=[device newBufferWithLength:1280 options:MTLResourceStorageModeShared];
    auto gpu=[device newBufferWithLength:1280 options:MTLResourceStorageModePrivate];assert(upload && gpu);
    const uint64_t root=gpu.gpuAddress;
    for (unsigned trial=0;trial<128;++trial) {
        const uint32_t mode=1;std::array<float,4> input,expected;
        for (unsigned i=0;i<4;++i) input[i]=(float)((int)(trial*17+i*31)%257-128)/16;
        expected=input;
        if (mode==1) for (unsigned i=0;i<4;++i) expected[i]+=(float)(i+1);
        else expected[0]+=(float)mode;
        memcpy(upload.contents,input.data(),sizeof input);memcpy((uint8_t *)upload.contents+760,&mode,4);
        auto commands=[queue commandBuffer];auto blit=[commands blitCommandEncoder];[blit copyFromBuffer:upload sourceOffset:0 toBuffer:gpu destinationOffset:0 size:1280];[blit endEncoding];
        for (unsigned i=0;i<2;++i) {
            auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=targets[i];pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
            auto render=[commands renderCommandEncoderWithDescriptor:pass];[render setRenderPipelineState:pipelines[i]];[render setFragmentBytes:&root length:8 atIndex:2];[render useResource:gpu usage:MTLResourceUsageRead stages:MTLRenderStageFragment];[render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[render endEncoding];
        }
        [commands commit];[commands waitUntilCompleted];assert(commands.status==MTLCommandBufferStatusCompleted);
        for (auto target:targets) {
            std::array<float,4> actual;[target getBytes:actual.data() bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
            if (memcmp(actual.data(),expected.data(),sizeof actual)) { fprintf(stderr,"pixel mismatch at mode %u trial %u\n",mode,trial);return 1; }
        }
    }
    puts("shader specialization: 128 active-preset GPU-only CBV cases match independent expected pixels in both libraries");
}}
