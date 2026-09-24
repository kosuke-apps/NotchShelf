import CoreGraphics
import Testing
@testable import NotchShelf

/// The layout below is the real one from a 14" M1 Pro on 2026-09-19: five items swallowed by
/// the notch (x=948 to 1029), the drawn ones starting at x=1064, a stale window parked at
/// x=580 that belongs to no slot, and an item its own app hid in the middle of the drawn run.
private func layout(allOffScreen: Bool = false) -> [StatusItem] {
    func item(_ id: CGWindowID, _ x: CGFloat, _ width: CGFloat, drawn: Bool, _ name: String = "") -> StatusItem {
        StatusItem(windowID: id, name: name.isEmpty ? "Item-\(id)" : name,
                   cgFrame: CGRect(x: x, y: 0, width: width, height: 39),
                   isOnScreen: drawn && !allOffScreen, ownerPID: 608, ownerName: "Control Center")
    }
    return [
        item(1, 580, 760, drawn: false, "Stale"),
        item(2, 948, 26, drawn: false),
        item(3, 974, 17, drawn: false),
        item(4, 991, 19, drawn: false),
        item(5, 1010, 19, drawn: false),
        item(6, 1029, 35, drawn: false, "Claude"),
        item(7, 1064, 28, drawn: true),
        item(8, 1092, 20, drawn: true),
        item(9, 1112, 26, drawn: true, "Amphetamine"),
        item(10, 1718, 72, drawn: false, "HiddenByItsApp"),
        item(11, 1694, 108, drawn: true, "Clock"),
    ]
}

private let swallowedIDs: Set<CGWindowID> = [2, 3, 4, 5, 6]
private let threshold: CGFloat = 1010 + 24

@Test func findsSwallowedItemsWhileTheMenuBarIsShowing() {
    var memory = MenuBarScanner.Memory()
    let snapshot = MenuBarScanner.classify(layout(), memory: &memory, fallbackThreshold: threshold)

    #expect(Set(snapshot.swallowedByNotch.map(\.windowID)) == swallowedIDs)
    #expect(snapshot.hiddenByOwner.map(\.windowID).contains(10))
    #expect(!snapshot.swallowedByNotch.map(\.windowID).contains(1))   // the stale window
    #expect(memory.cutoff == 1064)
}

/// The reported bug: with a full-screen app in front every item reports itself off screen,
/// and the shelf came up empty on every Space but the plain desktop.
@Test func stillFindsThemWithAFullScreenAppInFront() {
    var memory = MenuBarScanner.Memory()
    _ = MenuBarScanner.classify(layout(), memory: &memory, fallbackThreshold: threshold)

    let snapshot = MenuBarScanner.classify(layout(allOffScreen: true), memory: &memory,
                                           fallbackThreshold: threshold)

    #expect(Set(snapshot.swallowedByNotch.map(\.windowID)) == swallowedIDs)
    #expect(Set(snapshot.visible.map(\.windowID)) == [7, 8, 9, 11])
    #expect(snapshot.hiddenByOwner.map(\.windowID).contains(10))
    #expect(memory.cutoff == 1064)   // not overwritten by the full-screen scan
}

/// Launched while a full-screen app is already in front, so the boundary has never been seen.
@Test func findsThemOnAFirstLaunchInFullScreen() {
    var memory = MenuBarScanner.Memory()
    let snapshot = MenuBarScanner.classify(layout(allOffScreen: true), memory: &memory,
                                           fallbackThreshold: threshold)

    #expect(Set(snapshot.swallowedByNotch.map(\.windowID)) == swallowedIDs)
}

@Test func findsNothingWhenEverythingFits() {
    var memory = MenuBarScanner.Memory()
    let fitting = layout().filter { !swallowedIDs.contains($0.windowID) }
    let snapshot = MenuBarScanner.classify(fitting, memory: &memory, fallbackThreshold: threshold)

    #expect(snapshot.swallowedByNotch.isEmpty)
}

// MARK: - Scans caught mid-animation

private let screenMaxX: CGFloat = 1800

private func shifted(by dx: CGFloat) -> [StatusItem] {
    layout().map {
        StatusItem(windowID: $0.windowID, name: $0.name,
                   cgFrame: $0.cgFrame.offsetBy(dx: dx, dy: 0),
                   isOnScreen: $0.isOnScreen, ownerPID: $0.ownerPID, ownerName: $0.ownerName)
    }
}

@Test func acceptsAMenuBarAtRest() {
    #expect(MenuBarScanner.isPlausible(layout(), screenMaxX: screenMaxX))
}

/// While Spaces slide, the items are reported far off to one side. Classifying those frames
/// made the shelf's contents jump between 0 and 4 items from one second to the next.
@Test func rejectsItemsSlidOffToTheRight() {
    #expect(!MenuBarScanner.isPlausible(shifted(by: 1800), screenMaxX: screenMaxX))
}

@Test func rejectsItemsSlidOffToTheLeft() {
    #expect(!MenuBarScanner.isPlausible(shifted(by: -1800), screenMaxX: screenMaxX))
}

@Test func rejectsAnEmptyScan() {
    #expect(!MenuBarScanner.isPlausible([], screenMaxX: screenMaxX))
}
