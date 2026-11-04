#import <Metal/Metal.h>
#include "d3d12_metal.h"
#include "root_signature_fixture.h"
#include <array>
#include <atomic>
#include <bit>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>
#ifdef D3DM_ROOT_SIGNATURE_CASES
#include D3DM_ROOT_SIGNATURE_CASES
#endif

static std::atomic<unsigned> checks;
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "root_signature_test:%d: %s\n", __LINE__, #value); std::exit(1); } ++checks; } while (0)
#define OK(value) CHECK((value) == S_OK)
static ID3D12RootSignature *create(ID3D12Device *device, const void *bytes, size_t size) {
    ID3D12RootSignature *root = nullptr;
    OK(device->CreateRootSignature(0, bytes, size, __uuidof(ID3D12RootSignature), (void **)&root));
    CHECK(root != nullptr); return root;
}
static ID3DMRootSignature *backing(ID3D12RootSignature *root) {
    ID3DMRootSignature *native = nullptr;
    OK(root->QueryInterface(__uuidof(ID3DMRootSignature), (void **)&native)); return native;
}
static void contract(ID3D12Device *device) {
    std::vector<unsigned> bytes(std::begin(root_mixed), std::end(root_mixed));
    auto *root = create(device, bytes.data(), bytes.size() * 4);
    std::fill(bytes.begin(), bytes.end(), 0); // The caller may immediately reuse the serialized blob.
    auto *native = backing(root); const auto &layout = *native->GetLayout();
    const UINT offsets[] = {0,16,24,32,40,48,56};
    CHECK(layout.serializedSize==sizeof root_mixed && !memcmp(layout.serialized,root_mixed,sizeof root_mixed));
    CHECK(layout.desc.NumParameters == 7 && layout.desc.NumStaticSamplers == 2 && layout.desc.Flags == 0);
    CHECK(!memcmp(layout.parameterOffsets, offsets, sizeof offsets) && layout.argumentBufferSize == 72 && layout.staticSamplerOffset == 64);
    const auto *p = layout.desc.pParameters;
    CHECK(p[0].Constants.ShaderRegister == 0 && p[0].Constants.RegisterSpace == 1 && p[0].Constants.Num32BitValues == 3);
    CHECK(p[1].Descriptor.Flags == D3D12_ROOT_DESCRIPTOR_FLAG_DATA_STATIC_WHILE_SET_AT_EXECUTE && p[1].Descriptor.ShaderRegister == 1);
    CHECK(p[2].ParameterType == D3D12_ROOT_PARAMETER_TYPE_SRV && p[3].ParameterType == D3D12_ROOT_PARAMETER_TYPE_UAV);
    CHECK(p[4].DescriptorTable.NumDescriptorRanges == 2 && p[4].DescriptorTable.pDescriptorRanges[0].OffsetInDescriptorsFromTableStart == 0);
    CHECK(p[4].DescriptorTable.pDescriptorRanges[1].OffsetInDescriptorsFromTableStart == 4 && p[4].DescriptorTable.pDescriptorRanges[1].RangeType == D3D12_DESCRIPTOR_RANGE_TYPE_CBV);
    CHECK(p[6].DescriptorTable.pDescriptorRanges[0].RangeType == D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER);
    CHECK(layout.desc.pStaticSamplers[0].ShaderRegister == 3 && layout.desc.pStaticSamplers[1].ShaderRegister == 1);
    CHECK(layout.desc.pStaticSamplers[0].MipLODBias == 1.25f && layout.desc.pStaticSamplers[1].MipLODBias == -0.5f);
    auto table = (__bridge id<MTLBuffer>)layout.staticSamplers;
    CHECK(table && table.length == 48);
    const auto *entries = (const uint64_t *)table.contents;
    CHECK(entries[0] && entries[3] && entries[1] == 0 && entries[4] == 0);
    CHECK(entries[2] == std::bit_cast<uint32_t>(1.25f) && entries[5] == std::bit_cast<uint32_t>(-0.5f));
    ID3D12Device *owner = nullptr; OK(root->GetDevice(__uuidof(ID3D12Device), (void **)&owner)); CHECK(owner == device); owner->Release();
    for (const auto &iid : {__uuidof(IUnknown), __uuidof(ID3D12Object), __uuidof(ID3D12DeviceChild), __uuidof(ID3D12RootSignature)}) {
        IUnknown *identity = nullptr; OK(root->QueryInterface(iid, (void **)&identity)); CHECK(identity == (IUnknown *)root); identity->Release();
    }
    void *invalid = (void *)1; CHECK(root->QueryInterface(__uuidof(ID3D12Pageable), &invalid) == E_NOINTERFACE && !invalid);
    CHECK(root->QueryInterface(__uuidof(IUnknown), nullptr) == E_POINTER);
    OK(root->SetName(L"root signature \u03bb")); UINT size = 0;
    OK(root->GetPrivateData(WKPDID_D3DDebugObjectNameW, &size, nullptr)); CHECK(size == sizeof(L"root signature \u03bb"));
    const GUID key = {0x63c72011,0,0,{1,2,3,4,5,6,7,8}};
    const UINT input = 0xcafebabe; UINT output = 0; size = sizeof output;
    OK(root->SetPrivateData(key, sizeof input, &input)); OK(root->GetPrivateData(key, &size, &output)); CHECK(output == input);
    auto *child = create(device, root_empty, sizeof root_empty);
    OK(root->SetPrivateDataInterface(key, child)); CHECK(child->Release() == 1);
    OK(root->SetPrivateDataInterface(key, nullptr));
    native->Release(); CHECK(root->Release() == 0);

    root = create(device, root_v1, sizeof root_v1); native = backing(root);
    const auto &v1 = *native->GetLayout();
    CHECK(v1.desc.NumParameters == 3 && v1.argumentBufferSize == 24 && v1.staticSamplerOffset == UINT_MAX && !v1.staticSamplers);
    CHECK(v1.parameterOffsets[0] == 0 && v1.parameterOffsets[1] == 8 && v1.parameterOffsets[2] == 16);
    CHECK(v1.desc.pParameters[0].DescriptorTable.pDescriptorRanges[0].Flags == 3 && v1.desc.pParameters[0].DescriptorTable.pDescriptorRanges[1].Flags == 3);
    CHECK(v1.desc.pParameters[0].DescriptorTable.pDescriptorRanges[1].OffsetInDescriptorsFromTableStart == 2);
    CHECK(v1.desc.pParameters[1].Descriptor.Flags == D3D12_ROOT_DESCRIPTOR_FLAG_DATA_VOLATILE);
    native->Release(); root->Release();
    root = create(device, root_empty, sizeof root_empty); native = backing(root);
    CHECK(native->GetLayout()->desc.NumParameters == 0 && native->GetLayout()->argumentBufferSize == 0);
    native->Release(); root->Release();
    std::vector<unsigned> container(std::begin(root_mixed), std::begin(root_mixed) + 8);
    container[6] = sizeof root_mixed + 16; container[7] = 2;
    container.insert(container.end(), {40,52,0x54534554,4,0});
    container.insert(container.end(), std::begin(root_mixed) + 9, std::end(root_mixed));
    root = create(device, container.data(), container.size() * 4); root->Release();
    container[8] = 52;
    void *overlap = (void *)1;
    CHECK(device->CreateRootSignature(0,container.data(),container.size() * 4,__uuidof(ID3D12RootSignature),&overlap) == E_INVALIDARG && !overlap);
    CHECK(device->CreateRootSignature(1, root_mixed, sizeof root_mixed, __uuidof(ID3D12RootSignature), nullptr) == S_FALSE);
    invalid = (void *)1;
    CHECK(device->CreateRootSignature(0, root_mixed, sizeof root_mixed, __uuidof(ID3D12Heap), &invalid) == E_NOINTERFACE && !invalid);
    CHECK(device->CreateRootSignature(2, root_mixed, sizeof root_mixed, __uuidof(ID3D12RootSignature), &invalid) == E_INVALIDARG && !invalid);
    CHECK(device->CreateRootSignature(0, nullptr, sizeof root_mixed, __uuidof(ID3D12RootSignature), &invalid) == E_INVALIDARG && !invalid);
}

