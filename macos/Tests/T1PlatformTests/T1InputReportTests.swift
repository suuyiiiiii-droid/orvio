import Foundation
import XCTest
@testable import T1Platform

final class T1InputReportTests: XCTestCase {
    func testVoiceEdgesContinueWhenAReportPathDropsAndIgnoreStaleCopies() {
        var voice = T1InputReport.VoiceEdges()
        XCTAssertTrue(voice.accept(pressed: true, tick: 100))
        XCTAssertFalse(voice.accept(pressed: true, tick: 100))
        XCTAssertTrue(voice.accept(pressed: false, tick: 115))

        // The next press can arrive only via the element callback.
        XCTAssertTrue(voice.accept(pressed: true, tick: 200))
        XCTAssertFalse(voice.accept(pressed: false, tick: 115))
        XCTAssertTrue(voice.pressed)
        XCTAssertFalse(voice.accept(pressed: true, tick: 201))
        XCTAssertTrue(voice.accept(pressed: false, tick: 215))
        XCTAssertFalse(voice.accept(pressed: false, tick: 216))
    }

    func testDirectReceiverSelectionUsesBothInterfacesAndExcludesTheHub() {
        let connected = [device("keyboard", 6), device("mouse", 2), device("hub", 6, vendorID: 0x1A86)]
        XCTAssertEqual(HIDDevice.directT1LearningGroup(in: connected), ["keyboard", "mouse"])
        XCTAssertTrue(HIDDevice.directT1LearningGroup(in: connected + [device("second", 2, locationID: 2)]).isEmpty)
        XCTAssertTrue(HIDDevice.directT1LearningGroup(in: [device("keyboard", 6), device("mouse", 2, locationID: 2)]).isEmpty)
    }

    func testArrowAndEnterReportsReleaseAndKeepSimultaneousHeldKeys() {
        let down = decode([0, 0, 0x50, 0x4F, 0x28, 0, 0, 0], .keyboard, 0)
        XCTAssertEqual(down?.page, 0x07)
        XCTAssertEqual(down?.usages, [0x50, 0x4F, 0x28])
        XCTAssertEqual(decode([0, 0, 0x4F, 0, 0, 0, 0, 0], .keyboard, 0)?.usages, [0x4F])
        XCTAssertEqual(decode(Array(repeating: 0, count: 8), .keyboard, 0)?.usages, [])
        XCTAssertNil(decode([0, 0, 1, 1, 1, 1, 1, 1], .keyboard, 0))
        XCTAssertNil(decode([0, 0, 0x50], .keyboard, 0))
    }

    func testPointerMotionDoesNotChangeTheOKButtonState() {
        let pressed = decode([0x01, 0x01, 0xF1, 0x21, 0, 0], .mediaMouse, 1)
        XCTAssertEqual(pressed?.page, 0x09)
        XCTAssertEqual(pressed?.usages, [1])
        let movedWhilePressed = decode([0x01, 0xA2, 0x33, 0, 0], .mediaMouse, 1)
        XCTAssertEqual(pressed?.usages, movedWhilePressed?.usages)
        XCTAssertEqual(decode([0, 0x12, 0x23, 0, 0], .mediaMouse, 1)?.usages, [])
        XCTAssertNil(decode([0x02, 0x01, 0, 0, 0, 0], .mediaMouse, 1))
        XCTAssertNil(decode([0x01, 0, 0, 0, 0], .consumerOnly, 1))
    }

    func testXiaomiBluetoothIdentityRequiresTheRC003KeyboardCollection() {
        func matches(vendor: Int = 0x2717, product: Int = 0x32B8,
                     transport: String = "Bluetooth Low Energy", usage: Int = 6) -> Bool {
            HIDDevice(id: "remote", fingerprint: "remote", name: "小米蓝牙语音遥控器",
                      vendorID: vendor, productID: product, locationID: 1, transport: transport,
                      usagePage: 1, usage: usage, isSharedHub: false).isXiaomiBluetoothRemote
        }
        XCTAssertTrue(matches())
        XCTAssertTrue(matches(transport: "Bluetooth"))
        XCTAssertFalse(matches(transport: "USB"))
        XCTAssertFalse(matches(vendor: 0x32C2))
        XCTAssertFalse(matches(product: 0x32B9))
        XCTAssertFalse(matches(usage: 2))
    }

    func testXiaomiKeyboardReportsUseThreeLittleEndianSlots() {
        func keys(_ bytes: [UInt8], id: UInt32 = 1) -> Set<UInt32>? {
            bytes.withUnsafeBufferPointer { XiaomiInputReport.pressedKeys(reportID: id, bytes: $0) }
        }
        XCTAssertEqual(keys([0x01, 0x28, 0, 0x50, 0, 0x80, 0]), [0x28, 0x50, 0x80])
        XCTAssertEqual(keys([0x3E, 0, 0x81, 0, 0, 0]), [0x3E, 0x81])
        XCTAssertEqual(keys([0x01, 0, 0, 0, 0, 0, 0]), [])
        XCTAssertNil(keys([0x01, 0, 0, 0, 0, 0, 0], id: 6))
        XCTAssertNil(keys([0x02, 0x28, 0, 0, 0, 0, 0]))
        XCTAssertNil(keys([0x28, 1, 0, 0, 0, 0]))
        XCTAssertNil(keys([0x01, 0, 0, 0, 0, 0]))
    }

    private func decode(_ bytes: [UInt8], _ layout: T1InputReport.Layout, _ id: UInt32)
        -> (page: UInt32, usages: Set<UInt32>)? {
        bytes.withUnsafeBufferPointer { T1InputReport.pressedKeys(layout: layout, reportID: id, bytes: $0) }
    }

    private func device(_ id: String, _ usage: Int, vendorID: Int = 0x1915, locationID: UInt32 = 1) -> HIDDevice {
        HIDDevice(id: id, fingerprint: id, name: id, vendorID: vendorID,
                  productID: 0x1025, locationID: locationID, transport: "USB", usagePage: 1,
                  usage: usage, isSharedHub: vendorID == 0x1A86)
    }
}
