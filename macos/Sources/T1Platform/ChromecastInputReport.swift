import Foundation

/// Decoded independently from the HID descriptor and observed 0x011B reports.
/// The affected firmware omits the third (numeric-button) byte of report 2.
enum ChromecastInputReport {
    static let consumerUsages: Set<UInt32> = [
        0x30, 0x41, 0x42, 0x43, 0x44, 0x45, 0x77, 0x78,
        0xB5, 0xB6, 0xCD, 0xE2, 0xE9, 0xEA, 0x189, 0x19E, 0x221, 0x223, 0x224
    ]

    static func pressedKeys(reportID: UInt32, bytes: [UInt8]) -> (page: UInt32, usages: Set<UInt32>)? {
        switch reportID {
        case 2:
            // IOKit may include the report ID. A three-byte payload is otherwise
            // unprefixed: only the four-byte form has an unambiguous ID prefix.
            let payload = bytes.count == 4 && bytes.first == 2 ? Array(bytes.dropFirst()) : bytes
            guard payload.count == 2 || payload.count == 3 else { return nil }
            // Numeric buttons are a separate descriptor field, not a consumer usage.
            guard payload.count == 2 || payload[2] == 0 else { return nil }
            let usage = UInt32(payload[0]) | UInt32(payload[1]) << 8
            guard usage == 0 || consumerUsages.contains(usage) else { return nil }
            return (0x0C, usage == 0 ? [] : [usage])
        case 1:
            let payload = bytes.count == 9 && bytes.first == 1 ? Array(bytes.dropFirst()) : bytes
            guard payload.count == 8, payload[1] == 0 else { return nil }
            let slots = payload.dropFirst(2)
            guard slots.allSatisfy({ $0 == 0 || (4...0xEB).contains($0) }) else { return nil }
            var usages = Set(slots.filter { $0 != 0 }.map(UInt32.init))
            for bit in 0..<8 where payload[0] & (1 << bit) != 0 { usages.insert(UInt32(0xE0 + bit)) }
            return (0x07, usages)
        default: return nil
        }
    }
}

/// Input report IDs, including constant fields. Unknown/malformed descriptors
/// cannot establish ownership of a system-log report and therefore fail closed.
enum HIDReportDescriptor {
    static func inputBitCounts(_ data: Data) -> [UInt32: Int]? {
        let bytes = Array(data)
        struct Globals { var id: UInt32 = 0; var size = 0; var count = 0 }
        var globals = Globals(), stack: [Globals] = [], result: [UInt32: Int] = [:]
        var index = 0
        while index < bytes.count {
            let prefix = bytes[index]; index += 1
            if prefix == 0xFE {
                guard index + 2 <= bytes.count else { return nil }
                let count = Int(bytes[index]); index += 2
                guard index + count <= bytes.count else { return nil }
                index += count
                continue
            }
            let count = prefix & 3 == 3 ? 4 : Int(prefix & 3)
            guard index + count <= bytes.count else { return nil }
            let value = (0..<count).reduce(UInt32(0)) { $0 | UInt32(bytes[index + $1]) << (8 * $1) }
            index += count
            switch prefix & 0xFC {
            case 0x74: guard value <= 65_536 else { return nil }; globals.size = Int(value)
            case 0x84: guard (1...255).contains(value) else { return nil }; globals.id = value
            case 0x94: guard value <= 65_536 else { return nil }; globals.count = Int(value)
            case 0xA4: stack.append(globals)
            case 0xB4: guard let saved = stack.popLast() else { return nil }; globals = saved
            case 0x80:
                let bits = globals.size * globals.count
                guard bits > 0, bits <= 1_048_576, result[globals.id, default: 0] <= 1_048_576 - bits else { return nil }
                result[globals.id, default: 0] += bits
            default: break
            }
        }
        return stack.isEmpty && !result.isEmpty ? result : nil
    }
}

enum ChromecastLogParser {
    enum Result: Equatable { case ignored, redacted, report(Set<UInt32>) }

    static func parse(_ data: Data) -> Result {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["subsystem"] as? String == "com.apple.bluetooth",
              record["category"] as? String == "BTLEServer",
              record["processImagePath"] as? String == "/usr/sbin/BTLEServer",
              let message = record["eventMessage"] as? String,
              message.hasPrefix("Updated input report for ID #2: ") else { return .ignored }
        if message.hasSuffix("<private>") { return .redacted }
        // Only this firmware's two-byte consumer payload is accepted. Do not
        // reinterpret keyboard logs or reports from healthy firmware.
        let prefix = "Updated input report for ID #2: {length = 2, bytes = 0x"
        guard message.hasPrefix(prefix), message.hasSuffix("}") else { return .ignored }
        let hex = message.dropFirst(prefix.count).dropLast()
        guard hex.count == 4, hex.allSatisfy(\.isHexDigit), let low = UInt8(hex.prefix(2), radix: 16),
              let high = UInt8(hex.suffix(2), radix: 16),
              let decoded = ChromecastInputReport.pressedKeys(reportID: 2, bytes: [low, high]) else { return .ignored }
        return .report(decoded.usages)
    }
}

/// BTLEServer's report line has no peripheral identifier. Never infer ownership
/// from timing: reject another short report-2 producer. Known larger report
/// layouts are distinguishable by length; unknown descriptors are not.
enum ChromecastLogTopology {
    struct Endpoint {
        let id: String
        let affectedChromecast: Bool
        let inputReports: [UInt32: Int]?
    }

    static func eligibleDevice(in endpoints: [Endpoint]) -> String? {
        let targets = endpoints.filter(\.affectedChromecast)
        guard targets.count == 1, let target = targets.first, target.inputReports?[2] == 24 else { return nil }
        guard endpoints.allSatisfy({ endpoint in
            endpoint.id == target.id || (endpoint.inputReports != nil &&
                (endpoint.inputReports?[2] == nil || endpoint.inputReports![2]! > 24))
        }) else { return nil }
        return target.id
    }
}
