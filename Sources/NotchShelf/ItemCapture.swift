import AppKit
import ScreenCaptureKit

/// Copies the pixels of a status item so we can redraw it somewhere macOS is willing to show.
///
/// A notch-swallowed item is never composited, but ScreenCaptureKit will still hand over its
/// backing store when asked for off-screen windows. That is the only route to a real icon: the
/// WindowServer attributes every status item to the Control Center process, so there is no
/// owning app to take an icon from, and the old `CGWindowListCreateImage` path returns nothing
/// for these windows on current macOS.
///
/// Capture is the expensive part of this app, so it is done only for items that are actually
/// missing an image, all of them at once rather than one after another, and never on a timer.
final class ItemCapture {
    enum Path: String {
        case none = "not probed"
        case screenCaptureKit = "ScreenCaptureKit"
        case unavailable = "unavailable"
    }

    private(set) var path: Path = .none
    private var cache: [CGWindowID: (image: NSImage, capturedAt: Date)] = [:]
    private var inFlight = false
    /// Icons change slowly (a CPU meter is the exception), so a long life keeps the shelf
    /// instant. `refreshAll` forces a re-capture when the user actually opens the shelf.
    private let lifetime: TimeInterval = 30

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func image(for item: StatusItem) -> NSImage? { cache[item.windowID]?.image }

    func invalidate() { cache.removeAll() }

    /// Captures anything in `items` that has no fresh image. Does nothing — and costs nothing —
    /// when the cache already covers them, which is the steady state.
    func ensureImages(for items: [StatusItem], force: Bool = false,
                      completion: @escaping () -> Void) {
        guard hasPermission, !inFlight else { return }
        let now = Date()
        let missing = items.filter { item in
            guard !force, let cached = cache[item.windowID] else { return true }
            return now.timeIntervalSince(cached.capturedAt) > lifetime
        }
        guard !missing.isEmpty else { return }

        inFlight = true
        Task { [weak self] in
            let captured = await Self.capture(missing)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight = false
                self.path = captured.isEmpty ? .unavailable : .screenCaptureKit
                guard !captured.isEmpty else { return }
                let stamp = Date()
                for (id, image) in captured { self.cache[id] = (image, stamp) }
                completion()
            }
        }
    }

    // MARK: - Capture

    private static func capture(_ items: [StatusItem]) async -> [CGWindowID: NSImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false) else { return [:] }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let windows = items.compactMap { byID[$0.windowID] }
        guard !windows.isEmpty else { return [:] }

        // In parallel: capturing two dozen windows one after another is what made the shelf
        // feel laggy.
        return await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for window in windows {
                group.addTask { (window.windowID, await captureOne(window)) }
            }
            var result: [CGWindowID: NSImage] = [:]
            for await (id, image) in group {
                if let image { result[id] = image }
            }
            return result
        }
    }

    private static func captureOne(_ window: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = 2
        configuration.width = max(1, Int(window.frame.width) * scale)
        configuration.height = max(1, Int(window.frame.height) * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration),
              cgImage.width > 1, cgImage.height > 1 else { return nil }
        return trimmed(cgImage, scale: CGFloat(scale))
    }

    /// Status item windows are mostly transparent padding around a small glyph. Cropping to the
    /// opaque pixels keeps the shelf's cells from looking half empty.
    private static func trimmed(_ image: CGImage, scale: CGFloat) -> NSImage? {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return wrap(image, scale: scale) }
        let bytesPerRow = image.bytesPerRow
        var minX = image.width, maxX = -1, minY = image.height, maxY = -1

        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * bytesPerRow + x * 4 + 3] > 12 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY,
              let cropped = image.cropping(to: CGRect(x: minX, y: minY,
                                                      width: maxX - minX + 1,
                                                      height: maxY - minY + 1))
        else { return wrap(image, scale: scale) }
        return wrap(cropped, scale: scale)
    }

    private static func wrap(_ image: CGImage, scale: CGFloat) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale,
                                             height: CGFloat(image.height) / scale))
    }
}
