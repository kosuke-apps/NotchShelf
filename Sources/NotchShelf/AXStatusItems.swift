import AppKit
import ApplicationServices

/// The accessibility view of the menu bar, which is the one place a notch-swallowed item is
/// still reachable.
///
/// macOS never composites an item the notch ate, so it cannot be clicked, dragged or hit-tested
/// at its coordinates. It does, however, stay in its owning app's `AXExtrasMenuBar`, complete
/// with a working `AXPress` — and the accessibility position matches the real one to the pixel,
/// hidden or not, which is what lets an entry in our shelf be tied back to the right element.
///
/// This is also where an item's owner comes from. Every status item is attributed to the
/// Control Center process in the window list, so the app that actually put it there can only be
/// learned this way.
final class AXStatusItems {
    struct Entry {
        let element: AXUIElement
        let x: CGFloat
        let width: CGFloat
        let appName: String
        let bundleID: String?
        let icon: NSImage?
        let pid: pid_t
    }

    private var entries: [Entry] = []
    private var lastScan = Date.distantPast

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Rebuilds the map. Cheap enough to call when the shelf opens; not something to do on a
    /// timer, since it touches every running app.
    func refresh(force: Bool = false) {
        guard isTrusted else { entries = []; return }
        guard force || Date().timeIntervalSince(lastScan) > 5 else { return }
        lastScan = Date()

        var found: [Entry] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier > 0 else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            // Unresponsive apps would otherwise stall the whole scan.
            AXUIElementSetMessagingTimeout(element, 0.25)
            guard let extras = copyElement(element, "AXExtrasMenuBar") else { continue }
            for child in copyChildren(extras) {
                guard let position = copyPoint(child, kAXPositionAttribute as String),
                      let size = copySize(child, kAXSizeAttribute as String) else { continue }
                found.append(Entry(element: child, x: position.x, width: size.width,
                                   appName: app.localizedName ?? "Unknown",
                                   bundleID: app.bundleIdentifier,
                                   icon: app.icon, pid: app.processIdentifier))
            }
        }
        entries = found
    }

    /// A name worth showing. Every Apple extra belongs to Control Center, so that owner name
    /// identifies nothing; the item's own autosave name is more use there.
    func label(for item: StatusItem) -> String? {
        guard let entry = entry(for: item) else { return nil }
        if entry.bundleID == "com.apple.controlcenter" || entry.bundleID == "com.apple.systemuiserver" {
            return item.hasUsefulName ? item.displayName : entry.appName
        }
        return entry.appName
    }

    /// Accessibility reports an item a pixel or so off from the window list, so matching allows
    /// a little slack.
    func entry(for item: StatusItem) -> Entry? {
        entries.min { a, b in
            abs(a.x - item.cgFrame.minX) < abs(b.x - item.cgFrame.minX)
        }.flatMap { abs($0.x - item.cgFrame.minX) <= 3 ? $0 : nil }
    }

    /// Opens the item's menu exactly as clicking it would, without moving the pointer.
    @discardableResult
    func press(_ item: StatusItem) -> Bool {
        refresh(force: true)
        guard let entry = entry(for: item) else { return false }
        return AXUIElementPerformAction(entry.element, kAXPressAction as CFString) == .success
    }

    // MARK: - Reading

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let raw = value else { return nil }
        var result = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &result) else { return nil }
        return result
    }

    private func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let raw = value else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &result) else { return nil }
        return result
    }
}
