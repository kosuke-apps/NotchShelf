# Third-party material

NotchShelf contains no third-party code, data, fonts, or models. It uses only frameworks that
ship with macOS:

| Framework | Used for |
|---|---|
| AppKit | windows, drawing, menus |
| ApplicationServices (Accessibility) | finding which app owns each menu bar item, and opening it |
| CoreGraphics | reading the menu bar layout, noticing a click on the notch, Bring out |
| ScreenCaptureKit | copying the icons of the items behind the notch |
| Foundation | settings and the log file |
| Swift Testing (tests only) | unit tests; part of the Swift toolchain, not shipped with the app |

The Swift package declares no dependencies (see `Package.swift`). The app icon is drawn by
`Scripts/make-icon.swift` in this repository.
