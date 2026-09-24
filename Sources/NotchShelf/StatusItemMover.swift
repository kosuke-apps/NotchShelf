import AppKit

/// Rearranges the menu bar by synthesising the command-drag a person would make.
///
/// This is the only mechanism macOS accepts, and it comes at a price: the events have to go
/// through the HID tap, which drags the real pointer along with them. The pointer is hidden for
/// the second it takes and put back exactly where it was, but it is still the user's pointer,
/// which is why nothing here runs unless they have explicitly allowed it.
enum StatusItemMover {
    private static let steps = 20
    private static let stepDelay: useconds_t = 16_000

    static func drag(from source: CGPoint, to target: CGPoint) {
        guard let events = CGEventSource(stateID: .combinedSessionState) else { return }
        let commandKey: CGKeyCode = 0x37

        let origin = CGEvent(source: nil)?.location
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let origin {
                CGWarpMouseCursorPosition(origin)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            CGDisplayShowCursor(CGMainDisplayID())
        }

        post(CGEvent(keyboardEventSource: events, virtualKey: commandKey, keyDown: true))
        usleep(60_000)
        post(mouse(.leftMouseDown, at: source, source: events))
        usleep(120_000)

        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            post(mouse(.leftMouseDragged,
                       at: CGPoint(x: source.x + (target.x - source.x) * t, y: source.y),
                       source: events))
            usleep(stepDelay)
        }

        usleep(120_000)
        post(mouse(.leftMouseUp, at: target, source: events))
        usleep(60_000)
        post(CGEvent(keyboardEventSource: events, virtualKey: commandKey, keyDown: false))
    }

    private static func mouse(_ type: CGEventType, at point: CGPoint,
                              source: CGEventSource) -> CGEvent? {
        let event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)
        event?.flags = .maskCommand
        return event
    }

    private static func post(_ event: CGEvent?) {
        event?.flags.insert(.maskCommand)
        event?.post(tap: .cghidEventTap)
    }
}

/// Pulls one swallowed item back into the drawn part of the bar.
final class MoveCoordinator {
    private let queue = DispatchQueue(label: "NotchShelf.move", qos: .userInitiated)
    private(set) var isBusy = false

    var willBegin: (() -> Void)?
    var didFinish: (() -> Void)?
    var log: ((String) -> Void)?
    var onImmovable: ((String) -> Void)?
    var knownImmovable: () -> Set<String> = { [] }

    /// The target itself cannot be grabbed — macOS never draws it. What can be grabbed is a
    /// drawn item, and dropping one to the target's left shifts the target right.
    ///
    /// Visibility is purely positional, so everything between the target and the notch surfaces
    /// along with it, and exactly as many items go the other way. Those are taken from the edge
    /// of the notch outwards, so what disappears is whatever was already closest to falling off.
    func bringOut(_ target: StatusItem, geometry: MenuBarGeometry, excluding protected: Set<String>) {
        run { [weak self] in
            guard let self else { return }
            var immovable = self.knownImmovable()

            for round in 1...8 {
                let snapshot = MenuBarScanner.scan(geometry: geometry)
                if snapshot.visible.contains(where: { $0.windowID == target.windowID }) {
                    self.log?("\(target.displayName) is back in the menu bar (\(round - 1) moves)")
                    return
                }
                guard let current = snapshot.swallowedByNotch
                    .first(where: { $0.windowID == target.windowID }) else { return }
                // Take the item sitting closest to the notch — the one that was next in line to
                // fall off anyway. Picking the widest item instead would need fewer moves, but
                // it sacrifices whichever item happens to be biggest rather than the one the
                // user already pushed to the edge, which is not a trade worth making.
                guard let victim = snapshot.visible
                    .filter({ !protected.contains($0.name) && !immovable.contains($0.name) })
                    .min(by: { $0.cgFrame.minX < $1.cgFrame.minX }) else {
                    self.log?("nothing movable left to swap with \(target.displayName)")
                    return
                }
                // Drop onto the item currently left of the target: aiming at empty space, or at
                // the gap beside the notch, is not a position macOS recognises.
                let index = snapshot.all.firstIndex { $0.windowID == current.windowID } ?? 0
                let dropX = index > 0 ? snapshot.all[index - 1].cgFrame.midX
                                      : max(geometry.menuBar.minX + 12, current.cgFrame.minX - 12)

                self.log?("bringing out \(target.displayName); \(victim.displayName) goes in")
                StatusItemMover.drag(from: CGPoint(x: victim.cgFrame.midX, y: victim.cgFrame.midY),
                                     to: CGPoint(x: dropX, y: victim.cgFrame.midY))
                usleep(250_000)

                let moved = MenuBarScanner.scan(geometry: geometry).all
                    .first { $0.windowID == victim.windowID }
                if moved == nil || moved!.cgFrame.minX == victim.cgFrame.minX {
                    immovable.insert(victim.name)
                    self.onImmovable?(victim.name)
                    self.log?("  \(victim.displayName) will not move — macOS pins it")
                }
            }
        }
    }

    private func run(_ work: @escaping () -> Void) {
        guard !isBusy else { return }
        isBusy = true
        willBegin?()
        queue.async { [weak self] in
            work()
            usleep(300_000)
            DispatchQueue.main.async {
                self?.isBusy = false
                self?.didFinish?()
            }
        }
    }
}
