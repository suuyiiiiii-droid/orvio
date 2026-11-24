import Foundation

public struct PlatformResult: Sendable, Equatable {
    public enum Status: String, Sendable {
        case confirmed
        case submitted
        case unavailable
        case failed
    }

    public let status: Status
    public let message: String

    public init(_ status: Status, _ message: String) {
        self.status = status
        self.message = message
    }
}
