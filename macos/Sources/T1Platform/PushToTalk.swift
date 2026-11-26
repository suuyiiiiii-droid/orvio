import AudioToolbox
import AVFoundation
import CryptoKit
import Foundation
import OSLog
import Speech

private let captureLog = Logger(subsystem: "local.t1controller.app", category: "Capture")

public struct WhisperConfiguration: Codable, Sendable, Equatable {
    public let executablePath: String
    public let modelPath: String
    public let modelSHA256: String?

    public init(executablePath: String, modelPath: String, modelSHA256: String? = nil) {
        self.executablePath = executablePath
        self.modelPath = modelPath
        self.modelSHA256 = modelSHA256
    }
}

public struct VoiceRecognition: Sendable, Equatable {
    public let transcript: String?
    public let result: PlatformResult

    fileprivate init(_ status: PlatformResult.Status, _ message: String, transcript: String? = nil) {
        self.transcript = transcript
        self.result = PlatformResult(status, message)
    }
}

public struct AudioCaptureDiagnostics: Sendable, Equatable {
    public let capturedSeconds: TimeInterval
    public let peak: Float
    public let strongestRMS: Float
    public let reconfigurations: Int
    public let isRecovering: Bool
}

@MainActor
public final class PushToTalk {
    private let duration: TimeInterval = 15
    private let captureQueue = DispatchQueue(label: "T1Controller.AudioCapture")
    private let sessionQueue = DispatchQueue(label: "T1Controller.AudioSession")
    private var attempt: UUID?
    private var activeCapture: Capture?
    private var maxDurationTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var speechRecognition: OnDeviceRecognition?
    private var lastCancellation: PlatformResult?
    public var onCancellation: (@MainActor (PlatformResult) -> Void)?

    public var isRecording: Bool { activeCapture != nil }
    public var level: Float { activeCapture?.route.pcm.segments.last?.level ?? 0 }
    public var inputName: String? { activeCapture?.inputName }
    public var secondsSinceSpeech: TimeInterval? {
        activeCapture?.segments.compactMap(\.secondsSinceSpeech).min()
    }
    public var secondsSinceLastAudioBuffer: TimeInterval? {
        activeCapture?.route.pcm.secondsSinceLastBuffer
    }
    public var classifiedTrailingSilence: TimeInterval? {
        activeCapture?.route.pcm.segments.last?.speechActivity?.trailingSilence
    }
    public var captureDiagnostics: AudioCaptureDiagnostics? {
        guard let capture = activeCapture else { return nil }
        let readings = capture.segments.map(\.reading)
        return AudioCaptureDiagnostics(
            capturedSeconds: readings.reduce(0) { $0 + $1.seconds },
            peak: readings.map(\.peak).max() ?? 0,
            strongestRMS: readings.map(\.strongestRMS).max() ?? 0,
            reconfigurations: capture.reconfigurations,
            isRecovering: recoveryTask != nil
        )
    }

    public init() {}

    public static func inputDevices() -> [AudioInputInfo] {
        AudioHardware.inputDevices().map(\.info)
    }

    public static var microphoneAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func begin(deviceUID: String? = nil, classifySpeech: Bool = false) -> PlatformResult {
        guard attempt == nil else { return .init(.unavailable, "语音会话正在进行。") }
        guard Self.microphoneAllowed else {
            return .init(.unavailable, "请授权麦克风，再按住说话。")
        }
        let devices = AudioHardware.inputDevices()
        guard let currentInput = devices.first(where: { device in
            deviceUID.map { $0 == device.info.uid } ?? device.info.isDefault
        }) else { return .init(.unavailable, "所选麦克风未连接。") }
        let id = UUID()
        do {
            activeCapture = try openCapture(
                currentInput, explicit: deviceUID != nil, attemptID: id,
                classifySpeech: classifySpeech && currentInput.info.name == "Mic Device"
            )
        } catch let error as CaptureFailure {
            return error.result
        } catch {
            return .init(.failed, "麦克风启动失败。请确认设备连接和系统权限。")
        }

        attempt = id
        lastCancellation = nil
        if let activeCapture { start(activeCapture, attemptID: id) }
        maxDurationTask = Task { [weak self, duration] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, self.attempt == id, self.activeCapture != nil else { return }
            self.cancel(.init(.unavailable, "录音已达 15 秒，本次语音已取消。"))
        }
        return .init(.submitted, "正在启动「\(currentInput.info.name)」录音。")
    }

