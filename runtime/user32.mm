/* Displays, clipboard, dialogs and resource answers; native windows and messages are in window.mm. */
#include "runtime.h"
#include "input.h"

#import <AppKit/AppKit.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <mutex>
#include <vector>

namespace {
struct Monitor {
    CGDirectDisplayID display;
    double scale;
    NSRect frame;
    DesktopRect rect, work;
    uint64_t handle() const { return UINT64_C(0x100000000) | display; }
};
NSPoint to_desktop(const Monitor &m, NSPoint p) {
    return NSMakePoint(m.rect.left + (p.x - NSMinX(m.frame)) * m.scale, m.rect.top + (NSMaxY(m.frame) - p.y) * m.scale);
}
NSPoint to_native(const Monitor &m, NSPoint p) {
    return NSMakePoint(NSMinX(m.frame) + (p.x - m.rect.left) / m.scale, NSMaxY(m.frame) - (p.y - m.rect.top) / m.scale);
}
DesktopRect desktop_rect(const Monitor &m, NSRect r) {
    const NSPoint p = to_desktop(m, NSMakePoint(NSMinX(r), NSMaxY(r)));
    const int32_t x = (int32_t)llround(p.x), y = (int32_t)llround(p.y);
    return {x, y, x + (int32_t)llround(r.size.width * m.scale), y + (int32_t)llround(r.size.height * m.scale)};
}
/* Quartz answers on any thread, as the game asks from workers too. AppKit's usable area (without
 * menu bar and Dock) is main-thread state, so workers see the area last read on the main thread. */
std::mutex work_mutex;
std::vector<std::pair<CGDirectDisplayID, NSRect>> visible_frames;
std::vector<Monitor> monitors() {
    CGDirectDisplayID ids[32];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(32, ids, &count) != kCGErrorSuccess || !count) { ids[0] = CGMainDisplayID(); count = 1; }
    std::stable_partition(ids, ids + count, [](CGDirectDisplayID id) { return id == CGMainDisplayID(); });
    std::vector<Monitor> list;
    for (uint32_t i = 0; i < count; ++i) {
        if (CGDisplayMirrorsDisplay(ids[i]) != kCGNullDirectDisplay) continue;
        const CGRect bounds = CGDisplayBounds(ids[i]);
        double scale = 1;
        if (CGDisplayModeRef mode = CGDisplayCopyDisplayMode(ids[i])) {
            if (CGDisplayModeGetWidth(mode)) scale = (double)CGDisplayModeGetPixelWidth(mode) / CGDisplayModeGetWidth(mode);
            CGDisplayModeRelease(mode);
        }
        list.push_back({ids[i], scale, NSRect(bounds), {}, {}});
    }
    const double top = list[0].frame.size.height;
    double largest = 1;
    for (const Monitor &m : list) largest = std::max(largest, m.scale);
    if ([NSThread isMainThread]) {
        std::lock_guard lock(work_mutex);
        visible_frames.clear();
        for (NSScreen *screen in NSScreen.screens) visible_frames.emplace_back([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue], screen.visibleFrame);
    }
    for (Monitor &m : list) {
        // ponytail: origins use the largest scale, so mixed-DPI displays never overlap but may leave gaps
        // between them; an edge-adjacency layout would close the gaps if a game ever depends on that.
        const int32_t x = (int32_t)llround(m.frame.origin.x * largest), y = (int32_t)llround(m.frame.origin.y * largest);
        m.frame.origin.y = top - NSMaxY(m.frame);
        m.rect = {x, y, x + (int32_t)llround(m.frame.size.width * m.scale), y + (int32_t)llround(m.frame.size.height * m.scale)};
        m.work = m.rect;
        std::lock_guard lock(work_mutex);
        for (const auto &[display, visible] : visible_frames) if (display == m.display) m.work = desktop_rect(m, visible);
    }
    return list;
}
double distance(NSRect r, NSPoint p) {
    const double dx = std::max({NSMinX(r) - p.x, 0., p.x - NSMaxX(r)}), dy = std::max({NSMinY(r) - p.y, 0., p.y - NSMaxY(r)});
    return std::hypot(dx, dy);
}
double distance(DesktopRect r, NSPoint p) {
    const double dx = std::max({r.left - p.x, 0., p.x - r.right}), dy = std::max({r.top - p.y, 0., p.y - r.bottom});
    return std::hypot(dx, dy);
}
double overlap(NSRect a, NSRect b) { const NSRect r = NSIntersectionRect(a, b); return r.size.width * r.size.height; }
double overlap(DesktopRect a, DesktopRect b) {
    const double w = std::min(a.right, b.right) - std::max(a.left, b.left), h = std::min(a.bottom, b.bottom) - std::max(a.top, b.top);
    return w > 0 && h > 0 ? w * h : 0;
}
template <class Score> size_t best(const std::vector<Monitor> &list, Score score) {
    size_t index = 0;
    for (size_t i = 1; i < list.size(); ++i) if (score(list[i]) < score(list[index])) index = i;
    return index;
}
/* The display showing most of a rectangle, or the nearest one to its centre (the first on ties). */
size_t monitor_for(const std::vector<Monitor> &list, NSRect r) {
    const size_t covering = best(list, [&](const Monitor &m) { return -overlap(m.frame, r); });
    if (overlap(list[covering].frame, r) > 0) return covering;
    return best(list, [&](const Monitor &m) { return distance(m.frame, NSMakePoint(NSMidX(r), NSMidY(r))); });
}
size_t monitor_for(const std::vector<Monitor> &list, DesktopRect r) {
    const size_t covering = best(list, [&](const Monitor &m) { return -overlap(m.rect, r); });
    if (overlap(list[covering].rect, r) > 0) return covering;
    return best(list, [&](const Monitor &m) { return distance(m.rect, NSMakePoint((r.left + r.right) / 2., (r.top + r.bottom) / 2.)); });
}
const Monitor *find_monitor(const std::vector<Monitor> &list, uint64_t handle) {
    for (const Monitor &m : list) if (m.handle() == handle) return &m;
    rt_set_last_error(1461); // ERROR_INVALID_MONITOR_HANDLE
    return nullptr;
}
std::string device_name(size_t index) { return "\\\\.\\DISPLAY" + std::to_string(index + 1); }
}

