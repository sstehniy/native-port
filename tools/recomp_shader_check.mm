#import <Metal/Metal.h>
#include "../d3d12-metal/include/d3d12_metal.h"
#include "../runtime/shader_cache.h"
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <sys/resource.h>
#include <cerrno>
#include <cstring>

static std::vector<uint8_t> read(const std::string &path) {
    std::ifstream file(path,std::ios::binary|std::ios::ate);
    if (!file) { fprintf(stderr,"shader_check: cannot open %s: %s\n",path.c_str(),strerror(errno));return {}; }
    const auto size=file.tellg();
    if (!file || size<=0 || (uint64_t)size>UINT32_MAX) return {};
    std::vector<uint8_t> data((size_t)size);file.seekg(0);
    if (!file.read((char *)data.data(),size)) return {};return data;
}
int main(int argc,const char **argv) { @autoreleasepool {
    if (argc!=2) return 2;
    rlimit limit{};
    if (getrlimit(RLIMIT_NOFILE,&limit)) return 2;
    limit.rlim_cur=std::min<rlim_t>(limit.rlim_max,256);
    if (setrlimit(RLIMIT_NOFILE,&limit)) return 2;
    auto metal=MTLCreateSystemDefaultDevice(); if (!metal) return 2;
    std::ifstream jobs(argv[1]);std::string line;unsigned count=0;
    while (std::getline(jobs,line)) { @autoreleasepool {
        std::istringstream row(line);std::string key,code_path,root_path,flags,mask;
        if (!std::getline(row,key,'\t') || !std::getline(row,code_path,'\t') || !std::getline(row,root_path,'\t') || !std::getline(row,flags,'\t') || !std::getline(row,mask)) return 2;
        auto code=read(code_path),root=read(root_path);D3DMShader shader{};
        const HRESULT hr=rt_load_shader((__bridge void *)metal,root.data(),root.size(),code.data(),code.size(),(UINT)std::stoul(mask),&shader);
        if (FAILED(hr) || !shader.library || !shader.entryPoint || ![(__bridge id<MTLLibrary>)shader.library newFunctionWithName:@(shader.entryPoint)]) {
            fprintf(stderr,"shader_check: %s HRESULT=%08x\n",key.c_str(),(unsigned)hr);return 1;
        }
        if (shader.specializedLibrary && ![(__bridge id<MTLLibrary>)shader.specializedLibrary newFunctionWithName:@(shader.specializedEntryPoint)]) return 1;
        ++count;
    }}
    if (!count) return 2;
    printf("shader_check: %u prebuilt libraries and entry points passed\n",count);return 0;
}}
