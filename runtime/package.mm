#include "runtime.h"
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <Metal/Metal.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

@interface SSLauncher : NSWindowController <NSWindowDelegate>
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
@end

@implementation SSLauncher {
    NSUserDefaults *_defaults;
    NSButton *_metalFX;
    NSButton *_smooth30;
}
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 350)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    if (!(self = [super initWithWindow:window])) return nil;
    _defaults = defaults;
    window.title = @"Order of the Sinking Star";
    window.delegate = self;
    window.releasedWhenClosed = NO;

    NSTextField *title = [NSTextField labelWithString:@"Order of the Sinking Star"];
    title.font = [NSFont boldSystemFontOfSize:24];
    NSTextField *subtitle = [NSTextField labelWithString:@"Choose your display options, then play."];
    subtitle.textColor = NSColor.secondaryLabelColor;
    NSStackView *header = [NSStackView stackViewWithViews:@[title, subtitle]];
    header.orientation = NSUserInterfaceLayoutOrientationVertical;
    header.alignment = NSLayoutAttributeLeading;
    header.spacing = 6;

    _metalFX = [NSButton checkboxWithTitle:@"MetalFX upscaling" target:nil action:nil];
    _smooth30 = [NSButton checkboxWithTitle:@"Smooth 30 FPS" target:nil action:nil];
    const char *metalFX = getenv("SS_METALFX"), *pacing = getenv("SS_FRAME_PACING");
    _metalFX.state = (metalFX ? !strcmp(metalFX, "1") : [defaults boolForKey:@"MetalFXUpscaling"]);
    _smooth30.state = (pacing ? !strcmp(pacing, "30") : [defaults boolForKey:@"Smooth30FPS"]);
    _metalFX.enabled = !metalFX;
    _smooth30.enabled = !pacing;
    if (metalFX) _metalFX.toolTip = @"Controlled by this launch's settings.";
    if (pacing) _smooth30.toolTip = @"Controlled by this launch's settings.";
    NSTextField *upscaling = [NSTextField wrappingLabelWithString:
        @"Upscales the scene with MetalFX and keeps text sharp. Choose a lower resolution in the game's Graphics settings."];
    NSTextField *smoothing = [NSTextField wrappingLabelWithString:
        @"Aims for steadier frame pacing, with more input delay. Use a 60 FPS cap and turn VSync off in the game."];
    NSStackView *options = [NSStackView stackViewWithViews:@[_metalFX, upscaling, _smooth30, smoothing]];
    options.orientation = NSUserInterfaceLayoutOrientationVertical;
    options.alignment = NSLayoutAttributeLeading;
    options.spacing = 6;
    [options setCustomSpacing:18 afterView:upscaling];
    for (NSTextField *description in @[upscaling, smoothing]) {
        description.font = [NSFont systemFontOfSize:12];
        description.textColor = NSColor.secondaryLabelColor;
        [description.widthAnchor constraintEqualToConstant:460].active = YES;
    }
    NSBox *box = [NSBox new];
    box.titlePosition = NSNoTitle;
    box.boxType = NSBoxPrimary;
    [box.contentView addSubview:options];
    options.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [options.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:16],
        [options.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-16],
        [options.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:16],
        [options.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-16]
    ]];
    NSButton *close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(cancel:)];
    close.keyEquivalent = @"\e";
    NSButton *play = [NSButton buttonWithTitle:@"Play" target:self action:@selector(play:)];
    play.keyEquivalent = @"\r";
    for (NSView *view in @[header, box, close, play]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [window.contentView addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:28],
        [header.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:28],
        [box.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:24],
        [box.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [box.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-28],
        [play.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
        [play.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor constant:-22],
        [play.topAnchor constraintGreaterThanOrEqualToAnchor:box.bottomAnchor constant:20],
        [play.widthAnchor constraintEqualToConstant:80],
        [close.trailingAnchor constraintEqualToAnchor:play.leadingAnchor constant:-8],
        [close.centerYAnchor constraintEqualToAnchor:play.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:80]
    ]];
    [window center];
    return self;
}
- (void)play:(id)sender {
    if (_metalFX.enabled) [_defaults setBool:_metalFX.state == NSControlStateValueOn forKey:@"MetalFXUpscaling"];
    if (_smooth30.enabled) [_defaults setBool:_smooth30.state == NSControlStateValueOn forKey:@"Smooth30FPS"];
    [NSApp stopModalWithCode:NSModalResponseOK];
}
- (void)cancel:(id)sender { [NSApp stopModalWithCode:NSModalResponseCancel]; }
- (BOOL)windowShouldClose:(NSWindow *)sender { [self cancel:nil]; return NO; }
@end

