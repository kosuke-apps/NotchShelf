import AppKit

struct HiddenEntry {
    let item: StatusItem
    let image: NSImage?
    /// The app that owns the item, which only the accessibility tree can tell us.
    let ownerName: String?

    var label: String { ownerName ?? item.displayName }
}

/// The shelf that drops out of the notch when it is clicked.
///
/// It is the notch carried downwards: the same black, the same width, one menu bar tall per row
/// of icons, with shoulders that flare at the top of the display the way the notch's do. It
/// reads as the notch itself opening rather than as a panel laid over the screen.
final class NotchStrip: NSPanel {
    private let content = StripView()
    private var dismissMonitor: Any?
    /// Clicking the notch toggles the shelf. Without this the click both dismissed the shelf and
    /// re-opened it, so it could never be closed the way it was opened.
    private var notchRect: CGRect = .zero

    var onSelect: ((StatusItem) -> Void)? {
        get { content.onSelect }
        set { content.onSelect = newValue }
    }
    var onSecondaryClick: (() -> Void)? {
        get { content.onSecondaryClick }
        set { content.onSecondaryClick = newValue }
    }
    /// Option-click on one of the icons: bring that item back into the menu bar.
    var onBringOut: ((StatusItem) -> Void)? {
        get { content.onBringOut }
        set { content.onBringOut = newValue }
    }
    /// Right-click on one of the icons: NotchShelf's own menu for that item.
    var onContextMenu: ((StatusItem, NSEvent) -> Void)? {
        get { content.onContextMenu }
        set { content.onContextMenu = newValue }
    }
    /// New display order, by item name, after the user drags an icon inside the shelf.
    var onReorder: (([String]) -> Void)? {
        get { content.onReorder }
        set { content.onReorder = newValue }
    }
    var onOverflow: (() -> Void)? {
        get { content.onOverflow }
        set { content.onOverflow = newValue }
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 38),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // No window shadow: in dark mode macOS rims a shadowed window with a light hairline on
        // every side, including the top, which drew a line between the strip and the notch and
        // made it look like a separate panel. The strip's own edge (see StripView.drawEdge)
        // is what keeps it visible against a dark desktop.
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false

        // The shape is drawn by the view (see StripView.shape): the notch's own outline carried
        // down, not a rectangle hung underneath it.
        contentView = content
        content.onNotchArea = { [weak self] in self?.hide(reason: "notch clicked") }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var isShown: Bool { isVisible }
    /// True while the user is dragging an icon inside the shelf; the refresh loop must leave
    /// the contents alone until they let go, or the dragged index points at the wrong item.
    var isRearranging: Bool { content.isRearranging }

    func show(entries: [HiddenEntry], geometry: MenuBarGeometry) {
        let wasShown = isVisible
        let notch = geometry.notch ?? geometry.menuBar
        notchRect = notch
        let rowHeight = geometry.menuBar.height
        content.rowHeight = rowHeight
        content.rowCount = Settings.shared.rows
        // The shelf defaults to real menu bar order; anything the user has rearranged by hand
        // takes precedence.
        content.entries = Settings.shared.arrange(entries) { $0.item.name }

        // Starts at the very top of the screen and covers the notch itself, so the notch and the
        // shelf are one black shape. Hung below the menu bar instead, the notch's rounded lower
        // corners met the shelf's square upper ones, and against a light background the join
        // showed as a step. The shoulders flare out a little on either side, the way the notch
        // meets the top edge of the display.
        let flare = content.flare
        content.topInset = geometry.menuBar.height
        let height = geometry.menuBar.height + rowHeight * CGFloat(Settings.shared.rows)
        let frame = NSRect(x: notch.minX - flare, y: geometry.menuBar.maxY - height,
                           width: notch.width + flare * 2, height: height)
        setFrame(frame, display: true)
        content.frame = NSRect(origin: .zero, size: frame.size)

        orderFrontRegardless()
        installDismissMonitor()
        // "Opened" in the log and nothing on screen is exactly the report being chased, so record
        // what the window server thinks right after ordering the strip in.
        guard !wasShown else { return }   // a refresh of an open shelf, not an opening
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            Diagnostics.shared.log("  shelf state: visible=\(self.isVisible)"
                + " onActiveSpace=\(self.isOnActiveSpace)"
                + " occluded=\(!self.occlusionState.contains(.visible))")
        }
    }

    func hide(reason: String = "toggle") {
        if isVisible { Diagnostics.shared.log("  shelf closed (\(reason))") }
        orderOut(nil)
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        dismissMonitor = nil
    }

    private func installDismissMonitor() {
        guard dismissMonitor == nil else { return }
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            guard !self.frame.contains(point), !self.notchRect.contains(point) else { return }
            self.hide(reason: "click elsewhere at \(Int(point.x)),\(Int(point.y))")
        }
    }
}

