#import <Metal/Metal.h>
#include "d3d12_metal.h"
#include "shader_cache.h"
#include <CommonCrypto/CommonDigest.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <mutex>
#include <string>

namespace {
struct Shader {
    id<MTLLibrary> library,specializedLibrary;
    std::string entry,reflection,specializedEntry;
    std::array<UINT,3> threads{};
    UINT parameter=0,index=0,offset=0,value=0;
};
std::mutex shader_mutex;
std::map<std::pair<uint64_t,std::string>,Shader> shaders;
}

const char *rt_pipeline_archive_path() {
    static const std::string path=[] {
        if (const char *configured=std::getenv("SS_PIPELINE_ARCHIVE")) return std::string(configured);
        NSString *directory;
        if (const char *configured=std::getenv("SS_SHADER_CACHE")) directory=@(configured);
        else directory=[[[NSProcessInfo processInfo].arguments[0] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"shaders/cache"];
        return std::string([[directory stringByAppendingPathComponent:@"pipelines.metalarc"] fileSystemRepresentation]);
    }();
    return path.c_str();
}

bool rt_spatial_upscale_source(const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc, UINT *parameter, UINT *index) {
    const char *enabled=std::getenv("SS_METALFX");
    if (!enabled || strcmp(enabled,"1")) return false;
    auto matches=[](D3D12_SHADER_BYTECODE code,const char *expected) {
        if (!code.pShaderBytecode || !code.BytecodeLength || code.BytecodeLength>UINT32_MAX) return false;
        unsigned char hash[CC_SHA256_DIGEST_LENGTH];char text[65];
        CC_SHA256(code.pShaderBytecode,(CC_LONG)code.BytecodeLength,hash);
        for (size_t i=0;i<sizeof hash;++i) snprintf(text+i*2,3,"%02x",hash[i]);
        return !strcmp(text,expected);
    };
    // shortcut: approve the traced post-FXAA SDR copy only; extend after other shader variants are verified.
    if (!matches(desc->VS,"171f6529530042caf5de924f06cb5c4559c5863d0d96c47086b58751e9e91d17") ||
        !matches(desc->PS,"c489b88b4ebce41be92067a131fd3085c9d8c349d7a92c354cde252116e9cdc7")) return false;
    ID3DMRootSignature *root=nullptr;
    if (!desc->pRootSignature || FAILED(desc->pRootSignature->QueryInterface(__uuidof(ID3DMRootSignature),(void **)&root))) return false;
    const auto &layout=*root->GetLayout();
    const bool matched=matches({layout.serialized,layout.serializedSize},"44b94f3f63267c877403350dfd7414660d2dc7d888410cdbcba1bc653312503d");
    root->Release();if (!matched) return false;
    *parameter=0;*index=0;return true;
}

HRESULT rt_load_shader(void *native_metal,const void *root,SIZE_T root_size,const void *code,SIZE_T code_size,UINT mask,D3DMShader *out) {
    if (!out) return E_POINTER;
    *out={};
    if (!root || !code || !root_size || !code_size || root_size>UINT32_MAX || code_size>UINT32_MAX || mask>255) return E_INVALIDARG;
    std::array<uint8_t,72> input{};
    CC_SHA256(root,(CC_LONG)root_size,input.data()); CC_SHA256(code,(CC_LONG)code_size,input.data()+32);
    const UINT flags=0x130;
    memcpy(input.data()+64,&flags,4); memcpy(input.data()+68,&mask,4);
    std::array<uint8_t,32> digest; CC_SHA256(input.data(),(CC_LONG)input.size(),digest.data());
    char text[65];
    for (size_t i=0;i<digest.size();++i) snprintf(text+i*2,3,"%02x",digest[i]);
    id<MTLDevice> metal=(__bridge id<MTLDevice>)native_metal;
    if (!metal) return E_INVALIDARG;
    std::lock_guard lock(shader_mutex);
    const auto key=std::make_pair(metal.registryID,std::string(text));
    auto found=shaders.find(key);
    if (found==shaders.end()) { @autoreleasepool {
        NSString *directory;
        if (const char *path=std::getenv("SS_SHADER_CACHE")) directory=@(path);
        else directory=[[[NSProcessInfo processInfo].arguments[0] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"shaders/cache"];
        NSString *base=[directory stringByAppendingPathComponent:@(text)];
        NSData *json=[NSData dataWithContentsOfFile:[base stringByAppendingPathExtension:@"json"]];
        NSDictionary *reflection=json?[NSJSONSerialization JSONObjectWithData:json options:0 error:nil]:nil;
        if (reflection && ![reflection isKindOfClass:[NSDictionary class]]) reflection=nil;
        NSError *error=nil;
        // URL-backed libraries retain files and exhaust the GUI app's descriptor budget.
        NSData *bytes=[NSData dataWithContentsOfFile:[base stringByAppendingPathExtension:@"metallib"] options:0 error:&error];
        dispatch_data_t data=bytes?dispatch_data_create(bytes.bytes,bytes.length,nullptr,DISPATCH_DATA_DESTRUCTOR_DEFAULT):nullptr;
        id<MTLLibrary> library=data?[metal newLibraryWithData:data error:&error]:nil;
        NSString *entry=reflection[@"EntryPoint"];
        if (!library || ![entry isKindOfClass:[NSString class]] || !entry.length) {
            std::fprintf(stderr,"shader cache miss %s mask=%u: %s\n",text,mask,error.localizedDescription.UTF8String ?: "invalid reflection");
            return DXGI_ERROR_UNSUPPORTED;
        }
        library.label=@(text);
        Shader shader; shader.library=library; shader.entry=entry.UTF8String;
        shader.reflection.assign((const char *)json.bytes,json.length);
        NSDictionary *state=reflection[@"state"];
        if (![state isKindOfClass:[NSDictionary class]]) return E_INVALIDARG;
        NSArray *threads=state[@"tg_size"];
        if (threads) {
            if (![threads isKindOfClass:[NSArray class]] || threads.count!=3) return E_INVALIDARG;
            for (NSUInteger i=0;i<3;++i) {
                if (![threads[i] isKindOfClass:[NSNumber class]]) return E_INVALIDARG;
                const NSInteger n=[threads[i] integerValue]; if (n<=0 || n>1024) return E_INVALIDARG;
                shader.threads[i]=(UINT)n;
            }
        }
        NSDictionary *variant=reflection[@"specialization"];
        if (variant) {
            if (![variant isKindOfClass:[NSDictionary class]]) return E_INVALIDARG;
            NSString *key=variant[@"key"];
            if (![key isKindOfClass:[NSString class]] || key.length!=64 ||
                [key rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location!=NSNotFound) return E_INVALIDARG;
            for (NSString *field in @[@"parameter",@"index",@"offset",@"value"])
                if (![variant[field] isKindOfClass:[NSNumber class]] || [variant[field] longLongValue]<0 || [variant[field] unsignedLongLongValue]>UINT_MAX) return E_INVALIDARG;
            shader.parameter=[variant[@"parameter"] unsignedIntValue];shader.index=[variant[@"index"] unsignedIntValue];
            shader.offset=[variant[@"offset"] unsignedIntValue];shader.value=[variant[@"value"] unsignedIntValue];
            if (shader.parameter>=64 || shader.offset%4) return E_INVALIDARG;
            NSString *variantBase=[directory stringByAppendingPathComponent:key];
            NSData *variantBytes=[NSData dataWithContentsOfFile:[variantBase stringByAppendingPathExtension:@"metallib"]];
            NSData *variantJSON=[NSData dataWithContentsOfFile:[variantBase stringByAppendingPathExtension:@"json"]];
            NSDictionary *variantReflection=variantJSON?[NSJSONSerialization JSONObjectWithData:variantJSON options:0 error:nil]:nil;
            if (![variantReflection isKindOfClass:[NSDictionary class]]) return E_INVALIDARG;
            NSString *entry=variantReflection[@"EntryPoint"];
            if (![entry isKindOfClass:[NSString class]] || !entry.length) return E_INVALIDARG;
            dispatch_data_t data=variantBytes?dispatch_data_create(variantBytes.bytes,variantBytes.length,nullptr,DISPATCH_DATA_DESTRUCTOR_DEFAULT):nullptr;
            shader.specializedLibrary=data?[metal newLibraryWithData:data error:&error]:nil;
            if (!shader.specializedLibrary) return DXGI_ERROR_UNSUPPORTED;
            shader.specializedLibrary.label=key;shader.specializedEntry=entry.UTF8String;
        }
        found=shaders.emplace(key,std::move(shader)).first;
    }}
    auto &shader=found->second;
    *out={(__bridge void *)shader.library,shader.entry.c_str(),shader.reflection.c_str(),
          {shader.threads[0],shader.threads[1],shader.threads[2]},
          (__bridge void *)shader.specializedLibrary,shader.specializedEntry.c_str(),shader.parameter,shader.index,shader.offset,shader.value};
    return S_OK;
}
