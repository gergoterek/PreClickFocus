#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

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

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable((CFMachPortRef)refcon, true);
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

static void checkAccessibilityPermission(void) {
    NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    if (!trusted) {
        // Show a blocking alert so the user knows what to do.
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Accessibility Permission Required";
            alert.informativeText =
                @"PreClickFocus needs Accessibility access to focus windows on click.\n\n"
                @"Open System Settings > Privacy & Security > Accessibility and enable PreClickFocus, "
                @"then relaunch the app.";
            alert.alertStyle = NSAlertStyleWarning;
            [alert addButtonWithTitle:@"Open System Settings"];
            [alert addButtonWithTitle:@"Quit"];
            NSModalResponse resp = [alert runModal];
            if (resp == NSAlertFirstButtonReturn) {
                [[NSWorkspace sharedWorkspace] openURL:
                    [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
            }
            [NSApp terminate:nil];
        });
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        checkAccessibilityPermission();

        // Install the event tap only if we're trusted.
        if (AXIsProcessTrusted()) {
            CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown);
            CFMachPortRef tap = CGEventTapCreate(
                kCGHIDEventTap,
                kCGHeadInsertEventTap,
                kCGEventTapOptionDefault,
                mask,
                eventTapCallback,
                NULL);

            if (!tap) {
                fprintf(stderr, "PreClickFocus: failed to create event tap. Check Accessibility permission.\n");
                return 1;
            }

            // Pass tap as refcon so the callback can re-enable it on timeout.
            // CGEventTapCreate returns a retained MachPort; we store it in static so it
            // stays alive for the lifetime of the process.
            static CFMachPortRef globalTap;
            globalTap = tap;

            // Re-create tap with refcon set to itself now that we have the port.
            CFRelease(tap);
            tap = CGEventTapCreate(
                kCGHIDEventTap,
                kCGHeadInsertEventTap,
                kCGEventTapOptionDefault,
                mask,
                eventTapCallback,
                NULL);
            globalTap = tap;

            CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
            CGEventTapEnable(tap, true);
            CFRelease(src);

            printf("PreClickFocus: running (PID %d)\n", getpid());
        }

        [app run];
    }
    return 0;
}
