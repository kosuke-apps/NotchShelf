import Foundation
import Testing
@testable import NotchShelf

/// Fresh, empty preference domains for each test, removed afterwards.
private func domains() -> (old: UserDefaults, new: UserDefaults, cleanUp: () -> Void) {
    let oldName = "NotchShelfTests.old.\(UUID().uuidString)"
    let newName = "NotchShelfTests.new.\(UUID().uuidString)"
    let old = UserDefaults(suiteName: oldName)!
    let new = UserDefaults(suiteName: newName)!
    return (old, new, {
        old.removePersistentDomain(forName: oldName)
        new.removePersistentDomain(forName: newName)
    })
}

@Test func carriesTheKeysStillInUse() {
    let (old, new, cleanUp) = domains()
    defer { cleanUp() }
    old.set(2, forKey: "shelfRows")
    old.set(["Battery", "WiFi"], forKey: "shelfOrder")
    old.set(["Clock"], forKey: "immovableItems")
    old.set(1064.0, forKey: "lastDrawingCutoff")

    let copied = LegacySettingsMigration.run(from: old, to: new)

    #expect(Set(copied) == ["shelfRows", "shelfOrder", "immovableItems", "lastDrawingCutoff"])
    #expect(new.integer(forKey: "shelfRows") == 2)
    #expect(new.stringArray(forKey: "shelfOrder") == ["Battery", "WiFi"])
    #expect(new.stringArray(forKey: "immovableItems") == ["Clock"])
    #expect(new.double(forKey: "lastDrawingCutoff") == 1064)
}

@Test func leavesRemovedFeaturesBehind() {
    let (old, new, cleanUp) = domains()
    defer { cleanUp() }
    old.set(["Amphetamine"], forKey: "parkedItems")
    old.set(true, forKey: "allowPointerMoves")
    old.set(647, forKey: "NSStatusItem Preferred Position NotchShelfControl")

    #expect(LegacySettingsMigration.run(from: old, to: new).isEmpty)
    #expect(new.object(forKey: "parkedItems") == nil)
    #expect(new.object(forKey: "NSStatusItem Preferred Position NotchShelfControl") == nil)
}

@Test func runsOnlyOnce() {
    let (old, new, cleanUp) = domains()
    defer { cleanUp() }
    old.set(2, forKey: "shelfRows")
    LegacySettingsMigration.run(from: old, to: new)

    new.set(1, forKey: "shelfRows")          // the user changes it afterwards
    old.set(2, forKey: "shelfRows")
    #expect(LegacySettingsMigration.run(from: old, to: new).isEmpty)
    #expect(new.integer(forKey: "shelfRows") == 1)
}

@Test func neverOverwritesAValueAlreadyThere() {
    let (old, new, cleanUp) = domains()
    defer { cleanUp() }
    old.set(2, forKey: "shelfRows")
    new.set(1, forKey: "shelfRows")

    #expect(LegacySettingsMigration.run(from: old, to: new).isEmpty)
    #expect(new.integer(forKey: "shelfRows") == 1)
}

@Test func copesWithNoOldSettings() {
    let (_, new, cleanUp) = domains()
    defer { cleanUp() }
    #expect(LegacySettingsMigration.run(from: nil, to: new).isEmpty)
    #expect(new.bool(forKey: LegacySettingsMigration.doneKey))
}
