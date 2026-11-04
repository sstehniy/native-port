// Native DXGI checks against a real window: queries, presents, resizes, the captured pixels and refcounts.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

// Like the runtime's view; declared before d3d12_metal.h, whose Windows stubs define `interface`.
@interface RecordingLayer : CAMetalLayer
@property(nonatomic, strong) NSMutableArray<NSNumber *> *presented;
@end
@implementation RecordingLayer
- (id<CAMetalDrawable>)nextDrawable {
    id<CAMetalDrawable> drawable = [super nextDrawable];
    NSMutableArray<NSNumber *> *times = self.presented;
    if (times) [drawable addPresentedHandler:^(id<MTLDrawable> frame) {
        @synchronized(times) { [times addObject:@(frame.presentedTime)]; }
    }];
    return drawable;
}
@end

@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
- (CALayer *)makeBackingLayer { return [RecordingLayer layer]; }
@end

#include "d3d12_metal.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <string>

static int checks;
#define CHECK(condition)                                                                    \
    do {                                                                                    \
        if (!(condition)) {                                                                 \
            fprintf(stderr, "dxgi_test: %s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
            exit(1);                                                                        \
        }                                                                                   \
        ++checks;                                                                           \
    } while (0)
#define OK(call) CHECK((call) == S_OK)

namespace {

class Queue final : public ID3DMMetalQueue, public ID3D12DeviceChild {
public:
    Queue(id<MTLDevice> metal, ID3D12Device *device) : queue([metal newCommandQueue]), device(device) { device->AddRef(); }
    ~Queue() { device->Release(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(ID3DMMetalQueue)) *out = static_cast<ID3DMMetalQueue *>(this);
        else if (riid == __uuidof(ID3D12Object) || riid == __uuidof(ID3D12DeviceChild)) *out = static_cast<ID3D12DeviceChild *>(this);
        else return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { return --refs; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID, UINT *, void *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID, UINT, const void *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID, const IUnknown *) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID riid, void **out) override { return device->QueryInterface(riid, out); }
    void *STDMETHODCALLTYPE MetalCommandQueue() override { return (__bridge void *)queue; }
    ULONG refs = 1;
    id<MTLCommandQueue> queue;
    ID3D12Device *device;
};

struct Semaphore {
    dispatch_semaphore_t semaphore;
    std::atomic<int> handles;
};

void release_semaphore(HANDLE handle, LONG count) {
    while (count--) dispatch_semaphore_signal(((Semaphore *)handle)->semaphore);
}
// Starts at zero: libdispatch traps when a semaphore is freed below its initial value.
HANDLE create_semaphore(LONG initial, LONG) {
    Semaphore *semaphore = new Semaphore{dispatch_semaphore_create(0), 1};
    release_semaphore(semaphore, initial);
    return semaphore;
}
HANDLE duplicate_handle(HANDLE handle) {
    ++((Semaphore *)handle)->handles;
    return handle;
}
void close_handle(HANDLE handle) {
    if (!--((Semaphore *)handle)->handles) delete (Semaphore *)handle;
}
bool wait(HANDLE handle, double seconds) {
    return !dispatch_semaphore_wait(((Semaphore *)handle)->semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)));
}

