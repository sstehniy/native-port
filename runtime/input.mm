#include "runtime.h"
#include "input.h"
#import <IOKit/hidsystem/IOLLEvent.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <deque>
#include <map>
#include <mutex>
#include <optional>

namespace {
struct InputPoint { int32_t x, y; };
using Rect = DesktopRect;
struct Registration { uint16_t page, usage; uint32_t flags; uint64_t target; };
struct RawHeader { uint32_t type, size; uint64_t device, wp; };
struct RawKey { uint16_t scan, flags, reserved, vk; uint32_t message, extra; };
struct RawMouse { uint16_t flags, padding, buttons, data; uint32_t raw_buttons; int32_t x, y; uint32_t extra; };
struct MouseEvent {
    NSTimeInterval time;
    NSEventType type;
    NSInteger number;
    double x,y;
    uint32_t buttons;
    bool operator==(const MouseEvent &) const = default;
};
static_assert(sizeof(Registration) == 16 && sizeof(RawHeader) == 24 && sizeof(RawKey) == 16 && sizeof(RawMouse) == 24);
struct Packet { RawHeader header; std::array<uint8_t, 24> data; uint64_t target; };
struct Key { uint16_t vk, scan; };
// Set-1 scan codes retain physical key positions, while Latin virtual keys follow the native layout.
static constexpr Key keymap[128] = {
    {0x41, 0x1e}, {0x53, 0x1f}, {0x44, 0x20}, {0x46, 0x21}, {0x48, 0x23}, {0x47, 0x22}, {0x5a, 0x2c}, {0x58, 0x2d},
    {0x43, 0x2e}, {0x56, 0x2f}, {0xe2, 0x56}, {0x42, 0x30}, {0x51, 0x10}, {0x57, 0x11}, {0x45, 0x12}, {0x52, 0x13},
    {0x59, 0x15}, {0x54, 0x14}, {0x31, 0x2}, {0x32, 0x3}, {0x33, 0x4}, {0x34, 0x5}, {0x36, 0x7}, {0x35, 0x6},
    {0xbb, 0xd}, {0x39, 0xa}, {0x37, 0x8}, {0xbd, 0xc}, {0x38, 0x9}, {0x30, 0xb}, {0xdd, 0x1b}, {0x4f, 0x18},
    {0x55, 0x16}, {0xdb, 0x1a}, {0x49, 0x17}, {0x50, 0x19}, {0xd, 0x1c}, {0x4c, 0x26}, {0x4a, 0x24}, {0xde, 0x28},
    {0x4b, 0x25}, {0xba, 0x27}, {0xdc, 0x2b}, {0xbc, 0x33}, {0xbf, 0x35}, {0x4e, 0x31}, {0x4d, 0x32}, {0xbe, 0x34},
    {0x9, 0xf}, {0x20, 0x39}, {0xc0, 0x29}, {0x8, 0xe}, {0x0, 0x0}, {0x1b, 0x1}, {0x5c, 0x15c}, {0x5b, 0x15b},
    {0xa0, 0x2a}, {0x14, 0x3a}, {0xa4, 0x38}, {0xa2, 0x1d}, {0xa1, 0x36}, {0xa5, 0x138}, {0xa3, 0x11d}, {0x0, 0x0},
    {0x80, 0x68}, {0x6e, 0x53}, {0x0, 0x0}, {0x6a, 0x37}, {0x0, 0x0}, {0x6b, 0x4e}, {0x0, 0x0}, {0x90, 0x45},
    {0x0, 0x0}, {0x0, 0x0}, {0x0, 0x0}, {0x6f, 0x135}, {0xd, 0x11c}, {0x0, 0x0}, {0x6d, 0x4a}, {0x81, 0x69},
    {0x82, 0x6a}, {0x92, 0x59}, {0x60, 0x52}, {0x61, 0x4f}, {0x62, 0x50}, {0x63, 0x51}, {0x64, 0x4b}, {0x65, 0x4c},
    {0x66, 0x4d}, {0x67, 0x47}, {0x83, 0x6b}, {0x68, 0x48}, {0x69, 0x49}, {0xdc, 0x7d}, {0xe2, 0x73}, {0x6c, 0x7e},
    {0x74, 0x3f}, {0x75, 0x40}, {0x76, 0x41}, {0x72, 0x3d}, {0x77, 0x42}, {0x78, 0x43}, {0xf0, 0x7b}, {0x7a, 0x57},
    {0xf2, 0x70}, {0x2c, 0x137}, {0x7f, 0x67}, {0x91, 0x46}, {0x0, 0x0}, {0x79, 0x44}, {0x0, 0x0}, {0x7b, 0x58},
    {0x0, 0x0}, {0x13, 0x245}, {0x2d, 0x152}, {0x24, 0x147}, {0x21, 0x149}, {0x2e, 0x153}, {0x73, 0x3e}, {0x23, 0x14f},
    {0x71, 0x3c}, {0x22, 0x151}, {0x70, 0x3b}, {0x25, 0x14b}, {0x27, 0x14d}, {0x28, 0x150}, {0x26, 0x148}, {0x0, 0x0},
};
std::mutex state_mutex;
std::array<uint8_t, 256> keys;
std::array<uint16_t, 128> pressed_vk;
std::array<Registration, 2> registrations;
std::map<uint64_t, Packet> packets;
uint64_t next_packet = 0x71000000, focus, capture;
std::optional<Rect> clip;
std::optional<InputPoint> warped_position;
std::optional<MouseEvent> last_mouse_event;
InputPoint warp_anchor{};
std::optional<bool> caps_state;
bool hidden;
int32_t show_count;
uint64_t cursor = 0x20000 + 32512;
double wheel_x, wheel_y, raw_x, raw_y;
uint64_t fail(uint32_t error, uint64_t result = 0) { rt_set_last_error(error); return result; }
bool main_thread() { if ([NSThread isMainThread]) return true; fail(1444); return false; }
InputPoint screen_point(NSPoint p) { const NSPoint d = rt_desktop_point(p); return {(int32_t)llround(d.x), (int32_t)llround(d.y)}; }
uint64_t packed(int32_t x, int32_t y) { return (uint16_t)x | (uint32_t)(uint16_t)y << 16; }
NSCursor *native_cursor(uint64_t handle) {
    switch (handle - 0x20000) {
    case 32512: case 32514: case 32650: case 32516: case 32651: return NSCursor.arrowCursor;
    case 32513: return NSCursor.IBeamCursor;
    case 32515: return NSCursor.crosshairCursor;
    case 32642: case 32643: case 32646: return NSCursor.closedHandCursor;
    case 32644: return NSCursor.resizeLeftRightCursor;
    case 32645: return NSCursor.resizeUpDownCursor;
    case 32648: return NSCursor.operationNotAllowedCursor;
    case 32649: return NSCursor.pointingHandCursor;
    default: return nil;
    }
}
void set_key(uint16_t vk, bool down) {
    if (!vk || vk >= keys.size()) return;
    const bool pressed = down && !(keys[vk] & 0x80);
    if (down) { if (pressed) keys[vk] |= 1; keys[vk] |= 0x80; }
    else keys[vk] &= ~0x80;
    for (const auto pair : {std::array<uint16_t, 3>{0xa0, 0xa1, 0x10}, {0xa2, 0xa3, 0x11}, {0xa4, 0xa5, 0x12}}) {
        if (vk != pair[0] && vk != pair[1]) continue;
        if ((keys[pair[0]] | keys[pair[1]]) & 0x80) keys[pair[2]] |= 0x80;
        else keys[pair[2]] &= ~0x80;
        if (pressed) keys[pair[2]] |= 1;
    }
}
struct Modifier { uint16_t code; uint32_t mask; };
static constexpr Modifier modifiers[] = {
    {54, NX_DEVICERCMDKEYMASK}, {55, NX_DEVICELCMDKEYMASK},
    {56, NX_DEVICELSHIFTKEYMASK}, {60, NX_DEVICERSHIFTKEYMASK},
    {58, NX_DEVICELALTKEYMASK}, {61, NX_DEVICERALTKEYMASK},
    {59, NX_DEVICELCTLKEYMASK}, {62, NX_DEVICERCTLKEYMASK},
};
void sync_modifiers(NSEventModifierFlags flags, uint16_t except = 128) {
    std::lock_guard lock(state_mutex);
    for (const auto modifier : modifiers) if (modifier.code != except) {
        const uint16_t vk = keymap[modifier.code].vk;
        const bool down = (flags & modifier.mask) != 0;
        set_key(vk, down); pressed_vk[modifier.code] = down ? vk : 0;
    }
}
uint16_t generic(uint16_t vk) {
    if (vk == 0xa0 || vk == 0xa1) return 0x10;
    if (vk == 0xa2 || vk == 0xa3) return 0x11;
    if (vk == 0xa4 || vk == 0xa5) return 0x12;
    return vk;
}
uint32_t mouse_flags(NSEvent *e) {
    uint32_t flags = 0;
    if (keys[1] & 0x80) flags |= 1;
    if (keys[2] & 0x80) flags |= 2;
    if (keys[4] & 0x80) flags |= 16;
    if (keys[5] & 0x80) flags |= 32;
    if (keys[6] & 0x80) flags |= 64;
    if (e.modifierFlags & NSEventModifierFlagShift) flags |= 4;
    if (e.modifierFlags & NSEventModifierFlagControl) flags |= 8;
    return flags;
}
uint32_t registration_flags(unsigned type) {
    std::lock_guard lock(state_mutex);
    return registrations[type].flags;
}
void raw_packet(uint32_t type, const void *data, size_t bytes) {
    uint64_t handle, target;
    {
        std::lock_guard lock(state_mutex);
        const auto reg = registrations[type];
        if (!reg.usage || !focus || !NSApp.active || packets.size() >= 10000) return;
        target = reg.target ? reg.target : focus;
        handle = ++next_packet;
        Packet p = {{type, (uint32_t)(sizeof(RawHeader) + bytes), 0x72000000 + type, 0}, {}, target};
        memcpy(p.data.data(), data, bytes);
        packets.emplace(handle, p);
    }
    rt_window_input(target, 0xff, 0, handle);
}
/* Quartz global points put the menu-bar display's top-left corner at the origin, with y down. */
bool warp(NSPoint pixels) {
    const NSPoint p = rt_native_point(pixels);
    if (CGWarpMouseCursorPosition(CGPointMake(p.x,NSMaxY(NSScreen.screens.firstObject.frame)-p.y))!=kCGErrorSuccess) return false;
    // Quartz rounds sub-point warps; preserve Windows pixels until the hardware cursor moves.
    warp_anchor=screen_point(NSEvent.mouseLocation);
    warped_position=InputPoint{(int32_t)llround(pixels.x),(int32_t)llround(pixels.y)};
    return true;
}
InputPoint cursor_position() {
    const InputPoint point=screen_point(NSEvent.mouseLocation);
    if (warped_position && point.x==warp_anchor.x && point.y==warp_anchor.y) return *warped_position;
    warped_position.reset();return point;
}
void cursor_state() {
    const bool foreground = focus && NSApp.active;
    const bool want_hidden = foreground && (show_count < 0 || !cursor);
    if (want_hidden != hidden) { if (want_hidden) CGDisplayHideCursor(kCGNullDirectDisplay); else CGDisplayShowCursor(kCGNullDirectDisplay); hidden = want_hidden; }
    if (foreground && clip) {
        const InputPoint position=cursor_position();
        const int32_t x=std::clamp(position.x,clip->left,clip->right-1),y=std::clamp(position.y,clip->top,clip->bottom-1);
        // Keep hardware movement connected when rendering blocks the main thread.
        if (x!=position.x || y!=position.y) warp(NSMakePoint(x,y));
    }
    if (foreground && cursor) [native_cursor(cursor) set];
}
}

