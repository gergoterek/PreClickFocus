#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>

// ── TEMP PROFILING — remove after measurement ────────────────────────────────
// Monotonic milliseconds. CLOCK_UPTIME_RAW excludes sleep and isn't subject to
// NTP adjustments, so phase deltas are accurate.
static double nowMs(void) {
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1.0e6;
}
// ─────────────────────────────────────────────────────────────────────────────

static pid_t frontmostPID(void) {
    NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
    return app ? app.processIdentifier : -1;
}

static pid_t pidOfWindowUnderCursor(CGPoint point) {
    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!windowList) return -1;
    pid_t targetPID = -1;
    CFIndex count = CFArrayGetCount(windowList);
    for (CFIndex i = 0; i < count; i++) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(windowList, i);
        NSNumber *layer = info[(__bridge NSString *)kCGWindowLayer];
        if (!layer) continue;
        NSDictionary *bounds = info[(__bridge NSString *)kCGWindowBounds];
        if (!bounds) continue;
        CGRect rect;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &rect)) continue;
        if (CGRectContainsPoint(rect, point)) {
            if (layer.integerValue == 0) {
                NSNumber *pidNum = info[(__bridge NSString *)kCGWindowOwnerPID];
                if (pidNum) targetPID = (pid_t)pidNum.intValue;
            }
            // else: menu or overlay on top — return -1 (no focus)
            break;
        }
    }
    CFRelease(windowList);
    return targetPID;
}

static void focusAppWindow(pid_t pid, CGPoint point, double hitTestMs) {
    double tStart = nowMs();   // TEMP PROFILING
    AXUIElementRef appElement = AXUIElementCreateApplication(pid);
    if (!appElement) return;
    // Bound worst-case latency: every AXUIElementCopyAttributeValue below is a
    // synchronous IPC round-trip to the target app, and this runs inside the
    // event tap callback that gates click delivery. The default AX messaging
    // timeout is multi-second, so a busy/unresponsive target app could stall
    // the user's click that long. Cap it at 250 ms — well above a healthy
    // app's response time, but short enough to never feel frozen.
    AXUIElementSetMessagingTimeout(appElement, 0.25f);
    CFArrayRef windows = NULL;
    AXError err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, (CFTypeRef *)&windows);
    if (err != kAXErrorSuccess || !windows) { CFRelease(appElement); return; }
    CFIndex wCount = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < wCount; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
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
                if (posVal)  CFRelease(posVal);
                if (sizeVal) CFRelease(sizeVal);
                break;
            }
        }
        if (posVal)  CFRelease(posVal);
        if (sizeVal) CFRelease(sizeVal);
    }
    CFRelease(windows);
    CFRelease(appElement);
    double tRaise = nowMs();   // TEMP PROFILING — end of AX enumeration + raise
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSString *name = app.localizedName ?: @"?";
    double tLookup = nowMs();  // TEMP PROFILING — end of running-app + name lookup
    [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    double tActivate = nowMs(); // TEMP PROFILING — end of activation
    // TEMP PROFILING — one consolidated breakdown line per focus event.
    printf("PreClickFocus: focused PID %d (%s) | hit-test %.1fms AX-raise %.1fms lookup %.1fms activate %.1fms total %.1fms\n",
           pid, name.UTF8String,
           hitTestMs,
           tRaise - tStart,
           tLookup - tRaise,
           tActivate - tLookup,
           hitTestMs + (tActivate - tStart));
}

typedef NS_ENUM(NSInteger, DisableKeyMode) {
    DisableKeyControl = 0,
    DisableKeyOption,
    DisableKeyNone,
};

@class AppController;
static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type,
                                   CGEventRef event, void *refcon);

@interface AppController : NSObject
- (void)setup;
- (void)reEnableTap;
- (BOOL)shouldSkipFocusForPID:(pid_t)pid event:(CGEventRef)event;
- (BOOL)hoverPrimingEnabled;
@end

@implementation AppController {
    NSStatusItem       *_statusItem;
    NSMenuItem         *_toggleItem;
    NSMenuItem         *_loginItem;
    CFMachPortRef       _tap;
    CFRunLoopSourceRef  _tapSource;
    BOOL                _enabled;
    BOOL                _userEnabled;
    BOOL                _hoverPrimingEnabled;   // default YES
    NSSet<NSString *>  *_ignoreApps;
    DisableKeyMode      _disableKey;
}