NSPoint rt_desktop_point(NSPoint native) {
    const auto list = monitors();
    return to_desktop(list[best(list, [&](const Monitor &m) { return distance(m.frame, native); })], native);
}
NSPoint rt_native_point(NSPoint desktop) {
    const auto list = monitors();
    return to_native(list[best(list, [&](const Monitor &m) { return distance(m.rect, desktop); })], desktop);
}
DesktopRect rt_desktop_rect(NSRect native) {
    const auto list = monitors();
    return desktop_rect(list[monitor_for(list, native)], native);
}
NSRect rt_native_rect(DesktopRect desktop) {
    const auto list = monitors();
    const Monitor &m = list[monitor_for(list, desktop)];
    const NSPoint p = to_native(m, NSMakePoint(desktop.left, desktop.top));
    const double width = (desktop.right - desktop.left) / m.scale, height = (desktop.bottom - desktop.top) / m.scale;
    return NSMakeRect(p.x, p.y - height, width, height);
}
double rt_desktop_scale(NSRect native) {
    const auto list = monitors();
    return list[monitor_for(list, native)].scale;
}
DesktopRect rt_desktop_bounds() {
    const auto list = monitors();
    DesktopRect r = list[0].rect;
    for (const Monitor &m : list) r = {std::min(r.left, m.rect.left), std::min(r.top, m.rect.top), std::max(r.right, m.rect.right), std::max(r.bottom, m.rect.bottom)};
    return r;
}

