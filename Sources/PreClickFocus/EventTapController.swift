import AppKit
import CoreGraphics

/// Installs a system-wide CGEventTap that intercepts left mouse down events.
/// When a click targets a non-frontmost normal window, that window is raised
/// before the event is forwarded, so the first click lands on the active window.
final class EventTapController {

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init() {
        install()
    }

    deinit {
        remove()
    }

    // MARK: - Tap lifecycle

    private func install() {
        // TODO: Implement CGEventTap installation
        // - Event mask: leftMouseDown
        // - Placement: kCGHIDEventTap (before the window server delivers the event)
        // - Callback: EventTapController.eventTapCallback
    }

    private func remove() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
        }
    }

    // MARK: - Event handling

    // TODO: Implement the tap callback:
    // 1. Get cursor position from the event.
    // 2. Find the window under the cursor via CGWindowListCopyWindowInfo.
    // 3. If its owning app is not the frontmost app, activate it via
    //    NSRunningApplication(processIdentifier:).activate(options:).
    // 4. Return the original event unchanged so the click is delivered normally.
}
