// Game-specific feature policy; backend mechanics stay in d3d12-metal.
#pragma once
#include "d3d12_metal.h"
#include <algorithm>
#include <cstring>

namespace {
template <class T> HRESULT feature_value(void *data, UINT size, const T &value) {
    if (!data || size != sizeof(T)) return E_INVALIDARG;
    memcpy(data, &value, sizeof value);
    return S_OK;
}
HRESULT device_feature(D3D12_FEATURE feature, void *data, UINT size) {
    if (!data) return E_INVALIDARG;
    switch (feature) {
    case D3D12_FEATURE_D3D12_OPTIONS:
        return feature_value(data, size, D3D12_FEATURE_DATA_D3D12_OPTIONS{
            FALSE, TRUE, D3D12_SHADER_MIN_PRECISION_SUPPORT_16_BIT, D3D12_TILED_RESOURCES_TIER_2,
            D3D12_RESOURCE_BINDING_TIER_3, TRUE, TRUE, TRUE, D3D12_CONSERVATIVE_RASTERIZATION_TIER_NOT_SUPPORTED,
            64, FALSE, D3D12_CROSS_NODE_SHARING_TIER_NOT_SUPPORTED, FALSE, TRUE, D3D12_RESOURCE_HEAP_TIER_2});
    case D3D12_FEATURE_D3D12_OPTIONS1:
        return feature_value(data, size, D3D12_FEATURE_DATA_D3D12_OPTIONS1{TRUE, 32, 32, 1024, TRUE, TRUE});
    case D3D12_FEATURE_D3D12_OPTIONS4:
        return feature_value(data, size, D3D12_FEATURE_DATA_D3D12_OPTIONS4{TRUE, D3D12_SHARED_RESOURCE_COMPATIBILITY_TIER_2, TRUE});
    case D3D12_FEATURE_D3D12_OPTIONS7:
        return feature_value(data, size, D3D12_FEATURE_DATA_D3D12_OPTIONS7{D3D12_MESH_SHADER_TIER_1, D3D12_SAMPLER_FEEDBACK_TIER_NOT_SUPPORTED});
    case D3D12_FEATURE_D3D12_OPTIONS13:
        return feature_value(data, size, D3D12_FEATURE_DATA_D3D12_OPTIONS13{});
    case D3D12_FEATURE_ARCHITECTURE1: {
        if (size != sizeof(D3D12_FEATURE_DATA_ARCHITECTURE1)) return E_INVALIDARG;
        const auto input = *(D3D12_FEATURE_DATA_ARCHITECTURE1 *)data;
        if (input.NodeIndex) return E_INVALIDARG;
        return feature_value(data, size, D3D12_FEATURE_DATA_ARCHITECTURE1{});
    }
    case D3D12_FEATURE_FEATURE_LEVELS: {
        if (size != sizeof(D3D12_FEATURE_DATA_FEATURE_LEVELS)) return E_INVALIDARG;
        auto &levels = *(D3D12_FEATURE_DATA_FEATURE_LEVELS *)data;
        if (!levels.NumFeatureLevels || !levels.pFeatureLevelsRequested) return E_INVALIDARG;
        D3D_FEATURE_LEVEL maximum = {};
        // The reference returns the highest requested value without filtering unknown feature levels.
        for (UINT i = 0; i < levels.NumFeatureLevels; ++i) {
            maximum = std::max(maximum, levels.pFeatureLevelsRequested[i]);
        }
        levels.MaxSupportedFeatureLevel = maximum;
        return S_OK;
    }
    case D3D12_FEATURE_SHADER_MODEL: {
        if (size != sizeof(D3D12_FEATURE_DATA_SHADER_MODEL)) return E_INVALIDARG;
        auto &model = *(D3D12_FEATURE_DATA_SHADER_MODEL *)data;
        // D3DMetal reports 6.6 even for a lower or unknown requested shader model.
        model.HighestShaderModel = D3D_SHADER_MODEL_6_6;
        return S_OK;
    }
    default: return E_INVALIDARG;
    }
}
}
