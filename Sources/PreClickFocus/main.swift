import AppKit

// Manual NSApplication bootstrap — keeps the package structure simple
// and avoids @NSApplicationMain / @main on a non-AppDelegate type.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar only; no Dock icon
app.run()
