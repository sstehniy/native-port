#include "runtime.h"
#include "input.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <deque>
#include <map>
#include <mutex>
#include <vector>

namespace {
struct WinPoint { int32_t x, y; };
using Rect = DesktopRect;
struct Position {
    uint64_t hwnd, after;
    int32_t x, y, cx, cy;
    uint32_t flags, padding;
};
static_assert(sizeof(Position) == 40);
struct Message {
    uint64_t hwnd;
    uint32_t message, padding;
    uint64_t wparam, lparam;
    uint32_t time;
    WinPoint point;
    uint32_t padding2;
};
static_assert(sizeof(Message) == 48);
struct SentMessage { Message value; Position position; std::vector<uint8_t> device = {}; };
using Guid = std::array<uint8_t, 16>;
struct DeviceRegistration { uint64_t window; Guid guid; bool all; };
const Guid gamepad_guids[] = {
    {0xe3, 0xf1, 0x87, 0xec, 0x3b, 0xc1, 0x00, 0x41, 0xb5, 0xf7, 0x8b, 0x84, 0xd5, 0x42, 0x60, 0xcb},
    {0xb2, 0x55, 0x1e, 0x4d, 0x6f, 0xf1, 0xcf, 0x11, 0x88, 0xcb, 0x00, 0x11, 0x11, 0x00, 0x00, 0x30},
};
std::map<uint64_t, DeviceRegistration> device_registrations;
uint64_t next_notification = 0x60001;
struct Translation { Message value; std::u16string text; };
struct Queue { std::mutex mutex; std::deque<Message> posted; std::deque<Translation> translations; std::deque<SentMessage> sent; };
bool same_message(const Message &a, const Message &b) {
    return a.hwnd == b.hwnd && a.message == b.message && a.wparam == b.wparam && a.lparam == b.lparam && a.time == b.time && a.point.x == b.point.x && a.point.y == b.point.y;
}
thread_local auto queue = std::make_shared<Queue>();
struct Class {
    uint64_t proc, instance, cursor;
    uint32_t style;
    int32_t extra;
    uint16_t atom;
    std::u16string name;
};
struct Window {
    uint64_t handle, proc, instance, owner, id, class_cursor, userdata = 0;
    uint32_t style, exstyle, class_style;
    std::vector<uint8_t> extra;
    NSWindow *__strong native;
    ::id __strong delegate;
    std::shared_ptr<Queue> queue;
    bool destroying = false, created = false, dirty = true, changing = false;
    double scale = 1;
    NSRect requested_frame = {};
    NSWindowStyleMask requested_style = NSWindowStyleMaskBorderless;
    bool fullscreen_transition = false, frame_pending = false, native_close_pending = false;
    bool dxgi_fullscreen = false;
    uint32_t dxgi_saved_style = 0;
    NSRect dxgi_saved_frame = {};
};
std::vector<Class> classes;
std::mutex windows_mutex;
std::map<uint64_t, std::shared_ptr<Window>> windows;
uint64_t next_handle = 0x50001;
uint16_t next_atom = 0xc001;
uint64_t fail(uint32_t error) { rt_set_last_error(error); return 0; }
bool main_thread() { if ([NSThread isMainThread]) return true; fail(1444); return false; }
std::shared_ptr<Window> find(uint64_t handle, bool closing = false) {
    std::lock_guard lock(windows_mutex);
    auto it = windows.find(handle);
    if (it == windows.end() || (it->second->native_close_pending && !closing)) { fail(1400); return {}; }
    return it->second;
}
uint64_t packed(int32_t x, int32_t y) { return (uint16_t)x | (uint32_t)(uint16_t)y << 16; }
WinPoint screen_point(NSPoint p) { const NSPoint d = rt_desktop_point(p); return {(int32_t)llround(d.x), (int32_t)llround(d.y)}; }
NSRect native_rect(Rect r) { return rt_native_rect(r); }
Rect guest_rect(NSRect r) { return rt_desktop_rect(r); }
Rect client_rect(const Window &w) {
    const NSSize size = w.native.contentView.bounds.size;
    return {0, 0, (int32_t)llround(size.width * w.scale), (int32_t)llround(size.height * w.scale)};
}
WinPoint client_origin(const Window &w) {
    NSRect r = [w.native convertRectToScreen:w.native.contentView.frame];
    return screen_point(NSMakePoint(NSMinX(r), NSMaxY(r)));
}
uint64_t invoke(const std::shared_ptr<Window> &w, uint32_t message, uint64_t wp = 0, uint64_t lp = 0) {
    const uint64_t args[] = {w->handle, message, wp, lp};
    return bbcpu_call_win64(w->proc, 4, args);
}
Message message(uint64_t hwnd, uint32_t msg, uint64_t wp, uint64_t lp) {
    return {hwnd, msg, 0, wp, lp, (uint32_t)llround(NSProcessInfo.processInfo.systemUptime * 1000), screen_point(NSEvent.mouseLocation), 0};
}
void enqueue(const std::shared_ptr<Window> &w, uint32_t msg, uint64_t wp = 0, uint64_t lp = 0, bool sent = true) {
    if (w->destroying) return;
    auto m = message(w->handle, msg, wp, lp);
    std::lock_guard lock(w->queue->mutex);
    if (sent) w->queue->sent.push_back({m, {}});
    else w->queue->posted.push_back(m);
}
void drain_sent() {
    for (;;) {
        SentMessage sent;
        {
            std::lock_guard lock(queue->mutex);
            if (queue->sent.empty()) break;
            sent = queue->sent.front(); queue->sent.pop_front();
        }
        const Message &m = sent.value;
        auto w = find(m.hwnd);
        if (w && !w->destroying) {
            if (m.message == 0x2e0) { Rect r = guest_rect(w->native.frame); invoke(w, m.message, m.wparam, (uintptr_t)&r); }
            else if (m.message == 0x47) invoke(w, m.message, 0, (uintptr_t)&sent.position);
            else if (!sent.device.empty()) invoke(w, m.message, m.wparam, (uintptr_t)sent.device.data());
            else invoke(w, m.message, m.wparam, m.lparam);
        }
    }
}
NSWindowStyleMask native_style(uint32_t style) {
    NSWindowStyleMask mask = NSWindowStyleMaskBorderless;
    if ((style & 0xc00000) == 0xc00000) mask |= NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
    if (style & 0x20000) mask |= NSWindowStyleMaskMiniaturizable;
    if (style & 0x40000) mask |= NSWindowStyleMaskResizable;
    return mask;
}
void update_layer(const std::shared_ptr<Window> &w) {
    CAMetalLayer *layer = (CAMetalLayer *)w->native.contentView.layer;
    layer.contentsScale = w->native.backingScaleFactor;
    layer.drawableSize = CGSizeMake(w->native.contentView.bounds.size.width * layer.contentsScale,
                                    w->native.contentView.bounds.size.height * layer.contentsScale);
}
/* A borderless window over a whole display is the game's borderless fullscreen; the menu bar and
 * Dock would otherwise draw over it. Known limit: the camera housing area is covered, not avoided. */
void update_presentation() {
    if (NSApp.presentationOptions & NSApplicationPresentationFullScreen) return;
    bool covering = false;
    {
        std::lock_guard lock(windows_mutex);
        for (auto &[handle, w] : windows) {
            if (w->destroying) continue;
            NSWindow *n = w->native;
            if (n.visible && !n.miniaturized && !(n.styleMask & NSWindowStyleMaskTitled) && n.screen && NSContainsRect(n.frame, n.screen.frame)) covering = true;
        }
    }
    const NSApplicationPresentationOptions options = covering ? NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar : NSApplicationPresentationDefault;
    if (NSApp.presentationOptions != options) NSApp.presentationOptions = options;
}
/* WS_EX_TOPMOST stays above other apps only while the game is active, like a Windows game losing focus. */
void update_level(const std::shared_ptr<Window> &w) {
    const bool fullscreen = w->fullscreen_transition || (w->native.styleMask & NSWindowStyleMaskFullScreen);
    const NSWindowLevel level = !fullscreen && (w->exstyle & 8) && NSApp.active ? NSFloatingWindowLevel : NSNormalWindowLevel;
    if (w->native.level != level) w->native.level = level;
}
void apply_frame(const std::shared_ptr<Window> &w) {
    w->changing = true;
    w->native.collectionBehavior = NSWindowCollectionBehaviorFullScreenNone;
    if (w->native.styleMask != w->requested_style) w->native.styleMask = w->requested_style;
    if (!NSEqualRects(w->native.frame, w->requested_frame)) [w->native setFrame:w->requested_frame display:YES];
    w->changing = false;
}
void update_fullscreen(const std::shared_ptr<Window> &w) {
    if (w->destroying) return;
    if (w->fullscreen_transition) { w->frame_pending = true; return; }
    bool covering = false;
    if (w->native.visible && !(w->requested_style & NSWindowStyleMaskTitled))
        for (NSScreen *screen in NSScreen.screens)
            if (NSContainsRect(w->requested_frame, screen.frame)) covering = true;
    const bool fullscreen = w->native.styleMask & NSWindowStyleMaskFullScreen;
    if (covering != fullscreen) {
        w->fullscreen_transition = true;
        if (covering) {
            apply_frame(w);
            w->native.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
            w->native.styleMask = w->requested_style | NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;
        }
        update_level(w);
        [w->native toggleFullScreen:nil];
    } else if (!fullscreen) apply_frame(w);
}
/* Each display's identity and desktop rectangle; removing or moving any display changes it. */
bool display_layout_changed() {
    static std::vector<std::array<int64_t, 5>> last;
    std::vector<std::array<int64_t, 5>> now;
    for (NSScreen *screen in NSScreen.screens) {
        const DesktopRect r = rt_desktop_rect(screen.frame);
        now.push_back({[screen.deviceDescription[@"NSScreenNumber"] longLongValue], r.left, r.top, r.right, r.bottom});
    }
    const bool changed = now != last;
    last = std::move(now);
    return changed;
}
void geometry(uint64_t handle, bool moved, bool resized) {
    auto w = find(handle);
    if (!w || w->destroying || w->changing) return;
    if (!w->fullscreen_transition && !(w->native.styleMask & NSWindowStyleMaskFullScreen)) w->requested_frame = w->native.frame;
    update_layer(w);
    if (resized) w->dirty = true;
    const Rect r = guest_rect(w->native.frame);
    const uint32_t flags = (moved ? 0 : 2) | (resized ? 0 : 1);
    const Position position = {handle, 0, r.left, r.top, r.right - r.left, r.bottom - r.top, flags, 0};
    // AppKit returns before guest dispatch; the queued record owns WINDOWPOS until the callback returns.
    std::lock_guard lock(w->queue->mutex);
    w->queue->sent.push_back({message(handle, 0x47, 0, 0), position});
}
void close_native(const std::shared_ptr<Window> &w) {
    w->native.delegate = nil;
    [w->native orderOut:nil];
    [w->native close];
    w->delegate = nil;
    w->native = nil;
    {
        std::lock_guard lock(windows_mutex);
        windows.erase(w->handle);
    }
    update_presentation();
}
void finish_fullscreen(uint64_t handle, bool failed = false) {
    // Run queued changes after AppKit finishes its fullscreen transition.
    dispatch_async(dispatch_get_main_queue(), ^{
        auto w = find(handle, true);
        if (!w) return;
        w->fullscreen_transition = false;
        if (w->native_close_pending) {
            if (!failed && (w->native.styleMask & NSWindowStyleMaskFullScreen)) {
                w->fullscreen_transition = true;
                [w->native toggleFullScreen:nil];
            } else close_native(w);
            return;
        }
        const bool pending = w->frame_pending;
        w->frame_pending = false;
        if (!(w->native.styleMask & NSWindowStyleMaskFullScreen)) apply_frame(w);
        if (pending && !failed) update_fullscreen(w);
        update_level(w);
        geometry(handle, true, true);
        update_presentation();
    });
}
}

