// d3d12-metal public interface: DirectX-Headers types plus d3dm_dxgi.h, and the host hooks.
// Objective-C++ users must import Apple headers first: the Windows stubs define `interface`.
// There, the Windows BOOL is spelled WINBOOL and Objective-C keeps its own BOOL.
#pragma once

#define HWND d3dm_stub_HWND
#ifdef __OBJC__
#define BOOL WINBOOL
#undef TRUE
#undef FALSE
#endif
#include <wsl/winadapter.h>
#include <directx/d3d12.h>
#include <dxguids/dxguids.h>
#undef HWND
typedef struct HWND__ *HWND;
#include "d3dm_dxgi.h"
#ifdef __OBJC__
#undef BOOL
#endif

// One display as the host's window system names it. The first entry is the primary display.
struct D3DMOutputInfo {
    uint32_t display; // CGDirectDisplayID
    HMONITOR monitor;
    RECT desktop;     // desktop pixels: primary top-left origin, y down
};

// Shader data supplied by the host's offline converter catalog. Pointers remain host-owned.
struct D3DMShader {
    void *library; // id<MTLLibrary>, unretained
    const char *entryPoint;
    const char *reflection;
    UINT threads[3];
    // Equivalent fragment variant when the specified copied CBV word matches.
    void *specializedLibrary = nullptr;
    const char *specializedEntryPoint = nullptr;
    UINT specializationParameter = 0, specializationIndex = 0, specializationOffset = 0, specializationValue = 0;
};

// Host services. Every hook is optional unless stated.
struct D3DMHost {
    // Required for swap chains: the window's CAMetalLayer (unretained), or null.
    void *(*metal_layer)(HWND window);
    // Fills up to `capacity` outputs and returns the total. Default: Quartz displays, handle = display ID.
    UINT (*outputs)(D3DMOutputInfo *list, UINT capacity);
    // Required for DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT: Win32-style semaphore handles.
    HANDLE (*create_semaphore)(LONG initial, LONG maximum);
    void (*release_semaphore)(HANDLE semaphore, LONG count);
    HANDLE (*duplicate_handle)(HANDLE handle);
    void (*close_handle)(HANDLE handle);
    bool (*try_wait_semaphore)(HANDLE handle);
    // Optional window integration. The host owns fullscreen transitions and display-mode policy.
    HMONITOR (*window_monitor)(HWND window);
    HRESULT (*set_fullscreen)(HWND window, WINBOOL fullscreen, HMONITOR monitor);
    // Required for device creation: the host's feature/capability policy, independent of Metal object ownership.
    HRESULT (*check_feature)(D3D12_FEATURE feature, void *data, UINT size) = nullptr;
    HRESULT (*load_shader)(void *metal, const void *root, SIZE_T root_size, const void *code, SIZE_T code_size,
                           UINT unorm8_mask, D3DMShader *shader) = nullptr;
    HANDLE (*duplicate_event)(HANDLE event) = nullptr;
    void (*signal_event)(HANDLE event) = nullptr;
    const char *pipeline_archive = nullptr;
    // Approves a pure fullscreen copy pipeline for spatial upscaling and identifies its source SRV.
    bool (*spatial_upscale_source)(const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc, UINT *parameter, UINT *index) = nullptr;
    // Optional host pacing override, in seconds (0 disables; valid range (0, 1]). Enables display sync.
    double minimum_present_duration = 0;
};

extern "C" {
void D3DMSetHost(const D3DMHost *host);
HRESULT D3DMCreateDXGIFactory2(UINT Flags, REFIID riid, void **ppFactory);
HRESULT D3DMCreateDevice(IUnknown *adapter, D3D_FEATURE_LEVEL minimum, REFIID riid, void **device);
HRESULT D3DMFlushPipelineArchive();
// Saves pending archive entries on a background queue; returns at once. D3DMFlushPipelineArchive waits for it.
void D3DMSchedulePipelineArchiveFlush();
}

// Private interface a D3D12 command queue implements so swap chains present on its Metal queue.
interface ID3DMMetalQueue : public IUnknown {
    virtual void *STDMETHODCALLTYPE MetalCommandQueue() = 0; // id<MTLCommandQueue>, unretained
};
__CRT_UUID_DECL(ID3DMMetalQueue, 0x5d3e8a71, 0x2c4f, 0x4b9a, 0x9e, 0x13, 0x6f, 0x0d, 0x84, 0xa2, 0x55, 0xc1)

