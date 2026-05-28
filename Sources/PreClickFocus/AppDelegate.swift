import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?
    private var eventTapController: EventTapController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityPermission()
        statusBarController = StatusBarController()
        eventTapController = EventTapController()
    }

    // MARK: - Accessibility

    private func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            // The system prompt has been shown; the user needs to grant access
            // in System Settings → Privacy & Security → Accessibility, then relaunch.
        }
    }
}