uint64_t rt_input_set_cursor(uint64_t handle) {
    if (!main_thread()) return 0;
    if (handle && !native_cursor(handle)) return fail(6);
    const uint64_t previous = cursor; cursor = handle; cursor_state(); return previous;
}
void rt_input_update_cursor() { if ([NSThread isMainThread]) cursor_state(); }
void rt_input_cleanup(uint64_t handle) { std::lock_guard lock(state_mutex); packets.erase(handle); }
void rt_input_focus(uint64_t handle, bool active) {
    static const bool cleanup_registered = [] {
        std::atexit([] { if (hidden) CGDisplayShowCursor(kCGNullDirectDisplay); });
        return true;
    }();
    (void)cleanup_registered;
    if (active) {
        focus = handle;
        const NSEventModifierFlags flags = NSEvent.modifierFlags;
        caps_state = (flags & NSEventModifierFlagCapsLock) != 0;
        sync_modifiers(flags);
    }
    else if (focus == handle) {
        focus = 0;
        warped_position.reset();
        last_mouse_event.reset();
        { std::lock_guard lock(state_mutex); keys.fill(0); pressed_vk.fill(0); }
        if (capture) { const uint64_t old = capture; capture = 0; rt_window_input(old, 0x215, 0, 0, {}, 0, true); }
    }
    cursor_state();
}
void rt_input_destroy(uint64_t handle) {
    rt_input_focus(handle, false);
    if (capture == handle) capture = 0;
    std::lock_guard lock(state_mutex);
    for (auto &reg : registrations) if (reg.target == handle) reg = {};
    std::erase_if(packets, [handle](const auto &p) { return p.second.target == handle; });
}
void rt_input_key(uint64_t handle, NSEvent *e, bool down) {
    if (e.keyCode >= 128) return;
    Key key = keymap[e.keyCode];
    if (!key.vk) return;
    NSString *label = e.charactersIgnoringModifiers;
    if (key.scan < 0x100 && ((key.vk >= 'A' && key.vk <= 'Z') || (key.vk >= '0' && key.vk <= '9') || key.vk >= 0xba) && label.length == 1) {
        const unichar ch = [label characterAtIndex:0];
        if (ch >= 'a' && ch <= 'z') key.vk = ch - 'a' + 'A';
        else if ((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) key.vk = ch;
    }
    bool previous;
    {
        std::lock_guard lock(state_mutex);
        if (pressed_vk[e.keyCode]) key.vk = pressed_vk[e.keyCode];
        previous = (keys[key.vk] & 0x80) != 0;
        set_key(key.vk, down);
        pressed_vk[e.keyCode] = down ? key.vk : 0;
    }
    const bool alt = (e.modifierFlags & NSEventModifierFlagOption) != 0;
    const bool system = alt || generic(key.vk) == 0x12 || key.vk == 0x79;
    uint32_t message = down ? 0x100 : 0x101;
    if (system) message += 4;
    uint32_t bits = 1 | ((key.scan & 0xff) << 16);
    if (key.scan & 0x100) bits |= 1u << 24;
    if (alt) bits |= 1u << 29;
    if (previous || e.ARepeat || !down) bits |= 1u << 30;
    if (!down) bits |= 1u << 31;
    const RawKey raw = {(uint16_t)(key.scan & 0xff), (uint16_t)((down ? 0 : 1) | ((key.scan & 0x100) ? 2 : 0) | ((key.scan & 0x200) ? 4 : 0)), 0, generic(key.vk), message, 0};
    raw_packet(1, &raw, sizeof raw);
    if ((registration_flags(1) & 0x30) == 0x30) return;
    std::u16string text;
    NSString *chars = e.characters;
    if (down && chars.length && !([chars characterAtIndex:0] >= 0xf700 && [chars characterAtIndex:0] <= 0xf8ff)) {
        text.resize(chars.length); [chars getCharacters:(unichar *)text.data() range:NSMakeRange(0, chars.length)];
    }
    rt_window_input(handle, message, generic(key.vk), bits, text, (uint32_t)llround(e.timestamp * 1000));
}
void rt_input_flags(uint64_t handle, NSEvent *e) {
    if (e.keyCode >= 128) return;
    const Key key = keymap[e.keyCode];
    bool down;
    if (key.vk == 0x14) {
        const bool enabled = (e.modifierFlags & NSEventModifierFlagCapsLock) != 0;
        if (caps_state && *caps_state == enabled) return;
        caps_state = enabled;
        down = true;
    } else {
        const auto modifier = std::find_if(std::begin(modifiers), std::end(modifiers), [&](const Modifier &m) { return m.code == e.keyCode; });
        if (modifier == std::end(modifiers)) return;
        down = (e.modifierFlags & modifier->mask) != 0;
        sync_modifiers(e.modifierFlags, e.keyCode);
    }
    // Modifier events do not expose characters and must not be queried for them.
    NSEvent *key_event = [NSEvent keyEventWithType:down ? NSEventTypeKeyDown : NSEventTypeKeyUp location:e.locationInWindow modifierFlags:e.modifierFlags timestamp:e.timestamp windowNumber:e.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:e.keyCode];
    rt_input_key(handle, key_event, down);
    if (key.vk == 0x14 && down) rt_input_key(handle, key_event, false);
}
void rt_input_mouse(uint64_t handle, NSView *view, NSEvent *e, uint32_t class_style) {
    uint32_t msg = 0x200, button = 0, raw_button = 0, vk = 0;
    bool down = false;
    switch (e.type) {
    case NSEventTypeLeftMouseDown: msg = 0x201; vk = 1; raw_button = 1; down = true; break;
    case NSEventTypeLeftMouseUp: msg = 0x202; vk = 1; raw_button = 2; break;
    case NSEventTypeRightMouseDown: msg = 0x204; vk = 2; raw_button = 4; down = true; break;
    case NSEventTypeRightMouseUp: msg = 0x205; vk = 2; raw_button = 8; break;
    case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp:
        down = e.type == NSEventTypeOtherMouseDown;
        if (e.buttonNumber == 2) { msg = down ? 0x207 : 0x208; vk = 4; raw_button = down ? 16 : 32; }
        else if (e.buttonNumber == 3 || e.buttonNumber == 4) {
            button = (uint32_t)e.buttonNumber - 2; vk = button + 4; msg = down ? 0x20b : 0x20c;
            raw_button = 0x40u << (2 * (button - 1) + (down ? 0 : 1));
        } else return;
        break;
    default: break;
    }
    NSPoint global = NSEvent.mouseLocation;
    if (e.window) global = [e.window convertPointToScreen:e.locationInWindow];
    if (clip && focus && NSApp.active) {
        const InputPoint p=screen_point(global);
        global=rt_native_point(NSMakePoint(std::clamp(p.x,clip->left,clip->right-1),std::clamp(p.y,clip->top,clip->bottom-1)));
    }
    const NSPoint point = [view convertPoint:[view.window convertPointFromScreen:global] fromView:nil];
    double dx = e.deltaX, dy = e.deltaY;
    if (e.CGEvent) {
        dx = CGEventGetDoubleValueField(e.CGEvent, kCGEventUnacceleratedPointerMovementX);
        dy = CGEventGetDoubleValueField(e.CGEvent, kCGEventUnacceleratedPointerMovementY);
    }
    const MouseEvent event{e.timestamp,e.type,e.eventNumber,dx,dy,raw_button};
    // AppKit forwards mouse movement to both the hovered and key windows.
    if (last_mouse_event && *last_mouse_event==event) return;
    last_mouse_event=event;
    uint32_t flags;
    { std::lock_guard lock(state_mutex); if (vk) set_key(vk, down); flags = mouse_flags(e); }
    raw_x+=dx;raw_y+=dy;
    const int32_t x=(int32_t)std::clamp(std::trunc(raw_x),(double)INT32_MIN,(double)INT32_MAX);
    const int32_t y=(int32_t)std::clamp(std::trunc(raw_y),(double)INT32_MIN,(double)INT32_MAX);
    raw_x-=x;raw_y-=y;
    const RawMouse raw={0,0,(uint16_t)raw_button,0,0,x,y,0};raw_packet(0,&raw,sizeof raw);
    if (down && e.clickCount == 2 && (class_style & 8)) msg += 2;
    if (!capture) rt_window_input(handle, 0x20, handle, packed(NSPointInRect(point, view.bounds) ? 1 : 0, msg), {}, 0, true);
    if ((registration_flags(0) & 0x30) == 0x30) return;
    rt_window_input(handle, msg, flags | (button << 16), packed((int32_t)llround(point.x * view.window.backingScaleFactor), (int32_t)llround(point.y * view.window.backingScaleFactor)));
    cursor_state();
}
void rt_input_scroll(uint64_t handle, NSView *view, NSEvent *e) {
    wheel_y += e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 120);
    wheel_x -= e.scrollingDeltaX * (e.hasPreciseScrollingDeltas ? 1 : 120);
    NSPoint global = NSEvent.mouseLocation;
    if (e.window) global = [e.window convertPointToScreen:e.locationInWindow];
    const InputPoint p = screen_point(global);
    uint32_t flags;
    { std::lock_guard lock(state_mutex); flags = mouse_flags(e); }
    for (int axis = 0; axis < 2; ++axis) {
        double &amount = axis ? wheel_x : wheel_y;
        const int32_t delta = (int32_t)std::clamp(std::trunc(amount), -32768., 32767.);
        if (!delta) continue;
        amount -= delta;
        const RawMouse raw = {0, 0, (uint16_t)(axis ? 0x800 : 0x400), (uint16_t)delta, 0, 0, 0, 0};
        raw_packet(0, &raw, sizeof raw);
        if ((registration_flags(0) & 0x30) != 0x30) rt_window_input(handle, axis ? 0x20e : 0x20a, flags | (uint32_t)(uint16_t)delta << 16, packed(p.x, p.y));
    }
}
bool rt_input_route(NSEvent *event) {
    if (!capture || !NSApp.active) return false;
    NSView *view = rt_window_native(capture).contentView;
    if (!view) return false;
    switch (event.type) {
    case NSEventTypeMouseMoved: [view mouseMoved:event]; break;
    case NSEventTypeLeftMouseDragged: [view mouseDragged:event]; break;
    case NSEventTypeRightMouseDragged: [view rightMouseDragged:event]; break;
    case NSEventTypeOtherMouseDragged: [view otherMouseDragged:event]; break;
    case NSEventTypeLeftMouseDown: [view mouseDown:event]; break;
    case NSEventTypeLeftMouseUp: [view mouseUp:event]; break;
    case NSEventTypeRightMouseDown: [view rightMouseDown:event]; break;
    case NSEventTypeRightMouseUp: [view rightMouseUp:event]; break;
    case NSEventTypeOtherMouseDown: [view otherMouseDown:event]; break;
    case NSEventTypeOtherMouseUp: [view otherMouseUp:event]; break;
    case NSEventTypeScrollWheel: [view scrollWheel:event]; break;
    default: return false;
    }
    return true;
}