namespace {
/* Accessibility shortcut settings belong to Windows; the game turns off their hotkeys, so the
 * answers are kept per process and macOS is never changed. */
struct Accessibility { uint32_t get, set, size; std::array<uint8_t, 24> data; };
std::mutex accessibility_mutex;
Accessibility accessibility[] = {{0x32, 0x33, 24, {24, 0, 0, 0, 2}}, {0x34, 0x35, 8, {8, 0, 0, 0, 2}}, {0x3a, 0x3b, 8, {8, 0, 0, 0, 2}}};

H(SystemParametersInfoW) {
    const uint32_t action = (uint32_t)A(0);
    if (action == 0x30) { // SPI_GETWORKAREA
        if (!P(2)) { rt_set_last_error(87); return 0; }
        rt_put(P(2), monitors()[0].work);
        return 1;
    }
    for (Accessibility &setting : accessibility) {
        if (action != setting.get && action != setting.set) continue;
        uint32_t size = 0;
        if (P(2)) memcpy(&size, P(2), 4);
        if ((uint32_t)A(1) != setting.size || size != setting.size) { rt_set_last_error(87); return 0; }
        std::lock_guard lock(accessibility_mutex);
        if (action == setting.get) memcpy(P(2), setting.data.data(), setting.size);
        else memcpy(setting.data.data(), P(2), setting.size);
        return 1;
    }
    printf("runtime: SystemParametersInfoW(%#x) not supported\n", action);
    rt_set_last_error(87);
    return 0;
}

enum { SM_CXSCREEN = 0, SM_CYSCREEN = 1, SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77, SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79, SM_CMONITORS = 80 };
H(GetSystemMetrics) {
    const auto list = monitors();
    const DesktopRect primary = list[0].rect, bounds = rt_desktop_bounds();
    switch ((int32_t)A(0)) {
    case SM_CXSCREEN: return (uint32_t)(primary.right - primary.left);
    case SM_CYSCREEN: return (uint32_t)(primary.bottom - primary.top);
    case SM_XVIRTUALSCREEN: return (uint32_t)bounds.left;
    case SM_YVIRTUALSCREEN: return (uint32_t)bounds.top;
    case SM_CXVIRTUALSCREEN: return (uint32_t)(bounds.right - bounds.left);
    case SM_CYVIRTUALSCREEN: return (uint32_t)(bounds.bottom - bounds.top);
    case SM_CMONITORS: return list.size();
    case 94: case 95: return 0; // SM_DIGITIZER, SM_MAXIMUMTOUCHES: this port has no touch device.
    default: printf("runtime: GetSystemMetrics(%d) = 0\n", (int32_t)A(0)); return 0;
    }
}

/* EnumDisplayMonitors(hdc, clip, proc, data): proc(monitor, hdc, rect*, data) per display until it returns 0. */
H(EnumDisplayMonitors) {
    if (A(0)) { rt_set_last_error(87); return 0; } // Device-context clipping needs GDI.
    for (const Monitor &m : monitors()) {
        DesktopRect rect = m.rect;
        if (P(1)) {
            DesktopRect clip; memcpy(&clip, P(1), sizeof clip);
            rect = {std::max(rect.left, clip.left), std::max(rect.top, clip.top), std::min(rect.right, clip.right), std::min(rect.bottom, clip.bottom)};
            if (rect.left >= rect.right || rect.top >= rect.bottom) continue;
        }
        const uint64_t args[4] = {m.handle(), 0, (uint64_t)(uintptr_t)&rect, A(3)};
        if (!(uint32_t)bbcpu_call_win64((uintptr_t)A(2), 4, args)) break;
    }
    return 1;
}
/* MonitorFromWindow(hwnd, flags): MONITOR_DEFAULTTONULL 0, PRIMARY 1, NEAREST 2. */
H(MonitorFromWindow) {
    const uint32_t flags = (uint32_t)A(1);
    if (flags > 2) { rt_set_last_error(87); return 0; }
    NSWindow *window = rt_window_native(A(0));
    const auto list = monitors();
    if (!window) return flags ? list[0].handle() : 0;
    const NSRect frame = window.frame;
    const size_t index = monitor_for(list, frame);
    if (overlap(list[index].frame, frame) > 0 || flags == 2) return list[index].handle();
    return flags ? list[0].handle() : 0;
}

/* MONITORINFO(EX): cbSize, rcMonitor, rcWork, dwFlags (MONITORINFOF_PRIMARY), then the device name. */
uint64_t monitor_info(WinCall *c, bool wide) {
    uint8_t *info = P(1);
    if (!info) { rt_set_last_error(87); return 0; }
    uint32_t size;
    memcpy(&size, info, 4);
    const uint32_t extended = 40 + (wide ? 64 : 32);
    if (size != 40 && size != extended) { rt_set_last_error(87); return 0; }
    const auto list = monitors();
    const Monitor *m = find_monitor(list, A(0));
    if (!m) return 0;
    rt_put(info + 4, m->rect);
    rt_put(info + 20, m->work);
    rt_put<uint32_t>(info + 36, m == &list[0]);
    if (size == extended) {
        const std::string name = device_name(m - list.data());
        for (size_t i = 0; i <= name.size(); ++i) {
            const uint8_t ch = i < name.size() ? name[i] : 0;
            if (wide) rt_put<uint16_t>(info + 40 + 2 * i, ch);
            else info[40 + i] = ch;
        }
    }
    return 1;
}
H(GetMonitorInfoW) { return monitor_info(c, true); }
H(GetMonitorInfoA) { return monitor_info(c, false); }

int32_t refresh_rate(const Monitor &m) {
    double rate = 0;
    if (CGDisplayModeRef mode = CGDisplayCopyDisplayMode(m.display)) { rate = CGDisplayModeGetRefreshRate(mode); CGDisplayModeRelease(mode); }
    return rate > 0 ? (int32_t)llround(rate) : 60;
}
/* EnumDisplaySettingsA(device, mode, DEVMODEA*): the current mode (ENUM_CURRENT_SETTINGS -1 or
 * ENUM_REGISTRY_SETTINGS -2) of the named display or the primary one; mode lists are not offered. */
H(EnumDisplaySettingsA) {
    const int32_t mode = (int32_t)A(1);
    uint8_t *dm = P(2);
    if (!dm) { rt_set_last_error(87); return 0; }
    const auto list = monitors();
    size_t index = 0;
    if (const char *device = P(0)) {
        for (index = 0; index < list.size() && strcasecmp(device, device_name(index).c_str()); ++index) {}
        if (index == list.size()) { rt_set_last_error(87); return 0; }
    }
    if (mode != -1 && mode != -2) { printf("runtime: EnumDisplaySettingsA mode %d is not offered\n", mode); return 0; }
    const Monitor &m = list[index];
    rt_put<uint32_t>(dm + 40, 0x20 | 0x40000 | 0x80000 | 0x100000 | 0x400000); /* dmFields */
    rt_put<int32_t>(dm + 44, m.rect.left);                                   /* dmPosition */
    rt_put<int32_t>(dm + 48, m.rect.top);
    rt_put<uint32_t>(dm + 104, 32);                                          /* dmBitsPerPel */
    rt_put<int32_t>(dm + 108, m.rect.right - m.rect.left);                   /* dmPelsWidth */
    rt_put<int32_t>(dm + 112, m.rect.bottom - m.rect.top);                   /* dmPelsHeight */
    rt_put<uint32_t>(dm + 120, refresh_rate(m));                             /* dmDisplayFrequency */
    return 1;
}

/* One clipboard session per process. Tests name a private pasteboard so the user's clipboard stays intact.
 * As on Windows, the clipboard owns the CF_DIB memory from a successful SetClipboardData until it is emptied or replaced. */
std::mutex clipboard_mutex;
bool clipboard_open, clipboard_emptied;
uint64_t clipboard_memory;
void release_clipboard_memory(uint64_t keep = 0) {
    if (clipboard_memory && clipboard_memory != keep) rt_global_free(clipboard_memory);
    clipboard_memory = keep;
}
NSPasteboard *pasteboard() {
    const char *name = getenv("SS_PASTEBOARD");
    return name ? [NSPasteboard pasteboardWithName:@(name)] : NSPasteboard.generalPasteboard;
}
H(OpenClipboard) {
    std::lock_guard lock(clipboard_mutex);
    if (clipboard_open) { rt_set_last_error(5); return 0; }
    clipboard_open = true; clipboard_emptied = false;
    return 1;
}
H(EmptyClipboard) {
    std::lock_guard lock(clipboard_mutex);
    if (!clipboard_open) { rt_set_last_error(1418); return 0; }
    [pasteboard() clearContents];
    release_clipboard_memory();
    clipboard_emptied = true;
    return 1;
}
H(CloseClipboard) {
    std::lock_guard lock(clipboard_mutex);
    if (!clipboard_open) { rt_set_last_error(1418); return 0; }
    clipboard_open = false;
    return 1;
}
/* A 32-bit BI_RGB device-independent bitmap as an opaque sRGB image. */
NSBitmapImageRep *dib_image(const std::vector<uint8_t> &dib) {
    if (dib.size() < 40) return nil;
    uint32_t header, compression; int32_t width, height; uint16_t planes, bits;
    memcpy(&header, dib.data(), 4); memcpy(&width, dib.data() + 4, 4); memcpy(&height, dib.data() + 8, 4);
    memcpy(&planes, dib.data() + 12, 2); memcpy(&bits, dib.data() + 14, 2); memcpy(&compression, dib.data() + 16, 4);
    const int64_t rows = std::abs((int64_t)height), stride = (int64_t)width * 4;
    if (header < 40 || planes != 1 || bits != 32 || compression || width <= 0 || width > 32768 || !rows || rows > 32768) return nil;
    if ((uint64_t)(header + stride * rows) > dib.size()) return nil;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:width pixelsHigh:rows bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:stride bitsPerPixel:32];
    for (int64_t y = 0; y < rows; ++y) {
        const uint8_t *source = dib.data() + header + stride * (height > 0 ? rows - 1 - y : y);
        uint8_t *target = rep.bitmapData + stride * y;
        for (int32_t x = 0; x < width; ++x) {
            target[4 * x] = source[4 * x + 2]; target[4 * x + 1] = source[4 * x + 1]; target[4 * x + 2] = source[4 * x]; target[4 * x + 3] = 255;
        }
    }
    return [rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];
}
/* SetClipboardData(format, memory): CF_DIB (8), the game's screenshot copy. On failure the caller keeps the memory. */
H(SetClipboardData) {
    std::lock_guard lock(clipboard_mutex);
    if (!clipboard_open) { rt_set_last_error(1418); return 0; }
    if ((uint32_t)A(0) != 8 || !A(1)) {
        printf("runtime: SetClipboardData format %u is not supported\n", (uint32_t)A(0));
        rt_set_last_error(87); return 0;
    }
    std::vector<uint8_t> dib;
    if (!rt_global_copy(A(1), dib)) { rt_set_last_error(6); return 0; }
    NSBitmapImageRep *image = dib_image(dib);
    if (!image) { rt_set_last_error(87); return 0; }
    NSPasteboard *board = pasteboard();
    if (!clipboard_emptied) { [board clearContents]; clipboard_emptied = true; }
    [board setData:[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] forType:NSPasteboardTypePNG];
    [board setData:image.TIFFRepresentation forType:NSPasteboardTypeTIFF];
    release_clipboard_memory(A(1));
    return A(1);
}