    private func openCapture(
        _ device: (id: AudioDeviceID, info: AudioInputInfo),
        explicit: Bool,
        attemptID: UUID,
        classifySpeech: Bool,
        previous: Capture? = nil
    ) throws -> Capture {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
        let defaultSource = AVCaptureDevice.default(for: .audio)
        guard let source = devices.first(where: { $0.uniqueID == device.info.uid })
            ?? defaultSource.flatMap({ $0.uniqueID == device.info.uid ? $0 : nil }) else {
            throw CaptureFailure(.unavailable, "系统录音接口未找到「\(device.info.name)」。")
        }
        let earlier = previous?.segments ?? []
        let remaining = duration - earlier.reduce(0) { $0 + $1.reading.seconds }
        guard remaining > 0 else { throw CaptureFailure(.unavailable, "录音已达 15 秒，本次语音已取消。") }
        let route = try CaptureRoute(
            source: source, duration: remaining, classifySpeech: classifySpeech,
            captureQueue: captureQueue, sessionQueue: sessionQueue
        )
        let routeID = UUID()
        let center = NotificationCenter.default
        let listeners = [
            AVCaptureSession.runtimeErrorNotification, AVCaptureSession.didStopRunningNotification
        ].map { name in
            center.addObserver(forName: name, object: route.session, queue: nil) { [weak self] notification in
                if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                    captureLog.error("Capture runtime error domain=\(error.domain, privacy: .public) code=\(error.code)")
                }
                Task { @MainActor [weak self] in
                    self?.configurationChanged(attemptID: attemptID, routeID: routeID)
                }
            }
        }
        let reconfigurations = previous.map { $0.reconfigurations + 1 } ?? 0
        captureLog.info("Capture configured explicit=\(explicit) recovery=\(reconfigurations) source=\(device.info.name, privacy: .public)")
        return Capture(
            route: route, listeners: listeners, earlier: earlier, inputName: device.info.name,
            inputUID: device.info.uid, explicit: explicit, routeID: routeID, reconfigurations: reconfigurations
        )
    }

    private func start(_ capture: Capture, attemptID: UUID) {
        let routeID = capture.routeID
        capture.route.start { [weak self] running in
            captureLog.info("Capture session start result running=\(running)")
            if !running {
                Task { @MainActor [weak self] in
                    self?.configurationChanged(attemptID: attemptID, routeID: routeID)
                }
            }
        }
    }

    private func configurationChanged(attemptID: UUID, routeID: UUID) {
        guard attempt == attemptID, let capture = activeCapture, capture.routeID == routeID,
              !capture.route.session.isRunning, recoveryTask == nil else { return }
        guard capture.reconfigurations == 0 else {
            cancel(.init(.failed, "「\(capture.inputName)」重新连接后再次停止，录音已取消。"))
            return
        }
        captureLog.info("Capture session stopped; retrying the same input")
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, self.attempt == attemptID, let current = self.activeCapture,
                  current.routeID == routeID else { return }
            self.recoveryTask = nil
            if current.route.session.isRunning { return }
            guard let device = AudioHardware.inputDevices().first(where: {
                $0.info.uid == current.inputUID && (current.explicit || $0.info.isDefault)
            }) else {
                self.cancel(.init(.failed, "「\(current.inputName)」已断开或不再是当前输入，录音已取消。"))
                return
            }
            self.activeCapture = nil
            current.close()
            do {
                let replacement = try self.openCapture(
                    device, explicit: current.explicit, attemptID: attemptID,
                    classifySpeech: current.route.pcm.classifiesSpeech, previous: current
                )
                self.activeCapture = replacement
                self.start(replacement, attemptID: attemptID)
            } catch let error as CaptureFailure {
                self.cancel(error.result)
            } catch {
                self.cancel(.init(.failed, "「\(current.inputName)」重新连接失败，录音已取消。"))
            }
        }
    }

    public func finish(
        using config: WhisperConfiguration? = nil, onCaptureStopped: () -> Void = {}
    ) async -> VoiceRecognition {
        guard let id = attempt, let capture = activeCapture else {
            let result = lastCancellation ?? .init(.unavailable, "当前没有待识别的录音。")
            return VoiceRecognition(result.status, result.message)
        }
        let sessionWasRunning = capture.route.session.isRunning
        logEnd(cancelled: false)
        stopCapture()
        defer {
            if attempt == id {
                attempt = nil
                speechRecognition = nil
            }
        }
        await capture.route.waitForStop()
        guard attempt == id, !Task.isCancelled else { return .init(.unavailable, "本次语音已取消。") }
        onCaptureStopped()
        let segments = capture.segments.map { ($0.snapshot(), $0.sampleRate) }
        let capturedSeconds = segments.reduce(0) { $0 + Double($1.0.values.count) / $1.1 }
        guard capturedSeconds < duration, !segments.contains(where: { $0.0.reachedLimit }) else {
            return .init(.unavailable, "录音已达 15 秒，本次语音已取消。")
        }
        guard capturedSeconds > 0 else {
            if !sessionWasRunning { return .init(.failed, "录音设备未就绪，本次语音已取消。") }
            return .init(.unavailable, "「\(capture.inputName)」没有向应用交付 PCM 音频。")
        }
        guard capturedSeconds >= 0.2, segments.contains(where: { $0.0.peak >= 0.003 }) else {
            return .init(.unavailable, "未检测到足够的语音。")
        }
        guard let audio = Self.makeSpeechBuffer(segments.map { ($0.0.values, $0.1) }) else {
            return .init(.failed, "无法转换麦克风音频。")
        }
        let recognition: VoiceRecognition
        if let config {
            recognition = await WhisperRecognition.recognize(audio: Self.wavData(audio), config: config)
        } else {
            let recognizer = OnDeviceRecognition()
            speechRecognition = recognizer
            recognition = await recognizer.recognize(audio)
        }
        guard attempt == id else { return .init(.unavailable, "本次语音已取消。") }
        return recognition
    }

    public func cancel() {
        cancel(.init(.unavailable, "本次语音已取消。"))
    }

    /// Recognizes Bluetooth PCM without opening a system microphone.
    public func recognizePCM(_ samples: [Float], sampleRate: Double, using config: WhisperConfiguration? = nil) async -> VoiceRecognition {
        guard attempt == nil else { return .init(.unavailable, "另一段语音正在处理。") }
        guard sampleRate == 8_000 || sampleRate == 16_000,
              samples.count >= Int(sampleRate * 0.2), samples.count < Int(sampleRate * 15),
              samples.allSatisfy(\.isFinite), samples.contains(where: { abs($0) >= 0.003 }),
              let audio = Self.resample(samples, from: sampleRate) else {
            return .init(.unavailable, "遥控器没有交付足够的有效语音，请检查蓝牙收音状态。")
        }
        let id = UUID()
        attempt = id
        defer { if attempt == id { attempt = nil; speechRecognition = nil } }
        let result: VoiceRecognition
        if let config { result = await WhisperRecognition.recognize(audio: Self.wavData(audio), config: config) }
        else {
            let recognizer = OnDeviceRecognition()
            speechRecognition = recognizer
            result = await recognizer.recognize(audio)
        }
        guard attempt == id, !Task.isCancelled else { return .init(.unavailable, "本次语音已取消。") }
        return result
    }

    private func cancel(_ result: PlatformResult) {
        guard attempt != nil else { return }
        logEnd(cancelled: true)
        stopCapture()
        attempt = nil
        speechRecognition?.cancel()
        speechRecognition = nil
        lastCancellation = result
        onCancellation?(result)
    }

    private func logEnd(cancelled: Bool) {
        guard let diagnostics = captureDiagnostics else { return }
        captureLog.info("Capture ended cancelled=\(cancelled) seconds=\(diagnostics.capturedSeconds) peak=\(diagnostics.peak) rms=\(diagnostics.strongestRMS) recoveries=\(diagnostics.reconfigurations)")
    }

    private func stopCapture() {
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        guard let capture = activeCapture else { return }
        activeCapture = nil
        capture.close()
    }

    private static func makeSpeechBuffer(_ segments: [([Float], Double)]) -> AVAudioPCMBuffer? {
        let nonempty = segments.filter { !$0.0.isEmpty }
        let converted = nonempty.compactMap { resample($0.0, from: $0.1) }
        guard converted.count == nonempty.count, let first = converted.first else { return nil }
        if converted.count == 1 { return first }

        let frameCount = converted.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard let output = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: frameCount),
              let destination = output.floatChannelData?[0] else { return nil }
        output.frameLength = frameCount
        var offset = 0
        for buffer in converted {
            guard let source = buffer.floatChannelData?[0] else { return nil }
            let count = Int(buffer.frameLength)
            destination.advanced(by: offset).update(from: source, count: count)
            offset += count
        }
        return output
    }

    private static func resample(_ values: [Float], from sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(values.count)),
              let inputData = input.floatChannelData?[0] else { return nil }
        input.frameLength = AVAudioFrameCount(values.count)
        values.withUnsafeBufferPointer { inputData.update(from: $0.baseAddress!, count: values.count) }
        if sampleRate == 16_000 { return input }

        let estimatedFrames = Int((Double(values.count) * 16_000 / sampleRate).rounded(.up))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(estimatedFrames + 1024)),
              let converter = AVAudioConverter(from: inputFormat, to: format) else { return nil }
        let source = ConverterInput(input)
        var conversionError: NSError?
        let supply: @Sendable (AVAudioPacketCount, UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? = { _, inputStatus in
            source.take(status: inputStatus)
        }
        let status = converter.convert(to: output, error: &conversionError, withInputFrom: supply)
        return status != .error && conversionError == nil && output.frameLength > 0 ? output : nil
    }

    private static func wavData(_ audio: AVAudioPCMBuffer) -> Data {
        let frames = Int(audio.frameLength)
        var wav = Data()
        wav.reserveCapacity(44 + frames * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + frames * 2))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        wav.append(contentsOf: "data".utf8)
        append(UInt32(frames * 2))
        let values = audio.floatChannelData![0]
        for index in 0..<frames {
            let sample = values[index].isFinite ? min(max(values[index], -1), 1) : 0
            append(Int16((sample * Float(Int16.max)).rounded()))
        }
        return wav
    }

    private struct Capture {
        let route: CaptureRoute
        let listeners: [NSObjectProtocol]
        let earlier: [CaptureSamples]
        let inputName: String
        let inputUID: String
        let explicit: Bool
        let routeID: UUID
        let reconfigurations: Int

        var segments: [CaptureSamples] { earlier + route.pcm.segments }

        func close() {
            for listener in listeners { NotificationCenter.default.removeObserver(listener) }
            route.stop()
        }
    }

    private struct CaptureFailure: Error {
        let result: PlatformResult

        init(_ status: PlatformResult.Status, _ message: String) {
            self.result = PlatformResult(status, message)
        }
    }
}

