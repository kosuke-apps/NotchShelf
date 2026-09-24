import AppKit

/// Accessibility gate. Moving items means synthesising a command-drag, which macOS only lets a
/// trusted process do.
enum Activator {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
