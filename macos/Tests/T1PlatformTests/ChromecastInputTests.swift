import Foundation
import XCTest
@testable import T1Platform

final class ChromecastInputTests: XCTestCase {
    // Descriptor read from this Mac's 18D1:9450, firmware 0x011B.
    private let descriptor = "05010906a101850175019508050719e029e715002501810295017508810195057501050819012905910295017503910195067508150025eb0507190029eb8100c0050c0901a101850219002a9c021500269c029501751081000902a10205091901290a1501250a950175088140c0c005010902a10185030901a1000509190129051500250195057501810295017503810305010930093109381581257f750895038106c0c00601ff0901a102851e0914750895141580257f8122c00680ff0900a1808505150026ff00750895140900810209009102c0"

    func testObservedShortReportsPreserveEachRelease() {
        for (bytes, usage) in [([UInt8(0x42), 0], UInt32(0x42)), ([0x41, 0], 0x41), ([0x24, 2], 0x224)] {
            XCTAssertEqual(ChromecastInputReport.pressedKeys(reportID: 2, bytes: bytes)?.usages, [usage])
            XCTAssertEqual(ChromecastInputReport.pressedKeys(reportID: 2, bytes: [0, 0])?.usages, [])
        }
    }

    func testCapturedPowerAndInputKeysReachTheSamePressAndReleaseDecoder() throws {
        // Physical sequence captured locally: Up, Power, Input, Up, each released.
        for (payload, usage, hex) in [([UInt8(0x9E), 0x01], UInt32(0x019E), "9e01"),
                                     ([0x89, 0x01], 0x0189, "8901")] {
            XCTAssertEqual(ChromecastInputReport.pressedKeys(reportID: 2, bytes: payload)?.usages, [usage])
            XCTAssertEqual(try parse("Updated input report for ID #2: {length = 2, bytes = 0x\(hex)}"), .report([usage]))
            XCTAssertEqual(try parse("Updated input report for ID #2: {length = 2, bytes = 0x0000}"), .report([]))
            XCTAssertTrue(HIDKey(page: 0x0C, usage: usage).supportsNativeIsolation)
        }
        // Preserve the policy for actual system power/sleep usages.
        XCTAssertFalse(HIDKey(page: 0x0C, usage: 0x30).supportsNativeIsolation)
    }

    func testHealthyConsumerAndBootKeyboardLayoutsDoNotConfuseReportIDsWithPayloads() {
        XCTAssertEqual(ChromecastInputReport.pressedKeys(reportID: 2, bytes: [0xE9, 0, 0])?.usages, [0xE9])
        XCTAssertEqual(ChromecastInputReport.pressedKeys(reportID: 2, bytes: [2, 0xEA, 0, 0])?.usages, [0xEA])
        XCTAssertNil(ChromecastInputReport.pressedKeys(reportID: 2, bytes: [0x41, 0, 1]))
        XCTAssertNil(ChromecastInputReport.pressedKeys(reportID: 2, bytes: [2, 0x41, 0]))
        XCTAssertNil(ChromecastInputReport.pressedKeys(reportID: 2, bytes: [0xFF, 0xFF]))
        XCTAssertNil(ChromecastInputReport.pressedKeys(reportID: 5, bytes: [0x41, 0]))
        XCTAssertEqual(ChromecastInputReport.pressedKeys(reportID: 1, bytes: [1, 2, 0, 0x28, 0, 0, 0, 0, 0])?.usages,
                       [0xE1, 0x28])
        XCTAssertNil(ChromecastInputReport.pressedKeys(reportID: 1, bytes: [0, 0, 1, 1, 1, 1, 1, 1]))
    }

    func testDescriptorProvesReport2DeclaresThreeBytes() {
        let bytes = stride(from: 0, to: descriptor.count, by: 2).map { offset in
            UInt8(descriptor.dropFirst(offset).prefix(2), radix: 16)!
        }
        let counts = HIDReportDescriptor.inputBitCounts(Data(bytes))
        XCTAssertEqual(counts?[1], 64)
        XCTAssertEqual(counts?[2], 24)
        XCTAssertEqual(counts?[3], 32)
        XCTAssertEqual(counts?[0x1E], 160)
        XCTAssertEqual(counts?[5], 160)
    }

    func testMalformedDescriptorCannotAuthorizeLogOwnership() {
        for bytes: [UInt8] in [[], [0x85], [0xFE, 2], [0xB4], [0xA4, 0x75, 8, 0x95, 2, 0x81, 0]] {
            XCTAssertNil(HIDReportDescriptor.inputBitCounts(Data(bytes)))
        }
        // Global push/pop must restore the report ID and size.
        let scoped: [UInt8] = [0x85, 1, 0x75, 8, 0x95, 1, 0xA4, 0x85, 2, 0x95, 3, 0x81, 0, 0xB4, 0x81, 0]
        XCTAssertEqual(HIDReportDescriptor.inputBitCounts(Data(scoped)), [1: 8, 2: 24])
    }

