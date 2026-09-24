import AppKit

/// One status item as the WindowServer sees it.
///
/// On macOS 26 every status item — Apple's and third parties' alike — is composited by the
/// Control Center process, so `ownerName` is never the app that created it. The window's
/// *name* is the item's `NSStatusItem.autosaveName`, which many apps do set; the ones that
/// don't fall back to a positional "Item-N" label.
struct StatusItem: Equatable {
    let windowID: CGWindowID
    let name: String
    /// Top-left origin, global. This is where macOS *thinks* the item is, even when it
    /// refuses to draw it.
    let cgFrame: CGRect
    let isOnScreen: Bool
    let ownerPID: pid_t
    let ownerName: String

    var nsFrame: CGRect { Coord.toNS(cgFrame) }

    /// Apps that never set an autosaveName are indistinguishable from each other by name.
    var hasUsefulName: Bool { !name.isEmpty && !name.hasPrefix("Item-") }

    var displayName: String {
        hasUsefulName ? name.replacingOccurrences(of: "_", with: " ") : "Unnamed item"
    }

    /// Single-character fallback badge for when we have no captured image.
    var badge: String {
        guard hasUsefulName, let first = displayName.first else { return "?" }
        return String(first).uppercased()
    }
}

struct MenuBarSnapshot {
    /// Every status item, left to right.
    let all: [StatusItem]
    /// Drawn and clickable.
    let visible: [StatusItem]
    /// Positioned at or left of the notch, so macOS drops them entirely — the bug we exist for.
    let swallowedByNotch: [StatusItem]
    /// Offscreen but positioned right of the notch: the owning app hid these on purpose.
    let hiddenByOwner: [StatusItem]

    static let empty = MenuBarSnapshot(all: [], visible: [], swallowedByNotch: [], hiddenByOwner: [])
}

enum MenuBarScanner {
    /// Status items live on their own window layer.
    static let statusItemLayer = 25

    /// What carries over from one scan to the next: where macOS stopped drawing, and which
    /// items their own apps had hidden, as last seen with the menu bar on screen. Needed while
    /// it is not — see `classify`.
    struct Memory: Equatable {
        var cutoff: CGFloat?
        var ownerHidden: Set<CGWindowID> = []
    }

    /// Persisted, so a launch that happens while a full-screen app is in front still knows the
    /// boundary. Written only when it changes: the scan runs every second.
    private static var memory = Memory(cutoff: {
        let value = UserDefaults.standard.double(forKey: "lastDrawingCutoff")
        return value > 0 ? CGFloat(value) : nil
    }()) {
        didSet {
            guard memory.cutoff != oldValue.cutoff else { return }
            UserDefaults.standard.set(memory.cutoff.map(Double.init) ?? 0, forKey: "lastDrawingCutoff")
        }
    }

    /// The last classification worth trusting, reused while a scan cannot be.
    private static var lastGood: MenuBarSnapshot = .empty

    static func scan(geometry: MenuBarGeometry) -> MenuBarSnapshot {
        let options: CGWindowListOption = [.optionAll]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return .empty
        }

        var items: [StatusItem] = []
        for window in raw {
            guard window[kCGWindowLayer as String] as? Int == statusItemLayer,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            // While Spaces switch, macOS slides stand-in copies of the status items across the
            // screen. They are not items, and their coordinates are mid-animation nonsense.
            if window[kCGWindowName as String] as? String == "System Status Item Clone" { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                               width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            // Guard against anything odd that shares the layer.
            guard frame.height > 10, frame.height < 80, frame.width > 0 else { continue }
            items.append(StatusItem(
                windowID: CGWindowID(exactly: window[kCGWindowNumber as String] as? Int ?? 0) ?? 0,
                name: window[kCGWindowName as String] as? String ?? "",
                cgFrame: frame,
                isOnScreen: window[kCGWindowIsOnscreen as String] as? Bool ?? false,
                ownerPID: pid_t(window[kCGWindowOwnerPID as String] as? Int ?? 0),
                ownerName: window[kCGWindowOwnerName as String] as? String ?? ""))
        }
        // A scan can catch the bar mid-movement. While Spaces slide, the real items are reported
        // hundreds of points off-screen (x=2923 and x=-686 were both observed), and classifying
        // those frames — or learning the boundary from them — made the shelf's contents jump
        // between 0 and 4 items from one second to the next. Such a frame is not a layout, so
        // the previous one stands.
        guard isPlausible(items, screenMaxX: geometry.menuBar.maxX) else { return lastGood }

        // Measured on a 14" M1 Pro: swallowed items started as far right as x=1029 and drawn
        // ones as far left as x=1036, with the notch ending at x=1010. This threshold sits in
        // that gap and is only used before the real boundary has ever been seen.
        let threshold = (geometry.notch?.maxX ?? geometry.menuBar.maxX) + 24
        lastGood = classify(items, memory: &memory, fallbackThreshold: threshold)
        return lastGood
    }

