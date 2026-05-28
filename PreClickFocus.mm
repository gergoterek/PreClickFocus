#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

// ── Core focus logic (unchanged) ─────────────────────────────────────────────

static pid_t frontmostPID(void) {
    NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
    return app ? app.processIdentifier : -1;
}

// Returns the PID of the topmost normal window under the given screen point,
// or -1 if none found or if it belongs to the frontmost app.
static pid_t pidOfWindowUnderCursor(CGPoint point) {
    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!windowList) return -1;

    pid_t targetPID = -1;
    pid_t front = frontmostPID();

    CFIndex count = CFArrayGetCount(windowList);
    for (CFIndex i = 0; i < count; i++) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(windowList, i);

        // Only normal windows (layer 0)
        NSNumber *layer = info[(__bridge NSString *)kCGWindowLayer];
        if (!layer || layer.integerValue != 0) continue;

        NSNumber *pidNum = info[(__bridge NSString *)kCGWindowOwnerPID];
        if (!pidNum) continue;
        pid_t pid = (pid_t)pidNum.intValue;

        // Skip the frontmost app's own windows
        if (pid == front) continue;

        NSDictionary *bounds = info[(__bridge NSString *)kCGWindowBounds];
        if (!bounds) continue;
        CGRect rect;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &rect)) continue;

        if (CGRectContainsPoint(rect, point)) {
            // CGWindowListCopyWindowInfo returns windows front-to-back on screen,
            // so the first match is the topmost one.
            targetPID = pid;
            break;
        }
    }

    CFRelease(windowList);
    return targetPID;
}

// Raise and focus the window of the given app that is under the cursor.
static void focusAppWindow(pid_t pid, CGPoint point) {
    AXUIElementRef appElement = AXUIElementCreateApplication(pid);
    if (!appElement) return;

    CFArrayRef windows = NULL;
    AXError err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, (CFTypeRef *)&windows);
    if (err != kAXErrorSuccess || !windows) {
        CFRelease(appElement);
        return;
    }

    CFIndex wCount = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < wCount; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);

        // Get window position and size via AX to confirm this is the one under cursor.
        CFTypeRef posVal = NULL, sizeVal = NULL;
        AXUIElementCopyAttributeValue(win, kAXPositionAttribute, &posVal);
        AXUIElementCopyAttributeValue(win, kAXSizeAttribute, &sizeVal);

        if (posVal && sizeVal) {
            CGPoint winPos; CGSize winSize;
            AXValueGetValue((AXValueRef)posVal, (AXValueType)kAXValueCGPointType, &winPos);
            AXValueGetValue((AXValueRef)sizeVal, (AXValueType)kAXValueCGSizeType, &winSize);
            CGRect winRect = {winPos, winSize};

            if (CGRectContainsPoint(winRect, point)) {
                AXUIElementPerformAction(win, kAXRaiseAction);
                if (posVal) CFRelease(posVal);
                if (sizeVal) CFRelease(sizeVal);
                break;
            }
        }
        if (posVal) CFRelease(posVal);
        if (sizeVal) CFRelease(sizeVal);
    }

    CFRelease(windows);
    CFRelease(appElement);

    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSString *name = app.localizedName ?: @"?";
    [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    NSLog(@"PreClickFocus: focused PID %d (%@)", pid, name);
    printf("PreClickFocus: focused PID %d (%s)\n", pid, name.UTF8String);
}

// ── Forward declaration (callback needs AppController) ───────────────────────

@class AppController;
static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type,
                                   CGEventRef event, void *refcon);

// ── AppController ─────────────────────────────────────────────────────────────

@interface AppController : NSObject
- (void)setup;
- (void)reEnableTap;   // called from C callback
@end

@implementation AppController {
    NSStatusItem       *_statusItem;
    NSMenuItem         *_toggleItem;
    CFMachPortRef       _tap;
    CFRunLoopSourceRef  _tapSource;
    BOOL                _enabled;
}

// ── Public entry point ────────────────────────────────────────────────────────

- (void)setup {
    // Install tap first so _enabled is correct when the menu is built.
    if (AXIsProcessTrusted()) {
        [self installEventTap];
    }
    [self setupStatusBar];

    // If not trusted, show the alert asynchronously and keep running.
    if (!AXIsProcessTrusted()) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self promptForAccessibility]; });
    }
}

