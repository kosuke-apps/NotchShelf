import AppKit

/// Turns the notch — 220pt of dead space that currently swallows clicks — into the app's
/// only affordance. Nothing is drawn there (there are no pixels behind the camera housing),
/// so this is purely about receiving the click.
///
/// Detection is by a listen-only event tap, which sees every click as it enters the session —
/// before the window server decides who gets it — and neither consumes nor alters it.
///
/// The global mouse monitor used before only sees clicks that are delivered to some other
/// application. What was observed with it: physical notch clicks were detected on the first
/// desktop and, by the user's report, not on the others, although the windows over the notch
/// were identical on every desktop; and a synthetic click at the notch went unseen on both the
/// first and second desktop. Why the monitor missed them is not established — the likeliest
/// explanation, a menu bar click that is never delivered to any app, does not account for the
/// synthetic click being missed with the Claude app in front. The tap sits upstream of all of
/// that: the same synthetic click was seen on the first, second and third desktop.
///
/// An invisible panel sitting on the notch would receive the click too, but it also swallows
/// every other event in that region, including the command-drag people use to rearrange the
/// menu bar, so there is no window over the notch.
final class NotchInput {
    enum Mode: String {
        case tap, catcher, monitor, both
    }

    private let mode: Mode
    private var panel: NSPanel?
    private var monitor: Any?
    private var modifierMonitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var geometry: MenuBarGeometry?

    var onNotchClick: (() -> Void)?
    /// Reports which mechanism actually fired, so the diagnostics window can settle the question.
    var onMechanismFired: ((String) -> Void)?

    init(mode: Mode) {
        self.mode = mode
    }

    /// True when nothing of ours sits over the menu bar.
    var isPassive: Bool { panel == nil }

    func start(geometry: MenuBarGeometry) {
        self.geometry = geometry
        guard geometry.notch != nil else { return }
        if mode == .tap {
            if !installTap() {
                // Without permission to tap the event stream, fall back to the monitor, which
                // works at least while an app that receives menu bar clicks is in front.
                Diagnostics.shared.log("Could not create the event tap; watching with a global monitor")
                installMonitor()
            }
        }
        if mode == .catcher { installCatcher(); installModifierWatch() }
        if mode == .monitor || mode == .both { installMonitor() }
    }

    func update(geometry: MenuBarGeometry) {
        self.geometry = geometry
        layoutCatcher()
    }

    /// The catcher must stand down whenever the menu bar is not showing — in full screen the
    /// notch area belongs to the app's content, and swallowing clicks there would be exactly
    /// the interference this design exists to avoid.
    func setEnabled(_ enabled: Bool) {
        guard let panel else { return }
        if enabled {
            layoutCatcher()
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: - Mechanisms

    private func installCatcher() {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        let view = ClickView()
        view.onClick = { [weak self] in
            self?.onMechanismFired?("catcher")
            self?.onNotchClick?()
        }
        panel.contentView = view
        self.panel = panel
        layoutCatcher()
        panel.orderFrontRegardless()
    }

    private func layoutCatcher() {
        guard let panel, let notch = geometry?.notch else { return }
        // The WindowServer shaves 2pt off each side of a window laid over the notch, which
        // would leave the outermost columns of the notch unclickable. Ask for a slightly
        // wider frame so the whole notch ends up covered.
        let outset = notch.insetBy(dx: -4, dy: 0)
        panel.setFrame(outset, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: panel.frame.size)
    }

    /// Command-dragging an item across the menu bar is how a person rearranges it, and the
    /// catcher sits right in the path of that gesture. While Command is held it steps aside
    /// completely, so the drag reaches the menu bar exactly as if we were not here.
    private func installModifierWatch() {
        let apply: (NSEvent.ModifierFlags) -> Void = { [weak self] flags in
            guard let panel = self?.panel else { return }
            let standAside = flags.contains(.command)
            guard panel.ignoresMouseEvents != standAside else { return }
            panel.ignoresMouseEvents = standAside
            Diagnostics.shared.log(standAside
                ? "Command held — notch click target stepped aside"
                : "Command released — notch click target active")
        }
        apply(NSEvent.modifierFlags)
        modifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { event in
            apply(event.modifierFlags)
        }
    }

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let input = Unmanaged<NotchInput>.fromOpaque(info).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // macOS switches a tap off if it ever answers too slowly; switch it back on.
                if let tap = input.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            case .leftMouseDown:
                input.handleTappedClick(at: event.location, flags: event.flags)
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.tapSource = source
        return true
    }

    /// `point` is in the tap's coordinates: global, top-left origin.
    private func handleTappedClick(at point: CGPoint, flags: CGEventFlags) {
        guard let notch = geometry?.notch, Coord.toCG(notch).contains(point) else { return }
        guard !flags.contains(.maskCommand) else { return }   // a command-drag, not a click
        onMechanismFired?("tap")
        onNotchClick?()
    }

    private func installMonitor() {
        // Mouse-only global monitors do not need the accessibility permission.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let notch = self.geometry?.notch else { return }
            let location = NSEvent.mouseLocation
            guard notch.contains(location) else { return }
            guard !event.modifierFlags.contains(.command) else { return }
            self.onMechanismFired?("monitor")
            self.onNotchClick?()
        }
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    }

    private final class ClickView: NSView {
        var onClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) { onClick?() }
    }
}
