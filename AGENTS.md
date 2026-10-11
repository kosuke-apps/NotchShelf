# NotchShelf

Instructions for agents working on this repository. Workspace rules are in `~/Developer/AGENTS.md`,
the Mac app rules in `../AGENTS.md`.

## What it is

A utility for Macs with a notch. macOS stops drawing menu bar items that do not fit to the right of
the notch. NotchShelf shows them in a shelf that drops out of the notch when the notch is clicked,
and opens them through the accessibility API. One purpose: reach the items the notch swallowed.

Hard requirements from the user:

- The notch itself is the way in. NotchShelf never occupies menu bar space: no status item of its
  own, and no window over the menu bar while the shelf is closed.
- Reliability over features. A feature that cannot be made to work reliably is left out.
- The shelf is the notch carried downwards: black, notch-wide, concave shoulders at the top of the
  display, rounded lower corners, a hairline only below the menu bar.

## Platform facts

Measured macOS behaviour, including what was tried and failed (right-clicks, reordering,
making room), is in `docs/platform-facts.md`. Read it before changing how items are found,
opened, or moved.

## Architecture

| File | Role |
|---|---|
| `main.swift` | Starts the app as an accessory (no Dock icon). |
| `AppDelegate.swift` | Wiring, the one-second refresh loop, opening and closing the shelf, the settings window, the debug hooks. |
| `Geometry.swift` | Conversion between window-list coordinates (top-left origin) and AppKit's (bottom-left); the notch from `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`. |
| `MenuBarScanner.swift` | Reads the status item windows. `classify` sorts them into drawn, swallowed by the notch, and hidden by their own app; `isPlausible` rejects scans taken mid-animation; the boundary is remembered for when the menu bar is not on screen. |
| `AXStatusItems.swift` | Every app's `AXExtrasMenuBar`: which app owns an item, and pressing it. |
| `ItemCapture.swift` | ScreenCaptureKit captures of the items' windows, in parallel, cached, trimmed to the glyph. |
| `NotchInput.swift` | Notch click detection: listen-only event tap, global monitor as fallback. |
| `NotchStrip.swift` | The shelf panel and its view: the notch-shaped outline, icons right-aligned in menu bar order, dragging to reorder, right-click menu, Option-click. |
| `SettingsWindow.swift` | Settings: shelf height, the item list with Open and Bring out, permissions. |
| `Settings.swift` | Options kept in `UserDefaults`, and the one-time carry-over from the pre-release identifier. |
| `StatusItemMover.swift` | The command-drag behind Bring out. The only code that moves the pointer. |
| `Diagnostics.swift` | The log at `~/Library/Logs/NotchShelf.log` and the diagnostics window. |
| `Activator.swift` | Accessibility trust check and prompt. |

## Commands

```sh
Scripts/install.sh       # build, sign, install to /Applications (quits the running copy)
Scripts/build-app.sh     # build and sign into build/ only
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
tail -f ~/Library/Logs/NotchShelf.log
```

Regenerating the icon:

```sh
swiftc -O Scripts/make-icon.swift -o /tmp/make-icon
/tmp/make-icon build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

Debug hooks, set with `open -a /Applications/NotchShelf.app --env NAME=value`:

| Variable | Effect |
|---|---|
| `NOTCHSHELF_AUTOSHOW` | open the shelf after launch |
| `NOTCHSHELF_SHOWSETTINGS` | open the settings window after launch |
| `NOTCHSHELF_SHOWAFTER=<seconds>` | open the shelf after a delay |
| `NOTCHSHELF_CLICKNOTCHAT=<s,s,...>` | post real clicks at the notch at those times (moves the pointer) |
| `NOTCHSHELF_INPUT=tap\|monitor\|catcher\|both` | notch detection method |

Do not run desktop-switching or clicking tests while the user is working at the Mac: their input
and the test's mix in the log, and keystrokes can reach a full-screen Screen Sharing session.

## Signing

Signed with the shared self-signed certificate `Mac Utilities Code Signing` (see `../AGENTS.md`),
so the designated requirement is the identifier plus the certificate and permissions survive
rebuilds. Never narrow the requirement to the identifier alone.

## Known gaps

- UI strings are hard-coded in English. The Japanese localization through a String Catalog, which
  the workspace rules require, is not done.
- A "parked" tier (items hidden on purpose) is on hold: making room would need spacer items, which
  macOS 26 does not reliably lay out. `Settings.parked` and `Settings.allowsPointerMoves` are
  leftovers.
