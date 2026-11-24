import AVFoundation
import Foundation
import SoundAnalysis

/// Uses the system's on-device speech class rather than microphone level alone.
final class SpeechActivity: NSObject, SNResultsObserving, @unchecked Sendable {
    private let sampleRate: Double
    private let queue = DispatchQueue(label: "T1Controller.SpeechActivity")
    private let lock = NSLock()
    private var analyzer: SNAudioStreamAnalyzer?
    private var initialized = false
    private var analyzedThrough: TimeInterval = 0
    private var latestSpeechEnd: TimeInterval?

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    var trailingSilence: TimeInterval? {
        lock.withLock { latestSpeechEnd.map { max(0, analyzedThrough - $0) } }
    }

    func append(_ samples: [Float], startingAt frame: Int64) {
        guard !samples.isEmpty else { return }
        queue.async {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: self.sampleRate, channels: 1) else { return }
            if !self.initialized {
                self.initialized = true
                if let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
                    request.windowDuration = CMTime(value: 3, timescale: 5)
                    request.overlapFactor = 0.5
                    let analyzer = SNAudioStreamAnalyzer(format: format)
                    if (try? analyzer.add(request, withObserver: self)) != nil {
                        self.analyzer = analyzer
                    }
                }
            }
            guard let analyzer = self.analyzer,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?.pointee else { return }
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: source.count) }
            }
            analyzer.analyze(buffer, atAudioFramePosition: frame)
        }
    }

    func close() {
        queue.async {
            self.analyzer?.removeAllRequests()
            self.analyzer = nil
        }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let info = result as? SNClassificationResult else { return }
        let end = info.timeRange.end.seconds
        guard end.isFinite else { return }
        let speaks = info.classifications.contains { $0.identifier == "speech" && $0.confidence >= 0.65 }
        lock.withLock {
            analyzedThrough = max(analyzedThrough, end)
            if speaks { latestSpeechEnd = max(latestSpeechEnd ?? 0, end) }
        }
    }
}