/// Draws the icons and lets the user rearrange them by dragging. Rearranging inside the shelf
/// is our own bookkeeping — every item here is already behind the notch — so it is instant,
/// unlike moving an item back into the menu bar.
private final class StripView: NSView {
    /// In menu bar order, left to right — the same order macOS lays them out in.
    var entries: [HiddenEntry] = [] { didSet { needsDisplay = true } }
    var rowCount = 1
    var rowHeight: CGFloat = 38
    /// Height of the part that sits over the notch itself; the items live below it.
    var topInset: CGFloat = 38 { didSet { needsDisplay = true } }
    /// How far the shoulders flare out past the notch at the top of the screen.
    let flare: CGFloat = 8
    private let bottomRadius: CGFloat = 10

    /// A click on the part covering the notch. The shelf is on top of the notch while open, so
    /// the global notch monitor never sees that click; it has to be handled here.
    var onNotchArea: (() -> Void)?

    /// Where the icons go: below the notch, and within its width.
    private var contentRect: NSRect {
        NSRect(x: flare, y: topInset, width: bounds.width - flare * 2,
               height: max(0, bounds.height - topInset))
    }

    var onSelect: ((StatusItem) -> Void)?
    var onOverflow: (() -> Void)?
    var onSecondaryClick: (() -> Void)?
    var onReorder: (([String]) -> Void)?
    var onBringOut: ((StatusItem) -> Void)?
    var onContextMenu: ((StatusItem, NSEvent) -> Void)?

    var isRearranging: Bool { isDragging }

    private var dragIndex: Int?
    private var dragOrigin: NSPoint = .zero
    private var dragPoint: NSPoint = .zero
    private var isDragging = false

    private let cellWidth: CGFloat = 28
    private let sidePadding: CGFloat = 6
    private var hovered: Int?

    override var isFlipped: Bool { true }

    private var columns: Int { max(1, Int((contentRect.width - sidePadding * 2) / cellWidth)) }
    private var capacity: Int { columns * rowCount }
    private var overflowCount: Int { max(0, entries.count - capacity) }

    /// Which entries get drawn: the ones nearest the notch, since those are the ones the bar
    /// would show next. When some do not fit, the leftmost slot becomes a "+n" badge.
    private var shown: [Int] {
        let room = overflowCount > 0 ? capacity - 1 : capacity
        return Array(entries.indices.suffix(room))
    }

    /// Laid out right to left from the shelf's right edge, so the row reads as a continuation
    /// of the menu bar rather than a separate list that happens to start on the left.
    private func slotFrame(slotFromRight: Int) -> NSRect {
        let row = slotFromRight / columns
        let column = slotFromRight % columns
        let x = contentRect.maxX - sidePadding - CGFloat(column + 1) * cellWidth
        let y = bounds.maxY - CGFloat(row + 1) * rowHeight
        return NSRect(x: x, y: y, width: cellWidth, height: rowHeight)
    }

