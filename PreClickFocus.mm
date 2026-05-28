#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>

// ── Core focus logic (unchanged) ─────────────────────────────────────────────

static pid_t frontmostPID(void) {
    NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
    return app ? app.processIdentifier : -1;
}

// Returns the PID of the topmost normal (layer-0) window whose bounds contain
// the given screen point, or -1 if none is found.
// CGWindowListCopyWindowInfo returns windows front-to-back (index 0 = frontmost),
// so the first matching entry is the topmost window at the cursor position.
// Whether that window belongs to the frontmost app is intentionally NOT checked
// here; that decision is made in the event-tap callback.
static pid_t pidOfWindowUnderCursor(CGPoint point) {
    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!windowList) return -1;

    pid_t targetPID = -1;

    CFIndex count = CFArrayGetCount(windowList);
    for (CFIndex i = 0; i < count; i++) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(windowList, i);

        // Only normal windows (layer 0); skip menu bars, overlays, system UI.
        NSNumber *layer = info[(__bridge NSString *)kCGWindowLayer];
        if (!layer || layer.integerValue != 0) continue;

        NSNumber *pidNum = info[(__bridge NSString *)kCGWindowOwnerPID];
        if (!pidNum) continue;

        NSDictionary *bounds = info[(__bridge NSString *)kCGWindowBounds];
        if (!bounds) continue;
        CGRect rect;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &rect)) continue;

        if (CGRectContainsPoint(rect, point)) {
            // First match in front-to-back order = topmost window at cursor.
            targetPID = (pid_t)pidNum.intValue;
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

// ── Config ────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, DisableKeyMode) {
    DisableKeyControl = 0,   // skip focus when Control is held (default)
    DisableKeyOption,        // skip focus when Option is held
    DisableKeyNone,          // never skip based on modifier ("disabled")
};

// ── Forward declaration (callback needs AppController) ───────────────────────

@class AppController;
static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type,
                                   CGEventRef event, void *refcon);

// ── AppController ─────────────────────────────────────────────────────────────

@interface AppController : NSObject
- (void)setup;
- (void)reEnableTap;                                          // called from C callback
- (BOOL)shouldSkipFocusForPID:(pid_t)pid event:(CGEventRef)event; // called from C callback
@end

@implementation AppController {
    NSStatusItem       *_statusItem;
    NSMenuItem         *_toggleItem;
    NSMenuItem         *_loginItem;
    CFMachPortRef       _tap;
    CFRunLoopSourceRef  _tapSource;
    BOOL                _enabled;
    // Config
    NSSet<NSString *>  *_ignoreApps;
    DisableKeyMode      _disableKey;
}

// ── Config loading ────────────────────────────────────────────────────────────

- (void)loadConfig {
    // Defaults
    _ignoreApps = [NSSet set];
    _disableKey = DisableKeyControl;

    NSString *path = [@"~/.PreClickFocus" stringByExpandingTildeInPath];
    NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (!contents) return; // file absent — keep defaults

    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
    NSCharacterSet *spaces   = [NSCharacterSet whitespaceCharacterSet];

    for (NSString *rawLine in [contents componentsSeparatedByCharactersInSet:newlines]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:spaces];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;

        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;

        NSString *key   = [[line substringToIndex:eq.location]
                           stringByTrimmingCharactersInSet:spaces];
        NSString *value = [[line substringFromIndex:eq.location + 1]
                           stringByTrimmingCharactersInSet:spaces];

        // Strip surrounding double-quotes (AutoRaise format: key="val")
        if (value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
            value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        }

        if ([key isEqualToString:@"ignoreApps"]) {
            NSMutableSet *apps = [NSMutableSet set];
            for (NSString *part in [value componentsSeparatedByString:@","]) {
                NSString *name = [part stringByTrimmingCharactersInSet:spaces];
                if (name.length > 0) [apps addObject:name];
            }
            _ignoreApps = [apps copy];

        } else if ([key isEqualToString:@"disableKey"]) {
            if ([value isEqualToString:@"option"]) {
                _disableKey = DisableKeyOption;
            } else if ([value isEqualToString:@"disabled"]) {
                _disableKey = DisableKeyNone;
            } else {
                _disableKey = DisableKeyControl;
            }
        }
    }
}