// ── Status bar ────────────────────────────────────────────────────────────────

- (void)setupStatusBar {
    _statusItem = [[NSStatusBar systemStatusBar]
                   statusItemWithLength:NSVariableStatusItemLength];

    // Icon priority: SF Symbol "cursorarrow.click" → "cursorarrow.rays" → plain text.
    // Note: "template" is a C++ keyword; use the setter [icon setTemplate:YES].
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"cursorarrow.click"
                              accessibilityDescription:@"PreClickFocus"];
    if (!icon) {
        icon = [NSImage imageWithSystemSymbolName:@"cursorarrow.rays"
                          accessibilityDescription:@"PreClickFocus"];
    }
    if (icon) {
        [icon setTemplate:YES];
        _statusItem.button.image = icon;
    } else {
        _statusItem.button.title = @"PCF";
    }

    [self rebuildMenu];
}

- (void)rebuildMenu {
    NSMenu *menu = [[NSMenu alloc] init];

    NSString *title = _enabled ? @"PreClickFocus: Enabled" : @"PreClickFocus: Disabled";
    _toggleItem = [[NSMenuItem alloc] initWithTitle:title
                                             action:@selector(toggleEnabled:)
                                      keyEquivalent:@""];
    _toggleItem.target = self;
    _toggleItem.state  = _enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:_toggleItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];

    _statusItem.menu = menu;
}

// ── Toggle ────────────────────────────────────────────────────────────────────

- (void)toggleEnabled:(id)sender {
    if (_enabled) {
        [self removeEventTap];
        _toggleItem.title = @"PreClickFocus: Disabled";
        _toggleItem.state = NSControlStateValueOff;
        printf("PreClickFocus: disabled\n");
    } else {
        if (AXIsProcessTrusted()) {
            [self installEventTap];
            _toggleItem.title = @"PreClickFocus: Enabled";
            _toggleItem.state = NSControlStateValueOn;
        } else {
            [self promptForAccessibility];
        }
    }
}

// ── Event tap management ──────────────────────────────────────────────────────

- (void)installEventTap {
    if (_tap) return; // already installed

    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown);
    _tap = CGEventTapCreate(
        kCGHIDEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        eventTapCallback,
        (__bridge void *)self);   // pass self so callback can call reEnableTap

    if (!_tap) {
        fprintf(stderr, "PreClickFocus: failed to create event tap. "
                        "Check Accessibility permission.\n");
        _enabled = NO;
        return;
    }

    _tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), _tapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    _enabled = YES;
    printf("PreClickFocus: running (PID %d)\n", getpid());
}

- (void)removeEventTap {
    if (_tap) {
        CGEventTapEnable(_tap, false);
        if (_tapSource) {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _tapSource, kCFRunLoopCommonModes);
            CFRelease(_tapSource);
            _tapSource = NULL;
        }
        CFRelease(_tap);
        _tap = NULL;
    }
    _enabled = NO;
}

- (void)reEnableTap {
    if (_tap) CGEventTapEnable(_tap, true);
}

// ── Accessibility alert ───────────────────────────────────────────────────────

- (void)promptForAccessibility {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText     = @"Accessibility Permission Required";
    alert.informativeText =
        @"PreClickFocus needs Accessibility access to focus windows on click.\n\n"
        @"Open System Settings → Privacy & Security → Accessibility "
        @"and enable PreClickFocus, then relaunch the app.";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Open System Settings"];
    [alert addButtonWithTitle:@"Later"];

    NSModalResponse resp = [alert runModal];
    if (resp == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:
            [NSURL URLWithString:
             @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    }
    // Continue running — do not quit.
}

@end

// ── Event tap callback ────────────────────────────────────────────────────────

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type,
                                   CGEventRef event, void *refcon) {
    AppController *controller = (__bridge AppController *)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [controller reEnableTap];
        return event;
    }

    if (type != kCGEventLeftMouseDown) return event;

    CGPoint point = CGEventGetLocation(event);
    pid_t pid = pidOfWindowUnderCursor(point);
    if (pid != -1) {
        focusAppWindow(pid, point);
    }

    return event;
}

// ── Entry point ───────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        AppController *controller = [[AppController alloc] init];
        [controller setup];

        [app run];
    }
    return 0;
}