    private func frame(forShownIndex index: Int) -> NSRect {
        slotFrame(slotFromRight: shown.count - 1 - index)
    }

    private var overflowFrame: NSRect { slotFrame(slotFromRight: shown.count) }

    private func entryIndex(at point: NSPoint) -> Int? {
        for (offset, index) in shown.enumerated() where frame(forShownIndex: offset).contains(point) {
            return index
        }
        return nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        shape().fill()
        drawEdge()
        guard !entries.isEmpty else { drawEmptyState(); return }

        for (offset, index) in shown.enumerated() where index != dragIndex || !isDragging {
            let slot = frame(forShownIndex: offset)
            if hovered == index && !isDragging { drawHighlight(in: slot) }
            draw(entries[index], in: slot)
        }

        if isDragging, let dragIndex {
            let slot = frame(forShownIndex: dropOffset(at: dragPoint))
            NSColor.white.withAlphaComponent(0.3).setFill()
            NSRect(x: slot.minX - 1, y: slot.minY + 5, width: 2, height: slot.height - 10).fill()
            draw(entries[dragIndex], in: NSRect(x: dragPoint.x - cellWidth / 2,
                                                y: slot.minY, width: cellWidth, height: slot.height))
        }

        if overflowCount > 0 {
            drawText("+\(overflowCount)", in: overflowFrame,
                     font: .systemFont(ofSize: 11, weight: .semibold),
                     colour: NSColor.white.withAlphaComponent(0.55))
        }
    }

    /// The notch's outline, carried down: concave shoulders where it leaves the top edge of the
    /// display, straight sides, rounded lower corners.
    private func shape() -> NSBezierPath {
        let f = flare, r = bottomRadius, k: CGFloat = 0.5523   // quarter circle as a Bézier
        let w = bounds.width, h = bounds.height
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.curve(to: NSPoint(x: f, y: f),
                   controlPoint1: NSPoint(x: k * f, y: 0),
                   controlPoint2: NSPoint(x: f, y: f - k * f))
        path.line(to: NSPoint(x: f, y: h - r))
        path.curve(to: NSPoint(x: f + r, y: h),
                   controlPoint1: NSPoint(x: f, y: h - r + k * r),
                   controlPoint2: NSPoint(x: f + r - k * r, y: h))
        path.line(to: NSPoint(x: w - f - r, y: h))
        path.curve(to: NSPoint(x: w - f, y: h - r),
                   controlPoint1: NSPoint(x: w - f - r + k * r, y: h),
                   controlPoint2: NSPoint(x: w - f, y: h - r + k * r))
        path.line(to: NSPoint(x: w - f, y: f))
        path.curve(to: NSPoint(x: w, y: 0),
                   controlPoint1: NSPoint(x: w - f, y: f - k * f),
                   controlPoint2: NSPoint(x: w - k * f, y: 0))
        path.close()
        return path
    }