/* MessageBoxA/W as a native alert. It may come from any thread (fatal errors), so it uses
 * CFUserNotification instead of NSAlert. SS_ALERT_TIMEOUT (seconds) lets tests dismiss it; a
 * dismissed alert answers with its default button. */
struct Button { const char *title; uint32_t id; };
const std::vector<Button> button_sets[] = {
    {{"OK", 1}}, {{"OK", 1}, {"Cancel", 2}}, {{"Abort", 3}, {"Retry", 4}, {"Ignore", 5}},
    {{"Yes", 6}, {"No", 7}, {"Cancel", 2}}, {{"Yes", 6}, {"No", 7}}, {{"Retry", 4}, {"Cancel", 2}},
    {{"Cancel", 2}, {"Try Again", 10}, {"Continue", 11}},
};
uint64_t message_box(const std::string &text, const std::string &title, uint32_t type) {
    if ((type & 0xf) >= std::size(button_sets)) { rt_set_last_error(87); return 0; }
    std::vector<Button> buttons = button_sets[type & 0xf];
    const size_t preferred = (type >> 8) & 0xf;
    if (preferred < buttons.size()) std::rotate(buttons.begin(), buttons.begin() + preferred, buttons.begin() + preferred + 1);
    CFOptionFlags level = kCFUserNotificationPlainAlertLevel;
    switch (type & 0xf0) {
    case 0x10: level = kCFUserNotificationStopAlertLevel; break;
    case 0x30: level = kCFUserNotificationCautionAlertLevel; break;
    case 0x20: case 0x40: level = kCFUserNotificationNoteAlertLevel; break;
    }
    printf("runtime: MessageBox \"%s\": %s\n", title.c_str(), text.c_str());
    fflush(stdout);
    auto string = [](const char *s) { return (__bridge CFStringRef)@(s); };
    const char *timeout = getenv("SS_ALERT_TIMEOUT");
    CFOptionFlags response = kCFUserNotificationDefaultResponse;
    const SInt32 error = CFUserNotificationDisplayAlert(timeout ? atof(timeout) : 0, level, nullptr, nullptr, nullptr,
        string(title.c_str()), string(text.c_str()), string(buttons[0].title), buttons.size() > 1 ? string(buttons[1].title) : nullptr,
        buttons.size() > 2 ? string(buttons[2].title) : nullptr, &response);
    if (error) { rt_set_last_error(8); return 0; }
    const size_t index = response & 3;
    return buttons[index < buttons.size() ? index : 0].id;
}
H(MessageBoxW) { return message_box(rt_utf8((const char16_t *)P(1)), A(2) ? rt_utf8((const char16_t *)P(2)) : "Error", (uint32_t)A(3)); }
H(MessageBoxA) {
    auto ansi = [](const char *s) { std::u16string wide; for (; *s; ++s) wide += (char16_t)(uint8_t)*s; return rt_utf8(wide); };
    return message_box(A(1) ? ansi(P(1)) : "", A(2) ? ansi(P(2)) : "Error", (uint32_t)A(3));
}