static bool show_launcher(NSUserDefaults *defaults) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    SSLauncher *launcher = [[SSLauncher alloc] initWithDefaults:defaults];
    NSMenu *menu = [NSMenu new], *applicationMenu = [NSMenu new];
    NSMenuItem *application = [NSMenuItem new];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Order of the Sinking Star" action:@selector(cancel:) keyEquivalent:@"q"];
    quit.target = launcher;
    [applicationMenu addItem:quit];
    application.submenu = applicationMenu;
    [menu addItem:application];
    NSApp.mainMenu = menu;
    [NSApp finishLaunching];
    [launcher showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
    const bool play = [NSApp runModalForWindow:launcher.window] == NSModalResponseOK;
    [launcher.window orderOut:nil];
    NSApp.mainMenu = nil;
    // Let the game's ShowWindow acquire focus after the launcher and shader preparation.
    [NSApp deactivate];
    return play;
}

static RtPackageStatus fail(NSString *message) {
    [NSApplication sharedApplication];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Order of the Sinking Star could not start";
    alert.informativeText = message;
    [alert runModal];
    return RtPackageStatus::Failed;
}

static NSString *digest(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data || data.length > UINT32_MAX) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *text = [NSMutableString new];
    for (unsigned i = 0; i < sizeof(hash); ++i) [text appendFormat:@"%02x", hash[i]];
    return text;
}