    func testAmbiguousBluetoothTopologyPausesInsteadOfControllingAnotherDevice() {
        let remote = endpoint("remote", affected: true, reports: [1: 64, 2: 24])
        let mouse = endpoint("mouse", reports: [1: 64])
        XCTAssertEqual(ChromecastLogTopology.eligibleDevice(in: [remote, mouse]), "remote")
        // This Mac's ANTICATER_MINI and BT5.1 Mouse both declare an eight-byte
        // keyboard report 2. Their reports cannot match the two-byte parser.
        XCTAssertEqual(ChromecastLogTopology.eligibleDevice(in: [remote, endpoint("mouse-keyboard", reports: [2: 64])]), "remote")
        XCTAssertNil(ChromecastLogTopology.eligibleDevice(in: []))
        XCTAssertNil(ChromecastLogTopology.eligibleDevice(in: [remote, endpoint("other", reports: [2: 16])]))
        XCTAssertNil(ChromecastLogTopology.eligibleDevice(in: [remote, endpoint("other3", reports: [2: 24])]))
        XCTAssertNil(ChromecastLogTopology.eligibleDevice(in: [remote, endpoint("unknown", reports: nil)]))
        XCTAssertNil(ChromecastLogTopology.eligibleDevice(in: [remote, endpoint("second", affected: true, reports: [2: 24])]))
        XCTAssertNil(ChromecastLogTopology.eligibleDevice(in: [endpoint("healthy", reports: [2: 24])]))
        XCTAssertNil(ChromecastLogTopology.eligibleDevice(in: [endpoint("wrong-layout", affected: true, reports: [2: 16])]))
    }

    func testLogParserAcceptsObservedPayloadAndRedactionWithoutGuessing() throws {
        XCTAssertEqual(try parse("Updated input report for ID #2: {length = 2, bytes = 0x4200}"), .report([0x42]))
        XCTAssertEqual(try parse("Updated input report for ID #2: {length = 2, bytes = 0x0000}"), .report([]))
        XCTAssertEqual(try parse("Updated input report for ID #2: <private>"), .redacted)
        for message in ["Updated input report for ID #1: {length = 2, bytes = 0x4100}",
                        "Updated input report for ID #2: {length = 3, bytes = 0x410000}",
                        "Updated input report for ID #2: {length = 2, bytes = 0xffff}",
                        "Updated input report for ID #2: {length = 2, bytes = 0x41zz}",
                        "Updated input report for ID #2: {length = 2, bytes = 0x4100} trailing"] {
            XCTAssertEqual(try parse(message), .ignored)
        }
        XCTAssertEqual(try parse("Updated input report for ID #2: {length = 2, bytes = 0x4100}", process: "/tmp/BTLEServer"), .ignored)
        XCTAssertEqual(ChromecastLogParser.parse(Data("not json".utf8)), .ignored)
    }

    func testChromecastIdentityCannotMatchUSBHubOrOtherBluetoothKeyboards() {
        func remote(vendor: Int = 0x18D1, product: Int = 0x9450, transport: String = "Bluetooth Low Energy", usage: Int = 6) -> HIDDevice {
            HIDDevice(id: "test", fingerprint: "test", name: "Chromecast Remote", vendorID: vendor,
                      productID: product, locationID: 1, transport: transport, usagePage: 1, usage: usage, isSharedHub: false)
        }
        XCTAssertTrue(remote().isChromecastRemote)
        XCTAssertFalse(remote(vendor: 0x1A86).isChromecastRemote)
        XCTAssertFalse(remote(product: 0x9451).isChromecastRemote)
        XCTAssertFalse(remote(transport: "USB").isChromecastRemote)
        XCTAssertFalse(remote(usage: 2).isChromecastRemote)
    }

    private func endpoint(_ id: String, affected: Bool = false, reports: [UInt32: Int]?) -> ChromecastLogTopology.Endpoint {
        .init(id: id, affectedChromecast: affected, inputReports: reports)
    }

    private func parse(_ message: String, process: String = "/usr/sbin/BTLEServer") throws -> ChromecastLogParser.Result {
        ChromecastLogParser.parse(try JSONSerialization.data(withJSONObject: ["eventMessage": message,
            "subsystem": "com.apple.bluetooth", "category": "BTLEServer", "processImagePath": process]))
    }
}
