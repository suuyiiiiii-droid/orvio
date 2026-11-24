import XCTest
@testable import T1Platform

final class NativeKeyMapTests: XCTestCase {
    func testMappedModesOwnOnlyTheRequestedReturnAndNativeModeRestoresTheOriginalMap() {
        let unrelated = mapping(0x39, to: 0xE0)
        let returnKey = mapping(0x28, to: 0)
        let keypadEnter = mapping(0x58, to: 0)

        let media = NativeKeyMap.reconcile([unrelated], owned: [], desired: NativeKeyMap.mute([key(0x28)]))
        XCTAssertEqual(media.merged, [unrelated, returnKey])
        XCTAssertEqual(media.owned, [returnKey])

        let host = NativeKeyMap.reconcile(media.merged, owned: media.owned, desired: NativeKeyMap.mute([key(0x58)]))
        XCTAssertEqual(host.merged, [unrelated, keypadEnter])
        XCTAssertEqual(host.owned, [keypadEnter])

        let native = NativeKeyMap.reconcile(host.merged, owned: host.owned, desired: [])
        XCTAssertEqual(native.merged, [unrelated])
        XCTAssertTrue(native.owned.isEmpty)
    }

    func testAnExistingReturnMappingKeepsItsOwnerEvenIfItAlreadyMutesTheKey() {
        let requested = NativeKeyMap.mute([key(0x28)])
        XCTAssertEqual(requested, [mapping(0x28, to: 0)])
        for existing in [mapping(0x28, to: 0), mapping(0x28, to: 0x2C)] {
            let change = NativeKeyMap.reconcile([existing], owned: [], desired: requested)
            XCTAssertEqual(change.merged, [existing])
            XCTAssertTrue(change.owned.isEmpty)
        }
    }

    func testExternalEditsToOwnedSourcesSurviveModeChange() {
        let external = mapping(0x28, to: 0x2C)
        let native = NativeKeyMap.reconcile([external], owned: NativeKeyMap.mute([key(0x28)]), desired: [])
        XCTAssertEqual(native.merged, [external])
        XCTAssertTrue(native.owned.isEmpty)
    }

    func testArrowAndConsumerKeysAreIsolatedTogetherAndReleaseRestoresExistingMaps() {
        let keys: Set<HIDKey> = [key(0x4F), key(0x50), HIDKey(page: 0x0C, usage: 0xE9)]
        let map = NativeKeyMap.mute(keys)
        XCTAssertEqual(map.count, 3)
        XCTAssertEqual(map.last?["HIDKeyboardModifierMappingSrc"], 0xC000000E9)
        XCTAssertTrue(map.allSatisfy(NativeKeyMap.isOwnedEntry))
        XCTAssertTrue(NativeKeyMap.reconcile(map, owned: map, desired: []).merged.isEmpty)
    }

    func testMousePowerAndMalformedControlsCannotClaimIsolation() {
        XCTAssertTrue(NativeKeyMap.mute([HIDKey(page: 9, usage: 1), key(0x66), HIDKey(page: 12, usage: 0x30)]).isEmpty)
        XCTAssertNil(HIDKey(controlID: "key:0D/1C/0"))
        XCTAssertNil(HIDKey(controlID: "hid:0007:0028:INVALID"))
        XCTAssertEqual(HIDKey(controlID: "hid:000C:00E9:02"), HIDKey(page: 12, usage: 0xE9))
    }

    private func key(_ usage: UInt32) -> HIDKey { HIDKey(page: 7, usage: usage) }

    private func mapping(_ source: UInt64, to destination: UInt64) -> NativeKeyMap.Entry {
        ["HIDKeyboardModifierMappingSrc": 0x700000000 | source,
         "HIDKeyboardModifierMappingDst": 0x700000000 | destination]
    }
}
