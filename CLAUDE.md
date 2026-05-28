# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Working Directory

Always work directly inside `/Users/gergoterek/Movies/OBS/Claude/PreClickFocus`.

## Autonomy

- Do not ask for confirmation before normal development steps (file edits, builds, tests, linting).
- Use auto-approve behavior for normal file edits when the session allows it.

## Git Workflow

After every meaningful completed change, run in order:

```
/usr/bin/git add -A
/usr/bin/git commit -m "<Clear short commit message>"
/usr/bin/git push origin main
```

- If there are no changes, do not create an empty commit.
- If push fails because the remote has newer changes, run:

```
/usr/bin/git pull --rebase --autostash origin main
/usr/bin/git push origin main
```

## Hard Constraints

- Never use `sudo`.
- Never run commands that require admin privileges or a password.
- Never change code signing settings or certificates.
- Never delete important project files.
- Do not use private/undocumented macOS APIs in the MVP.
- Do not copy GPL-licensed code (e.g. from AutoRaise).
- Do not implement hover focus — hovering over windows must do nothing.
- Do not poll mouse movement.
- Do not warp the mouse cursor.

## App: PreClickFocus

**Goal:** A native macOS menu bar utility.

**Behavior:** When the user left-clicks on a non-frontmost normal window under the cursor, focus and raise that window immediately before the original click is delivered to it.

**Tech stack:** Swift · AppKit · CoreGraphics · Accessibility APIs

### Architecture

```
PreClickFocus/
├── Package.swift                       # Swift Package Manager manifest
├── PreClickFocus.entitlements          # Hardened Runtime entitlements
└── Sources/PreClickFocus/
    ├── main.swift                      # Entry point, NSApplication bootstrap
    ├── AppDelegate.swift               # App lifecycle, permission check
    ├── StatusBarController.swift       # NSStatusBar menu bar item
    └── EventTapController.swift        # CGEventTap — intercepts left mouse down
```

**Core mechanism:**

1. `EventTapController` installs a `CGEventTap` at `kCGHIDEventTap` listening for `leftMouseDown`.
2. On each event, determine the window under the cursor via `CGWindowListCopyWindowInfo` + hit-test.
3. If that window belongs to a non-frontmost app, call `AXUIElementPerformAction(raise)` / `NSRunningApplication.activate()` before returning the event.
4. Hovering triggers no action — only actual clicks are intercepted.

**Required permission:** Accessibility — requested at runtime via `AXIsProcessTrustedWithOptions`. The app must NOT be sandboxed (sandboxing blocks system-wide `CGEventTap`).
