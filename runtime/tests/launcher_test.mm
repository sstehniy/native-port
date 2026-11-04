#include "../package.mm"
#include <assert.h>

static NSButton *button(NSView *view, NSString *title) {
    if ([view isKindOfClass:NSButton.class] && [((NSButton *)view).title isEqualToString:title]) return (NSButton *)view;
    for (NSView *child in view.subviews) {
        if (NSButton *found = button(child, title)) return found;
    }
    return nil;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *suite = [@"local.sinking-star.launcher-test." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        unsetenv("SS_METALFX");
        unsetenv("SS_FRAME_PACING");
        [NSApplication sharedApplication];
        if (argc > 1 && !strcmp(argv[1], "--preview")) {
            show_launcher(defaults);
        } else {
            for (int scenario = 0; scenario < 4; ++scenario) {
                if (scenario == 3) {
                    setenv("SS_METALFX", "0", 1);
                    setenv("SS_FRAME_PACING", "0", 1);
                }
                NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:NO block:^(NSTimer *) {
                    assert([NSApp.modalWindow.title isEqualToString:@"Order of the Sinking Star"]);
                    NSView *content = NSApp.modalWindow.contentView;
                    NSButton *metalFX = button(content, @"MetalFX upscaling");
                    NSButton *smooth30 = button(content, @"Smooth 30 FPS");
                    assert(metalFX && smooth30);
                    const bool enabled = scenario != 3;
                    assert(metalFX.enabled == enabled && smooth30.enabled == enabled);
                    const bool checked = scenario == 2;
                    assert((metalFX.state == NSControlStateValueOn) == checked);
                    assert((smooth30.state == NSControlStateValueOn) == checked);
                    if (scenario < 2) {
                        [metalFX performClick:nil];
                        [smooth30 performClick:nil];
                    }
                    if (scenario == 2) [NSApp.modalWindow performClose:nil];
                    else [button(content, scenario == 0 ? @"Close" : @"Play") performClick:nil];
                }];
                [NSRunLoop.mainRunLoop addTimer:timer forMode:NSModalPanelRunLoopMode];
                assert(show_launcher(defaults) == (scenario == 1 || scenario == 3));
                const bool saved = scenario != 0;
                assert([defaults boolForKey:@"MetalFXUpscaling"] == saved);
                assert([defaults boolForKey:@"Smooth30FPS"] == saved);
            }
            puts("launcher: Close discards, Play persists, reopen restores, window close cancels, environment overrides preserve saved choices");
        }
        [defaults removePersistentDomainForName:suite];
    }
}
