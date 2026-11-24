import Foundation

public struct HIDKey: Hashable, Sendable {
    public let page: UInt32
    public let usage: UInt32

    public init(page: UInt32, usage: UInt32) {
        self.page = page
        self.usage = usage
    }

    public init?(controlID: String) {
        let parts = controlID.split(separator: ":")
        guard parts.count == 4, parts[0] == "hid", let page = UInt32(parts[1], radix: 16),
              let usage = UInt32(parts[2], radix: 16), UInt32(parts[3], radix: 16) != nil else { return nil }
        self.init(page: page, usage: usage)
    }

    // Only keyboard events enter Apple's keyboard-remapping filter.
    public var supportsNativeIsolation: Bool {
        (page == 0x07 && (0x04...0xE7).contains(usage) && usage != 0x66) ||
            (page == 0x0C && (1...0xFFFF).contains(usage) && !(0x30...0x32).contains(usage))
    }

    var encoded: UInt64 { UInt64(page) << 32 | UInt64(usage) }
}