private final class CaptureRoute: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let pcm: CapturePCM
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue: DispatchQueue

    init(
        source: AVCaptureDevice, duration: TimeInterval, classifySpeech: Bool,
        captureQueue: DispatchQueue, sessionQueue: DispatchQueue
    ) throws {
        self.pcm = CapturePCM(duration: duration, classifySpeech: classifySpeech)
        self.sessionQueue = sessionQueue
        super.init()
        let input = try AVCaptureDeviceInput(device: source)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else {
            throw NSError(domain: "T1Controller.AudioCapture", code: 1)
        }
        session.addInput(input)
        // Receive the exact format supplied by the selected device.
        output.audioSettings = nil
        guard session.canAddOutput(output) else {
            throw NSError(domain: "T1Controller.AudioCapture", code: 2)
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: captureQueue)
    }

    func start(_ completed: @escaping @Sendable (Bool) -> Void) {
        sessionQueue.async {
            guard !self.pcm.isClosed else { return }
            self.session.startRunning()
            completed(self.session.isRunning)
        }
    }

    func stop() {
        pcm.close()
        sessionQueue.async {
            self.output.setSampleBufferDelegate(nil, queue: nil)
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            self.session.removeOutput(self.output)
            self.session.commitConfiguration()
            captureLog.notice("Capture stopped running=\(self.session.isRunning)")
        }
    }

    func waitForStop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { continuation.resume() }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        pcm.append(sampleBuffer)
    }
}

