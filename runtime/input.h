#ifndef SS_INPUT_H
#define SS_INPUT_H
#import <AppKit/AppKit.h>
#include <cstdint>
#include <string_view>

/* Windows desktop pixels: the primary display's top-left corner is the origin and y grows downward.
 * Each display keeps its own backing scale (user32.mm). */
struct DesktopRect { int32_t left, top, right, bottom; };
NSPoint rt_desktop_point(NSPoint native);
NSPoint rt_native_point(NSPoint desktop);
DesktopRect rt_desktop_rect(NSRect native);
NSRect rt_native_rect(DesktopRect desktop);
/* The backing scale of the display that shows most of a native rectangle. */
double rt_desktop_scale(NSRect native);
DesktopRect rt_desktop_bounds();

NSWindow *rt_window_native(uint64_t handle);
bool rt_window_fullscreen(uint64_t handle, bool fullscreen, uint32_t display);
void rt_window_input(uint64_t handle, uint32_t message, uint64_t wp, uint64_t lp,
                     std::u16string_view text = {}, uint32_t time = 0, bool sent = false);
uint64_t rt_window_send(uint64_t handle, uint32_t message, uint64_t wp, uint64_t lp);
void rt_input_key(uint64_t handle, NSEvent *event, bool down);
void rt_input_flags(uint64_t handle, NSEvent *event);
void rt_input_mouse(uint64_t handle, NSView *view, NSEvent *event, uint32_t class_style);
void rt_input_scroll(uint64_t handle, NSView *view, NSEvent *event);
bool rt_input_route(NSEvent *event);
void rt_input_focus(uint64_t handle, bool active);
void rt_input_destroy(uint64_t handle);
void rt_input_cleanup(uint64_t raw_handle);
uint64_t rt_input_set_cursor(uint64_t handle);
void rt_input_update_cursor();
#endif