@interface SSWindow : NSWindow
@end
@implementation SSWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)setStyleMask:(NSWindowStyleMask)style {
    // AppKit can replace the first responder when switching to a borderless window.
    NSResponder *responder = self.firstResponder;
    [super setStyleMask:style];
    if (responder) [self makeFirstResponder:responder];
}
@end

@interface SSWindowDelegate : NSObject <NSWindowDelegate>
@property uint64_t handle;
@end
@implementation SSWindowDelegate
- (void)windowWillEnterFullScreen:(NSNotification *)n { auto w = find(self.handle); if (w) w->fullscreen_transition = true; }
- (void)windowWillExitFullScreen:(NSNotification *)n { auto w = find(self.handle); if (w) w->fullscreen_transition = true; }
- (void)windowDidEnterFullScreen:(NSNotification *)n { finish_fullscreen(self.handle); }
- (void)windowDidExitFullScreen:(NSNotification *)n { finish_fullscreen(self.handle); }
- (void)windowDidFailToEnterFullScreen:(NSWindow *)window { finish_fullscreen(self.handle, true); }
- (void)windowDidFailToExitFullScreen:(NSWindow *)window { finish_fullscreen(self.handle, true); }
- (BOOL)windowShouldClose:(NSWindow *)sender {
    auto w = find(self.handle);
    if (w) enqueue(w, 0x10);
    return NO;
}
- (void)windowDidResize:(NSNotification *)n { geometry(self.handle, false, true); update_presentation(); }
- (void)windowWillStartLiveResize:(NSNotification *)n { auto w = find(self.handle); if (w) enqueue(w, 0x231); }
- (void)windowDidEndLiveResize:(NSNotification *)n { auto w = find(self.handle); if (w) enqueue(w, 0x232); }
- (void)windowDidMove:(NSNotification *)n { geometry(self.handle, true, false); }
- (void)windowDidMiniaturize:(NSNotification *)n { geometry(self.handle, false, true); }
- (void)windowDidDeminiaturize:(NSNotification *)n { geometry(self.handle, false, true); }
- (void)windowDidBecomeKey:(NSNotification *)n {
    auto w = find(self.handle);
    if (w) { rt_input_focus(self.handle, true); enqueue(w, 6, 1); enqueue(w, 7); }
}
- (void)windowDidResignKey:(NSNotification *)n {
    auto w = find(self.handle);
    if (w) { rt_input_focus(self.handle, false); enqueue(w, 8); enqueue(w, 6); }
}
- (void)windowDidChangeBackingProperties:(NSNotification *)n {
    auto w = find(self.handle);
    if (!w || w->destroying) return;
    const double previous = [n.userInfo[NSBackingPropertyOldScaleFactorKey] doubleValue] ?: w->scale;
    w->scale = w->native.backingScaleFactor;
    update_layer(w);
    if (previous != w->scale) enqueue(w, 0x2e0, packed((int32_t)llround(96 * w->scale), (int32_t)llround(96 * w->scale)));
}
@end

