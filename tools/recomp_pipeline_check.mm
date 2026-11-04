#import <Metal/Metal.h>
#include "../d3d12-metal/include/d3d12_metal.h"
#include "../runtime/shader_cache.h"
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

static std::vector<uint8_t> unhex(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length%2) return {};
    std::vector<uint8_t> bytes(text.length/2); const char *p=text.UTF8String;
    for (size_t i=0;i<bytes.size();++i) { unsigned value=0;if (sscanf(p+i*2,"%2x",&value)!=1) return {};bytes[i]=(uint8_t)value; }
    return bytes;
}
int main(int argc,const char **argv) { @autoreleasepool {
    if (argc!=2) return 2;
    NSData *file=[NSData dataWithContentsOfFile:@(argv[1])];NSError *error=nil;
    NSDictionary *capture=file?[NSJSONSerialization JSONObjectWithData:file options:0 error:&error]:nil;
    if (!capture) return 2;
    D3DMHost host{};host.load_shader=rt_load_shader;host.pipeline_archive=rt_pipeline_archive_path();
    host.check_feature=[](D3D12_FEATURE feature,void *data,UINT size)->HRESULT {
        if (feature!=D3D12_FEATURE_FEATURE_LEVELS || size!=sizeof(D3D12_FEATURE_DATA_FEATURE_LEVELS)) return E_INVALIDARG;
        ((D3D12_FEATURE_DATA_FEATURE_LEVELS *)data)->MaxSupportedFeatureLevel=D3D_FEATURE_LEVEL_12_2;return S_OK;
    };
    D3DMSetHost(&host);ID3D12Device *device=nullptr;
    if (FAILED(D3DMCreateDevice(nullptr,D3D_FEATURE_LEVEL_12_0,__uuidof(ID3D12Device),(void **)&device))) return 2;
    std::map<uint64_t,ID3D12RootSignature *> roots;unsigned graphics=0,compute=0;
    for (NSDictionary *record in capture[@"records"]) { @autoreleasepool {
        if ([record[@"result"] unsignedIntValue]) return 2;
        if ([record[@"kind"] isEqual:@"root"]) {
            auto blob=unhex(record[@"blob"]);ID3D12RootSignature *root=nullptr;
            if (FAILED(device->CreateRootSignature(0,blob.data(),blob.size(),__uuidof(ID3D12RootSignature),(void **)&root))) return 1;
            auto &previous=roots[[record[@"object"] unsignedLongLongValue]];if (previous) previous->Release();previous=root;continue;
        }
        auto found=roots.find([record[@"root"] unsignedLongLongValue]);if (found==roots.end()) return 2;
        ID3D12PipelineState *state=nullptr;HRESULT hr=E_FAIL;
        if ([record[@"kind"] isEqual:@"compute"]) {
            auto code=unhex(record[@"cs"]),raw=unhex(record[@"desc"]);D3D12_COMPUTE_PIPELINE_STATE_DESC d{};
            if (!raw.empty()) { if (raw.size()!=sizeof d) return 2;memcpy(&d,raw.data(),sizeof d); }
            d.pRootSignature=found->second;d.CS={code.data(),code.size()};
            hr=device->CreateComputePipelineState(&d,__uuidof(ID3D12PipelineState),(void **)&state);++compute;
        } else {
            auto raw=unhex(record[@"desc"]),vs=unhex(record[@"vs"]),ps=unhex(record[@"ps"]);
            if (raw.size()!=sizeof(D3D12_GRAPHICS_PIPELINE_STATE_DESC)) return 2;
            D3D12_GRAPHICS_PIPELINE_STATE_DESC d;memcpy(&d,raw.data(),sizeof d);
            d.pRootSignature=found->second;d.VS={vs.data(),vs.size()};d.PS={ps.data(),ps.size()};
            NSArray *inputs=record[@"inputs"];if (inputs.count!=d.InputLayout.NumElements) return 2;
            std::vector<D3D12_INPUT_ELEMENT_DESC> elements(inputs.count);std::vector<std::string> names;names.reserve(inputs.count);
            for (NSUInteger i=0;i<inputs.count;++i) {
                NSDictionary *e=inputs[i];names.emplace_back([e[@"semantic"] UTF8String]);
                elements[i]={names.back().c_str(),[e[@"index"] unsignedIntValue],(DXGI_FORMAT)[e[@"format"] unsignedIntValue],
                    [e[@"slot"] unsignedIntValue],[e[@"offset"] unsignedIntValue],(D3D12_INPUT_CLASSIFICATION)[e[@"class"] unsignedIntValue],[e[@"step"] unsignedIntValue]};
            }
            d.InputLayout.pInputElementDescs=elements.data();
            hr=device->CreateGraphicsPipelineState(&d,__uuidof(ID3D12PipelineState),(void **)&state);++graphics;
        }
        if (FAILED(hr) || !state) { fprintf(stderr,"pipeline_check: graphics=%u compute=%u HRESULT=%08x\n",graphics,compute,(unsigned)hr);return 1; }
        ID3D12Device *owner=nullptr;
        if (FAILED(state->GetDevice(__uuidof(ID3D12Device),(void **)&owner)) || owner!=device) return 1;
        owner->Release();state->Release();
    }}
    for (auto &[key,root]:roots) root->Release();
    if (FAILED(D3DMFlushPipelineArchive())) return 1;
    if (device->Release()!=0 || !graphics || !compute) return 1;
    printf("pipeline_check: %u graphics and %u compute pipelines passed\n",graphics,compute);return 0;
}}