static void malformed(ID3D12Device *device) {
    const auto reject = [&](std::vector<unsigned> bytes, HRESULT expected = E_INVALIDARG) {
        void *out = (void *)1;
        CHECK(device->CreateRootSignature(0, bytes.data(), bytes.size() * 4, __uuidof(ID3D12RootSignature), &out) == expected && !out);
    };
    const auto change = [&](size_t word, UINT value, HRESULT expected = E_INVALIDARG) {
        std::vector<unsigned> bytes(std::begin(root_mixed), std::end(root_mixed)); bytes[word] = value; reject(bytes, expected);
    };
    for (size_t size = 0; size < sizeof root_mixed; ++size) {
        void *out = (void *)1;
        CHECK(device->CreateRootSignature(0, root_mixed, size, __uuidof(ID3D12RootSignature), &out) == E_INVALIDARG && !out);
    }
    change(0, 0); change(5, 0); change(7, UINT_MAX); change(8, 33); change(9, 0); change(10, UINT_MAX);
    change(11, 3); change(12, 65); change(13, UINT_MAX); change(14, 2033); change(15, 3); change(16, 0x1000);
    change(16, D3D12_ROOT_SIGNATURE_FLAG_LOCAL_ROOT_SIGNATURE, DXGI_ERROR_UNSUPPORTED);
    change(17, 5); change(18, 8); change(19, UINT_MAX);
    const size_t constants = 11 + root_mixed[19] / 4;
    change(constants + 2, 65);
    const size_t descriptor = 11 + root_mixed[22] / 4;
    change(descriptor, 0); change(descriptor + 2, 6);
    const size_t table = 11 + root_mixed[31] / 4, range = 11 + root_mixed[table + 1] / 4;
    change(table, UINT_MAX); change(range, 4); change(range + 1, 0);
    change(range + 2, UINT_MAX); change(range + 4, 6); change(range + 4, 9); change(range + 4, 0x10001);
    change(range + 6, D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER);
    const size_t sampler = 11 + root_mixed[15] / 4;
    change(sampler, 0xffff); change(sampler + 1, 0); change(sampler + 4, 0x7fc00000);
    change(sampler + 7, 3); change(sampler + 10, 5); change(sampler + 12, 8);
    auto unbounded = std::vector<unsigned>(std::begin(root_mixed), std::end(root_mixed));
    unbounded[range + 1] = UINT_MAX;
    auto *root = create(device, unbounded.data(), unbounded.size() * 4); root->Release();
    unbounded[range + 11] = UINT_MAX; reject(unbounded);
    for (const auto &[word, value] : {std::pair<size_t,UINT>{constants + 2,0}, {table,0}, {range + 5,UINT_MAX - 1}}) {
        auto bytes = std::vector<unsigned>(std::begin(root_mixed), std::end(root_mixed)); bytes[word] = value;
        root = create(device, bytes.data(), bytes.size() * 4); root->Release();
    }
    auto overflow = std::vector<unsigned>(std::begin(root_mixed), std::end(root_mixed));
    overflow[range + 5] = UINT_MAX - 1; overflow[range + 1] = 3; reject(overflow);
    for (size_t size = 68; size < sizeof root_mixed; size += 4) {
        auto bytes = std::vector<unsigned>(std::begin(root_mixed), std::end(root_mixed));
        bytes.resize(size / 4); bytes[6] = (UINT)size; bytes[10] = (UINT)size - 44; reject(bytes);
    }
    std::vector<uint8_t> unaligned(sizeof root_mixed + 1);
    memcpy(unaligned.data() + 1, root_mixed, sizeof root_mixed);
    root = create(device, unaligned.data() + 1, sizeof root_mixed); root->Release();
    // Fixed seed, small bounded mutations exercise nested offsets without assuming every edit is invalid.
    UINT random = 0x12345678;
    for (UINT i = 0; i < 2000; ++i) {
        auto bytes = std::vector<unsigned>(std::begin(root_mixed), std::end(root_mixed));
        random = random * 1664525 + 1013904223;
        bytes[(random >> 8) % bytes.size()] ^= 1u << (random % 32);
        ID3D12RootSignature *out = nullptr;
        const HRESULT hr = device->CreateRootSignature(0, bytes.data(), bytes.size() * 4, __uuidof(ID3D12RootSignature), (void **)&out);
        CHECK((hr == S_OK) == (out != nullptr)); if (out) out->Release();
    }
}

