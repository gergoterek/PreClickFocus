#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>
#import <math.h>

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

static void focusAppWindow(pid_t pid, CGPoint point) {
    AXUIElementRef appElement = AXUIElementCreateApplication(pid);
    if (!appElement) return;
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
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSString *name = app.localizedName ?: @"?";
    if (@available(macOS 14.0, *)) {
        [app activateFromApplication:[NSRunningApplication currentApplication]
                             options:0];
    } else {
        [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    }
    printf("PreClickFocus: focused PID %d (%s)\n", pid, name.UTF8String);
    NSLog(@"PreClickFocus: focused PID %d (%@)", pid, name);
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
- (NSInteger)preNudgeMs;
- (NSInteger)hoverWaitMs;
- (NSInteger)clickWaitMs;
@end

@implementation AppController {
    NSStatusItem       *_statusItem;
    NSMenuItem         *_toggleItem;
    NSMenuItem         *_loginItem;
    CFMachPortRef       _tap;
    CFRunLoopSourceRef  _tapSource;
    BOOL                _enabled;
    BOOL                _userEnabled;
    BOOL                _hoverPrimingEnabled;   // default NO
    NSInteger           _preNudgeMs;            // default 80
    NSInteger           _hoverWaitMs;           // default 300
    NSInteger           _clickWaitMs;           // default 50
    NSTextField        *_preNudgeLabel;
    NSTextField        *_hoverWaitLabel;
    NSTextField        *_clickWaitLabel;
    NSSet<NSString *>  *_ignoreApps;
    DisableKeyMode      _disableKey;
}

- (void)loadConfig {
    _hoverPrimingEnabled = NO;
    _preNudgeMs  = 80;
    _hoverWaitMs = 300;
    _clickWaitMs = 50;
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
            _hoverPrimingEnabled = [value isEqualToString:@"true"];
        } else if ([key isEqualToString:@"preNudgeMs"]) {
            NSInteger v = value.integerValue; if (v < 0) v = 0; if (v > 2000) v = 2000; _preNudgeMs = v;
        } else if ([key isEqualToString:@"hoverWaitMs"]) {
            NSInteger v = value.integerValue; if (v < 0) v = 0; if (v > 2000) v = 2000; _hoverWaitMs = v;
        } else if ([key isEqualToString:@"clickWaitMs"]) {
            NSInteger v = value.integerValue; if (v < 0) v = 0; if (v > 2000) v = 2000; _clickWaitMs = v;
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
}

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
    [self setupStatusBar];

    // Always attempt tap creation directly.
    // CGEventTapCreate has its own TCC check that works even when
    // AXIsProcessTrusted() gives a stale result.
    [self installEventTap];

    if (_enabled) {
        // Tap installed successfully — sync the menu to show Enabled.
        [self rebuildMenu];
        return;
    }

    // Tap creation failed — not trusted yet.
    // Register in System Settings and show the native permission dialog.
    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);

    // Poll every second, retrying tap creation until it succeeds.
    __weak AppController *weakSelf = self;
    [NSTimer scheduledTimerWithTimeInterval:1.0
                                    repeats:YES
                                      block:^(NSTimer *t) {
        AppController *s = weakSelf;
        if (!s) { [t invalidate]; return; }
        [s installEventTap];
        if (s->_enabled) {
            [t invalidate];
            [s rebuildMenu];
            NSLog(@"PreClickFocus: permission granted, tap installed");
        }
    }];
}