@interface SSView : NSView
@property uint64_t handle;
@end
@implementation SSView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (CALayer *)makeBackingLayer {
    CAMetalLayer *layer = [CAMetalLayer layer];
    if ([NSBundle.mainBundle.infoDictionary[@"SSFPSOverlayToggle"] boolValue]) layer.developerHUDProperties = @{@"mode": @"disabled"};
    return layer;
}
- (void)updateTrackingAreas {
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
    [super updateTrackingAreas];
}
- (void)mouse:(NSEvent *)event {
    auto w = find(self.handle);
    if (w && !w->destroying) rt_input_mouse(self.handle, self, event, w->class_style);
}
- (void)mouseMoved:(NSEvent *)e { [self mouse:e]; }
- (void)mouseDragged:(NSEvent *)e { [self mouse:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self mouse:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self mouse:e]; }
- (void)mouseDown:(NSEvent *)e { [self mouse:e]; }
- (void)mouseUp:(NSEvent *)e { [self mouse:e]; }
- (void)rightMouseDown:(NSEvent *)e { [self mouse:e]; }
- (void)rightMouseUp:(NSEvent *)e { [self mouse:e]; }
- (void)otherMouseDown:(NSEvent *)e { [self mouse:e]; }
- (void)otherMouseUp:(NSEvent *)e { [self mouse:e]; }
- (void)scrollWheel:(NSEvent *)e { rt_input_scroll(self.handle, self, e); }
- (void)keyDown:(NSEvent *)e { rt_input_key(self.handle, e, true); }
- (void)keyUp:(NSEvent *)e { rt_input_key(self.handle, e, false); }
- (void)flagsChanged:(NSEvent *)e { rt_input_flags(self.handle, e); }

@end

