// Build-time only. Each input line is key, shader path, root path, flags, UNorm8 target mask.
#include "../common/metal_converter.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

void IRCompilerPatchFloatToUnorm(IRCompiler *, bool);
void IRCompilerSetUnorm8RTMask(IRCompiler *, uint8_t);

static std::vector<uint8_t> read(const std::string &path) {
    std::ifstream file(path,std::ios::binary|std::ios::ate);
    const auto size=file.tellg();
    if (!file || size<=0 || (uint64_t)size>UINT32_MAX) return {};
    std::vector<uint8_t> bytes((size_t)size); file.seekg(0);
    if (!file.read((char *)bytes.data(),size)) return {};
    return bytes;
}
static bool write(const std::string &path,const void *data,size_t size) {
    std::ofstream file(path,std::ios::binary|std::ios::trunc);
    file.write((const char *)data,size); file.close(); return !file.fail();
}
int main(int argc,char **argv) {
    if (argc!=2) return 2;
    IRCompiler *compiler=IRCompilerCreate(); if (!compiler) return 1;
    IRCompilerSetMinimumGPUFamily(compiler,IRGPUFamilyApple7);
    IRCompilerSetMinimumDeploymentTarget(compiler,IROperatingSystem_macOS,"26.0.0");
    std::string line;
    unsigned failures=0;
    while (std::getline(std::cin,line)) {
        std::istringstream row(line); std::string key,shader_path,root_path,flags_text,mask_text;
        if (!std::getline(row,key,'\t') || !std::getline(row,shader_path,'\t') || !std::getline(row,root_path,'\t') ||
            !std::getline(row,flags_text,'\t') || !std::getline(row,mask_text)) return 2;
        const unsigned flags=std::stoul(flags_text),mask=std::stoul(mask_text);
        if (key.find_first_not_of("0123456789abcdef")!=std::string::npos || key.size()!=64 || mask>255) return 2;
        auto shader=read(shader_path),signature=read(root_path);
        IRError *error=nullptr; IRRootSignature *root=nullptr; IRObject *input=nullptr,*output=nullptr;
        IRMetalLibBinary *library=nullptr; IRShaderReflection *reflection=nullptr; const char *json=nullptr;
        bool passed=false;
        auto *desc=IRVersionedRootSignatureDescriptorCreateFromBlob(signature.data(),(uint32_t)signature.size(),&error);
        if (desc) { root=IRRootSignatureCreateFromDescriptor(desc,&error); IRVersionedRootSignatureDescriptorRelease(desc); }
        if (root && !shader.empty()) {
            IRCompilerSetGlobalRootSignature(compiler,root);
            IRCompilerSetCompatibilityFlags(compiler,(IRCompatibilityFlags)flags);
            IRCompilerPatchFloatToUnorm(compiler,mask!=0); IRCompilerSetUnorm8RTMask(compiler,(uint8_t)mask);
            input=IRObjectCreateFromDXIL(shader.data(),shader.size(),IRBytecodeOwnershipNone);
            if (input) output=IRCompilerAllocCompileAndLink(compiler,nullptr,input,&error);
        }
        if (output) {
            const auto stage=IRObjectGetMetalIRShaderStage(output);
            library=IRMetalLibBinaryCreate(); reflection=IRShaderReflectionCreate();
            if (library && reflection && IRObjectGetMetalLibBinary(output,stage,library) && IRObjectGetReflection(output,stage,reflection)) {
                std::vector<uint8_t> bytes(IRMetalLibGetBytecodeSize(library));
                json=IRShaderReflectionCopyJSONString(reflection);
                passed=json && !bytes.empty() && IRMetalLibGetBytecode(library,bytes.data())==bytes.size() &&
                    write(std::string(argv[1])+"/"+key+".metallib",bytes.data(),bytes.size()) &&
                    write(std::string(argv[1])+"/"+key+".json",json,std::char_traits<char>::length(json));
            }
        }
        std::printf("%s\t%s\t%u\n",key.c_str(),passed?"ok":"error",error?IRErrorGetCode(error):0); std::fflush(stdout);
        failures+=!passed;
        if (json) IRShaderReflectionReleaseString(json);
        if (reflection) IRShaderReflectionDestroy(reflection);
        if (library) IRMetalLibBinaryDestroy(library);
        if (output) IRObjectDestroy(output);
        if (input) IRObjectDestroy(input);
        IRCompilerSetGlobalRootSignature(compiler,nullptr);
        if (root) IRRootSignatureDestroy(root);
        if (error) IRErrorDestroy(error);
    }
    IRCompilerDestroy(compiler); return failures?1:0;
}