- (void)loadConfig {
    _hoverPrimingEnabled = YES;
    _ignoreApps = [NSSet set];
    _disableKey = DisableKeyControl;
    NSString *path = [@"~/.PreClickFocus" stringByExpandingTildeInPath];
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!contents) return;
    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
    NSCharacterSet *spaces   = [NSCharacterSet whitespaceCharacterSet];
    for (NSString *rawLine in [contents componentsSeparatedByCharactersInSet:newlines]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:spaces];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key   = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:spaces];
        NSString *value = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:spaces];
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
            if ([value isEqualToString:@"option"])        _disableKey = DisableKeyOption;
            else if ([value isEqualToString:@"disabled"]) _disableKey = DisableKeyNone;
            else                                          _disableKey = DisableKeyControl;
        } else if ([key isEqualToString:@"hoverPriming"]) {
            _hoverPrimingEnabled = ![value isEqualToString:@"false"];
        }
    }
}

- (void)logConfig {
    if (_ignoreApps.count > 0)
        printf("PreClickFocus: ignoreApps = %s\n", [_ignoreApps.allObjects componentsJoinedByString:@", "].UTF8String);
    else
        printf("PreClickFocus: ignoreApps = (none)\n");
    const char *keyName = (_disableKey == DisableKeyOption) ? "option" :
                          (_disableKey == DisableKeyNone)   ? "disabled" : "control";
    printf("PreClickFocus: disableKey = %s\n", keyName);
    printf("PreClickFocus: hoverPriming = %s\n", _hoverPrimingEnabled ? "on" : "off");
}

- (BOOL)hoverPrimingEnabled { return _hoverPrimingEnabled; }

- (BOOL)shouldSkipFocusForPID:(pid_t)pid event:(CGEventRef)event {
    if (_disableKey != DisableKeyNone) {
        CGEventFlags flags = CGEventGetFlags(event);
        if (_disableKey == DisableKeyControl && (flags & kCGEventFlagMaskControl))   return YES;
        if (_disableKey == DisableKeyOption  && (flags & kCGEventFlagMaskAlternate)) return YES;
    }
    if (_ignoreApps.count > 0) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        NSString *name = app.localizedName;
        if (name && [_ignoreApps containsObject:name]) return YES;
    }
    return NO;
}

- (void)setup {
    [self loadConfig];
    [self logConfig];
    if (AXIsProcessTrusted()) {
        [self installEventTap];
    } else {
        NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    }
    [self setupStatusBar];
}

- (void)setupStatusBar {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"cursorarrow.click" accessibilityDescription:@"PreClickFocus"];
    if (!icon) icon = [NSImage imageWithSystemSymbolName:@"cursorarrow.rays" accessibilityDescription:@"PreClickFocus"];
    if (icon) { [icon setTemplate:YES]; _statusItem.button.image = icon; }
    else { _statusItem.button.title = @"PCF"; }
    [self rebuildMenu];
}

- (void)rebuildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu setAutoenablesItems:NO];
    NSString *title = _enabled ? @"PreClickFocus: Enabled" : @"PreClickFocus: Disabled";
    _toggleItem = [[NSMenuItem alloc] initWithTitle:title action:@selector(toggleEnabled:) keyEquivalent:@""];
    _toggleItem.target  = self;
    _toggleItem.state   = _enabled ? NSControlStateValueOn : NSControlStateValueOff;
    _toggleItem.enabled = YES;
    [menu addItem:_toggleItem];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *hoverItem = [[NSMenuItem alloc] initWithTitle:@"Hover Priming"
                                                       action:@selector(toggleHoverPriming:)
                                                keyEquivalent:@""];
    hoverItem.target  = self;
    hoverItem.state   = _hoverPrimingEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    hoverItem.enabled = YES;
    [menu addItem:hoverItem];
    [menu addItem:[NSMenuItem separatorItem]];
    _loginItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login" action:@selector(toggleLoginItem:) keyEquivalent:@""];
    _loginItem.target  = self;
    _loginItem.state   = [self loginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    if (@available(macOS 13.0, *)) { _loginItem.enabled = YES; }
    else                           { _loginItem.enabled = NO;  }
    [menu addItem:_loginItem];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target  = NSApp;
    quit.enabled = YES;
    [menu addItem:quit];
    _statusItem.menu = menu;
}

- (BOOL)loginItemEnabled {
    if (@available(macOS 13.0, *))
        return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
    return NO;
}