/* The game's window has no WS_EX_ACCEPTFILES and the executable never calls DragAcceptFiles, so
 * WM_DROPFILES never arrives; a drop handle has no files. */
H(DragQueryFileW) { rt_set_last_error(6); return 0; }
H(DragFinish) { return 0; }

/* Brushes and icons only decorate a Windows window: the background is the Metal layer and the
 * macOS app icon comes from its bundle. */
H(CreateSolidBrush) { return 0x40000 | (A(0) & 0xffff); }
H(LoadIconW) { return 0x30000 + (A(1) & 0xffff); }
H(ExtractIconW) { return 0x30001; }

H(GetTouchInputInfo) {
    rt_set_last_error((uint32_t)A(3) != 48 || !A(1) || !P(2) ? 87 : 6);
    return 0;
}
H(CloseTouchInputHandle) { rt_set_last_error(6); return 0; }
}

#define E(name) {#name, name}
const RtEntry rt_user32_entries[] = {
    E(SystemParametersInfoW), E(GetSystemMetrics), E(EnumDisplayMonitors), E(MonitorFromWindow),
    E(GetMonitorInfoW), E(GetMonitorInfoA), E(EnumDisplaySettingsA), E(OpenClipboard), E(EmptyClipboard),
    E(CloseClipboard), E(SetClipboardData), E(MessageBoxW), E(MessageBoxA), E(DragQueryFileW), E(DragFinish),
    E(CreateSolidBrush), E(LoadIconW), E(ExtractIconW), E(GetTouchInputInfo), E(CloseTouchInputHandle), {nullptr, nullptr},
};