- (void)setupStatusBar {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"cursorarrow.click" accessibilityDescription:@"PreClickFocus"];
    if (!icon) icon = [NSImage imageWithSystemSymbolName:@"cursorarrow.rays" accessibilityDescription:@"PreClickFocus"];
    if (icon) { [icon setTemplate:YES]; _statusItem.button.image = icon; }
    else { _statusItem.button.title = @"PCF"; }
    // Show menu on both left and right click.
    [_statusItem.button sendActionOn:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown];
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
    // Restart Tap — manually re-creates the event tap (useful if it gets stuck).
    NSMenuItem *restartItem = [[NSMenuItem alloc] initWithTitle:@"Restart Tap"
                                                         action:@selector(restartTap:)
                                                  keyEquivalent:@"r"];
    restartItem.target  = self;
    restartItem.enabled = YES;
    [menu addItem:restartItem];
    [menu addItem:[NSMenuItem separatorItem]];
    // ── Hover Priming submenu ────────────────────────────────────────────────
    NSMenuItem *hoverParent = [[NSMenuItem alloc] initWithTitle:@"Hover Priming" action:nil keyEquivalent:@""];
    hoverParent.enabled = YES;
    NSMenu *hoverSubmenu = [[NSMenu alloc] init];
    [hoverSubmenu setAutoenablesItems:NO];
    NSMenuItem *hoverToggle = [[NSMenuItem alloc] initWithTitle:@"Enabled"
                                                         action:@selector(toggleHoverPriming:)
                                                  keyEquivalent:@""];
    hoverToggle.target  = self;
    hoverToggle.state   = _hoverPrimingEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    hoverToggle.enabled = YES;
    [hoverSubmenu addItem:hoverToggle];
    [hoverSubmenu addItem:[NSMenuItem separatorItem]];
    [hoverSubmenu addItem:[self sliderItemWithTitle:@"Pre-nudge"  value:_preNudgeMs  label:&_preNudgeLabel  action:@selector(preNudgeSliderChanged:)]];
    [hoverSubmenu addItem:[self sliderItemWithTitle:@"Hover wait" value:_hoverWaitMs label:&_hoverWaitLabel action:@selector(hoverWaitSliderChanged:)]];
    [hoverSubmenu addItem:[self sliderItemWithTitle:@"Click wait" value:_clickWaitMs label:&_clickWaitLabel action:@selector(clickWaitSliderChanged:)]];
    [hoverParent setSubmenu:hoverSubmenu];
    [menu addItem:hoverParent];
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

// ── Hover priming accessors (called from C callback) ─────────────────────────

- (BOOL)hoverPrimingEnabled { return _hoverPrimingEnabled; }
- (NSInteger)preNudgeMs     { return _preNudgeMs; }
- (NSInteger)hoverWaitMs    { return _hoverWaitMs; }
- (NSInteger)clickWaitMs    { return _clickWaitMs; }

// ── Generic slider menu item builder ─────────────────────────────────────────

- (NSMenuItem *)sliderItemWithTitle:(NSString *)title
                              value:(NSInteger)value
                              label:(NSTextField * __strong *)labelOut
                             action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] init];
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 56)];
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 32, 200, 18)];
    label.editable = NO; label.bordered = NO;
    label.backgroundColor = [NSColor clearColor];
    label.stringValue = [NSString stringWithFormat:@"%@: %ld ms", title, (long)value];
    [container addSubview:label];
    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(20, 8, 200, 20)];
    slider.minValue = 0; slider.maxValue = 2000;
    slider.doubleValue = (double)value;
    slider.target = self; slider.action = action;
    slider.continuous = YES;
    [container addSubview:slider];
    item.view = container;
    item.enabled = YES;
    *labelOut = label;
    return item;
}

// ── Slider actions ────────────────────────────────────────────────────────────

- (void)preNudgeSliderChanged:(NSSlider *)s {
    _preNudgeMs = (NSInteger)llround(s.doubleValue / 10.0) * 10;
    _preNudgeLabel.stringValue = [NSString stringWithFormat:@"Pre-nudge: %ld ms", (long)_preNudgeMs];
}

- (void)hoverWaitSliderChanged:(NSSlider *)s {
    _hoverWaitMs = (NSInteger)llround(s.doubleValue / 10.0) * 10;
    _hoverWaitLabel.stringValue = [NSString stringWithFormat:@"Hover wait: %ld ms", (long)_hoverWaitMs];
}

- (void)clickWaitSliderChanged:(NSSlider *)s {
    _clickWaitMs = (NSInteger)llround(s.doubleValue / 10.0) * 10;
    _clickWaitLabel.stringValue = [NSString stringWithFormat:@"Click wait: %ld ms", (long)_clickWaitMs];
}

// ── Hover priming toggle ──────────────────────────────────────────────────────