- (void)toggleLoginItem:(id)sender {
    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService mainAppService];
        NSError *error = nil;
        if (service.status == SMAppServiceStatusEnabled) [service unregisterAndReturnError:&error];
        else [service registerAndReturnError:&error];
        if (error) NSLog(@"PreClickFocus: login item toggle failed: %@", error.localizedDescription);
        _loginItem.state = [self loginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)toggleEnabled:(id)sender {
    if (_enabled) {
        _userEnabled = NO;
        [self removeEventTap];
        _toggleItem.title = @"PreClickFocus: Disabled";
        _toggleItem.state = NSControlStateValueOff;
        printf("PreClickFocus: disabled\n");
    } else {
        _userEnabled = YES;
        [self installEventTap];
        if (_enabled) {
            _toggleItem.title = @"PreClickFocus: Enabled";
            _toggleItem.state = NSControlStateValueOn;
        }
    }
}

- (void)toggleHoverPriming:(id)sender {
    _hoverPrimingEnabled = !_hoverPrimingEnabled;
    [sender setState:_hoverPrimingEnabled ? NSControlStateValueOn : NSControlStateValueOff];
    printf("PreClickFocus: hoverPriming = %s\n", _hoverPrimingEnabled ? "on" : "off");
}

- (void)installEventTap {
    if (_tap && CFMachPortIsValid(_tap)) return;
    if (_tap) [self removeEventTap];
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown);
    _tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                            mask, eventTapCallback, (__bridge void *)self);
    if (!_tap) {
        fprintf(stderr, "PreClickFocus: failed to create event tap. Check Accessibility permission.\n");
        _enabled = NO;
        return;
    }
    _tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), _tapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    _enabled     = YES;
    _userEnabled = YES;
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
    if (!_userEnabled) return;
    if (!_tap || !CFMachPortIsValid(_tap)) {
        [self removeEventTap];
        [self installEventTap];
        return;
    }
    CGEventTapEnable(_tap, true);
}

@end

// Marker written onto every synthetic event we post so the tap can
// recognise and pass them through without re-processing.
static const int64_t kPCFSyntheticTag = 0x50434600; // "PCF\0"

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type,
                                   CGEventRef event, void *refcon) {
    AppController *controller = (__bridge AppController *)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [controller reEnableTap];
        return NULL;
    }
    // Part B: pass our own synthetic events straight through — no re-processing.
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kPCFSyntheticTag)
        return event;

    if (type != kCGEventLeftMouseDown) return event;
    CGPoint point = CGEventGetLocation(event);
    double tHit0 = nowMs();   // TEMP PROFILING
    pid_t pid = pidOfWindowUnderCursor(point);
    double hitTestMs = nowMs() - tHit0;  // TEMP PROFILING
    if (pid != -1 && pid != frontmostPID() &&
        ![controller shouldSkipFocusForPID:pid event:event]) {
        focusAppWindow(pid, point, hitTestMs);

        if ([controller hoverPrimingEnabled]) {
            // Capture click-state so double-click detection survives the re-post.
            int64_t clickState = CGEventGetIntegerValueField(event, kCGMouseEventClickState);
            // Consume the original down; schedule a clean move→down→up on the
            // next run-loop tick so our synthetics never interleave with the
            // in-flight event.
            dispatch_async(dispatch_get_main_queue(), ^{
                CGEventRef mv   = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                                          point, kCGMouseButtonLeft);
                CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown,
                                                          point, kCGMouseButtonLeft);
                CGEventRef up   = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp,
                                                          point, kCGMouseButtonLeft);
                if (down) CGEventSetIntegerValueField(down, kCGMouseEventClickState, clickState);
                if (up)   CGEventSetIntegerValueField(up,   kCGMouseEventClickState, clickState);
                // Tag all three so the tap's passthrough guard above ignores them.
                if (mv)   CGEventSetIntegerValueField(mv,   kCGEventSourceUserData, kPCFSyntheticTag);
                if (down) CGEventSetIntegerValueField(down, kCGEventSourceUserData, kPCFSyntheticTag);
                if (up)   CGEventSetIntegerValueField(up,   kCGEventSourceUserData, kPCFSyntheticTag);
                if (mv)   { CGEventPost(kCGHIDEventTap, mv);   CFRelease(mv);   }
                if (down) { CGEventPost(kCGHIDEventTap, down); CFRelease(down); }
                if (up)   { CGEventPost(kCGHIDEventTap, up);   CFRelease(up);   }
            });
            return NULL; // original consumed; synthetic sequence replaces it
        }
    }
    return event;
}

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