@interface SSApplicationDelegate : NSObject <NSApplicationDelegate>
@end
@implementation SSApplicationDelegate
- (void)active:(BOOL)active {
    std::vector<std::shared_ptr<Window>> snapshot;
    { std::lock_guard lock(windows_mutex); for (auto &[handle, w] : windows) if (!w->destroying) snapshot.push_back(w); }
    for (auto &w : snapshot) { update_level(w); if (!active || w->native.keyWindow) rt_input_focus(w->handle, active); enqueue(w, 0x1c, active); }
}
- (void)applicationDidBecomeActive:(NSNotification *)n { [self active:YES]; }
- (void)applicationDidResignActive:(NSNotification *)n { [self active:NO]; }
- (void)applicationDidChangeScreenParameters:(NSNotification *)n {
    // Menu bar and Dock changes also arrive here; Windows reports only resolution and layout changes.
    if (!display_layout_changed()) return;
    const DesktopRect primary = rt_desktop_rect(NSScreen.screens.firstObject.frame);
    std::lock_guard lock(windows_mutex);
    for (auto &[handle, w] : windows) enqueue(w, 0x7e, 32, packed(primary.right - primary.left, primary.bottom - primary.top));
}
- (void)requestQuit:(id)sender {
    std::lock_guard lock(windows_mutex);
    for (auto &[handle, w] : windows) enqueue(w, 0x10);
}
- (void)toggleFPS:(NSMenuItem *)sender {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    if (![window.contentView.layer isKindOfClass:CAMetalLayer.class]) return;
    CAMetalLayer *layer = (CAMetalLayer *)window.contentView.layer;
    NSMutableDictionary *properties = [layer.developerHUDProperties mutableCopy] ?: [NSMutableDictionary new];
    const bool visible = [properties[@"mode"] isEqual:@"default"];
    properties[@"mode"] = visible ? @"disabled" : @"default";
    layer.developerHUDProperties = properties;
    sender.state = visible ? NSControlStateValueOff : NSControlStateValueOn;
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    [self requestQuit:nil];
    return NSTerminateCancel;
}
@end

