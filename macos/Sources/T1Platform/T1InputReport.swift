import Foundation

/// Raw input for the two descriptor layouts observed on the 1915:1025 USB receiver.
enum T1InputReport {
    struct VoiceEdges {
        private(set) var pressed = false
        private var lastTick: UInt64?

        mutating func accept(pressed next: Bool, tick: UInt64) -> Bool {
            if let lastTick, tick <= lastTick { return false }
            lastTick = tick
            guard next != pressed else { return false }
            pressed = next
            return true
        }
    }

    enum Layout: Equatable {
        case keyboard, mediaMouse, consumerOnly

        private static let keyboardDescriptor = Data([
            0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
            0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x75, 0x08, 0x95, 0x01, 0x81, 0x03,
            0x75, 0x01, 0x95, 0x05, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x75, 0x03, 0x95, 0x01, 0x91, 0x03,
            0x75, 0x08, 0x95, 0x06, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x05, 0x07, 0x19, 0x00, 0x2A, 0xFF, 0x00, 0x81, 0x00, 0xC0
        ])
        private static let mouseCollection = Data([
            0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x01, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01,
            0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x03, 0x81, 0x01,
            0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
            0x05, 0x0C, 0x0A, 0x38, 0x02, 0x95, 0x01, 0x81, 0x06, 0xC0, 0xC0
        ])
        private static let consumerCollection = Data([
            0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x02, 0x15, 0x00, 0x26, 0x3C, 0x04,
            0x19, 0x00, 0x2A, 0x3C, 0x04, 0x95, 0x01, 0x75, 0x10, 0x81, 0x00, 0xC0
        ])

        init?(descriptor: Data, primaryUsage: Int) {
            if primaryUsage == 0x06, descriptor == Self.keyboardDescriptor {
                self = .keyboard
            } else if primaryUsage == 0x02, descriptor.range(of: Self.consumerCollection) != nil {
                self = descriptor.starts(with: Self.mouseCollection) ? .mediaMouse : .consumerOnly
            } else {
                return nil
            }
        }

        func covers(page: UInt32, reportID: UInt32) -> Bool {
            switch self {
            case .keyboard: return reportID == 0 && page == 0x07
            case .mediaMouse: return (reportID == 0x01 && page == 0x09) || (reportID == 0x02 && page == 0x0C)
            case .consumerOnly: return reportID == 0x02 && page == 0x0C
            }
        }
    }

    static func pressedKeys(
        layout: Layout, reportID: UInt32, bytes: UnsafeBufferPointer<UInt8>
    ) -> (page: UInt32, usages: Set<UInt32>)? {
        switch (layout, reportID) {
        case (.keyboard, 0):
            guard bytes.count == 8 else { return nil }
            let keys = bytes.dropFirst(2)
            // ErrorRollOver, POSTFail and ErrorUndefined are not keys. Do not
            // release an existing press until a valid keyboard report arrives.
            guard !keys.contains(where: { (1...3).contains($0) }) else { return nil }
            return (0x07, Set(keys.lazy.filter { $0 != 0 }.map(UInt32.init)).union(bits(bytes[0], count: 8, first: 0xE0)))
        case (.mediaMouse, 0x01):
            let buttonBits: UInt8
            switch bytes.count {
            case 5: buttonBits = bytes[0]
            case 6 where bytes[0] == 0x01: buttonBits = bytes[1]
            default: return nil
            }
            return (0x09, bits(buttonBits, count: 5, first: 1))
        default: return nil
        }
    }

    private static func bits(_ value: UInt8, count: Int, first: UInt32) -> Set<UInt32> {
        Set((0..<count).compactMap { value & (1 << $0) == 0 ? nil : first + UInt32($0) })
    }
}
