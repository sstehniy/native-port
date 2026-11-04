#include "root_signature.h"
#include "descriptors.h"
#include <algorithm>
#include <bit>
#include <cstring>
#include <new>

namespace d3dm {
namespace {
// Serialized offsets follow Microsoft's DxilRootSignature.h; never cast untrusted blob pointers.
// https://github.com/microsoft/DirectXShaderCompiler/blob/main/include/dxc/DxilRootSignature/DxilRootSignature.h
struct Reader {
    const uint8_t *bytes;
    size_t size;
    bool valid = true;
    bool contains(size_t offset, size_t count, size_t stride = 4) {
        if (offset % 4 || offset > size || count > (size - offset) / stride) valid = false;
        return valid;
    }
    uint32_t word(size_t offset) {
        uint32_t value = 0;
        if (contains(offset, 1)) std::memcpy(&value, bytes + offset, 4);
        return value;
    }
};
struct Binding { UINT type, space, first, visibility; uint64_t end; };
bool add_binding(std::vector<Binding> &bindings, UINT type, UINT space, UINT first, UINT count, UINT visibility) {
    const uint64_t end = count == UINT_MAX ? UINT64_C(0x100000000) : (uint64_t)first + count;
    if (!count || end > UINT64_C(0x100000000)) return false;
    for (const auto &b : bindings) {
        if (b.type == type && b.space == space && (!b.visibility || !visibility || b.visibility == visibility) &&
            first < b.end && b.first < end) return false;
    }
    bindings.push_back({type, space, first, visibility, end});
    return true;
}
bool data_flags_valid(UINT flags) { return !(flags & ~14u) && std::popcount(flags) <= 1; }

class RootSignature final : public Object<ID3D12RootSignature>, public ID3DMRootSignature {
public:
    explicit RootSignature(ID3D12Device *device) : device_(device) { device_->AddRef(); }
    ~RootSignature() override { device_->Release(); }
    ULONG STDMETHODCALLTYPE AddRef() override { return Object::AddRef(); }
    ULONG STDMETHODCALLTYPE Release() override { return Object::Release(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (out && iid == __uuidof(ID3DMRootSignature)) { AddRef(); *out = static_cast<ID3DMRootSignature *>(this); return S_OK; }
        return query<IUnknown, ID3D12Object, ID3D12DeviceChild, ID3D12RootSignature>(iid, out);
    }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID name, UINT *size, void *data) override { return data_.get(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID name, UINT size, const void *data) override { return data_.set(name, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID name, const IUnknown *object) override { return data_.set_interface(name, object); }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR name) override {
        return data_.set(WKPDID_D3DDebugObjectNameW, name ? (UINT)((wcslen(name) + 1) * sizeof(WCHAR)) : 0, name);
    }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID iid, void **out) override { return device_->QueryInterface(iid, out); }
    const D3DMRootSignatureLayout *STDMETHODCALLTYPE GetLayout() override { return &layout_; }

