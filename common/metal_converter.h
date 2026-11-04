// Public Metal Shader Converter C ABI subset, Copyright 2023-2025 Apple Inc.
// SPDX-License-Identifier: Apache-2.0
// Source: https://github.com/wmarti/metal-shader-converter/blob/main/include/metal_irconverter.h
#pragma once
#include <cstddef>
#include <cstdint>

extern "C" {
struct IRCompiler;
struct IRObject;
struct IRMetalLibBinary;
struct IRShaderReflection;
struct IRError;
struct IRRootSignature;
struct IRVersionedRootSignatureDescriptor;

enum IRShaderStage { IRShaderStageInvalid, IRShaderStageVertex, IRShaderStageFragment, IRShaderStageCompute = 8 };
enum IRBytecodeOwnership { IRBytecodeOwnershipNone, IRBytecodeOwnershipCopy };
enum IRGPUFamily { IRGPUFamilyApple7 = 1007 };
enum IROperatingSystem { IROperatingSystem_macOS };
enum IRCompatibilityFlags {
    IRCompatibilityFlagPositionInvariance = 1 << 4,
    IRCompatibilityFlagSampleNanToZero = 1 << 5,
    IRCompatibilityFlagForceTextureArray = 1 << 8,
};
enum IRResourceType {
    IRResourceTypeTable, IRResourceTypeConstant, IRResourceTypeCBV, IRResourceTypeSRV,
    IRResourceTypeUAV, IRResourceTypeSampler, IRResourceTypeInvalid
};
struct IRResourceLocation {
    IRResourceType resourceType;
    uint32_t space, slot, topLevelOffset;
    uint64_t sizeBytes;
    const char *resourceName;
};

IRCompiler *IRCompilerCreate(void);
void IRCompilerDestroy(IRCompiler *);
void IRCompilerSetMinimumGPUFamily(IRCompiler *, IRGPUFamily);
void IRCompilerSetMinimumDeploymentTarget(IRCompiler *, IROperatingSystem, const char *);
void IRCompilerIgnoreRootSignature(IRCompiler *, bool);
void IRCompilerSetCompatibilityFlags(IRCompiler *, IRCompatibilityFlags);
IRVersionedRootSignatureDescriptor *IRVersionedRootSignatureDescriptorCreateFromBlob(const uint8_t *, uint32_t, IRError **);
void IRVersionedRootSignatureDescriptorRelease(IRVersionedRootSignatureDescriptor *);
IRRootSignature *IRRootSignatureCreateFromDescriptor(const IRVersionedRootSignatureDescriptor *, IRError **);
void IRRootSignatureDestroy(IRRootSignature *);
void IRCompilerSetGlobalRootSignature(IRCompiler *, const IRRootSignature *);
IRObject *IRObjectCreateFromDXIL(const uint8_t *, size_t, IRBytecodeOwnership);
IRObject *IRCompilerAllocCompileAndLink(IRCompiler *, const char *, const IRObject *, IRError **);
IRShaderStage IRObjectGetMetalIRShaderStage(const IRObject *);
void IRObjectDestroy(IRObject *);
uint32_t IRErrorGetCode(const IRError *);
const void *IRErrorGetPayload(const IRError *);
void IRErrorDestroy(IRError *);

IRMetalLibBinary *IRMetalLibBinaryCreate(void);
void IRMetalLibBinaryDestroy(IRMetalLibBinary *);
bool IRObjectGetMetalLibBinary(const IRObject *, IRShaderStage, IRMetalLibBinary *);
size_t IRMetalLibGetBytecodeSize(const IRMetalLibBinary *);
size_t IRMetalLibGetBytecode(const IRMetalLibBinary *, uint8_t *);

IRShaderReflection *IRShaderReflectionCreate(void);
void IRShaderReflectionDestroy(IRShaderReflection *);
bool IRObjectGetReflection(const IRObject *, IRShaderStage, IRShaderReflection *);
const char *IRShaderReflectionGetEntryPointFunctionName(const IRShaderReflection *);
size_t IRShaderReflectionGetResourceCount(const IRShaderReflection *);
void IRShaderReflectionGetResourceLocations(const IRShaderReflection *, IRResourceLocation *);
const char *IRShaderReflectionCopyJSONString(const IRShaderReflection *);
void IRShaderReflectionReleaseString(const char *);
}
