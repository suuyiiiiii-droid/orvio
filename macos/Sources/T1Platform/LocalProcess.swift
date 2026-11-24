import Darwin
import Foundation

struct LocalProcess {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
    }

    enum Failure: Error {
        case timeout
        case lostOutput
    }

    static func run(
        _ executable: URL,
        arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Swift.Result {
                    try runSynchronously(executable, arguments: arguments, input: input, timeout: timeout)
                })
            }
        }
    }

    private static func runSynchronously(
        _ executable: URL,
        arguments: [String],
        input: Data?,
        timeout: TimeInterval
    ) throws -> Result {
        let process = Process()
        let output = Pipe()
        let inputPipe = input.map { _ in Pipe() }
        let exited = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        let stdout = Output()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        if let inputPipe {
            let fileDescriptor = inputPipe.fileHandleForWriting.fileDescriptor
            guard fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        try process.run()

        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            while let bytes = try? reader.read(upToCount: 8_192), !bytes.isEmpty {
                stdout.append(bytes)
            }
            drained.signal()
        }
        if let input, let writer = inputPipe?.fileHandleForWriting {
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? writer.close() }
                try? writer.write(contentsOf: input)
            }
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            if exited.wait(timeout: .now() + .milliseconds(500)) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw Failure.timeout
        }
        guard drained.wait(timeout: .now() + .seconds(1)) == .success else {
            throw Failure.lostOutput
        }
        return Result(status: process.terminationStatus, stdout: stdout.text)
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit = 262_144

        func append(_ bytes: Data) {
            lock.withLock {
                data.append(bytes.prefix(max(0, limit - data.count)))
            }
        }

        var text: String {
            lock.withLock {
                String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