RtPackageStatus rt_prepare_package(const char *&executable) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSDictionary *info = bundle.infoDictionary;
        if (![info[@"SSGameExecutableSHA256"] isKindOfClass:NSString.class]) return RtPackageStatus::Ready;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if (!show_launcher(defaults)) return RtPackageStatus::Cancelled;
        NSString *resources = bundle.resourcePath;
        NSString *game = [resources stringByAppendingPathComponent:@"Game"];
        NSString *exe = [game stringByAppendingPathComponent:@"sinking_star.exe"];
        NSFileManager *files = NSFileManager.defaultManager;
        if (![files fileExistsAtPath:[game stringByAppendingPathComponent:@"data/levels.package"]] ||
            ![digest(exe) isEqualToString:info[@"SSGameExecutableSHA256"]]) {
            return fail(@"The bundled game files are missing or damaged. Reinstall Order of the Sinking Star from its disk image.");
        }
        NSString *profile = @(getenv("SS_PROFILE_DIR") ?: "");
        if (!profile.length) profile = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Sinking Star Native/Player"];
        NSError *error = nil;
        if (![files createDirectoryAtPath:profile withIntermediateDirectories:YES attributes:nil error:&error])
            return fail(error.localizedDescription);
        NSString *saves = [profile stringByAppendingPathComponent:@"Saved Games/Order of the Sinking Star"];
        NSString *settings = [saves stringByAppendingPathComponent:@"settings.menu_state"];
        if (![files fileExistsAtPath:settings]) {
            if (![files createDirectoryAtPath:saves withIntermediateDirectories:YES attributes:nil error:&error])
                return fail(error.localizedDescription);
            // Version 9 settings for the pinned executable: tested M1 graphics, neutral audio/input preferences.
            const uint8_t initial[77] = {
                9,0,0,0, 0,0,128,63, 0,0,128,63, 1,1,1,0,
                0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
                0,0,128,63, 0,0,128,63, 0,0,0,0, 0,60,0,0,
                0,0,0,0, 0,0,1,0, 0,0,0,0, 0,0,0,0,
                0,0,1,0, 0,0,0,0, 0,0,0,0, 0
            };
            if (![[NSData dataWithBytes:initial length:sizeof(initial)] writeToFile:settings
                    options:NSDataWritingWithoutOverwriting error:&error] && error.code != NSFileWriteFileExistsError)
                return fail(error.localizedDescription);
        }
        setenv("SS_PROFILE_DIR", profile.fileSystemRepresentation, 1);
        setenv("SS_SHADER_CACHE", [resources stringByAppendingPathComponent:@"shaders"].fileSystemRepresentation, 1);
        setenv("BB_RECOMP_LIB", [bundle.privateFrameworksPath stringByAppendingPathComponent:@"librecomp.dylib"].fileSystemRepresentation, 1);
        setenv("SS_MATH_LIB", [bundle.privateFrameworksPath stringByAppendingPathComponent:@"ucrt.dylib"].fileSystemRepresentation, 1);
        setenv("SS_SEED_SAVES", "", 0);
        setenv("MTL_DEBUG_LAYER", "0", 1);
        setenv("MTL_SHADER_VALIDATION", "0", 1);
        setenv("SS_METALFX", [defaults boolForKey:@"MetalFXUpscaling"] ? "1" : "0", 0);
        setenv("SS_FRAME_PACING", [defaults boolForKey:@"Smooth30FPS"] ? "30" : "0", 0);
        setenv("MTL_HUD_ENABLED", "1", 0);
        if (chdir(profile.fileSystemRepresentation)) return fail(@(strerror(errno)));
        if (!freopen("native-game.log", "w", stdout) || dup2(fileno(stdout), STDERR_FILENO) < 0)
            return fail(@(strerror(errno)));
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return fail(@"This app requires a Metal-capable Apple Silicon Mac.");
        NSString *key = [NSString stringWithFormat:@"%@-%llu-%@", info[@"SSPipelineSHA256"],
                         (unsigned long long)device.registryID, NSProcessInfo.processInfo.operatingSystemVersionString];
        NSString *cache = [profile stringByAppendingPathComponent:[@"PipelineCache" stringByAppendingPathComponent:key]];
        if (![files createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:&error])
            return fail(error.localizedDescription);
        NSString *archive = [cache stringByAppendingPathComponent:@"pipelines.metalarc"];
        NSString *ready = [cache stringByAppendingPathComponent:@"ready"];
        setenv("SS_PIPELINE_ARCHIVE", archive.fileSystemRepresentation, 1);
        if (![files fileExistsAtPath:ready] || ![files fileExistsAtPath:archive]) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 110)
                styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
            panel.title = @"Preparing shaders";
            NSTextField *label = [NSTextField labelWithString:@"Preparing this Mac for play. This only runs once."];
            label.frame = NSMakeRect(20, 65, 400, 25);
            [panel.contentView addSubview:label];
            NSProgressIndicator *progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 25, 400, 20)];
            progress.indeterminate = YES;
            [panel.contentView addSubview:progress];
            [progress startAnimation:nil];
            [panel center];
            [panel makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            NSTask *task = [NSTask new];
            task.executableURL = [NSURL fileURLWithPath:[bundle.executablePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"prepare-pipelines"]];
            task.arguments = @[[resources stringByAppendingPathComponent:@"pipelines.json"]];
            if (![task launchAndReturnError:&error]) return fail(error.localizedDescription);
            while (task.running) {
                NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]
                    inMode:NSDefaultRunLoopMode dequeue:YES];
                if (event) [NSApp sendEvent:event];
            }
            [task waitUntilExit];
            [panel orderOut:nil];
            if (task.terminationStatus || ![files fileExistsAtPath:archive])
                return fail(@"Shader preparation failed. See native-game.log in your native profile, then try again.");
            if (![@"ready" writeToFile:ready atomically:YES encoding:NSUTF8StringEncoding error:&error])
                return fail(error.localizedDescription);
            // Preparation activates AppKit early; let the game's own ShowWindow acquire focus after setup.
            [NSApp deactivate];
        }
        static std::string selected_executable;
        selected_executable = exe.fileSystemRepresentation;
        executable = selected_executable.c_str();
        return RtPackageStatus::Ready;
    }
}