private final class CapturePCM: @unchecked Sendable {
    private let lock = NSLock()
    private let duration: TimeInterval
    private var stored: [CaptureSamples] = []
    private var closed = false
    private var reportedFormatError = false
    private var lastBufferAt: TimeInterval?
    let classifiesSpeech: Bool

    init(duration: TimeInterval, classifySpeech: Bool) {
        self.duration = duration
        self.classifiesSpeech = classifySpeech
    }

    var segments: [CaptureSamples] { lock.withLock { stored } }
    var isClosed: Bool { lock.withLock { closed } }
    var secondsSinceLastBuffer: TimeInterval? {
        lock.withLock { lastBufferAt.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } }
    }

    func close() {
        lock.withLock {
            closed = true
            for segment in stored { segment.speechActivity?.close() }
        }
    }

    func append(_ buffer: CMSampleBuffer) {
        guard !isClosed, CMSampleBufferDataIsReady(buffer),
              let description = CMSampleBufferGetFormatDescription(buffer),
              var stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return }
        let frameCount = CMSampleBufferGetNumSamples(buffer)
        guard frameCount > 0, let frames = Int32(exactly: frameCount),
              stream.mFormatID == kAudioFormatLinearPCM,
              stream.mSampleRate.isFinite, (8_000...384_000).contains(stream.mSampleRate),
              stream.mChannelsPerFrame > 0, let format = AVAudioFormat(streamDescription: &stream),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            reportFormatError(formatID: stream.mFormatID)
            return
        }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            buffer, at: 0, frameCount: frames, into: pcm.mutableAudioBufferList
        ) == noErr else {
            reportFormatError(formatID: stream.mFormatID)
            return
        }
        guard [.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32].contains(format.commonFormat) else {
            reportFormatError(formatID: stream.mFormatID)
            return
        }
        lock.withLock {
            guard !closed else { return }
            let segment: CaptureSamples
            if let current = stored.last, current.sampleRate == stream.mSampleRate {
                segment = current
            } else {
                let remaining = duration - stored.reduce(0) { $0 + $1.reading.seconds }
                guard remaining > 0, stored.count < 4 else { return }
                stored.last?.speechActivity?.close()
                segment = CaptureSamples(
                    sampleRate: stream.mSampleRate, duration: remaining, classifySpeech: classifiesSpeech
                )
                stored.append(segment)
                captureLog.info("First PCM format rate=\(stream.mSampleRate) channels=\(stream.mChannelsPerFrame) bits=\(stream.mBitsPerChannel)")
            }
            lastBufferAt = ProcessInfo.processInfo.systemUptime
            segment.append(pcm)
        }
    }

    private func reportFormatError(formatID: AudioFormatID) {
        lock.withLock {
            guard !reportedFormatError else { return }
            reportedFormatError = true
            captureLog.error("Unsupported or unreadable PCM format ID=\(formatID)")
        }
    }
}

