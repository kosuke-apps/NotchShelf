import Foundation

/// User-visible options, kept in UserDefaults so they survive a relaunch.
final class Settings {
    static let shared = Settings()

    private enum Key {
        static let rows = "shelfRows"
        static let parked = "parkedItems"
        static let order = "shelfOrder"
        static let immovable = "immovableItems"
        static let allowPointerMoves = "allowPointerMoves"
    }

    private let defaults = UserDefaults.standard

    var onChange: (() -> Void)?

    init() {
        defaults.register(defaults: [Key.rows: 1])
    }

    /// How many rows tall the shelf is. One row keeps it exactly the size of the notch; two
    /// splits it into a parked row and a swallowed row.
    var rows: Int {
        get { max(1, min(2, defaults.integer(forKey: Key.rows))) }
        set {
            defaults.set(max(1, min(2, newValue)), forKey: Key.rows)
            onChange?()
        }
    }

    /// Items the user deliberately keeps out of the menu bar, as opposed to the ones the notch
    /// swallowed on its own. Physically both sit behind the notch — the distinction is the
    /// user's intent, which only we can record.
    var parked: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.parked) ?? []) }
        set {
            defaults.set(Array(newValue).sorted(), forKey: Key.parked)
            onChange?()
        }
    }

    func park(_ name: String) { parked.insert(name) }
    func unpark(_ name: String) { parked.remove(name) }

    /// Whether NotchShelf may rearrange the menu bar on the user's behalf.
    ///
    /// Off by default, and deliberately so: the only gesture macOS accepts for this is a real
    /// command-drag through the HID event tap, which means borrowing the pointer for about a
    /// second. Every alternative was tried and none work — the accessibility API exposes no
    /// settable position, events posted straight to the host process do nothing, and the stored
    /// position preferences are only read when an app launches.
    var allowsPointerMoves: Bool {
        get { defaults.bool(forKey: Key.allowPointerMoves) }
        set {
            defaults.set(newValue, forKey: Key.allowPointerMoves)
            onChange?()
        }
    }

    /// Items macOS refuses to let anyone drag — the clock and Control Center are pinned to the
    /// right end. There is no way to ask in advance, so this is learned from failed attempts
    /// and remembered, both to stop retrying and to grey the buttons out.
    var immovable: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.immovable) ?? []) }
        set {
            defaults.set(Array(newValue).sorted(), forKey: Key.immovable)
            onChange?()
        }
    }

    /// Only names that actually identify an item are worth remembering. Apps that never set an
    /// autosave name all share the placeholder "Item-N", so recording one of those would
    /// blacklist every unnamed item in the bar. Those stay session-local instead.
    func markImmovable(_ name: String) {
        guard !name.isEmpty, !name.hasPrefix("Item-") else { return }
        immovable.insert(name)
    }

    /// The order the user arranged the shelf in. Names not listed fall back to menu bar order.
    var order: [String] {
        get { defaults.stringArray(forKey: Key.order) ?? [] }
        set {
            defaults.set(newValue, forKey: Key.order)
            onChange?()
        }
    }

    /// Sorts by the user's arrangement, keeping unknown items in their original order at the end.
    func arrange<T>(_ items: [T], name: (T) -> String) -> [T] {
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return items.enumerated().sorted { a, b in
            let ia = index[name(a.element)], ib = index[name(b.element)]
            switch (ia, ib) {
            case let (x?, y?): return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}