// Private interface of resources backed by a Metal texture, such as swap-chain back buffers.
interface ID3DMMetalTexture : public IUnknown {
    virtual void *STDMETHODCALLTYPE MetalTexture() = 0; // id<MTLTexture>, unretained
};
__CRT_UUID_DECL(ID3DMMetalTexture, 0x8b21f4c6, 0x7d05, 0x4e3a, 0xb6, 0x42, 0x1c, 0x9e, 0x3a, 0x70, 0xd8, 0x2f)

// Private backing interfaces used by resource consumers and heap placement.
interface ID3DMMetalBuffer : public IUnknown {
    virtual void *STDMETHODCALLTYPE MetalBuffer() = 0; // id<MTLBuffer>, unretained
};
__CRT_UUID_DECL(ID3DMMetalBuffer, 0xce43a87b, 0x8cb9, 0x4df8, 0x83, 0xc1, 0x62, 0xc6, 0x12, 0xef, 0xa1, 0x91)

interface ID3DMMetalHeap : public IUnknown {
    virtual void *STDMETHODCALLTYPE MetalHeap() = 0; // id<MTLHeap>, unretained
};
__CRT_UUID_DECL(ID3DMMetalHeap, 0x9e951862, 0xaf2a, 0x43f8, 0x89, 0xc6, 0x63, 0xd2, 0xd1, 0x9c, 0xa8, 0x46)

// Native descriptor consumers use the table for shader binding and views for attachments/residency.
// Returned Metal objects are unretained and remain valid until the slot is overwritten or heap released.
struct D3DMDescriptorView {
    void *resource; // id<MTLResource>: buffer or texture view
    void *counter;  // id<MTLTexture>: optional structured UAV counter
    UINT depthPlane;
    UINT depthCount;
    D3D12_DSV_FLAGS depthFlags;
};
interface ID3DMDescriptorHeap : public IUnknown {
    virtual void *STDMETHODCALLTYPE MetalDescriptorBuffer() = 0; // id<MTLBuffer>, null for RTV/DSV
    virtual HRESULT STDMETHODCALLTYPE GetView(UINT index, D3DMDescriptorView *view) = 0;
};
__CRT_UUID_DECL(ID3DMDescriptorHeap, 0x7f9e3ab2, 0xc124, 0x45c3, 0x9d, 0x26, 0x23, 0x67, 0xf0, 0xbb, 0x8c, 0xe1)

// Immutable converter layout for pipeline creation and command-list root arguments.
// Version 1.0 inputs are promoted to 1.1, preserving their volatile descriptor/data semantics.
struct D3DMRootSignatureLayout {
    D3D12_ROOT_SIGNATURE_DESC1 desc;
    const UINT *parameterOffsets; // byte offsets in the top-level argument buffer
    UINT argumentBufferSize;
    UINT staticSamplerOffset; // UINT_MAX when there are no static samplers
    void *staticSamplers; // id<MTLBuffer>, unretained, 24-byte entries in declaration order
    const void *serialized;
    SIZE_T serializedSize;
};
interface ID3DMRootSignature : public IUnknown {
    virtual const D3DMRootSignatureLayout *STDMETHODCALLTYPE GetLayout() = 0;
};
__CRT_UUID_DECL(ID3DMRootSignature, 0x31f96d83, 0x552c, 0x4f91, 0xa8, 0x02, 0xd4, 0x64, 0x6d, 0x3c, 0xc9, 0x17)

// Backend command recording consumes the immutable state declared in src/pipeline.h.
interface ID3DMPipeline : public IUnknown {
    virtual const void *STDMETHODCALLTYPE NativePipelineState() = 0;
};
__CRT_UUID_DECL(ID3DMPipeline,0x863f19ae,0x82da,0x4c19,0xb6,0x78,0xc3,0x1c,0x02,0xe0,0x65,0x70)

// Presentation/command submission records the first permanent GPU failure on its owning device.
interface ID3DMDeviceStatus : public IUnknown {
    virtual void STDMETHODCALLTYPE RecordError(HRESULT reason) = 0;
};
__CRT_UUID_DECL(ID3DMDeviceStatus, 0x81d44651, 0x0477, 0x4cf9, 0xb2, 0xcc, 0x75, 0xb4, 0x83, 0x30, 0x58, 0x9f)