namespace {
H(RegisterRawInputDevices) {
    if (!main_thread()) return 0;
    if (!P(0) || !A(1) || A(1) > 128 || A(2) != sizeof(Registration) || A(0) % 4) return fail(87);
    auto updated = registrations;
    for (uint64_t i = 0; i < A(1); ++i) {
        Registration r; memcpy(&r, (const uint8_t *)P(0) + i * sizeof r, sizeof r);
        if (r.page != 1 || (r.usage != 2 && r.usage != 6)) return fail(50);
        if (r.flags & ~(1u | 0x30u)) return fail(50);
        if ((r.flags & 0x30) && (r.flags & 0x30) != 0x30) return fail(87);
        if ((r.flags & 1) && (r.target || r.flags != 1)) return fail(87);
        if (r.target && !rt_window_native(r.target)) return 0;
        updated[r.usage == 6 ? 1 : 0] = r.flags & 1 ? Registration{} : r;
    }
    std::lock_guard lock(state_mutex); registrations = updated; return 1;
}
H(GetRawInputData) {
    if (!P(3) || A(4) != sizeof(RawHeader) || (A(2) && A(2) % 4)) return fail(87, UINT32_MAX);
    std::lock_guard lock(state_mutex);
    auto it = packets.find(A(0)); if (it == packets.end()) return fail(6, UINT32_MAX);
    uint32_t required;
    if (A(1) == 0x10000005) required = sizeof(RawHeader);
    else if (A(1) == 0x10000003) required = it->second.header.size;
    else return fail(87, UINT32_MAX);
    uint32_t capacity; memcpy(&capacity, P(3), 4); rt_put<uint32_t>(P(3), required);
    if (!P(2)) return 0;
    if (capacity < required) return fail(122, UINT32_MAX);
    memcpy(P(2), &it->second.header, sizeof(RawHeader));
    if (required > sizeof(RawHeader)) memcpy((uint8_t *)P(2) + sizeof(RawHeader), it->second.data.data(), required - sizeof(RawHeader));
    return required;
}
H(GetAsyncKeyState) {
    const int32_t vk = (int32_t)A(0);
    if (vk < 0 || vk >= 256) return 0;
    std::lock_guard lock(state_mutex);
    const uint8_t state = keys[vk]; keys[vk] &= ~1;
    return ((state & 0x80) ? 0x8000 : 0) | (state & 1);
}
H(GetMessageExtraInfo) { return 0; }
H(SetCapture) {
    if (!main_thread()) return 0;
    if (!rt_window_native(A(0))) return 0;
    const uint64_t previous = capture; capture = A(0);
    if (previous && previous != capture) rt_window_send(previous, 0x215, 0, capture);
    return previous;
}
H(GetCapture) { if (!main_thread()) return 0; return capture; }
H(ReleaseCapture) {
    if (!main_thread()) return 0;
    const uint64_t previous = capture; capture = 0;
    if (previous) rt_window_send(previous, 0x215, 0, 0);
    return 1;
}
H(GetCursorPos) {
    if (!main_thread()) return 0;
    if (!P(0)) return fail(87);
    InputPoint point=cursor_position();
    if (clip && focus && NSApp.active) {
        point.x=std::clamp(point.x,clip->left,clip->right-1);point.y=std::clamp(point.y,clip->top,clip->bottom-1);
    }
    rt_put(P(0),point);
    return 1;
}
H(SetCursorPos) {
    if (!main_thread()) return 0;
    NSPoint p = NSMakePoint((int32_t)A(0), (int32_t)A(1));
    if (clip) { p.x = std::clamp(p.x, (double)clip->left, (double)clip->right - 1); p.y = std::clamp(p.y, (double)clip->top, (double)clip->bottom - 1); }
    if (!warp(p)) return fail(5);
    return 1;
}
H(ClipCursor) {
    if (!main_thread()) return 0;
    if (!P(0)) clip.reset();
    else { Rect r; memcpy(&r, P(0), sizeof r); if (r.left >= r.right || r.top >= r.bottom) return fail(87); clip = r; }
    cursor_state();
    return 1;
}
H(GetClipCursor) {
    if (!main_thread()) return 0;
    if (!P(0)) return fail(87);
    if (clip) rt_put(P(0), *clip);
    else rt_put(P(0), rt_desktop_bounds());
    return 1;
}
H(ShowCursor) {
    if (!main_thread()) return 0;
    if (A(0)) { if (show_count != INT32_MAX) ++show_count; }
    else if (show_count != INT32_MIN) --show_count;
    cursor_state(); return (uint32_t)show_count;
}
H(LoadCursorW) {
    if (!main_thread()) return 0;
    if (A(0) || A(1) > 0xffff) return fail(1814);
    const uint64_t handle = 0x20000 + A(1);
    if (!native_cursor(handle)) return fail(1814);
    return handle;
}
H(SetCursor) { return rt_input_set_cursor(A(0)); }
H(GetCursor) { if (!main_thread()) return 0; return cursor; }
}
#define E(name) {#name, name}
const RtEntry rt_input_entries[] = {
    E(RegisterRawInputDevices), E(GetRawInputData), E(GetAsyncKeyState), E(GetMessageExtraInfo),
    E(SetCapture), E(GetCapture), E(ReleaseCapture), E(GetCursorPos), E(SetCursorPos), E(ClipCursor), E(GetClipCursor),
    E(ShowCursor), E(LoadCursorW), E(SetCursor), E(GetCursor), {nullptr, nullptr}
};
