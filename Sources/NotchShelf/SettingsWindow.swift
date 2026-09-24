import AppKit

/// The full inventory of menu bar items and everything you can do to them. The shelf itself is
/// only a notch wide, so this window is where the arranging actually happens.
final class SettingsWindow: NSWindowController {
    var itemsProvider: (() -> MenuBarSnapshot)?
    var imageProvider: ((StatusItem) -> NSImage?)?
    var ownerName: ((StatusItem) -> String?)?
    var onActivate: ((StatusItem) -> Void)?
    var onBringOut: ((StatusItem) -> Void)?
    var isBusy: (() -> Bool)?

    var onOpenDiagnostics: (() -> Void)?

    private var rowsControl: NSSegmentedControl!
    private var itemsStack: NSStackView!
    private var statusLine: NSTextField!
    private var screenRecordingStatus: NSTextField!
    private var accessibilityStatus: NSTextField!
    private var refreshTimer: Timer?
    private var listSignature = ""

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "NotchShelf"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 360)
        self.init(window: window)
        buildContent()
    }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        listSignature = ""
        reload()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(sectionTitle("Shelf"))
        rowsControl = NSSegmentedControl(labels: ["1 row", "2 rows"],
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(rowsChanged))
        rowsControl.selectedSegment = Settings.shared.rows - 1
        root.addArrangedSubview(labelled("Height", control: rowsControl))
        root.addArrangedSubview(caption(
            "The shelf is one notch wide and one menu bar tall, so it reads as the notch itself "
            + "opening. A second row doubles how many items it holds."))

        root.addArrangedSubview(separator())
        root.addArrangedSubview(sectionTitle("Menu bar items"))
        root.addArrangedSubview(caption(
            "Click the notch to open the shelf, then click an item to open its menu. This works "
            + "on items macOS refuses to draw, and never touches your pointer.\n\n"
            + "Bring out (here, or Option-click on the shelf) moves an item back into the menu "
            + "bar. A hidden item cannot be grabbed — "
            + "macOS does not draw it — so this is the one thing that has to borrow your "
            + "pointer, for about a second, hidden and put back where it was. Items already in "
            + "the bar can be command-dragged by hand as usual; NotchShelf puts nothing over the "
            + "menu bar to get in the way."))

        statusLine = NSTextField(labelWithString: "")
        statusLine.font = .systemFont(ofSize: 11, weight: .medium)
        statusLine.textColor = .systemOrange
        root.addArrangedSubview(statusLine)

        itemsStack = NSStackView()
        itemsStack.orientation = .vertical
        itemsStack.alignment = .leading
        itemsStack.spacing = 3
        root.addArrangedSubview(itemsStack)

        root.addArrangedSubview(separator())
        root.addArrangedSubview(sectionTitle("Permissions"))

        screenRecordingStatus = statusLabel()
        root.addArrangedSubview(permissionRow(
            title: "Screen Recording", status: screenRecordingStatus,
            detail: "Draws each hidden item with its real icon.",
            action: #selector(grantScreenRecording)))

        accessibilityStatus = statusLabel()
        root.addArrangedSubview(permissionRow(
            title: "Accessibility", status: accessibilityStatus,
            detail: "Required to move items in and out of the notch.",
            action: #selector(grantAccessibility)))

        root.addArrangedSubview(separator())
        let footer = NSStackView(views: [
            button("Diagnostics…", action: #selector(openDiagnostics)),
            button("Quit NotchShelf", action: #selector(quit))
        ])
        footer.orientation = .horizontal
        footer.spacing = 10
        root.addArrangedSubview(footer)

        // Taller than any sensible window, so it scrolls; the document view is flipped so it
        // starts at the top rather than scrolled to the bottom.
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(root)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = documentView

        let content = NSView()
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            root.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: documentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
        window.contentView = content
    }

    // MARK: - Item list

    private func reload() {
        guard window?.isVisible == true else { return }
        apply(granted: CGPreflightScreenCaptureAccess(), to: screenRecordingStatus)
        apply(granted: AXIsProcessTrusted(), to: accessibilityStatus)

        let busy = isBusy?() ?? false
        statusLine.stringValue = busy ? "Rearranging the menu bar…" : ""

        let snapshot = itemsProvider?() ?? .empty
        let parked = Settings.shared.parked

        // Rebuilding on every tick moved buttons out from under the pointer, so only rebuild
        // when the list actually differs.
        let signature = snapshot.all.map { item -> String in
            let state = snapshot.swallowedByNotch.contains(item)
                ? (parked.contains(item.name) ? "p" : "h")
                : (snapshot.hiddenByOwner.contains(item) ? "o" : "v")
            return "\(item.name):\(state):\(imageProvider?(item) != nil)"
        }.joined(separator: "|") + "|busy=\(busy)|ax=\(AXIsProcessTrusted())"

            + "|pinned=\(Settings.shared.immovable.sorted())|x=\(snapshot.all.map { Int($0.cgFrame.minX) })"
        guard signature != listSignature else { return }
        listSignature = signature

        itemsStack.arrangedSubviews.forEach {
            itemsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let hidden = snapshot.swallowedByNotch
            .sorted { $0.cgFrame.minX > $1.cgFrame.minX }
        let visible = snapshot.visible
            .sorted { $0.cgFrame.minX > $1.cgFrame.minX }

        addSection("Behind the notch — swallowed by macOS", items: hidden, kind: .swallowed,
                   busy: busy, empty: "Nothing is hidden right now. Items appear here once your "
                   + "menu bar has more in it than fits to the right of the notch.")
        addSection("In the menu bar", items: visible, kind: .visible, busy: busy, empty: nil)
    }

    private enum Kind { case swallowed, visible }

    private func addSection(_ title: String, items: [StatusItem], kind: Kind, busy: Bool,
                            empty: String?, note: String? = nil, disabled: Bool = false) {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
        itemsStack.addArrangedSubview(spacer)
        itemsStack.addArrangedSubview(header)

        if let note { itemsStack.addArrangedSubview(caption(note)) }
        if items.isEmpty {
            if let empty { itemsStack.addArrangedSubview(caption(empty)) }
            return
        }
        for (index, item) in items.enumerated() {
            itemsStack.addArrangedSubview(row(for: item, kind: kind, busy: busy || disabled,
                                              isFirst: index == 0,
                                              isLast: index == items.count - 1))
        }
    }

    private func row(for item: StatusItem, kind: Kind, busy: Bool,
                     isFirst: Bool, isLast: Bool) -> NSView {
        let icon = NSImageView()
        icon.image = imageProvider?(item)
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let name = NSTextField(labelWithString: ownerName?(item) ?? item.displayName)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        name.widthAnchor.constraint(equalToConstant: 200).isActive = true

        var controls: [NSView] = [icon, name]

        if kind == .swallowed {
            controls.append(action("Bring out", item: item, selector: #selector(bringOutItem(_:)),
                                   enabled: !busy && AXIsProcessTrusted()))
        }

        if kind == .swallowed {
            // Opening goes through the accessibility API, so it works on an item macOS refuses
            // to draw and never moves the pointer. Rearranging is left to the ordinary
            // command-drag, which is both more predictable and nobody's pointer to steal.
            controls.append(action("Open", item: item, selector: #selector(activateItem(_:)),
                                   enabled: !busy && AXIsProcessTrusted()))
        }

        let stack = NSStackView(views: controls)
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }

    private func action(_ title: String, item: StatusItem, selector: Selector,
                        enabled: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(item.name)
        button.isEnabled = enabled
        return button
    }

    private func item(named name: String) -> StatusItem? {
        (itemsProvider?() ?? .empty).all.first { $0.name == name }
    }

    private func withItem(_ sender: NSButton, _ body: (StatusItem) -> Void) {
        guard let name = sender.identifier?.rawValue, let item = item(named: name) else { return }
        body(item)
        listSignature = ""
        reload()
    }

    @objc private func activateItem(_ sender: NSButton) { withItem(sender) { onActivate?($0) } }
    @objc private func bringOutItem(_ sender: NSButton) { withItem(sender) { onBringOut?($0) } }

    @objc private func pointerMovesChanged(_ sender: NSButton) {
        Settings.shared.allowsPointerMoves = sender.state == .on
        listSignature = ""
        reload()
    }


    // MARK: - Pieces

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 460
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 470).isActive = true
        return box
    }

    private func statusLabel() -> NSTextField {
        let field = NSTextField(labelWithString: "—")
        field.font = .systemFont(ofSize: 11, weight: .medium)
        return field
    }

    private func labelled(_ text: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 12
        return stack
    }

    private func permissionRow(title: String, status: NSTextField, detail: String,
                               action: Selector) -> NSStackView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12)
        let header = NSStackView(views: [name, status, button("Grant…", action: action)])
        header.orientation = .horizontal
        header.spacing = 10

        let stack = NSStackView(views: [header, caption(detail)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func apply(granted: Bool, to field: NSTextField) {
        field.stringValue = granted ? "Granted" : "Not granted"
        field.textColor = granted ? .systemGreen : .secondaryLabelColor
    }

    @objc private func rowsChanged() { Settings.shared.rows = rowsControl.selectedSegment + 1 }
    @objc private func grantScreenRecording() { CGRequestScreenCaptureAccess() }
    @objc private func grantAccessibility() { Activator.requestTrust() }
    @objc private func openDiagnostics() { onOpenDiagnostics?() }
    @objc private func quit() { NSApp.terminate(nil) }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