static void gpu(ID3D12Device *device, id<MTLDevice> metal) {
    auto *root = create(device, root_mixed, sizeof root_mixed); auto *native = backing(root);
    const auto &layout = *native->GetLayout();
    auto args = [metal newBufferWithLength:layout.argumentBufferSize options:MTLResourceStorageModeShared];
    const uint32_t constants[] = {7,11,13}; const uint32_t tail = 17;
    memcpy((char *)args.contents + layout.parameterOffsets[0], constants, sizeof constants);
    memcpy((char *)args.contents + layout.parameterOffsets[5], &tail, 4);
    const uint32_t data[] = {19,23};
    auto input = [metal newBufferWithBytes:data length:sizeof data options:MTLResourceStorageModeShared];
    auto output = [metal newBufferWithLength:32 options:MTLResourceStorageModeShared];
    auto table = [metal newBufferWithLength:5 * 24 options:MTLResourceStorageModeShared];
    ((uint64_t *)table.contents)[4 * 3] = input.gpuAddress;
    const uint64_t pointers[] = {input.gpuAddress,input.gpuAddress,output.gpuAddress,table.gpuAddress};
    for (UINT i = 0; i < 4; ++i) memcpy((char *)args.contents + layout.parameterOffsets[i + 1], &pointers[i], 8);
    auto static_samplers = (__bridge id<MTLBuffer>)layout.staticSamplers;
    const uint64_t address = static_samplers.gpuAddress;
    memcpy((char *)args.contents + layout.staticSamplerOffset, &address, 8);
    memcpy((char *)args.contents + layout.parameterOffsets[6], &address, 8);
    auto texture_desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:2 height:1 mipmapped:NO];
    texture_desc.storageMode = MTLStorageModeShared;
    auto texture = [metal newTextureWithDescriptor:texture_desc]; const float pixels[] = {2,6};
    [texture replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:pixels bytesPerRow:8];
    NSString *source = @R"(
