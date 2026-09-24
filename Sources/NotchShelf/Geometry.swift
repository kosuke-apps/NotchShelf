import AppKit

/// Converts between the two coordinate systems we straddle:
/// - CG (CGWindowList, CGEvent): global, origin at the TOP-left of the primary display, y grows down.
/// - NS (AppKit): global, origin at the BOTTOM-left of the primary display, y grows up.
enum Coord {
    /// Height used to flip: the primary display is the one whose NS origin is (0, 0).
    static var flipHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.maxY ?? 0
    }

    static func toNS(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: flipHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toCG(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: flipHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toCG(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: flipHeight - p.y)
    }
}

/// The shape of one screen's menu bar, including the notch cut-out if there is one.
/// All rects are in NS (AppKit) coordinates.
struct MenuBarGeometry {
    let screen: NSScreen
    let menuBar: CGRect
    /// The dead strip the camera housing occupies. Nil on screens without a notch.
    let notch: CGRect?
    /// Usable menu bar strip left of the notch (where the app menus live).
    let leftArea: CGRect?
    /// Usable menu bar strip right of the notch (where status items live).
    let rightArea: CGRect?

    var hasNotch: Bool { notch != nil }

    /// x below which macOS refuses to composite a status item.
    var statusItemCutoffX: CGFloat { notch?.maxX ?? screen.frame.minX }

    init(screen: NSScreen) {
        self.screen = screen
        let inset = screen.safeAreaInsets.top
        let height = inset > 0 ? inset : NSStatusBar.system.thickness
        self.menuBar = CGRect(x: screen.frame.minX,
                              y: screen.frame.maxY - height,
                              width: screen.frame.width,
                              height: height)
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        self.leftArea = left
        self.rightArea = right
        if let l = left, let r = right, r.minX > l.maxX {
            self.notch = CGRect(x: l.maxX, y: menuBar.minY, width: r.minX - l.maxX, height: height)
        } else {
            self.notch = nil
        }
    }

    /// The built-in display, which is the only one that can have a notch.
    static var builtIn: MenuBarGeometry? {
        let screen = NSScreen.screens.first { MenuBarGeometry(screen: $0).hasNotch }
            ?? NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main
        return screen.map(MenuBarGeometry.init(screen:))
    }
}
