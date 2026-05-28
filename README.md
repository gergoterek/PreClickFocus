# PreClickFocus

A native macOS menu bar utility that focuses and raises a window the moment you click on it — before the click is delivered — so your first click always lands correctly.

## What it does

On macOS, clicking on a background window typically activates it but may not perform the intended action (button press, text field focus, etc.) until a second click. PreClickFocus intercepts the left mouse button down event, detects if the target window is not frontmost, raises it immediately, and then lets the original click through — so the first click always acts on the now-focused window.

**Hovering over windows does nothing.** Only actual clicks trigger the focus behavior.

## Requirements

- macOS 12 Monterey or later
- Xcode command-line tools (`xcode-select --install`)
- Accessibility permission (granted in System Settings → Privacy & Security → Accessibility)

## Tech Stack

- Objective-C++ (`.mm`)
- AppKit (menu bar, `NSStatusBar`, `NSRunningApplication`)
- CoreGraphics (`CGEventTap` for system-wide click interception)
- Accessibility APIs (`AXUIElement`, `AXIsProcessTrustedWithOptions`)
- ServiceManagement (Launch at Login)

## Building

```bash
# Build the .app bundle
make

# Or install the binary to /usr/local/bin
make install
```

> **Note:** The app must NOT be sandboxed. A system-wide `CGEventTap` (required for intercepting clicks before they reach other apps) is blocked by the macOS sandbox.

## Architecture

The entire app lives in a single `PreClickFocus.mm` file (Objective-C++) compiled with `clang++`.

| Component | Responsibility |
|-----------|---------------|
| `main()` | NSApplication bootstrap, sets activation policy to `.accessory` (no Dock icon) |
| `AppDelegate` | App lifecycle; checks Accessibility permission once at launch |
| `StatusBarController` | Menu bar icon and menu (Enable/Disable, Launch at Login, Quit) |
| `EventTapController` | Installs `CGEventTap`; on `leftMouseDown`, raises non-frontmost window under cursor before forwarding the event |

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