#include <metal_stdlib>
using namespace metal;
struct Entry { ulong address, unused, metadata; };
struct Sampler { sampler value [[id(0)]]; ulong unused [[id(1)]], metadata [[id(2)]]; };
struct Root {
    uint constants[3];
    device const uint *cbv;
    device const uint *srv;
    device float *uav;
    device const Entry *table;
    uint tail;
    device const Sampler *dynamicSamplers;
    device const Sampler *staticSamplers;
};
kernel void test(device const Root &r [[buffer(2)]], texture2d<float> image [[texture(0)]]) {
    r.uav[0] = r.constants[0] + r.constants[1] + r.constants[2] + r.tail + r.cbv[0] + r.srv[1];
    r.uav[1] = ((device const uint *)r.table[4].address)[1];
    r.uav[2] = image.sample(r.staticSamplers[0].value, float2(0.375,0.5), level(0)).x;
    r.uav[3] = image.sample(r.staticSamplers[1].value, float2(0.375,0.5), level(0)).x;
    r.uav[4] = image.sample(r.staticSamplers[0].value, float2(-1,0.5), level(0)).x;
    r.uav[5] = as_type<float>(uint(r.staticSamplers[0].metadata));
    r.uav[6] = as_type<float>(uint(r.dynamicSamplers[1].metadata));
})";
    NSError *error = nil; auto options = [MTLCompileOptions new]; options.languageVersion = MTLLanguageVersion3_1;
    auto library = [metal newLibraryWithSource:source options:options error:&error];
    if (!library) fprintf(stderr, "%s\n", error.description.UTF8String); CHECK(library != nil);
    auto pipeline = [metal newComputePipelineStateWithFunction:[library newFunctionWithName:@"test"] error:&error]; CHECK(pipeline != nil);
    auto queue = [metal newCommandQueue]; auto commands = [queue commandBuffer]; auto encoder = [commands computeCommandEncoder];
    [encoder setComputePipelineState:pipeline]; [encoder setBuffer:args offset:0 atIndex:2]; [encoder setTexture:texture atIndex:0];
    for (id<MTLBuffer> buffer in @[input,output,table,static_samplers]) [encoder useResource:buffer usage:MTLResourceUsageRead | MTLResourceUsageWrite];
    [encoder dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [encoder endEncoding];
    [commands commit]; [commands waitUntilCompleted]; CHECK(commands.status == MTLCommandBufferStatusCompleted);
    const float expected[] = {90,23,3,2,1,1.25f,-0.5f};
    for (UINT i = 0; i < 7; ++i) {
        const float actual = ((float *)output.contents)[i];
        if (std::abs(actual - expected[i]) >= 0.00001f) fprintf(stderr, "GPU root result %u: %g, expected %g\n", i, actual, expected[i]);
        CHECK(std::abs(actual - expected[i]) < 0.00001f);
    }
    native->Release(); CHECK(root->Release() == 0);
}