- (void)logConfig {
    if (_ignoreApps.count > 0) {
        NSString *list = [_ignoreApps.allObjects componentsJoinedByString:@", "];
        printf("PreClickFocus: ignoreApps = %s\n", list.UTF8String);
    } else {
        printf("PreClickFocus: ignoreApps = (none)\n");
    }

    const char *keyName = "control";
    if (_disableKey == DisableKeyOption) keyName = "option";
    else if (_disableKey == DisableKeyNone) keyName = "disabled";
    printf("PreClickFocus: disableKey = %s\n", keyName);
}

// ── Callback helper ───────────────────────────────────────────────────────────

- (BOOL)shouldSkipFocusForPID:(pid_t)pid event:(CGEventRef)event {
    // 1. Modifier-key gate
    if (_disableKey != DisableKeyNone) {
        CGEventFlags flags = CGEventGetFlags(event);
        if (_disableKey == DisableKeyControl && (flags & kCGEventFlagMaskControl))   return YES;
        if (_disableKey == DisableKeyOption  && (flags & kCGEventFlagMaskAlternate)) return YES;
    }

    // 2. Ignored-app gate
    if (_ignoreApps.count > 0) {
        NSRunningApplication *app =
            [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        NSString *name = app.localizedName;
        if (name && [_ignoreApps containsObject:name]) return YES;
    }

    return NO;
}

// ── Public entry point ────────────────────────────────────────────────────────

- (void)setup {
    [self loadConfig];
    [self logConfig];

    // Check trust exactly once at launch — never re-polled after this point.
    BOOL trusted = AXIsProcessTrusted();
    if (trusted) {
        // Install tap first so _enabled is correct when the menu is built.
        [self installEventTap];
    }
    [self setupStatusBar];
    if (!trusted) {
        // Show alert asynchronously so the run loop is already spinning.
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
    // Disable AppKit's automatic item validation — AppController is not in the
    // responder chain, so autoenablesItems:YES (the default) would grey out
    // every item because no validateMenuItem: is found during chain-walking.
    [menu setAutoenablesItems:NO];

    // ① Toggle tap on/off
    NSString *title = _enabled ? @"PreClickFocus: Enabled" : @"PreClickFocus: Disabled";
    _toggleItem = [[NSMenuItem alloc] initWithTitle:title
                                             action:@selector(toggleEnabled:)
                                      keyEquivalent:@""];
    _toggleItem.target  = self;
    _toggleItem.state   = _enabled ? NSControlStateValueOn : NSControlStateValueOff;
    _toggleItem.enabled = YES;
    [menu addItem:_toggleItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // ② Launch at Login (SMAppService, macOS 13+)
    _loginItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                                            action:@selector(toggleLoginItem:)
                                     keyEquivalent:@""];
    _loginItem.target  = self;
    _loginItem.state   = [self loginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    if (@available(macOS 13.0, *)) { _loginItem.enabled = YES; }
    else                           { _loginItem.enabled = NO;  }
    [menu addItem:_loginItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // ③ Quit
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"];
    quit.target  = NSApp;
    quit.enabled = YES;
    [menu addItem:quit];

    _statusItem.menu = menu;
}

// ── Login item (SMAppService, macOS 13+) ──────────────────────────────────────

- (BOOL)loginItemEnabled {
    if (@available(macOS 13.0, *)) {
        return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
    }
    return NO;
}

- (void)toggleLoginItem:(id)sender {
    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService mainAppService];
        NSError *error = nil;
        if (service.status == SMAppServiceStatusEnabled) {
            [service unregisterAndReturnError:&error];
        } else {
            [service registerAndReturnError:&error];
        }
        if (error) {
            NSLog(@"PreClickFocus: login item toggle failed: %@", error.localizedDescription);
        }
        // Reflect updated state in the menu item.
        _loginItem.state = [self loginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

// ── Toggle ────────────────────────────────────────────────────────────────────

- (void)toggleEnabled:(id)sender {
    if (_enabled) {
        [self removeEventTap];
        _toggleItem.title = @"PreClickFocus: Disabled";
        _toggleItem.state = NSControlStateValueOff;
        printf("PreClickFocus: disabled\n");
    } else {
        // installEventTap sets _enabled=YES on success, NO on failure (no permission).
        // AXIsProcessTrusted() is intentionally not re-checked here per launch-only policy.
        [self installEventTap];
        if (_enabled) {
            _toggleItem.title = @"PreClickFocus: Enabled";
            _toggleItem.state = NSControlStateValueOn;
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
    // Skip if no window found, or if the topmost window already belongs to the
    // frontmost app (normal click within the active app — nothing to do).
    if (pid != -1 && pid != frontmostPID() &&
        ![controller shouldSkipFocusForPID:pid event:event]) {
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