    /// A hairline down the sides and along the bottom of the part below the menu bar, so the
    /// shelf stays visible against a dark desktop. Nothing above that: the upper part is the
    /// notch itself and has to read as one piece with it.
    private func drawEdge() {
        let r = bottomRadius
        let left = flare + 0.5, right = bounds.width - flare - 0.5, bottom = bounds.height - 0.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left, y: topInset))
        path.appendArc(from: NSPoint(x: left, y: bottom), to: NSPoint(x: left + r, y: bottom), radius: r)
        path.appendArc(from: NSPoint(x: right, y: bottom), to: NSPoint(x: right, y: topInset), radius: r)
        path.line(to: NSPoint(x: right, y: topInset))
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.stroke()
    }

    private func drawEmptyState() {
        drawText("Nothing hidden", in: contentRect, font: .systemFont(ofSize: 11),
                 colour: NSColor.white.withAlphaComponent(0.4))
    }

    private func drawHighlight(in slot: NSRect) {
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: slot.insetBy(dx: 1, dy: 4), xRadius: 5, yRadius: 5).fill()
    }

    private func draw(_ entry: HiddenEntry, in slot: NSRect) {
        if let image = entry.image {
            let scale = min(1, min((slot.width - 6) / image.size.width,
                                   (slot.height - 12) / image.size.height))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
                                  width: size.width, height: size.height))
            return
        }
        // Without screen recording we cannot copy the item's pixels, so fall back to an initial.
        let box = NSRect(x: slot.midX - 9, y: slot.midY - 9, width: 18, height: 18)
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        path.lineWidth = 1.2
        path.stroke()
        drawText(entry.item.badge, in: box, font: .systemFont(ofSize: 10, weight: .medium),
                 colour: NSColor.white.withAlphaComponent(0.85))
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, colour: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: colour, .paragraphStyle: style
        ])
        string.draw(in: NSRect(x: rect.minX, y: rect.midY - string.size().height / 2,
                               width: rect.width, height: string.size().height))
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHover = entryIndex(at: point)
        if newHover != hovered {
            hovered = newHover
            toolTip = newHover.map { entries[$0].label }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    /// Where a drop at `point` would land, as an offset into the drawn slots.
    private func dropOffset(at point: NSPoint) -> Int {
        for offset in shown.indices where frame(forShownIndex: offset).contains(point) { return offset }
        let leftmost = frame(forShownIndex: 0)
        return point.x < leftmost.midX ? 0 : max(0, shown.count - 1)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < topInset { onNotchArea?(); return }
        dragIndex = entryIndex(at: point)
        dragOrigin = point
        dragPoint = point
        isDragging = false
        if dragIndex == nil, overflowCount > 0, overflowFrame.contains(point) { onOverflow?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragIndex != nil else { return }
        dragPoint = convert(event.locationInWindow, from: nil)
        if !isDragging, hypot(dragPoint.x - dragOrigin.x, dragPoint.y - dragOrigin.y) > 3 {
            isDragging = true
        }
        if isDragging { needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragIndex = nil; isDragging = false; needsDisplay = true }
        guard let index = dragIndex else { return }
        let point = convert(event.locationInWindow, from: nil)

        guard isDragging else {
            guard entryIndex(at: point) == index else { return }
            // Bringing an item out rearranges the menu bar and borrows the pointer for a moment,
            // so it takes a deliberate modifier rather than sharing a plain click.
            if event.modifierFlags.contains(.option) {
                onBringOut?(entries[index].item)
            } else {
                onSelect?(entries[index].item)
            }
            return
        }

        // Reordering here changes how the shelf displays them, not the menu bar itself: macOS
        // never draws a swallowed item, so there is nothing to take hold of out there.
        guard let destination = shown[safe: dropOffset(at: point)] else { return }
        var names = entries.map(\.item.name)
        let moved = names.remove(at: index)
        names.insert(moved, at: min(destination, names.count))
        onReorder?(names)
    }

    /// A right-click on an icon opens NotchShelf's own menu for it rather than reaching the item.
    ///
    /// Reaching it is not possible for an item behind the notch. A left click works because it
    /// is not a click at all but the accessibility "press" command, which runs the button's
    /// standard action. There is no command for a right-click; that has to be a real
    /// right-button event delivered to the item's window, and a hidden item's window cannot be
    /// reached. It is not drawn, so nothing at its position receives the event, and on macOS 26
    /// it only has an app-local number that an event cannot carry: a right-button event posted to
    /// the owning app does arrive, but addressed to no window, and is dropped. Control Center,
    /// which relays real clicks, draws nothing for a hidden item and has nothing to relay. With
    /// right and left unable to differ, a right-click doing the same as a left one was useless.
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < topInset { onNotchArea?(); return }
        if let index = entryIndex(at: point) {
            onContextMenu?(entries[index].item, event)
        } else {
            onSecondaryClick?()
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
