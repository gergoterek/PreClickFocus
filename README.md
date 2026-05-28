# PreClickFocus

A native macOS menu bar utility that focuses and raises a window the moment you click on it — before the click is delivered — so your first click always lands correctly.

## What it does

On macOS, clicking on a background window typically activates it but may not perform the intended action (button press, text field focus, etc.) until a second click. PreClickFocus intercepts the left mouse button down event, detects if the target window is not frontmost, raises it immediately, and then lets the original click through — so the first click always acts on the now-focused window.

**Hovering over windows does nothing.** Only actual clicks trigger the focus behavior.

## Requirements

- macOS 13 Ventura or later
- Xcode 15+
- Accessibility permission (granted in System Settings → Privacy & Security → Accessibility)

## Tech Stack

- Swift 5.9+
- AppKit (menu bar, `NSStatusBar`, `NSRunningApplication`)
- CoreGraphics (`CGEventTap` for system-wide click interception)
- Accessibility APIs (`AXUIElement`, `AXIsProcessTrustedWithOptions`)

## Building

```bash
# Open in Xcode
open Package.swift

# Or build from the command line
swift build -c release
```

> **Note:** The app must NOT be sandboxed. A system-wide `CGEventTap` (required for intercepting clicks before they reach other apps) is blocked by the macOS sandbox.

## Architecture

| File | Responsibility |
|------|---------------|
| `main.swift` | NSApplication bootstrap, sets activation policy to `.accessory` (no Dock icon) |
| `AppDelegate.swift` | App lifecycle; requests Accessibility permission on launch |
| `StatusBarController.swift` | Menu bar icon and menu (Enable/Disable, Quit) |
| `EventTapController.swift` | Installs `CGEventTap`; on `leftMouseDown`, raises non-frontmost window under cursor before forwarding the event |

### Event flow

```
User left-clicks
       │
       ▼
CGEventTap (kCGHIDEventTap, leftMouseDown)
       │
       ├─ Is target window already frontmost? → pass event through unchanged
       │
       └─ Non-frontmost window under cursor
              │
              ├─ Identify owning app via CGWindowListCopyWindowInfo
              ├─ Raise window via AXUIElement / NSRunningApplication.activate()
              └─ Return original event (click is delivered to now-focused window)
```

## Privacy & Permissions

PreClickFocus requires Accessibility access to read window ownership and to activate applications. It does **not** log, transmit, or store any user input or window content.
