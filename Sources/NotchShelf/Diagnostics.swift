import AppKit

/// A live view of what the scanner sees, mirrored to a log file.
///
/// Almost everything this app depends on is undocumented WindowServer behaviour, so being able
/// to read back what happened — including from a session nobody was watching — is what makes
/// the difference between developing and guessing.
final class Diagnostics {
    static let shared = Diagnostics()

    private var window: NSWindow?
    private var textView: NSTextView?
    private var entries: [String] = []
    private let entryLimit = 200
    private let logURL: URL

    var latest: MenuBarSnapshot = .empty
    var geometry: MenuBarGeometry?
    var capturePath: ItemCapture.Path = .none

    init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("NotchShelf.log")
    }

    func log(_ message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.log(message) }
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)"
        entries.append(line)
        if entries.count > entryLimit { entries.removeFirst(entries.count - entryLimit) }
        append(line)
        refresh()
    }

    private func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "NotchShelf Diagnostics"
        window.center()
        window.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true

        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 12)
        scroll.documentView = textView

        window.contentView = scroll
        self.window = window
        self.textView = textView
    }

    func refresh() {
        guard let textView, window?.isVisible == true else { return }
        textView.string = report()
    }

    func report() -> String {
        var out = ""
        if let g = geometry {
            out += "Screen \(Int(g.screen.frame.width))x\(Int(g.screen.frame.height))"
            out += "   menu bar \(Int(g.menuBar.height))pt\n"
            if let notch = g.notch {
                out += "Notch x \(Int(notch.minX))–\(Int(notch.maxX)) (\(Int(notch.width))pt wide)\n"
            } else {
                out += "No notch on this screen\n"
            }
        }
        out += "Capture path: \(capturePath.rawValue)"
        out += "   Screen recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")"
        out += "   Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")\n"

        let s = latest
        out += "\n\(s.all.count) items total — \(s.visible.count) drawn, "
        out += "\(s.swallowedByNotch.count) swallowed by the notch, "
        out += "\(s.hiddenByOwner.count) hidden by their own app\n"

        if let g = geometry, let notch = g.notch {
            let leftmost = s.visible.map(\.cgFrame.minX).min() ?? notch.maxX
            out += "Free space between the notch and the leftmost drawn item: \(Int(leftmost - notch.maxX))pt\n"
        }

        out += "\n" + String(repeating: "-", count: 74) + "\n"
        out += String(format: "%-16@ %7@ %6@ %-8@ %@\n", "state" as NSString, "x" as NSString,
                      "width" as NSString, "wid" as NSString, "name" as NSString)
        for item in s.all {
            let state: String
            if item.isOnScreen { state = "drawn" }
            else if s.swallowedByNotch.contains(item) { state = "behind notch" }
            else { state = "hidden by app" }
            out += String(format: "%-16@ %7d %6d %-8d %@\n", state as NSString,
                          Int(item.cgFrame.minX), Int(item.cgFrame.width),
                          Int(item.windowID), item.name)
        }

        out += "\n" + String(repeating: "-", count: 74) + "\nLog (also at ~/Library/Logs/NotchShelf.log)\n"
        out += entries.suffix(60).joined(separator: "\n")
        return out
    }
}
