// Build-time DXIL round trip through Microsoft's assembler/disassembler API.
#include "dxcapi.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>

int main(int argc,char **argv) {
    assert(argc==3 || argc==4);
    assert((argc==3 && !strcmp(argv[1],"disassemble")) ||
           (argc==4 && (!strcmp(argv[1],"assemble") || !strcmp(argv[1],"compile"))));
    std::ifstream file(argv[2],std::ios::binary);assert(file);
    std::vector<char> bytes((std::istreambuf_iterator<char>(file)),{});assert(!bytes.empty());
    IDxcBlob *output=nullptr;
    if (argc==3 || !strcmp(argv[1],"compile")) {
        IDxcCompiler3 *compiler=nullptr;
        assert(SUCCEEDED(DxcCreateInstance(CLSID_DxcCompiler,__uuidof(IDxcCompiler3),(void **)&compiler)));
        DxcBuffer buffer{bytes.data(),bytes.size(),0};IDxcResult *result=nullptr;
        if (argc==3) assert(SUCCEEDED(compiler->Disassemble(&buffer,__uuidof(IDxcResult),(void **)&result)));
        else {
            const wchar_t *args[]={L"-T",L"ps_6_6",L"-E",L"main",L"-O3"};
            assert(SUCCEEDED(compiler->Compile(&buffer,args,std::size(args),nullptr,__uuidof(IDxcResult),(void **)&result)));
            IDxcBlobUtf8 *errors=nullptr;result->GetOutput(DXC_OUT_ERRORS,__uuidof(IDxcBlobUtf8),(void **)&errors,nullptr);
            if (errors) { fwrite(errors->GetStringPointer(),1,errors->GetStringLength(),stderr);errors->Release(); }
            HRESULT status;assert(SUCCEEDED(result->GetStatus(&status)) && SUCCEEDED(status));
        }
        assert(SUCCEEDED(result->GetResult(&output)));
        if (argc==3) assert(fwrite(output->GetBufferPointer(),1,output->GetBufferSize(),stdout)==output->GetBufferSize());
        else { std::ofstream out(argv[3],std::ios::binary);out.write((const char *)output->GetBufferPointer(),output->GetBufferSize());out.close();assert(out); }
        result->Release();compiler->Release();
    } else {
        IDxcUtils *utils=nullptr;IDxcAssembler *assembler=nullptr;IDxcBlobEncoding *source=nullptr;
        assert(SUCCEEDED(DxcCreateInstance(CLSID_DxcUtils,__uuidof(IDxcUtils),(void **)&utils)));
        assert(SUCCEEDED(utils->CreateBlob(bytes.data(),bytes.size(),DXC_CP_UTF8,&source)));
        assert(SUCCEEDED(DxcCreateInstance(CLSID_DxcAssembler,__uuidof(IDxcAssembler),(void **)&assembler)));
        IDxcOperationResult *result=nullptr;assert(SUCCEEDED(assembler->AssembleToContainer(source,&result)));
        IDxcBlobEncoding *errors=nullptr;result->GetErrorBuffer(&errors);
        if (errors) { fwrite(errors->GetBufferPointer(),1,errors->GetBufferSize(),stderr);errors->Release(); }
        HRESULT status;assert(SUCCEEDED(result->GetStatus(&status)) && SUCCEEDED(status));
        assert(SUCCEEDED(result->GetResult(&output)));
        std::ofstream out(argv[3],std::ios::binary);out.write((const char *)output->GetBufferPointer(),output->GetBufferSize());out.close();assert(out);
        result->Release();assembler->Release();source->Release();utils->Release();
    }
    output->Release();
}
