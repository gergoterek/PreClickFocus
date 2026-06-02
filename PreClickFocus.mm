#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>

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
@end

@implementation AppController {
    NSStatusItem       *_statusItem;
    NSMenuItem         *_toggleItem;
    NSMenuItem         *_loginItem;
    CFMachPortRef       _tap;
    CFRunLoopSourceRef  _tapSource;
    BOOL                _enabled;
    BOOL                _userEnabled;
    NSSet<NSString *>  *_ignoreApps;
    DisableKeyMode      _disableKey;
}

- (void)loadConfig {
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

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type,
                                   CGEventRef event, void *refcon) {
    AppController *controller = (__bridge AppController *)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [controller reEnableTap];
        return NULL;
    }
    if (type != kCGEventLeftMouseDown) return event;
    CGPoint point = CGEventGetLocation(event);
    pid_t pid = pidOfWindowUnderCursor(point);
    if (pid != -1 && pid != frontmostPID() &&
        ![controller shouldSkipFocusForPID:pid event:event]) {
        NSLog(@"PreClickFocus: attempting focus on PID %d", pid);
        focusAppWindow(pid, point);
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