// AVAudioConverter calls its input block synchronously during convert(to:).
private final class ConverterInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        guard let buffer else {
            status.pointee = .endOfStream
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}

private final class CaptureSamples: @unchecked Sendable {
    private static let minimumActivityRMS: Float = 0.0025
    private static let minimumActivityPeak: Float = 0.006

    let sampleRate: Double
    let speechActivity: SpeechActivity?
    private let lock = NSLock()
    private let limit: Int
    private let activityWindowFrames: Int
    private var values: [Float] = []
    private var rms: Float = 0
    private var peak: Float = 0
    private var strongestRMS: Float = 0
    private var windowFrames = 0
    private var windowSum: Float = 0
    private var windowSquareSum: Float = 0
    private var windowPeak: Float = 0
    private var activeWindows = 0
    private var lastSpeechAt: TimeInterval?

    init(sampleRate: Double, duration: TimeInterval, classifySpeech: Bool) {
        self.sampleRate = sampleRate
        self.speechActivity = classifySpeech ? SpeechActivity(sampleRate: sampleRate) : nil
        self.limit = Int(sampleRate * duration)
        self.activityWindowFrames = Int((sampleRate * 0.020).rounded())
        values.reserveCapacity(limit)
    }

    var level: Float { lock.withLock { rms } }
    var secondsSinceSpeech: TimeInterval? {
        lock.withLock { lastSpeechAt.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } }
    }
    var reading: (seconds: TimeInterval, peak: Float, strongestRMS: Float) {
        lock.withLock { (Double(values.count) / sampleRate, peak, strongestRMS) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let read: (Int, Int) -> Float
        if let channels = buffer.floatChannelData {
            read = { channels[$0][$1] }
        } else if let channels = buffer.int16ChannelData {
            read = { Float(channels[$0][$1]) / 32768 }
        } else if let channels = buffer.int32ChannelData {
            read = { Float(channels[$0][$1]) / 2147483648 }
        } else {
            return
        }
        let bufferFrames = Int(buffer.frameLength)
        let bufferArrival = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            let count = min(bufferFrames, limit - values.count)
            guard count > 0 else { return }
            let startFrame = values.count
            let channels = Int(buffer.format.channelCount)
            let stride = buffer.stride
            var squareSum: Float = 0
            for frame in 0..<count {
                var sum: Float = 0
                for channel in 0..<channels {
                    let value = read(channel, frame * stride)
                    if value.isFinite { sum += value }
                }
                let sample = sum / Float(channels)
                let magnitude = abs(sample)
                let squared = sample * sample
                values.append(sample)
                squareSum += squared
                peak = max(peak, magnitude)
                windowFrames += 1
                windowSum += sample
                windowSquareSum += squared
                windowPeak = max(windowPeak, magnitude)
                if windowFrames == activityWindowFrames {
                    // Use audio frame time within a callback, since a buffer can contain trailing silence.
                    let secondsRemaining = Double(bufferFrames - frame - 1) / sampleRate
                    finishActivityWindow(at: bufferArrival - secondsRemaining)
                }
            }
            rms = min(1, sqrt(squareSum / Float(count)))
            if let speechActivity {
                speechActivity.append(Array(values.suffix(count)), startingAt: Int64(startFrame))
            }
        }
    }

    private func finishActivityWindow(at time: TimeInterval) {
        let frames = Float(activityWindowFrames)
        let mean = windowSum / frames
        let variance = max(0, windowSquareSum / frames - mean * mean)
        strongestRMS = max(strongestRMS, sqrt(variance))
        let hasActivity = windowPeak >= Self.minimumActivityPeak
            && variance >= Self.minimumActivityRMS * Self.minimumActivityRMS
        // Require two consecutive windows so a brief key click is unlikely to arm recording.
        activeWindows = hasActivity ? min(activeWindows + 1, 2) : 0
        if activeWindows == 2 {
            lastSpeechAt = max(lastSpeechAt ?? time, time)
        }
        windowFrames = 0
        windowSum = 0
        windowSquareSum = 0
        windowPeak = 0
    }

    func snapshot() -> (values: [Float], peak: Float, reachedLimit: Bool) {
        lock.withLock { (values, peak, values.count >= limit) }
    }
}