void pump(double seconds) { [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; }

NSWindow *open_window(NSRect frame) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    FlippedView *view = [[FlippedView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
    window.contentView = view;
    view.layer.contentsScale = window.backingScaleFactor;
    view.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    [window makeKeyAndOrderFront:nil];
    pump(0.2);
    return window;
}

HWND hwnd(NSWindow *window) { return (HWND)(__bridge void *)window; }

void clear(Queue &queue, ID3D12Resource *resource, MTLClearColor color) {
    ID3DMMetalTexture *texture = nullptr;
    OK(resource->QueryInterface(__uuidof(ID3DMMetalTexture), (void **)&texture));
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = (__bridge id<MTLTexture>)texture->MetalTexture();
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = color;
    id<MTLCommandBuffer> commands = [queue.queue commandBuffer];
    [[commands renderCommandEncoderWithDescriptor:pass] endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    texture->Release();
}

void clear_buffers(Queue &queue, IDXGISwapChain3 *chain, MTLClearColor color) {
    DXGI_SWAP_CHAIN_DESC1 desc;
    OK(chain->GetDesc1(&desc));
    for (UINT i = 0; i < desc.BufferCount; ++i) {
        ID3D12Resource *buffer = nullptr;
        OK(chain->GetBuffer(i, __uuidof(ID3D12Resource), (void **)&buffer));
        clear(queue, buffer, color);
        buffer->Release();
    }
}

// Window contents as sRGB, sampled at fractions of the content area (0,0 = visual top-left).
struct Capture {
    NSBitmapImageRep *image;
    NSInteger top; // title-bar pixels above the content area
    NSColor *at(double x, double y) const {
        const NSInteger height = image.pixelsHigh - top;
        // colorAtX:y: drops the capture's display profile, so build the color from raw samples.
        NSUInteger raw[4] = {};
        [image getPixel:raw atX:(NSInteger)(x * (image.pixelsWide - 1)) y:top + (NSInteger)(y * (height - 1))];
        const CGFloat components[4] = {raw[0] / 255.0, raw[1] / 255.0, raw[2] / 255.0, 1};
        return [[NSColor colorWithColorSpace:image.colorSpace components:components count:4] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }
};

Capture capture(NSWindow *window) {
    pump(0.3);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"d3dm-dxgi-test.png"];
    const std::string command = "screencapture -x -o -l " + std::to_string(window.windowNumber) + " " + path.UTF8String;
    CHECK(system(command.c_str()) == 0);
    NSBitmapImageRep *image = (NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfFile:path];
    CHECK(image != nil);
    const double scale = image.pixelsHigh / window.frame.size.height;
    return {image, (NSInteger)((window.frame.size.height - window.contentView.frame.size.height) * scale)};
}

// Display profiles shift saturated colors (sRGB green reads back near 0.29, 1, 0 on a wide-gamut monitor),
// so compare which channels are on rather than exact values.
bool near(NSColor *color, double r, double g, double b) {
    const double channels[3] = {color.redComponent, color.greenComponent, color.blueComponent}, want[3] = {r, g, b};
    for (int i = 0; i < 3; ++i)
        if (want[i] ? channels[i] < 0.75 : channels[i] > 0.35) {
            fprintf(stderr, "dxgi_test: color %.3f %.3f %.3f\n", channels[0], channels[1], channels[2]);
            return false;
        }
    return true;
}

void check_queries(IDXGIFactory4 *factory) {
    void *other = nullptr;
    CHECK(D3DMCreateDXGIFactory2(2, __uuidof(IDXGIFactory4), &other) == E_INVALIDARG);
    IDXGIFactory5 *factory5 = nullptr;
    OK(factory->QueryInterface(__uuidof(IDXGIFactory5), (void **)&factory5));
    WINBOOL tearing = FALSE;
    OK(factory5->CheckFeatureSupport(DXGI_FEATURE_PRESENT_ALLOW_TEARING, &tearing, sizeof(tearing)));
    CHECK(tearing == TRUE);
    CHECK(factory5->CheckFeatureSupport(DXGI_FEATURE_PRESENT_ALLOW_TEARING, &tearing, 1) == E_INVALIDARG);
    factory5->Release();

    IDXGIAdapter1 *adapter = nullptr;
    OK(factory->EnumAdapters1(0, &adapter));
    DXGI_ADAPTER_DESC1 desc;
    OK(adapter->GetDesc1(&desc));
    CHECK(desc.VendorId == 0x106b && !(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) && desc.Description[0]);
    CHECK(desc.DedicatedVideoMemory > 0);
    const GUID private_key = {0x1234, 0, 0, {}};
    IDXGIAdapter1 *held = nullptr;
    OK(factory->EnumAdapters1(0, &held));
    OK(factory->SetPrivateDataInterface(private_key, held));
    held->Release();
    OK(factory->SetPrivateDataInterface(private_key, held));
    OK(factory->SetPrivateDataInterface(private_key, nullptr));
    UINT count = 1;
    IDXGIAdapter1 *extra = nullptr;
    while (factory->EnumAdapters1(count, &extra) == S_OK) {
        extra->Release();
        ++count;
    }
    CHECK(factory->EnumAdapters1(count, &extra) == DXGI_ERROR_NOT_FOUND && !extra);
    IDXGIAdapter *by_luid = nullptr;
    OK(factory->EnumAdapterByLuid(desc.AdapterLuid, __uuidof(IDXGIAdapter), (void **)&by_luid));
    by_luid->Release();

    IDXGIAdapter3 *adapter3 = nullptr;
    OK(adapter->QueryInterface(__uuidof(IDXGIAdapter3), (void **)&adapter3));
    DXGI_QUERY_VIDEO_MEMORY_INFO memory;
    OK(adapter3->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &memory));
    CHECK(memory.Budget > 0);
    adapter3->Release();

    IDXGIOutput *output = nullptr;
    OK(adapter->EnumOutputs(0, &output));
    DXGI_OUTPUT_DESC output_desc;
    OK(output->GetDesc(&output_desc));
    CHECK(!wcscmp(output_desc.DeviceName, L"\\\\.\\DISPLAY1") && output_desc.AttachedToDesktop);
    CHECK(output_desc.DesktopCoordinates.left == 0 && output_desc.DesktopCoordinates.top == 0);
    UINT modes = 0;
    OK(output->GetDisplayModeList(DXGI_FORMAT_R8G8B8A8_UNORM, 0, &modes, nullptr));
    CHECK(modes > 0);
    DXGI_MODE_DESC want = {1280, 720, {60, 1}, DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_MODE_SCANLINE_ORDER_UNSPECIFIED, DXGI_MODE_SCALING_UNSPECIFIED}, closest;
    OK(output->FindClosestMatchingMode(&want, &closest, nullptr));
    CHECK(closest.Width > 0 && closest.Format == DXGI_FORMAT_R8G8B8A8_UNORM);
    IDXGIAdapter *parent = nullptr;
    OK(output->GetParent(__uuidof(IDXGIAdapter), (void **)&parent));
    CHECK(parent == (IDXGIAdapter *)adapter);
    parent->Release();
    CHECK(output->Release() == 0);
    CHECK(adapter->Release() == 0);
}

// The game's sequence: flip-discard RGBA8, two buffers, tearing allowed, no scaling.
void check_presents(IDXGIFactory4 *factory, Queue &queue, NSWindow *window) {
    const CGSize pixels = [window.contentView convertSizeToBacking:window.contentView.bounds.size];
    DXGI_SWAP_CHAIN_DESC1 desc = {(UINT)pixels.width, (UINT)pixels.height, DXGI_FORMAT_R8G8B8A8_UNORM, FALSE, {1, 0},
                                  DXGI_USAGE_RENDER_TARGET_OUTPUT, 2, DXGI_SCALING_NONE, DXGI_SWAP_EFFECT_FLIP_DISCARD,
                                  DXGI_ALPHA_MODE_UNSPECIFIED, DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING};
    IDXGISwapChain1 *chain1 = nullptr;
    DXGI_SWAP_CHAIN_DESC1 bad = desc;
    bad.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    CHECK(factory->CreateSwapChainForHwnd(static_cast<ID3DMMetalQueue *>(&queue), hwnd(window), &bad, nullptr, nullptr, &chain1) == DXGI_ERROR_INVALID_CALL);
    bad = desc;
    bad.Flags |= DXGI_SWAP_CHAIN_FLAG_HW_PROTECTED;
    CHECK(factory->CreateSwapChainForHwnd(static_cast<ID3DMMetalQueue *>(&queue), hwnd(window), &bad, nullptr, nullptr, &chain1) == DXGI_ERROR_UNSUPPORTED && !chain1);
    OK(factory->CreateSwapChainForHwnd(static_cast<ID3DMMetalQueue *>(&queue), hwnd(window), &desc, nullptr, nullptr, &chain1));
    OK(factory->MakeWindowAssociation(hwnd(window), DXGI_MWA_NO_ALT_ENTER));
    IDXGISwapChain3 *chain = nullptr;
    OK(chain1->QueryInterface(__uuidof(IDXGISwapChain3), (void **)&chain));
    CHECK(chain1->Release() == 1);

    ID3D12Resource *buffers[2] = {};
    for (UINT i = 0; i < 2; ++i) OK(chain->GetBuffer(i, __uuidof(ID3D12Resource), (void **)&buffers[i]));
    CHECK(buffers[0] != buffers[1]);
    CHECK(chain->GetBuffer(2, __uuidof(ID3D12Resource), (void **)&buffers[1]) == DXGI_ERROR_INVALID_CALL);
    OK(chain->GetBuffer(1, __uuidof(ID3D12Resource), (void **)&buffers[1]));
    buffers[1]->Release();
    const D3D12_RESOURCE_DESC resource = buffers[0]->GetDesc();
    CHECK(resource.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE2D && resource.Width == desc.Width && resource.Height == desc.Height);
    CHECK(resource.Format == desc.Format && resource.Flags == D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET && resource.MipLevels == 1);
    ID3D12Device *device = nullptr;
    OK(buffers[0]->GetDevice(__uuidof(ID3D12Device), (void **)&device));
    CHECK(device == queue.device);
    device->Release();
    OK(chain->GetDevice(__uuidof(ID3D12Device), (void **)&device));
    CHECK(device == queue.device);
    device->Release();
    IUnknown *identity = nullptr;
    OK(chain->GetDevice(__uuidof(IUnknown), (void **)&identity));
    CHECK(identity == static_cast<IUnknown *>(queue.device));
    identity->Release();
    void *unsupported = (void *)1;
    CHECK(chain->GetDevice(__uuidof(ID3DMMetalQueue), &unsupported) == E_NOINTERFACE && !unsupported);
    CHECK(chain->GetDevice(__uuidof(ID3D12Device), nullptr) == E_POINTER);
    OK(buffers[0]->SetName(L"back buffer"));
    UINT size = 0;
    OK(buffers[0]->GetPrivateData(WKPDID_D3DDebugObjectNameW, &size, nullptr));
    CHECK(size == sizeof(L"back buffer"));
    clear(queue, buffers[0], MTLClearColorMake(1, 0, 0, 1));
    clear(queue, buffers[1], MTLClearColorMake(0, 1, 0, 1));

    CHECK(chain->GetCurrentBackBufferIndex() == 0);
    OK(chain->Present(1, 0));
    CHECK(chain->GetCurrentBackBufferIndex() == 1);
    Capture red = capture(window);
    CHECK(near(red.at(0.5, 0.5), 1, 0, 0) && near(red.at(0.05, 0.05), 1, 0, 0) && near(red.at(0.93, 0.93), 1, 0, 0));
    OK(chain->Present(0, DXGI_PRESENT_ALLOW_TEARING));
    CHECK(chain->GetCurrentBackBufferIndex() == 0);
    CHECK(near(capture(window).at(0.5, 0.5), 0, 1, 0));
    CHECK(chain->Present(1, DXGI_PRESENT_ALLOW_TEARING) == DXGI_ERROR_INVALID_CALL);
    CHECK(chain->Present(5, 0) == DXGI_ERROR_INVALID_CALL);
    OK(chain->Present(0, DXGI_PRESENT_TEST));
    CHECK(chain->GetCurrentBackBufferIndex() == 0);
    for (UINT sync = 2; sync <= 4; ++sync) OK(chain->Present(sync, 0));
    CHECK(chain->GetCurrentBackBufferIndex() == 1);
    UINT presents = 0;
    OK(chain->GetLastPresentCount(&presents));
    CHECK(presents == 5);

    CHECK(chain->ResizeBuffers(2, 0, 0, DXGI_FORMAT_UNKNOWN, DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING) == DXGI_ERROR_INVALID_CALL);
    for (ID3D12Resource *buffer : buffers) buffer->Release();
    // Zero sizes take the window's client size, as on Windows.
    OK(chain->ResizeBuffers(2, 0, 0, DXGI_FORMAT_UNKNOWN, DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING));
    DXGI_SWAP_CHAIN_DESC1 resized;
    OK(chain->GetDesc1(&resized));
    CHECK(resized.Width == desc.Width && resized.Height == desc.Height && resized.BufferCount == 2);
    CHECK(chain->GetCurrentBackBufferIndex() == 0);
    CHECK(chain->ResizeBuffers(0, 0, 0, DXGI_FORMAT_UNKNOWN, 0) == DXGI_ERROR_INVALID_CALL);
    CHECK(chain->ResizeBuffers(3, UINT32_MAX, 1, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING) == DXGI_ERROR_INVALID_CALL);
    OK(chain->GetDesc1(&resized));
    CHECK(resized.Width == desc.Width && resized.Height == desc.Height && resized.BufferCount == 2 && resized.Format == desc.Format);
    // Scaling NONE keeps a smaller image at the window's top-left.
    OK(chain->ResizeBuffers(3, desc.Width / 2, desc.Height / 2, DXGI_FORMAT_UNKNOWN, DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING));
    OK(chain->GetDesc1(&resized));
    CHECK(resized.Width == desc.Width / 2 && resized.Height == desc.Height / 2 && resized.BufferCount == 3);
    clear_buffers(queue, chain, MTLClearColorMake(0, 0, 1, 1));
    OK(chain->Present(1, 0));
    Capture corner = capture(window);
    CHECK(near(corner.at(0.25, 0.25), 0, 0, 1) && near(corner.at(0.05, 0.05), 0, 0, 1));
    CHECK(near(corner.at(0.75, 0.75), 0, 0, 0) && near(corner.at(0.75, 0.25), 0, 0, 0) && near(corner.at(0.25, 0.75), 0, 0, 0));
    OK(chain->SetSourceSize(desc.Width / 4, desc.Height / 4));
    UINT width = 0, height = 0;
    OK(chain->GetSourceSize(&width, &height));
    CHECK(width == desc.Width / 4 && height == desc.Height / 4);
    CHECK(chain->SetSourceSize(desc.Width, 1) == DXGI_ERROR_INVALID_CALL);
    OK(chain->Present(1, 0));

    UINT support = 0;
    OK(chain->CheckColorSpaceSupport(DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709, &support));
    CHECK(support == DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT);
    OK(chain->CheckColorSpaceSupport(DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020, &support));
    CHECK(support == 0);
    CHECK(chain->SetColorSpace1(DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020) == E_INVALIDARG);
    OK(chain->ResizeBuffers(0, 0, 0, DXGI_FORMAT_R10G10B10A2_UNORM, DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING));
    OK(chain->CheckColorSpaceSupport(DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020, &support));
    CHECK(support == DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT);
    OK(chain->SetColorSpace1(DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020));
    OK(chain->SetColorSpace1(DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709));
    OK(chain->ResizeBuffers(2, desc.Width, desc.Height, DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING));
    CHECK(chain->ResizeBuffers(2, 0, 0, DXGI_FORMAT_UNKNOWN, DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT) == DXGI_ERROR_INVALID_CALL);
    CHECK(chain->SetMaximumFrameLatency(2) == DXGI_ERROR_INVALID_CALL);
    CHECK(chain->GetFrameLatencyWaitableObject() == nullptr);

    WINBOOL fullscreen = TRUE;
    IDXGIOutput *target = nullptr;
    OK(chain->GetFullscreenState(&fullscreen, &target));
    CHECK(!fullscreen && !target);
    const NSRect original_frame = window.frame;
    OK(chain->SetFullscreenState(TRUE, nullptr));
    CHECK(!(window.styleMask & NSWindowStyleMaskTitled) && NSEqualRects(window.frame, window.screen.frame));
    OK(chain->GetFullscreenState(&fullscreen, &target));
    CHECK(fullscreen && target);
    target->Release();
    CHECK(chain->Present(0, DXGI_PRESENT_ALLOW_TEARING) == DXGI_ERROR_INVALID_CALL);
    OK(chain->SetFullscreenState(FALSE, nullptr));
    CHECK((window.styleMask & NSWindowStyleMaskTitled) && NSEqualRects(window.frame, original_frame));

    const GUID key = {0x1234, 0x5678, 0x9abc, {1, 2, 3, 4, 5, 6, 7, 8}};
    const uint32_t value = 0xfeedface;
    OK(chain->SetPrivateData(key, sizeof(value), &value));
    uint32_t read = 0;
    size = 2;
    CHECK(chain->GetPrivateData(key, &size, &read) == DXGI_ERROR_MORE_DATA);
    size = sizeof(read);
    OK(chain->GetPrivateData(key, &size, &read));
    CHECK(read == value);
    IDXGIFactory4 *parent = nullptr;
    OK(chain->GetParent(__uuidof(IDXGIFactory4), (void **)&parent));
    CHECK(parent == factory);
    parent->Release();
    HWND window_handle = nullptr;
    OK(chain->GetHwnd(&window_handle));
    CHECK(window_handle == hwnd(window));
    CHECK(chain->Release() == 0);
}

void check_pacing(IDXGIFactory4 *factory, Queue &queue, NSWindow *window, D3DMHost host) {
    host.minimum_present_duration = 1.0 / 30;
    D3DMSetHost(&host);
    DXGI_SWAP_CHAIN_DESC1 desc = {320, 240, DXGI_FORMAT_R8G8B8A8_UNORM, FALSE, {1, 0},
        DXGI_USAGE_RENDER_TARGET_OUTPUT, 2, DXGI_SCALING_STRETCH, DXGI_SWAP_EFFECT_FLIP_DISCARD, DXGI_ALPHA_MODE_UNSPECIFIED, 0};
    IDXGISwapChain1 *chain = nullptr;
    OK(factory->CreateSwapChainForHwnd(static_cast<ID3DMMetalQueue *>(&queue), hwnd(window), &desc, nullptr, nullptr, &chain));
    RecordingLayer *layer = (RecordingLayer *)window.contentView.layer;
    OK(chain->Present(0, 0));
    pump(0.2);
    NSMutableArray<NSNumber *> *times = [NSMutableArray new];
    layer.presented = times;
    for (unsigned i = 0; i < 16; ++i) OK(chain->Present(0, 0));
    pump(0.5);
    layer.presented = nil;
    @synchronized(times) {
        CHECK(times.count >= 12);
        NSArray<NSNumber *> *ordered = [times sortedArrayUsingSelector:@selector(compare:)];
        for (NSUInteger i = 1; i < ordered.count; ++i)
            CHECK(ordered[i].doubleValue - ordered[i - 1].doubleValue >= 0.032);
    }
    CHECK(layer.displaySyncEnabled && layer.maximumDrawableCount == 3);
    host.minimum_present_duration = 0;
    D3DMSetHost(&host);
    OK(chain->Present(0, 0));
    CHECK(!layer.displaySyncEnabled);
    CHECK(chain->Release() == 0);
}

void check_waitable(IDXGIFactory4 *factory, Queue &queue, NSWindow *window) {
    DXGI_SWAP_CHAIN_DESC1 desc = {0, 0, DXGI_FORMAT_B8G8R8A8_UNORM, FALSE, {1, 0}, DXGI_USAGE_RENDER_TARGET_OUTPUT, 2,
                                  DXGI_SCALING_STRETCH, DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL, DXGI_ALPHA_MODE_UNSPECIFIED,
                                  DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT};
    IDXGISwapChain1 *chain1 = nullptr;
    OK(factory->CreateSwapChainForHwnd(static_cast<ID3DMMetalQueue *>(&queue), hwnd(window), &desc, nullptr, nullptr, &chain1));
    IDXGISwapChain2 *chain = nullptr;
    OK(chain1->QueryInterface(__uuidof(IDXGISwapChain2), (void **)&chain));
    chain1->Release();
    DXGI_SWAP_CHAIN_DESC1 actual;
    OK(chain->GetDesc1(&actual));
    const CGSize pixels = [window.contentView convertSizeToBacking:window.contentView.bounds.size];
    CHECK(actual.Width == (UINT)pixels.width && actual.Height == (UINT)pixels.height);
    UINT latency = 0;
    OK(chain->GetMaximumFrameLatency(&latency));
    CHECK(latency == 1);
    HANDLE event = chain->GetFrameLatencyWaitableObject();
    CHECK(event != nullptr);
    CHECK(wait(event, 1));
    CHECK(!wait(event, 0.05));
    IDXGISwapChain3 *chain3 = nullptr;
    OK(chain->QueryInterface(__uuidof(IDXGISwapChain3), (void **)&chain3));
    ID3D12Resource *buffer = nullptr;
    OK(chain->GetBuffer(0, __uuidof(ID3D12Resource), (void **)&buffer));
    clear(queue, buffer, MTLClearColorMake(1, 1, 0, 1));
    buffer->Release();
    OK(chain->Present(1, 0));
    CHECK(wait(event, 1));
    CHECK(near(capture(window).at(0.5, 0.5), 1, 1, 0));
    OK(chain->SetMaximumFrameLatency(3));
    CHECK(wait(event, 1) && wait(event, 1));
    OK(chain->SetMaximumFrameLatency(3));
    OK(chain->SetMaximumFrameLatency(1));
    CHECK(!wait(event, 0.05));
    CHECK(chain->SetMaximumFrameLatency(17) == DXGI_ERROR_INVALID_CALL);

    const UINT index = chain3->GetCurrentBackBufferIndex();
    UINT presents = 0;
    OK(chain->GetLastPresentCount(&presents));
    ID3DMDeviceStatus *status = nullptr;
    OK(queue.device->QueryInterface(__uuidof(ID3DMDeviceStatus), (void **)&status));
    status->RecordError(DXGI_ERROR_DEVICE_REMOVED);
    status->Release();
    const HRESULT normal = chain->Present(0, 0), test = chain->Present(0, DXGI_PRESENT_TEST);
    const HRESULT normal1 = chain->Present1(0, 0, nullptr), test1 = chain->Present1(0, DXGI_PRESENT_TEST, nullptr);
    printf("dxgi_test: removed device Present=%#x Present(TEST)=%#x Present1=%#x Present1(TEST)=%#x\n",
           (unsigned)normal, (unsigned)test, (unsigned)normal1, (unsigned)test1);
    CHECK(normal == DXGI_ERROR_DEVICE_REMOVED && test == DXGI_ERROR_DEVICE_REMOVED);
    CHECK(normal1 == DXGI_ERROR_DEVICE_REMOVED && test1 == DXGI_ERROR_DEVICE_REMOVED);
    CHECK(chain3->GetCurrentBackBufferIndex() == index);
    UINT after = 0;
    OK(chain->GetLastPresentCount(&after));
    CHECK(after == presents);
    CHECK(!wait(event, 0.05));
    chain3->Release();
    CHECK(chain->Release() == 0);
    close_handle(event);
}

} // namespace

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
        [NSApp activateIgnoringOtherApps:YES];
        const D3DMHost hooks = {
            [](HWND window) -> void * { return (__bridge void *)((__bridge NSWindow *)(void *)window).contentView.layer; },
            nullptr, create_semaphore, release_semaphore, duplicate_handle, close_handle,
            [](HANDLE handle) { return wait(handle, 0); },
            [](HWND window) -> HMONITOR {
                NSWindow *native = (__bridge NSWindow *)(void *)window;
                return (HMONITOR)(uintptr_t)[native.screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
            },
            [](HWND window, WINBOOL fullscreen, HMONITOR monitor) -> HRESULT {
                NSWindow *native = (__bridge NSWindow *)(void *)window;
                static NSRect saved;
                static NSWindowStyleMask style;
                if (fullscreen) {
                    NSScreen *target = nil;
                    for (NSScreen *screen in NSScreen.screens)
                        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == (uintptr_t)monitor) target = screen;
                    if (!target) return DXGI_ERROR_NOT_FOUND;
                    saved = native.frame; style = native.styleMask;
                    native.styleMask = NSWindowStyleMaskBorderless;
                    [native setFrame:target.frame display:YES];
                } else {
                    native.styleMask = style;
                    [native setFrame:saved display:YES];
                }
                return S_OK;
            }};
        D3DMHost host = hooks;
        host.check_feature = [](D3D12_FEATURE feature, void *data, UINT size) -> HRESULT {
            if (feature != D3D12_FEATURE_FEATURE_LEVELS || !data || size != sizeof(D3D12_FEATURE_DATA_FEATURE_LEVELS)) return E_INVALIDARG;
            ((D3D12_FEATURE_DATA_FEATURE_LEVELS *)data)->MaxSupportedFeatureLevel = D3D_FEATURE_LEVEL_12_0;
            return S_OK;
        };
        D3DMSetHost(&host);

        IDXGIFactory4 *factory = nullptr;
        OK(D3DMCreateDXGIFactory2(0, __uuidof(IDXGIFactory4), (void **)&factory));
        check_queries(factory);
        ID3D12Device *device = nullptr;
        OK(D3DMCreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, __uuidof(ID3D12Device), (void **)&device));
        {
            Queue queue(MTLCreateSystemDefaultDevice(), device);
            NSWindow *window = open_window(NSMakeRect(200, 200, 320, 240));
            check_presents(factory, queue, window);
            check_pacing(factory, queue, window, host);
            [window close];
            NSWindow *second = open_window(NSMakeRect(260, 260, 240, 160));
            check_waitable(factory, queue, second);
            [second close];
            CHECK(queue.refs == 1);
        }
        CHECK(device->Release() == 0);
        CHECK(factory->Release() == 0);
        printf("dxgi_test: %d checks passed\n", checks);
    }
    return 0;
}