namespace {
void initialize() {
    static SSApplicationDelegate *delegate;
    if (delegate) return;
    [NSApplication sharedApplication];
    delegate = [SSApplicationDelegate new];
    NSApp.delegate = delegate;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSMenu *menu = [NSMenu new];
    NSMenuItem *application = [NSMenuItem new];
    NSMenu *applicationMenu = [NSMenu new];
    NSMenuItem *fps = [[NSMenuItem alloc] initWithTitle:@"FPS Overlay" action:@selector(toggleFPS:) keyEquivalent:@"F"];
    fps.target = delegate;
    [applicationMenu addItem:fps];
    [applicationMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Order of the Sinking Star" action:@selector(requestQuit:) keyEquivalent:@"q"];
    quit.target = delegate;
    [applicationMenu addItem:quit]; application.submenu = applicationMenu;
    [menu addItem:application]; NSApp.mainMenu = menu;
    [NSApp finishLaunching];
    display_layout_changed();
}
bool destroy(const std::shared_ptr<Window> &w) {
    if (w->destroying) return true;
    w->destroying = true;
    rt_input_destroy(w->handle);
    if (w->created) invoke(w, 2);
    invoke(w, 0x82);
    {
        std::lock_guard lock(w->queue->mutex);
        auto matches = [w](const Message &m) { return m.hwnd == w->handle; };
        std::erase_if(w->queue->posted, matches);
        std::erase_if(w->queue->sent, [&](const SentMessage &m) { return matches(m.value); });
        std::erase_if(w->queue->translations, [&](const Translation &m) { return matches(m.value); });
    }
    {
        std::lock_guard lock(windows_mutex);
        std::erase_if(device_registrations, [&](const auto &entry) { return entry.second.window == w->handle; });
    }
    if (w->fullscreen_transition || (w->native.styleMask & NSWindowStyleMaskFullScreen)) {
        w->native_close_pending = true;
        if (!w->fullscreen_transition) finish_fullscreen(w->handle);
    } else close_native(w);
    update_presentation();
    return true;
}
H(AdjustWindowRect) {
    if (!main_thread() || !P(0)) return fail(87);
    if (A(2)) return fail(50);
    initialize();
    Rect r; memcpy(&r, P(0), sizeof r);
    rt_put(P(0), guest_rect([NSWindow frameRectForContentRect:native_rect(r) styleMask:native_style((uint32_t)A(1))]));
    return 1;
}
H(RegisterClassExW) {
    if (!main_thread()) return 0;
    const uint8_t *p = P(0);
    if (!p || *(const uint32_t *)p != 80) return fail(87);
    Class cls = {};
    memcpy(&cls.proc, p + 8, 8); memcpy(&cls.instance, p + 24, 8); memcpy(&cls.style, p + 4, 4); memcpy(&cls.extra, p + 20, 4);
    memcpy(&cls.cursor, p + 40, 8);
    uint64_t name; memcpy(&name, p + 64, 8);
    if (!name || name <= 0xffff || !cls.proc || cls.extra < 0 || cls.extra > 4096) return fail(87);
    cls.name = (const char16_t *)name;
    for (auto &existing : classes) if (existing.name == cls.name && existing.instance == cls.instance) return fail(1410);
    cls.atom = next_atom++;
    classes.push_back(cls);
    printf("runtime: window class %s, procedure %#llx\n", rt_utf8(cls.name).c_str(), (unsigned long long)cls.proc);
    return cls.atom;
}
H(CreateWindowExW) {
    if (!main_thread()) return 0;
    const Class *cls = nullptr;
    for (auto &candidate : classes) if ((A(1) <= 0xffff ? candidate.atom == A(1) : candidate.name == (const char16_t *)P(1)) && (!A(10) || candidate.instance == A(10))) { cls = &candidate; break; }
    if (!cls) return fail(1407);
    if (A(3) & 0x40000000) return fail(50); // Child controls belong to a broader USER32 implementation.
    initialize();
    int32_t x = (int32_t)A(4), y = (int32_t)A(5), width = (int32_t)A(6), height = (int32_t)A(7);
    if (x == INT32_MIN) x = 80;
    if (y == INT32_MIN) y = 80;
    if (width == INT32_MIN) width = 960;
    if (height == INT32_MIN) height = 640;
    if (width <= 0 || height <= 0 || (int64_t)x + width > INT32_MAX || (int64_t)y + height > INT32_MAX) return fail(87);
    auto w = std::make_shared<Window>();
    w->handle = next_handle++; w->proc = cls->proc; w->instance = A(10); w->owner = A(8); w->id = A(9);
    w->style = (uint32_t)A(3); w->exstyle = (uint32_t)A(0); w->class_style = cls->style; w->class_cursor = cls->cursor; w->extra.resize(cls->extra); w->queue = queue;
    NSRect frame = native_rect({x, y, x + width, y + height});
    NSWindowStyleMask style = native_style(w->style);
    w->requested_frame = frame; w->requested_style = style;
    w->native = [[SSWindow alloc] initWithContentRect:[NSWindow contentRectForFrameRect:frame styleMask:style] styleMask:style backing:NSBackingStoreBuffered defer:NO];
    if (!w->native) return fail(8);
    w->native.releasedWhenClosed = NO;
    w->native.title = [NSString stringWithUTF8String:rt_utf8(P(2)).c_str()] ?: @"";
    w->native.acceptsMouseMovedEvents = YES;
    // The green title-bar button maximizes, as on Windows; the game has its own fullscreen mode.
    w->native.collectionBehavior = NSWindowCollectionBehaviorFullScreenNone;
    w->scale = w->native.backingScaleFactor;
    SSView *view = [[SSView alloc] initWithFrame:NSMakeRect(0, 0, w->native.contentView.bounds.size.width, w->native.contentView.bounds.size.height)];
    view.handle = w->handle; view.wantsLayer = YES;
    w->native.contentView = view;
    [w->native makeFirstResponder:view];
    SSWindowDelegate *delegate = [SSWindowDelegate new]; delegate.handle = w->handle;
    w->delegate = delegate; w->native.delegate = delegate;
    update_layer(w);
    update_level(w);
    { std::lock_guard lock(windows_mutex); windows.emplace(w->handle, w); }
    const struct Create {
        uint64_t param, instance, menu, parent;
        int32_t cy, cx, y, x;
        uint32_t style, padding;
        uint64_t name, cls;
        uint32_t exstyle, padding2;
    } create = {A(11), A(10), A(9), A(8), height, width, y, x, w->style, 0, A(2), A(1), w->exstyle, 0};
    static_assert(sizeof(Create) == 80);
    if (!invoke(w, 0x81, 0, (uintptr_t)&create)) { destroy(w); return 0; }
    if (!find(w->handle)) return 0;
    w->created = true;
    if (invoke(w, 1, 0, (uintptr_t)&create) == UINT64_MAX) { if (find(w->handle)) destroy(w); return 0; }
    if (!find(w->handle)) return 0;
    printf("runtime: CreateWindowExW(native NSWindow, title \"%s\", %d x %d, CAMetalLayer)\n", rt_utf8(P(2)).c_str(), width, height);
    if (w->style & 0x10000000) [w->native makeKeyAndOrderFront:nil];
    update_fullscreen(w);
    geometry(w->handle, true, true);
    update_presentation();
    drain_sent();
    return w->destroying ? 0 : w->handle;
}
H(DestroyWindow) { if (!main_thread()) return 0; auto w = find(A(0)); return w && destroy(w); }
H(CallWindowProcW) { const uint64_t args[] = {A(1), (uint32_t)A(2), A(3), A(4)}; return bbcpu_call_win64(A(0), 4, args); }
H(DefWindowProcW) {
    if (!main_thread()) return 0;
    auto w = find(A(0)); if (!w) return 0;
    if (A(1) == 0x47) {
        if (!P(3)) return fail(87);
        if (w->destroying) return 0;
        Position pos; memcpy(&pos, P(3), sizeof pos);
        if (!(pos.flags & 2)) {
            const WinPoint p = client_origin(*w);
            invoke(w, 3, 0, packed(p.x, p.y));
            if (w->destroying) return 0;
        }
        if (!(pos.flags & 1)) {
            const Rect size = client_rect(*w);
            uint64_t state = 0;
            if (w->native.miniaturized) state = 1;
            // AppKit also calls a borderless window over the whole display zoomed; the game's fullscreen is not maximized.
            else if (!w->fullscreen_transition && !(w->native.styleMask & NSWindowStyleMaskFullScreen) &&
                     (w->native.styleMask & NSWindowStyleMaskResizable) && w->native.zoomed) state = 2;
            invoke(w, 5, state, packed(size.right, size.bottom));
        }
        return 0;
    }
    if (A(1) == 0xff) { rt_input_cleanup(A(3)); return 0; }
    if (A(1) == 0x20) {
        if ((uint16_t)A(3) != 1) { rt_input_set_cursor(0x20000 + 32512); return 1; }
        if (!w->class_cursor) return 0;
        rt_input_set_cursor(w->class_cursor); return 1;
    }
    if (A(1) == 0x81) return 1;
    if (A(1) == 0x10) { destroy(w); return 0; }
    if (A(1) == 0xf) w->dirty = false;
    if (A(1) == 0xc) { w->native.title = [NSString stringWithUTF8String:rt_utf8(P(3)).c_str()] ?: @""; return 1; }
    return 0;
}
H(ShowWindow) {
    if (!main_thread()) return 0;
    auto w = find(A(0)); if (!w) return 0;
    const bool previous = w->native.visible;
    if (!A(1)) { w->style &= ~0x10000000u; [w->native orderOut:nil]; }
    else {
        w->style |= 0x10000000;
        if (A(1) == 2 || A(1) == 6 || A(1) == 7) [w->native miniaturize:nil];
        else {
            if (w->native.miniaturized) [w->native deminiaturize:nil];
            // SW_MAXIMIZE zooms; SW_SHOWNORMAL and SW_RESTORE return a zoomed window to its normal frame.
            if (!w->fullscreen_transition && !(w->native.styleMask & NSWindowStyleMaskFullScreen) &&
                (A(1) == 3) != w->native.zoomed && (A(1) == 1 || A(1) == 3 || A(1) == 9)) [w->native zoom:nil];
            if (A(1) == 4 || A(1) == 8) [w->native orderFront:nil];
            else { [w->native makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
        }
    }
    if (!w->fullscreen_transition && !(w->native.styleMask & NSWindowStyleMaskFullScreen)) w->requested_frame = w->native.frame;
    update_fullscreen(w);
    update_presentation();
    invoke(w, 0x18, A(1) != 0);
    drain_sent();
    return previous;
}
H(SetWindowTextW) {
    if (!main_thread()) return 0;
    auto w = find(A(0)); if (!w) return 0;
    return invoke(w, 0xc, 0, A(1));
}
H(GetWindowRect) { if (!main_thread()) return 0; auto w = find(A(0)); if (!w) return 0; if (!P(1)) return fail(87); rt_put(P(1), guest_rect(w->native.frame)); return 1; }
H(GetClientRect) { if (!main_thread()) return 0; auto w = find(A(0)); if (!w) return 0; if (!P(1)) return fail(87); rt_put(P(1), client_rect(*w)); return 1; }
H(ClientToScreen) {
    if (!main_thread()) return 0;
    auto w = find(A(0)); if (!w) return 0; if (!P(1)) return fail(87);
    WinPoint p; memcpy(&p, P(1), sizeof p); const WinPoint origin = client_origin(*w);
    const double s = rt_desktop_scale(w->native.frame) / w->scale;
    p.x = origin.x + (int32_t)llround(p.x * s); p.y = origin.y + (int32_t)llround(p.y * s);
    rt_put(P(1), p); return 1;
}
H(ScreenToClient) {
    if (!main_thread()) return 0;
    auto w = find(A(0)); if (!w) return 0; if (!P(1)) return fail(87);
    WinPoint p; memcpy(&p, P(1), sizeof p); const WinPoint origin = client_origin(*w);
    const double s = w->scale / rt_desktop_scale(w->native.frame);
    p.x = (int32_t)llround((p.x - origin.x) * s); p.y = (int32_t)llround((p.y - origin.y) * s);
    rt_put(P(1), p); return 1;
}
H(SetWindowPos) {
    if (!main_thread()) return 0;
    auto w = find(A(0)); if (!w) return 0;
    Position pos = {A(0), A(1), (int32_t)A(2), (int32_t)A(3), (int32_t)A(4), (int32_t)A(5), (uint32_t)A(6), 0};
    if (!(pos.flags & 0x400)) invoke(w, 0x46, 0, (uintptr_t)&pos);
    if (!find(w->handle)) return 0;
    Rect r = guest_rect(w->fullscreen_transition ? w->requested_frame : w->native.frame);
    int32_t width = r.right - r.left, height = r.bottom - r.top;
    if (!(pos.flags & 1)) { width = std::max(1, pos.cx); height = std::max(1, pos.cy); }
    if (!(pos.flags & 2)) { r.left = pos.x; r.top = pos.y; }
    if ((int64_t)r.left + width > INT32_MAX || (int64_t)r.top + height > INT32_MAX) return fail(87);
    r.right = r.left + width; r.bottom = r.top + height;
    w->requested_frame = native_rect(r);
    if (pos.flags & 0x20) w->requested_style = native_style(w->style);
    if (pos.flags & 0x80) { w->style &= ~0x10000000u; [w->native orderOut:nil]; }
    if (pos.flags & 0x40) { w->style |= 0x10000000; [w->native orderFront:nil]; }
    if (!(pos.flags & 4) && w->native.visible) {
        if (pos.after == UINT64_MAX) { w->exstyle |= 8; update_level(w); }
        else if (pos.after == UINT64_MAX - 1) { w->exstyle &= ~8u; update_level(w); }
        else if (pos.after == 1) [w->native orderBack:nil];
        else if (!pos.after) [w->native orderFront:nil];
        else { auto after = find(pos.after); if (after) [w->native orderWindow:NSWindowBelow relativeTo:after->native.windowNumber]; }
    }
    if (!(pos.flags & 0x10) && w->native.visible) [w->native makeKeyWindow];
    update_fullscreen(w);
    update_layer(w);
    update_presentation();
    if (!(pos.flags & 1)) w->dirty = true;
    invoke(w, 0x47, 0, (uintptr_t)&pos);
    drain_sent();
    return 1;
}
uint64_t window_long(WinCall *c, bool set, size_t size) {
    if (!main_thread()) return 0;
    auto w = find(A(0)); if (!w) return 0;
    const int32_t index = (int32_t)A(1);
    uint64_t *slot = nullptr;
    if (index == -4) slot = &w->proc;
    else if (index == -21) slot = &w->userdata;
    else if (index == -6) slot = &w->instance;
    else if (index == -12) slot = &w->id;
    else if (index == -8) slot = &w->owner;
    if (slot) { uint64_t old = *slot; if (set) *slot = size == 4 ? (uint32_t)A(2) : A(2); return size == 4 ? (uint32_t)old : old; }
    uint8_t *data = nullptr;
    if (index == -16) { data = (uint8_t *)&w->style; size = 4; }
    else if (index == -20) { data = (uint8_t *)&w->exstyle; size = 4; }
    else if (index >= 0 && (size_t)index + size <= w->extra.size()) data = w->extra.data() + index;
    if (!data) return fail(1413);
    uint64_t old = 0; memcpy(&old, data, size);
    if (set) { uint64_t value = A(2); memcpy(data, &value, size); }
    return old;
}
H(GetWindowLongW) { return window_long(c, false, 4); }
H(GetWindowLongPtrW) { return window_long(c, false, 8); }
H(SetWindowLongW) { return window_long(c, true, 4); }
H(SetWindowLongPtrW) { return window_long(c, true, 8); }
H(GetActiveWindow) {
    if (!main_thread() || !NSApp) return 0;
    std::lock_guard lock(windows_mutex);
    for (auto &[handle, w] : windows) if (!w->destroying && w->native.keyWindow) return handle;
    return 0;
}
H(WindowFromPoint) {
    if (!main_thread() || !NSApp) return 0;
    WinPoint p; uint64_t packed_point = A(0); memcpy(&p, &packed_point, sizeof p);
    for (NSWindow *native in NSApp.orderedWindows) {
        Rect r = guest_rect(native.frame);
        if (p.x < r.left || p.x >= r.right || p.y < r.top || p.y >= r.bottom) continue;
        std::lock_guard lock(windows_mutex);
        for (auto &[handle, w] : windows) if (!w->destroying && w->native == native) return handle;
    }
    return 0;
}
H(ValidateRect) { if (!main_thread()) return 0; auto w = find(A(0)); if (!w) return 0; w->dirty = false; return 1; }
H(UpdateWindow) { if (!main_thread()) return 0; auto w = find(A(0)); if (!w) return 0; if (w->dirty) invoke(w, 0xf); return 1; }
H(PostMessageW) {
    Message m = {A(0), (uint32_t)A(1), 0, A(2), A(3), 0, {}, 0};
    auto target = queue;
    if (A(0)) { auto w = find(A(0)); if (!w) return 0; target = w->queue; }
    std::lock_guard lock(target->mutex); target->posted.push_back(m); return 1;
}
H(PostQuitMessage) {
    Message m = {0, 0x12, 0, (uint32_t)A(0), 0, 0, {}, 0};
    std::lock_guard lock(queue->mutex); queue->posted.push_back(m); return 0;
}
H(PeekMessageW) {
    if (!P(0)) return fail(87);
    rt_window_pump_native();
    if ([NSThread isMainThread]) rt_gamepad_pump();
    drain_sent();
    const uint64_t hwnd = A(1);
    const uint32_t first = (uint16_t)A(2), last = (uint16_t)A(3);
    auto matches = [=](const Message &m) {
        if (m.message == 0x12) return true;
        if (hwnd == UINT64_MAX ? m.hwnd != 0 : (hwnd && m.hwnd != hwnd)) return false;
        return (!first && !last) || (m.message >= first && m.message <= last);
    };
    {
        std::lock_guard lock(queue->mutex);
        auto it = std::find_if(queue->posted.begin(), queue->posted.end(), matches);
        if (it != queue->posted.end()) {
            rt_put(P(0), *it);
            if (A(4) & 1) queue->posted.erase(it);
            return 1;
        }
    }
    if ([NSThread isMainThread]) {
        std::lock_guard lock(windows_mutex);
        for (auto &[handle, w] : windows) if (w->queue == queue && w->dirty && !w->destroying) {
            auto m = message(handle, 0xf, 0, 0);
            if (matches(m)) { rt_put(P(0), m); return 1; }
        }
    }
    return 0;
}
H(TranslateMessage) {
    if (!P(0)) return fail(87);
    Message m; memcpy(&m, P(0), sizeof m);
    if (m.message != 0x100 && m.message != 0x101 && m.message != 0x104 && m.message != 0x105) return 0;
    std::lock_guard lock(queue->mutex);
    const auto translation = std::find_if(queue->translations.begin(), queue->translations.end(), [&](const Translation &saved) { return same_message(m, saved.value); });
    if ((m.message == 0x100 || m.message == 0x104) && translation != queue->translations.end()) {
        m.message += 2;
        for (char16_t ch : translation->text) { m.wparam = ch; queue->posted.push_back(m); }
    }
    return 1;
}
H(DispatchMessageW) {
    if (!P(0)) return fail(87);
    Message m; memcpy(&m, P(0), sizeof m);
    if (!m.hwnd) return 0;
    {
        std::lock_guard lock(queue->mutex);
        std::erase_if(queue->translations, [&](const Translation &saved) { return same_message(m, saved.value); });
    }
    if (!main_thread()) return 0;
    auto w = find(m.hwnd); if (!w) return 0;
    if (m.message == 0x2e0 && !m.lparam) { Rect r = guest_rect(w->native.frame); return invoke(w, m.message, m.wparam, (uintptr_t)&r); }
    const uint64_t result = invoke(w, m.message, m.wparam, m.lparam);
    if (m.message == 0xff) rt_input_cleanup(m.lparam);
    return result;
}
H(RegisterDeviceNotificationW) {
    const uint32_t flags = (uint32_t)A(2);
    if (flags & ~4u) return fail(50);
    if (!P(1)) return fail(87);
    uint32_t header[3]; memcpy(header, P(1), sizeof header);
    if (header[0] < 32 || header[1] != 5) return fail(87);
    Guid guid; memcpy(guid.data(), (const uint8_t *)(uintptr_t)A(1) + 12, guid.size());
    std::lock_guard lock(windows_mutex);
    auto window = windows.find(A(0));
    if (window == windows.end() || window->second->native_close_pending) return fail(1400);
    const uint64_t handle = next_notification++;
    device_registrations.emplace(handle, DeviceRegistration{A(0), guid, (flags & 4) != 0});
    return handle;
}
H(UnregisterDeviceNotification) {
    std::lock_guard lock(windows_mutex);
    return device_registrations.erase(A(0)) ? 1 : fail(6);
}
}

bool rt_window_pump_native() {
    if (![NSThread isMainThread] || !NSApp) return false;
    // Native callbacks only queue guest messages; guest dispatch stays outside this pool.
    @autoreleasepool {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,0,true);
        for (unsigned i=0;i<256;++i) {
            NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES];
            if (!event) break;
            if (!rt_input_route(event)) [NSApp sendEvent:event];
        }
        [NSApp updateWindows];rt_input_update_cursor();
    }
    return true;
}

void rt_window_device_change(uint64_t identity, bool connected) {
    if (!main_thread()) return;
    const char *guid_names[] = {"ec87f1e3-c13b-4100-b5f7-8b84d54260cb", "4d1e55b2-f16f-11cf-88cb-001111000030"};
    std::lock_guard lock(windows_mutex);
    for (const auto &[handle, w] : windows) {
        if (w->destroying) continue;
        if (!(w->style & 0x40000000)) enqueue(w, 0x219, 7); // DBT_DEVNODES_CHANGED is not registration-dependent.
        for (size_t i = 0; i < std::size(gamepad_guids); ++i) {
            const bool registered = std::any_of(device_registrations.begin(), device_registrations.end(), [&](const auto &entry) {
                const auto &reg = entry.second;
                return reg.window == handle && (reg.all || reg.guid == gamepad_guids[i]);
            });
            if (!registered) continue;
            const std::u16string name = rt_utf16("\\\\?\\SS_GAMEPAD#" + std::to_string(identity) + "#{" + guid_names[i] + "}");
            std::vector<uint8_t> data(28 + (name.size() + 1) * 2);
            rt_put<uint32_t>(data.data(), (uint32_t)data.size());
            rt_put<uint32_t>(data.data() + 4, 5);
            memcpy(data.data() + 12, gamepad_guids[i].data(), 16);
            memcpy(data.data() + 28, name.c_str(), (name.size() + 1) * 2);
            std::lock_guard queue_lock(w->queue->mutex);
            w->queue->sent.push_back({message(handle, 0x219, connected ? 0x8000 : 0x8004, 0), {}, std::move(data)});
        }
    }
}

NSWindow *rt_window_native(uint64_t handle) {
    if (!main_thread()) return nil;
    auto w = find(handle);
    return w && !w->destroying ? w->native : nil;
}
bool rt_window_fullscreen(uint64_t handle, bool fullscreen, uint32_t display) {
    if (!main_thread()) return false;
    auto w = find(handle);
    if (!w || w->destroying) return false;
    NSScreen *target = nil;
    if (fullscreen) {
        for (NSScreen *screen in NSScreen.screens)
            if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == display) target = screen;
        if (!target) return false;
        if (!w->dxgi_fullscreen) {
            w->dxgi_saved_style = w->style;
            w->dxgi_saved_frame = w->requested_frame;
        }
    } else if (!w->dxgi_fullscreen) return true;
    if (fullscreen) {
        w->style &= ~0x00c40000u;
        w->requested_frame = target.frame;
    } else {
        w->style = w->dxgi_saved_style;
        w->requested_frame = w->dxgi_saved_frame;
    }
    w->requested_style = native_style(w->style);
    w->dxgi_fullscreen = fullscreen;
    update_fullscreen(w);
    geometry(handle, true, true);
    update_presentation();
    return true;
}
void rt_window_input(uint64_t handle, uint32_t msg, uint64_t wp, uint64_t lp, std::u16string_view text, uint32_t time, bool sent) {
    auto w = find(handle);
    if (!w || w->destroying) { if (msg == 0xff) rt_input_cleanup(lp); return; }
    Message m = message(handle, msg, wp, lp);
    if (time) m.time = time;
    std::lock_guard lock(w->queue->mutex);
    if (!text.empty()) {
        // Bound native text history even when the guest discards key messages without dispatching them.
        if (w->queue->translations.size() == 10000) w->queue->translations.pop_front();
        w->queue->translations.push_back({m, std::u16string(text)});
    }
    if (sent) w->queue->sent.push_back({m, {}});
    else w->queue->posted.push_back(m);
}
uint64_t rt_window_send(uint64_t handle, uint32_t msg, uint64_t wp, uint64_t lp) {
    auto w = find(handle);
    return w && !w->destroying ? invoke(w, msg, wp, lp) : 0;
}

#define E(name) {#name, name}
const RtEntry rt_window_entries[] = {
    E(AdjustWindowRect), E(RegisterClassExW), E(CreateWindowExW), E(DestroyWindow), E(CallWindowProcW), E(DefWindowProcW),
    E(ShowWindow), E(SetWindowTextW), E(GetWindowRect), E(GetClientRect), E(ClientToScreen), E(ScreenToClient), E(SetWindowPos),
    E(GetWindowLongW), E(GetWindowLongPtrW), E(SetWindowLongW), E(SetWindowLongPtrW), E(GetActiveWindow), E(WindowFromPoint),
    E(ValidateRect), E(UpdateWindow), E(PostMessageW), E(PostQuitMessage), E(PeekMessageW), E(TranslateMessage), E(DispatchMessageW),
    E(RegisterDeviceNotificationW), E(UnregisterDeviceNotification), {nullptr, nullptr}
};