private enum WhisperRecognition {
    static func recognize(audio: Data, config: WhisperConfiguration) async -> VoiceRecognition {
        let executable = URL(fileURLWithPath: config.executablePath)
        let model = URL(fileURLWithPath: config.modelPath)
        guard config.executablePath.hasPrefix("/"), config.modelPath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.isReadableFile(atPath: model.path) else {
            return .init(.unavailable, "请配置可执行的 whisper-cli 和可读的多语种模型。")
        }
        if let expected = config.modelSHA256?.lowercased(), !expected.isEmpty {
            let actual = await Task.detached(priority: .utility) { try? checksum(model) }.value
            guard actual == expected else { return .init(.unavailable, "Whisper 模型 SHA-256 与配置不符。") }
        }
        do {
            let result = try await LocalProcess.run(
                executable,
                arguments: ["-m", model.path, "-f", "-", "-l", "zh", "-nt", "-np"],
                input: audio,
                timeout: 45
            )
            guard result.status == 0 else {
                return .init(.failed, "whisper-cli 退出，状态 \(result.status)。")
            }
            guard !result.stdout.isEmpty else { return .init(.unavailable, "没有识别到中文指令。") }
            return .init(.confirmed, "已完成本地语音识别。", transcript: result.stdout)
        } catch {
            return .init(.failed, "whisper-cli 无法执行或已超时。")
        }
    }