static void replay(ID3D12Device *device) {
#ifdef D3DM_ROOT_SIGNATURE_CASES
    for (const auto &entry : root_signature_cases) {
        auto *root = create(device, entry.blob, entry.size); auto *native = backing(root); const auto &layout = *native->GetLayout();
        CHECK(layout.desc.Flags == entry.flags && layout.desc.NumParameters == entry.parameter_count && layout.desc.NumStaticSamplers == entry.sampler_count);
        UINT end = 0;
        for (UINT i = 0; i < entry.location_count; ++i) {
            const auto &expected = entry.locations[i]; end = expected.offset + expected.bytes;
            if (i == entry.parameter_count) { CHECK(layout.staticSamplerOffset == expected.offset && layout.staticSamplers); continue; }
            const auto &p = layout.desc.pParameters[i];
            CHECK((UINT)p.ParameterType == expected.type && layout.parameterOffsets[i] == expected.offset);
            if (p.ParameterType == D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS) {
                CHECK(p.Constants.ShaderRegister == expected.slot && p.Constants.RegisterSpace == expected.space && p.Constants.Num32BitValues * 4 == expected.bytes);
            } else if (p.ParameterType != D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE) {
                CHECK(p.Descriptor.ShaderRegister == expected.slot && p.Descriptor.RegisterSpace == expected.space && expected.bytes == 8);
            }
        }
        CHECK(layout.argumentBufferSize == ((end + 7) & ~7u));
        native->Release(); CHECK(root->Release() == 0);
    }
#endif
}

int main(int argc, const char **argv) { @autoreleasepool {
    D3DMHost host{};
    host.check_feature = [](D3D12_FEATURE feature, void *data, UINT size) -> HRESULT {
        if (feature != D3D12_FEATURE_FEATURE_LEVELS || size != sizeof(D3D12_FEATURE_DATA_FEATURE_LEVELS)) return E_INVALIDARG;
        ((D3D12_FEATURE_DATA_FEATURE_LEVELS *)data)->MaxSupportedFeatureLevel = D3D_FEATURE_LEVEL_12_2; return S_OK;
    };
    D3DMSetHost(&host);
    ID3D12Device *device = nullptr; OK(D3DMCreateDevice(nullptr,D3D_FEATURE_LEVEL_12_0,__uuidof(ID3D12Device),(void **)&device));
    auto metal = MTLCreateSystemDefaultDevice(); CHECK(metal != nil);
    contract(device); malformed(device); gpu(device, metal); replay(device);
    std::vector<std::thread> workers;
    for (UINT i = 0; i < 8; ++i) workers.emplace_back([&] { @autoreleasepool {
        for (UINT j = 0; j < 16; ++j) { auto *root = create(device, root_mixed, sizeof root_mixed); CHECK(root->Release() == 0); }
    }});
    for (auto &worker : workers) worker.join();
    auto *root = create(device, root_empty, sizeof root_empty);
    ID3DMDeviceStatus *status = nullptr; OK(device->QueryInterface(__uuidof(ID3DMDeviceStatus), (void **)&status));
    status->RecordError(DXGI_ERROR_DEVICE_HUNG); status->Release(); void *out = (void *)1;
    CHECK(device->CreateRootSignature(0, root_empty, sizeof root_empty, __uuidof(ID3D12RootSignature), &out) == DXGI_ERROR_DEVICE_HUNG && !out);
    CHECK(device->Release() == 1);
    ID3D12Device *owner = nullptr; OK(root->GetDevice(__uuidof(ID3D12Device), (void **)&owner)); CHECK(owner->GetDeviceRemovedReason() == DXGI_ERROR_DEVICE_HUNG); owner->Release();
    CHECK(root->Release() == 0);
    if (argc == 2) {
        const void *blobs[] = {root_mixed,root_v1,root_empty}; const size_t sizes[] = {sizeof root_mixed,sizeof root_v1,sizeof root_empty};
        for (UINT i = 0; i < 3; ++i) {
            NSString *path = [@(argv[1]) stringByAppendingPathComponent:[NSString stringWithFormat:@"owned-%u.dxbc",i]];
            CHECK([[NSData dataWithBytes:blobs[i] length:sizes[i]] writeToFile:path atomically:YES]);
        }
    }
    printf("root_signature_test: %u checks passed\n",checks.load());
    return 0;
}}