- (void)toggleHoverPriming:(id)sender {
    _hoverPrimingEnabled = !_hoverPrimingEnabled;
    [sender setState:_hoverPrimingEnabled ? NSControlStateValueOn : NSControlStateValueOff];
    NSLog(@"PreClickFocus: hoverPriming = %s", _hoverPrimingEnabled ? "on" : "off");
}

// ── Restart tap ───────────────────────────────────────────────────────────────

- (void)restartTap:(id)sender {
    [self removeEventTap];
    [self installEventTap];
    if (_enabled) {
        _toggleItem.title = @"PreClickFocus: Enabled";
        _toggleItem.state = NSControlStateValueOn;
        NSLog(@"PreClickFocus: tap restarted");
    }
}

- (void)installEventTap {
    if (_tap && CFMachPortIsValid(_tap)) return;
    if (_tap) [self removeEventTap];
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown);
    _tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                            mask, eventTapCallback, (__bridge void *)self);
    if (!_tap) {
        fprintf(stderr, "PreClickFocus: failed to create event tap. Check Accessibility permission.\n");
        NSLog(@"PreClickFocus: FAILED to create event tap (not trusted or denied)");
        _enabled = NO;
        return;
    }
    _tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), _tapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    _enabled     = YES;
    _userEnabled = YES;
    printf("PreClickFocus: running (PID %d)\n", getpid());
    NSLog(@"PreClickFocus: running (PID %d)", getpid());
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

// Marker on synthetic events we post — lets the tap skip re-processing them.
static const int64_t kPCFSyntheticTag = 0x50434600; // "PCF\0"

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type,
                                   CGEventRef event, void *refcon) {
    AppController *controller = (__bridge AppController *)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [controller reEnableTap];
        return NULL;
    }
    // Skip synthetic events we posted to avoid feedback loops.
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kPCFSyntheticTag)
        return event;

    if (type != kCGEventLeftMouseDown) return event;
    CGPoint point = CGEventGetLocation(event);
    pid_t pid = pidOfWindowUnderCursor(point);
    if (pid != -1 && pid != frontmostPID() &&
        ![controller shouldSkipFocusForPID:pid event:event]) {
        NSLog(@"PreClickFocus: attempting focus on PID %d", pid);
        focusAppWindow(pid, point);

        if (![controller hoverPrimingEnabled]) {
            // Fast path — no hover priming, return original event unchanged.
            return event;
        }

        // Hover priming ON: consume original click and replace it with a
        // physically-moved cursor + timed synthetic click sequence.
        int64_t clickState = CGEventGetIntegerValueField(event, kCGMouseEventClickState);
        NSInteger preN   = [controller preNudgeMs];
        NSInteger hoverW = [controller hoverWaitMs];
        NSInteger clickW = [controller clickWaitMs];
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(preN * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                CGDisplayMoveCursorToPoint(CGMainDisplayID(), point);
                // Also post a real mouseMoved event so NSTrackingArea and
                // Electron/Chrome apps receive the hover callback.
                CGEventRef moveEvent = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                                               point, kCGMouseButtonLeft);
                if (moveEvent) {
                    CGEventSetIntegerValueField(moveEvent, kCGEventSourceUserData, kPCFSyntheticTag);
                    CGEventPost(kCGHIDEventTap, moveEvent);
                    CFRelease(moveEvent);
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hoverW * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), ^{
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(clickW * NSEC_PER_MSEC)),
                                   dispatch_get_main_queue(), ^{
                        CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
                        CGEventRef up   = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp,   point, kCGMouseButtonLeft);
                        if (down) CGEventSetIntegerValueField(down, kCGMouseEventClickState, clickState);
                        if (up)   CGEventSetIntegerValueField(up,   kCGMouseEventClickState, clickState);
                        if (down) CGEventSetIntegerValueField(down, kCGEventSourceUserData, kPCFSyntheticTag);
                        if (up)   CGEventSetIntegerValueField(up,   kCGEventSourceUserData, kPCFSyntheticTag);
                        if (down) { CGEventPost(kCGHIDEventTap, down); CFRelease(down); }
                        if (up)   { CGEventPost(kCGHIDEventTap, up);   CFRelease(up);   }
                    });
                });
            });
        });
        return NULL; // original consumed; synthetic sequence replaces it
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