    /// Whether a scan describes a menu bar at rest. The status items always end flush with the
    /// right edge of the screen and never leave it; anything else is a frame caught mid-animation.
    static func isPlausible(_ items: [StatusItem], screenMaxX: CGFloat) -> Bool {
        guard let rightEdge = items.map(\.cgFrame.maxX).max() else { return false }
        guard abs(rightEdge - screenMaxX) <= 40 else { return false }
        return !items.contains { $0.cgFrame.minX < -20 || $0.cgFrame.maxX > screenMaxX + 20 }
    }

    /// Sorts status items into drawn, swallowed by the notch, and hidden by their own app.
    ///
    /// Where macOS stops drawing is not exactly the notch edge — on a 14" M1 Pro an item
    /// starting at x=1016 was dropped although the notch ends at x=1010 — so it is read off the
    /// layout instead: the leftmost item actually being drawn.
    ///
    /// That only works while the menu bar is on screen. With a full-screen app in front, or the
    /// menu bar set to hide, every status item reports itself off screen even though the layout
    /// is exactly the same; reading the boundary from that found nothing hidden at all, which
    /// left the shelf empty on every Space but the plain desktop. So the boundary is kept in
    /// `memory` from the last time it could be seen, and reused while it cannot.
    static func classify(_ unsorted: [StatusItem], memory: inout Memory,
                         fallbackThreshold: CGFloat) -> MenuBarSnapshot {
        let items = unsorted.sorted { $0.cgFrame.minX < $1.cgFrame.minX }
        let drawn = items.filter(\.isOnScreen)
        let menuBarShowing = !drawn.isEmpty

        let cutoff: CGFloat
        if let leftmost = drawn.map(\.cgFrame.minX).min() {
            cutoff = leftmost
            memory.cutoff = leftmost
            memory.ownerHidden = Set(items.filter { !$0.isOnScreen && $0.cgFrame.minX >= leftmost }
                .map(\.windowID))
        } else if let remembered = memory.cutoff {
            cutoff = remembered
        } else {
            // Never seen the menu bar on screen: take the first item that would sit past the
            // threshold. The chain below needs a real item edge to start from, not a guess.
            cutoff = items.first { $0.cgFrame.minX >= fallbackThreshold }?.cgFrame.minX
                ?? fallbackThreshold
        }

        // Genuinely swallowed items form one unbroken run leftwards from the boundary, each
        // butting up against the next. Walking that chain keeps out the stale windows some apps
        // leave parked at x=0, which have no place in the layout.
        let toTheLeft = items
            .filter { $0.cgFrame.minX < cutoff && !($0.isOnScreen && menuBarShowing) }
            .sorted { $0.cgFrame.minX > $1.cgFrame.minX }
        var chained: Set<CGWindowID> = []
        var edge = cutoff
        let tolerance: CGFloat = 8
        for item in toTheLeft where abs(item.cgFrame.maxX - edge) <= tolerance {
            chained.insert(item.windowID)
            edge = item.cgFrame.minX
        }

        var visible: [StatusItem] = [], swallowed: [StatusItem] = [], byOwner: [StatusItem] = []
        for item in items {
            if chained.contains(item.windowID) {
                swallowed.append(item)
            } else if item.cgFrame.minX < cutoff {
                byOwner.append(item)        // off in the layout's margins, not in a real slot
            } else if menuBarShowing ? item.isOnScreen : !memory.ownerHidden.contains(item.windowID) {
                visible.append(item)
            } else {
                byOwner.append(item)
            }
        }
        return MenuBarSnapshot(all: items, visible: visible,
                               swallowedByNotch: swallowed, hiddenByOwner: byOwner)
    }
}

extension MenuBarScanner {
    /// The menu bar hides itself in full screen (and when auto-hide is on). While it is gone,
    /// the notch belongs to whatever app is on screen, so we must not sit on clicks there.
    static var isMenuBarShowing: Bool {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.contains { window in
            window[kCGWindowLayer as String] as? Int == 24
                && window[kCGWindowName as String] as? String == "Menubar"
                && window[kCGWindowIsOnscreen as String] as? Bool == true
        }
    }
}
