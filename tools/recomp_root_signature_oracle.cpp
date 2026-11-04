// Development-only check against the same converter that the reference backend ships.
#include "../common/metal_converter.h"
#include <cstdio>
#include <cstdint>
#include <vector>

extern "C" {
const char *IRVersionedRootSignatureDescriptorCopyJSONString(const IRVersionedRootSignatureDescriptor *);
void IRVersionedRootSignatureDescriptorReleaseString(const char *);
size_t IRRootSignatureGetResourceCount(const IRRootSignature *);
void IRRootSignatureGetResourceLocations(const IRRootSignature *, IRResourceLocation *);
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    for (int i = 1; i < argc; ++i) {
        FILE *file = std::fopen(argv[i], "rb");
        if (!file || std::fseek(file, 0, SEEK_END)) return 2;
        const long size = std::ftell(file);
        if (size <= 0 || size > UINT32_MAX || std::fseek(file, 0, SEEK_SET)) return 2;
        std::vector<uint8_t> bytes(size);
        const size_t read = std::fread(bytes.data(), 1, bytes.size(), file);
        if (std::fclose(file) || read != bytes.size()) return 2;
        IRError *error = nullptr;
        auto *desc = IRVersionedRootSignatureDescriptorCreateFromBlob(bytes.data(), (uint32_t)bytes.size(), &error);
        if (!desc) { std::fprintf(stderr, "invalid root signature: %s\n", argv[i]); return 1; }
        auto *root = IRRootSignatureCreateFromDescriptor(desc, &error);
        if (!root) { std::fprintf(stderr, "invalid converter layout: %s\n", argv[i]); return 1; }
        const char *json = IRVersionedRootSignatureDescriptorCopyJSONString(desc);
        if (!json) return 1;
        std::printf("{\"descriptor\":%s,\"resources\":[", json);
        std::vector<IRResourceLocation> resources(IRRootSignatureGetResourceCount(root));
        IRRootSignatureGetResourceLocations(root, resources.data());
        for (size_t j = 0; j < resources.size(); ++j) {
            const auto &r = resources[j];
            std::printf("%s{\"type\":%u,\"space\":%u,\"slot\":%u,\"offset\":%u,\"bytes\":%llu}",
                j ? "," : "", r.resourceType, r.space, r.slot, r.topLevelOffset, (unsigned long long)r.sizeBytes);
        }
        std::puts("]}");
        IRVersionedRootSignatureDescriptorReleaseString(json);
        IRRootSignatureDestroy(root);
        IRVersionedRootSignatureDescriptorRelease(desc);
        if (error) IRErrorDestroy(error);
    }
    return 0;
}
