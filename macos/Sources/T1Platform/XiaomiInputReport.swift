/// The RC003 Bluetooth keyboard descriptor declares three 16-bit array entries
/// in report 1. Reports 6–8 carry vendor data and are outside the key mapper.
enum XiaomiInputReport {
    static func pressedKeys(reportID: UInt32, bytes: UnsafeBufferPointer<UInt8>) -> Set<UInt32>? {
        guard reportID == 1 else { return nil }
        let payload = bytes.count == 7 && bytes.first == 1 ? bytes.dropFirst() : bytes[...]
        guard payload.count == 6 else { return nil }
        var keys: Set<UInt32> = []
        for low in stride(from: payload.startIndex, to: payload.endIndex, by: 2) {
            let usage = UInt32(payload[low]) | (UInt32(payload[low + 1]) << 8)
            guard usage == 0 || (4...0xFE).contains(usage) else { return nil }
            if usage != 0 { keys.insert(usage) }
        }
        return keys
    }
}