    HRESULT build(id<MTLDevice> metal, Reader reader) {
        if (!reader.contains(0, 8) || reader.word(0) != 0x43425844 || reader.word(20) != 1 || reader.word(24) != reader.size) return E_INVALIDARG;
        const UINT chunks = reader.word(28);
        if (!reader.contains(32, chunks)) return E_INVALIDARG;
        Reader root{nullptr, 0};
        std::vector<std::pair<size_t, size_t>> parts;
        for (UINT i = 0; i < chunks; ++i) {
            const UINT offset = reader.word(32 + (size_t)i * 4);
            if (offset < 32 + (uint64_t)chunks * 4 || !reader.contains(offset, 2)) return E_INVALIDARG;
            const UINT size = reader.word((size_t)offset + 4);
            if (!reader.contains((size_t)offset + 8, size, 1)) return E_INVALIDARG;
            const size_t end = (size_t)offset + 8 + size;
            for (const auto &[start, previous_end] : parts) if (offset < previous_end && start < end) return E_INVALIDARG;
            parts.emplace_back(offset, end);
            if (reader.word(offset) != 0x30535452) continue; // RTS0
            if (root.bytes) return E_INVALIDARG;
            root = {reader.bytes + offset + 8, size};
        }
        if (!root.bytes || !root.contains(0, 6)) return E_INVALIDARG;
        const UINT version = root.word(0), count = root.word(4), parameters = root.word(8);
        const UINT sampler_count = root.word(12), samplers = root.word(16), flags = root.word(20);
        if ((version != 1 && version != 2) || count > 64 || sampler_count > 2032 || (flags & ~0xfffu)) return E_INVALIDARG;
        if (flags & D3D12_ROOT_SIGNATURE_FLAG_LOCAL_ROOT_SIGNATURE) return DXGI_ERROR_UNSUPPORTED;
        if (!root.contains(parameters, count, 12) || !root.contains(samplers, sampler_count, 52)) return E_INVALIDARG;
        parameters_.resize(count); ranges_.resize(count); offsets_.resize(count); samplers_.resize(sampler_count);
        std::vector<Binding> bindings;
        UINT cost = 0, argument_size = 0;
        for (UINT i = 0; i < count; ++i) {
            auto &p = parameters_[i];
            const size_t record = parameters + (size_t)i * 12;
            const UINT parameter_type = root.word(record), visibility = root.word(record + 4);
            if (parameter_type > D3D12_ROOT_PARAMETER_TYPE_UAV || visibility > D3D12_SHADER_VISIBILITY_MESH) return E_INVALIDARG;
            p.ParameterType = (D3D12_ROOT_PARAMETER_TYPE)parameter_type;
            p.ShaderVisibility = (D3D12_SHADER_VISIBILITY)visibility;
            const UINT payload = root.word(record + 8);
            if (!root.contains(payload, 2)) return E_INVALIDARG;
            UINT bytes = 8, alignment = 8;
            switch (p.ParameterType) {
            case D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE: {
                const UINT range_count = root.word(payload), range_offset = root.word((size_t)payload + 4);
                const UINT stride = version == 1 ? 20 : 24;
                if (!root.contains(range_offset, range_count, stride)) return E_INVALIDARG;
                auto &ranges = ranges_[i]; ranges.resize(range_count);
                uint64_t next = 0;
                UINT heap_type = UINT_MAX;
                for (UINT j = 0; j < range_count; ++j) {
                    auto &range = ranges[j];
                    const size_t r = range_offset + (size_t)j * stride;
                    const UINT range_type = root.word(r);
                    if (range_type > D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER) return E_INVALIDARG;
                    range.RangeType = (D3D12_DESCRIPTOR_RANGE_TYPE)range_type;
                    range.NumDescriptors = root.word(r + 4); range.BaseShaderRegister = root.word(r + 8); range.RegisterSpace = root.word(r + 12);
                    UINT range_flags = root.word(r + 16), offset = 0;
                    if (version == 1) {
                        offset = range_flags;
                        range_flags = D3D12_DESCRIPTOR_RANGE_FLAG_DESCRIPTORS_VOLATILE;
                        if (range.RangeType != D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER) range_flags |= D3D12_DESCRIPTOR_RANGE_FLAG_DATA_VOLATILE;
                    } else offset = root.word(r + 20);
                    if ((range_flags & ~0x1000fu) || !data_flags_valid(range_flags & 14u) || ((range_flags & 9u) == 9u) ||
                        ((range_flags & 0x10001u) == 0x10001u) || (range.RangeType == D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER && (range_flags & ~1u))) return E_INVALIDARG;
                    const UINT type = range.RangeType == D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER ? 1 : 0;
                    if (heap_type != UINT_MAX && heap_type != type) return E_INVALIDARG;
                    heap_type = type;
                    if (!add_binding(bindings, range.RangeType, range.RegisterSpace, range.BaseShaderRegister, range.NumDescriptors, p.ShaderVisibility)) return E_INVALIDARG;
                    if (offset == D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND) {
                        if (next > UINT_MAX) return E_INVALIDARG;
                        offset = (UINT)next;
                    }
                    next = UINT64_C(0x100000000);
                    if (range.NumDescriptors != UINT_MAX) next = (uint64_t)offset + range.NumDescriptors;
                    if (next > UINT64_C(0x100000000)) return E_INVALIDARG;
                    range.OffsetInDescriptorsFromTableStart = offset;
                    range.Flags = (D3D12_DESCRIPTOR_RANGE_FLAGS)range_flags;
                }
                p.DescriptorTable = {range_count, ranges.data()};
                ++cost;
                break;
            }
            case D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS:
                if (!root.contains(payload, 3)) return E_INVALIDARG;
                p.Constants = {root.word(payload), root.word((size_t)payload + 4), root.word((size_t)payload + 8)};
                if (p.Constants.Num32BitValues > 64 ||
                    !add_binding(bindings, D3D12_DESCRIPTOR_RANGE_TYPE_CBV, p.Constants.RegisterSpace, p.Constants.ShaderRegister, 1, p.ShaderVisibility)) return E_INVALIDARG;
                bytes = p.Constants.Num32BitValues * 4; alignment = 4; cost += p.Constants.Num32BitValues;
                break;
            case D3D12_ROOT_PARAMETER_TYPE_CBV: case D3D12_ROOT_PARAMETER_TYPE_SRV: case D3D12_ROOT_PARAMETER_TYPE_UAV: {
                if (version == 2 && !root.contains(payload, 3)) return E_INVALIDARG;
                UINT descriptor_flags = D3D12_ROOT_DESCRIPTOR_FLAG_DATA_VOLATILE;
                if (version == 2) descriptor_flags = root.word((size_t)payload + 8);
                if (!data_flags_valid(descriptor_flags)) return E_INVALIDARG;
                p.Descriptor = {root.word(payload), root.word((size_t)payload + 4), (D3D12_ROOT_DESCRIPTOR_FLAGS)descriptor_flags};
                UINT type = D3D12_DESCRIPTOR_RANGE_TYPE_CBV;
                if (p.ParameterType == D3D12_ROOT_PARAMETER_TYPE_SRV) type = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
                if (p.ParameterType == D3D12_ROOT_PARAMETER_TYPE_UAV) type = D3D12_DESCRIPTOR_RANGE_TYPE_UAV;
                if (!add_binding(bindings, type, p.Descriptor.RegisterSpace, p.Descriptor.ShaderRegister, 1, p.ShaderVisibility)) return E_INVALIDARG;
                cost += 2;
                break;
            }
            default: return E_INVALIDARG;
            }
            if (cost > 64) return E_INVALIDARG;
            argument_size = (argument_size + alignment - 1) & ~(alignment - 1);
            offsets_[i] = argument_size; argument_size += bytes;
        }
        if (!root.valid) return E_INVALIDARG;
        static_assert(sizeof(D3D12_STATIC_SAMPLER_DESC) == 52);
        for (UINT i = 0; i < sampler_count; ++i) {
            const size_t s = samplers + (size_t)i * 52;
            if ((root.word(s) & ~0x1d5u) || root.word(s + 4) < 1 || root.word(s + 4) > 5 ||
                root.word(s + 8) < 1 || root.word(s + 8) > 5 || root.word(s + 12) < 1 || root.word(s + 12) > 5 ||
                root.word(s + 24) > 8 || root.word(s + 28) > 2 || root.word(s + 48) > D3D12_SHADER_VISIBILITY_MESH) return E_INVALIDARG;
        }
        if (sampler_count) std::memcpy(samplers_.data(), root.bytes + samplers, sampler_count * 52);
        for (const auto &s : samplers_) {
            if (s.ShaderVisibility > D3D12_SHADER_VISIBILITY_MESH || s.BorderColor > D3D12_STATIC_BORDER_COLOR_OPAQUE_WHITE ||
                !add_binding(bindings, D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER, s.RegisterSpace, s.ShaderRegister, 1, s.ShaderVisibility)) return E_INVALIDARG;
            D3D12_SAMPLER_DESC desc = {s.Filter, s.AddressU, s.AddressV, s.AddressW, s.MipLODBias, s.MaxAnisotropy, s.ComparisonFunc, {}, s.MinLOD, s.MaxLOD};
            if (s.BorderColor == D3D12_STATIC_BORDER_COLOR_OPAQUE_WHITE) std::fill_n(desc.BorderColor, 4, 1.f);
            if (s.BorderColor == D3D12_STATIC_BORDER_COLOR_OPAQUE_BLACK) desc.BorderColor[3] = 1.f;
            id<MTLSamplerState> state;
            const HRESULT hr = make_sampler(metal, desc, &state);
            if (FAILED(hr)) return hr;
            sampler_states_.push_back(state);
        }
        layout_.staticSamplerOffset = UINT_MAX;
        if (sampler_count) {
            sampler_table_ = [metal newBufferWithLength:sampler_count * 24 options:MTLResourceStorageModeShared];
            if (!sampler_table_) return E_OUTOFMEMORY;
            auto *entries = (uint64_t *)sampler_table_.contents;
            for (UINT i = 0; i < sampler_count; ++i) {
                entries[i * 3] = sampler_states_[i].gpuResourceID._impl;
                entries[i * 3 + 1] = 0;
                entries[i * 3 + 2] = std::bit_cast<uint32_t>(samplers_[i].MipLODBias);
            }
            argument_size = (argument_size + 7) & ~7u;
            layout_.staticSamplerOffset = argument_size; argument_size += 8;
        }
        layout_.desc = {count, parameters_.data(), sampler_count, samplers_.data(), (D3D12_ROOT_SIGNATURE_FLAGS)flags};
        layout_.parameterOffsets = offsets_.data();
        layout_.argumentBufferSize = (argument_size + 7) & ~7u;
        layout_.staticSamplers = (__bridge void *)sampler_table_;
        serialized_.assign(reader.bytes,reader.bytes+reader.size);
        layout_.serialized=serialized_.data(); layout_.serializedSize=serialized_.size();
        return S_OK;
    }
private:
    ID3D12Device *device_;
    PrivateData data_;
    std::vector<D3D12_ROOT_PARAMETER1> parameters_;
    std::vector<std::vector<D3D12_DESCRIPTOR_RANGE1>> ranges_;
    std::vector<D3D12_STATIC_SAMPLER_DESC> samplers_;
    std::vector<UINT> offsets_;
    std::vector<uint8_t> serialized_;
    std::vector<id<MTLSamplerState>> sampler_states_;
    id<MTLBuffer> sampler_table_;
    D3DMRootSignatureLayout layout_{};
};
}

HRESULT create_root_signature(ID3D12Device *device, id<MTLDevice> metal, UINT mask, const void *blob, SIZE_T size, REFIID iid, void **out) {
    if (out) *out = nullptr;
    if (mask > 1 || !blob || size > UINT32_MAX) return E_INVALIDARG;
    auto *root = new (std::nothrow) RootSignature(device);
    if (!root) return E_OUTOFMEMORY;
    HRESULT hr = root->build(metal, {(const uint8_t *)blob, size});
    if (SUCCEEDED(hr)) {
        void *result = nullptr;
        hr = root->QueryInterface(iid, &result);
        if (SUCCEEDED(hr)) {
            if (out) *out = result;
            else { ((IUnknown *)result)->Release(); hr = S_FALSE; }
        }
    }
    root->Release();
    return hr;
}
}