    private static func checksum(_ model: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: model)
        defer { try? handle.close() }
        var digest = SHA256()
        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
            digest.update(data: block)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
private final class OnDeviceRecognition {
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<VoiceRecognition, Never>?
    private var timeout: Task<Void, Never>?
    private var cancelled = false

    func recognize(_ audio: AVAudioPCMBuffer) async -> VoiceRecognition {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.supportsOnDeviceRecognition else {
            return .init(.unavailable, "本机未提供离线中文系统识别。请配置 whisper-cli 和多语种模型。")
        }
        let authorization: SFSpeechRecognizerAuthorizationStatus
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                let onAuthorization: @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void = {
                    continuation.resume(returning: $0)
                }
                SFSpeechRecognizer.requestAuthorization(onAuthorization)
            }
        } else {
            authorization = current
        }
        guard !cancelled else { return .init(.unavailable, "本次语音已取消。") }
        guard authorization == .authorized else {
            return .init(.unavailable, "请授权本机语音识别，或配置 whisper-cli。")
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.recognizer = recognizer
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            let onResult: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { [weak self] result, error in
                let transcript = result?.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let isFinal = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    if isFinal, let transcript, !transcript.isEmpty {
                        self?.complete(.init(.confirmed, "已完成本机语音识别。", transcript: transcript))
                    } else if failed || isFinal {
                        self?.complete(.init(.unavailable, "未识别到中文指令，请检查离线语言资源。"))
                    }
                }
            }
            task = recognizer.recognitionTask(with: request, resultHandler: onResult)
            request.append(audio)
            request.endAudio()
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self?.complete(.init(.failed, "本机语音识别超时。"))
            }
        }
    }

    func cancel() {
        cancelled = true
        complete(.init(.unavailable, "本次语音已取消。"))
    }

    private func complete(_ result: VoiceRecognition) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        task?.cancel()
        task = nil
        recognizer = nil
        continuation.resume(returning: result)
    }
}
