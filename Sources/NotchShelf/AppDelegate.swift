import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let capture = ItemCapture()
    private let axItems = AXStatusItems()
    private let mover = MoveCoordinator()
    /// Replaced by a fresh panel every time the shelf opens; see `makeStrip`.
    private var strip = NotchStrip()
    private var input: NotchInput!
    private var settingsController: SettingsWindow?
    private var timer: Timer?
    private var geometry = MenuBarGeometry.builtIn
    private var entries: [HiddenEntry] = []
    private var hasAskedForCapture = false
    private var lastHiddenCount = -1

    private var isSettingsVisible: Bool { settingsController?.window?.isVisible == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NotchShelf has no menu bar icon of its own. It would take a place in the very bar whose
        // overflow the app exists to deal with, pushing one more item behind the notch. The way in
        // is the notch itself; settings open from the shelf's right-click, or by opening the app
        // again.

        strip = makeStrip()
        Settings.shared.onChange = { [weak self] in self?.reshowStripIfOpen() }

        mover.log = { Diagnostics.shared.log($0) }
        mover.knownImmovable = { Settings.shared.immovable }
        mover.onImmovable = { name in
            DispatchQueue.main.async { Settings.shared.markImmovable(name) }
        }
        mover.willBegin = { [weak self] in self?.strip.hide() }
        mover.didFinish = { [weak self] in
            self?.capture.invalidate()
            self?.refresh()
        }

        let mode = NotchInput.Mode(rawValue: ProcessInfo.processInfo.environment["NOTCHSHELF_INPUT"] ?? "")
            ?? .tap
        input = NotchInput(mode: mode)
        input.onNotchClick = { [weak self] in self?.toggleStrip() }
        input.onMechanismFired = { name in
            Diagnostics.shared.log("Notch click received via \(name)")
        }

        Diagnostics.shared.geometry = geometry
        Diagnostics.shared.log("NotchShelf started (notch detection: \(mode.rawValue))")
        Diagnostics.shared.log("Permissions — screen recording: \(CGPreflightScreenCaptureAccess()),"
                               + " accessibility: \(AXIsProcessTrusted())")

        if let geometry {
            input.start(geometry: geometry)
            if geometry.notch == nil { Diagnostics.shared.log("This screen has no notch") }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Coming back from sleep, the screen can be described differently for a moment and the
        // captured icons are stale; start again from what is there now.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // Opens the shelf after a delay, long enough to switch desktop first — for reproducing
        // problems that only show up away from the first desktop.
        if let delay = ProcessInfo.processInfo.environment["NOTCHSHELF_SHOWAFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.toggleStrip() }
        }

        // Posts real clicks (through the HID tap, as a mouse would) at the notch at the given
        // seconds after launch — "3,4,9" — so a sequence spanning a desktop switch can be
        // reproduced. The pointer is put back after each.
        if let times = ProcessInfo.processInfo.environment["NOTCHSHELF_CLICKNOTCHAT"] {
            for delay in times.split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let notch = self?.geometry?.notch,
                          let source = CGEventSource(stateID: .hidSystemState) else { return }
                    let point = Coord.toCG(NSPoint(x: notch.midX, y: notch.midY))
                    let origin = CGEvent(source: nil)?.location
                    Diagnostics.shared.log("click test: t=\(delay)s front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                mouseButton: .left)?.post(tap: .cghidEventTap)
                        usleep(40_000)
                    }
                    if let origin { CGWarpMouseCursorPosition(origin); CGAssociateMouseAndMouseCursorPosition(1) }
                }
            }
        }

        if ProcessInfo.processInfo.environment["NOTCHSHELF_AUTOSHOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.toggleStrip() }
        }
        if ProcessInfo.processInfo.environment["NOTCHSHELF_SHOWSETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.openSettings() }
        }

        // Without both permissions the app can neither draw nor open anything, and a fresh install
        // has neither. The settings window says why each is needed and has a button for each;
        // with no menu bar icon, there would otherwise be nowhere obvious to go.
        if !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openSettings() }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    // MARK: - Refresh loop

    /// Desktops are switched constantly, so this is recorded: when the shelf misbehaves it has
    /// so far always been on a desktop other than the first.
    ///
    /// The shelf closes on the way, the way menus do. Left open, it followed the user to the new
    /// desktop, so the next click on the notch closed it instead of opening it — against a dark
    /// desktop, where the open shelf is hard to see, that read as the click doing nothing.
    @objc private func activeSpaceChanged() {
        Diagnostics.shared.log("Desktop changed (shelf \(strip.isShown ? "open" : "closed"))")
        strip.hide(reason: "desktop changed")
    }

    @objc private func didWake() {
        Diagnostics.shared.log("Woke from sleep")
        screenParametersChanged()
    }

    @objc private func screenParametersChanged() {
        geometry = MenuBarGeometry.builtIn
        Diagnostics.shared.geometry = geometry
        capture.invalidate()
        if let geometry { input.update(geometry: geometry) }
        refresh()
    }

    private func refresh() {
        guard let geometry else { return }
        let snapshot = MenuBarScanner.scan(geometry: geometry)
        Diagnostics.shared.latest = snapshot

        // Only the items the shelf will draw, and only the ones we have no image for. Capturing
        // everything on a timer is what made opening the shelf feel slow.
        let needed = isSettingsVisible ? snapshot.all : snapshot.swallowedByNotch
        capture.ensureImages(for: needed) { [weak self] in
            Diagnostics.shared.capturePath = self?.capture.path ?? .none
            self?.rebuildEntries()
        }

        rebuildEntries(from: snapshot)
        if entries.count != lastHiddenCount {
            lastHiddenCount = entries.count
            Diagnostics.shared.log("Hidden behind the notch: \(entries.count)"
                + (snapshot.visible.contains { $0.isOnScreen } ? "" : " (menu bar not on screen; using remembered boundary)"))
        }

        // The click target stands down whenever the menu bar is not on screen: in full screen
        // the notch belongs to the app's content, and swallowing clicks there is exactly the
        // interference this design exists to avoid.
        input.setEnabled(MenuBarScanner.isMenuBarShowing)

        if !entries.isEmpty, !capture.hasPermission, !hasAskedForCapture {
            hasAskedForCapture = true
            capture.requestPermission()
            Diagnostics.shared.log("Requested screen recording access (relaunch once granted)")
        }

        Diagnostics.shared.refresh()
    }

    private func rebuildEntries() {
        guard let geometry else { return }
        rebuildEntries(from: MenuBarScanner.scan(geometry: geometry))
    }

    private func rebuildEntries(from snapshot: MenuBarSnapshot) {
        axItems.refresh()
        entries = snapshot.swallowedByNotch
            .map { HiddenEntry(item: $0, image: capture.image(for: $0),
                               ownerName: axItems.label(for: $0)) }
        reshowStripIfOpen()
    }

    // MARK: - Actions

    private func reshowStripIfOpen() {
        guard strip.isShown, !strip.isRearranging, let geometry else { return }
        strip.show(entries: entries, geometry: geometry)
    }

    /// A new panel for each opening.
    ///
    /// Once, the shelf opened — the window server said it was visible — but on a desktop other
    /// than the one in front, and stayed that way for every opening after, so it could not be
    /// seen at all. That happened a few minutes after the Mac woke from sleep, and right after a
    /// desktop switch; the same switch without a sleep never reproduced it, so the cause is not
    /// established. What was reliable in every test is that a newly created panel appears on
    /// the desktop in front. So the shelf never reuses one.
    private func makeStrip() -> NotchStrip {
        let panel = NotchStrip()
        panel.onSelect = { [weak self] item in self?.activate(item) }
        panel.onOverflow = { [weak self] in self?.openSettings() }
        panel.onSecondaryClick = { [weak self] in self?.openSettings() }
        panel.onReorder = { names in Settings.shared.order = names }
        panel.onBringOut = { [weak self] item in self?.bringOut(item) }
        panel.onContextMenu = { [weak self] item, _ in self?.showItemMenu(for: item) }
        return panel
    }

    private func toggleStrip() {
        guard let geometry else { return }
        if strip.isShown {
            strip.hide()
        } else {
            strip.hide(reason: "replaced")
            strip = makeStrip()
            strip.show(entries: entries, geometry: geometry)
            capture.ensureImages(for: entries.map(\.item), force: true) { [weak self] in
                self?.rebuildEntries()
            }
            Diagnostics.shared.log("Opened the shelf (\(entries.count) items)")
        }
    }

    /// Clicking an item in the shelf opens that item's own menu.
    ///
    /// The click goes through the accessibility API rather than as a synthetic mouse event:
    /// macOS never draws a swallowed item, so there is nothing at its coordinates to receive a
    /// click, and moving the pointer over there only looks like a malfunction.
    private func activate(_ item: StatusItem) {
        guard requireAccessibility() else { return }
        strip.hide()
        let opened = axItems.press(item)
        Diagnostics.shared.log(opened ? "Opened \(item.displayName)"
                                      : "Could not open \(item.displayName)")
    }

    /// Only ever reached deliberately — the item's right-click menu, Option-click on the shelf,
    /// or the button in settings — because this is the one path that borrows the pointer.
    private func bringOut(_ item: StatusItem) {
        guard let geometry, requireAccessibility() else { return }
        mover.bringOut(item, geometry: geometry, excluding: [])
    }

    private func showItemMenu(for item: StatusItem) {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open \(axItems.label(for: item) ?? item.displayName)",
                                action: #selector(openFromMenu(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = item
        let out = menu.addItem(withTitle: "Bring Out of the Notch",
                               action: #selector(bringOutFromMenu(_:)), keyEquivalent: "")
        out.target = self
        out.representedObject = item
        out.isEnabled = !mover.isBusy
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: strip.contentView)
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? StatusItem else { return }
        activate(item)
    }

    @objc private func bringOutFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? StatusItem else { return }
        bringOut(item)
    }

    private func requireAccessibility() -> Bool {
        guard axItems.isTrusted else {
            Diagnostics.shared.log("Accessibility access is required to open hidden items")
            Activator.requestTrust()
            return false
        }
        return true
    }

    var currentSnapshot: MenuBarSnapshot {
        guard let geometry else { return .empty }
        return MenuBarScanner.scan(geometry: geometry)
    }

    @objc private func openSettings() {
        strip.hide()
        if settingsController == nil { settingsController = makeSettingsWindow() }
        settingsController?.present()
    }

    private func makeSettingsWindow() -> SettingsWindow {
        let window = SettingsWindow()
        window.onOpenDiagnostics = { Diagnostics.shared.show() }
        window.itemsProvider = { [weak self] in self?.currentSnapshot ?? .empty }
        window.imageProvider = { [weak self] in self?.capture.image(for: $0) }
        window.ownerName = { [weak self] in self?.axItems.label(for: $0) }
        window.onActivate = { [weak self] in self?.activate($0) }

        window.onBringOut = { [weak self] in self?.bringOut($0) }
        window.isBusy = { [weak self] in self?.mover.isBusy ?? false }
        return window
    }

    // MARK: - Reopening

    /// Opening the app again while it is running — from Finder, Launchpad, or Spotlight — shows
    /// its settings. With no menu bar icon, this is the ordinary way back in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }
}
