import Foundation

/// Optional local compatibility transport. Never installs profiles, asks for
/// elevation, writes raw logs, or emits synthetic OS events.
@MainActor
final class ChromecastLogInput {
    var onReport: ((Set<UInt32>) -> Void)?
    var onStatus: ((String) -> Void)?
    var onInterrupted: (() -> Void)?
    private var process: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var buffer = Data()
    private var generation = UUID()
    private var releaseWatchdog: Task<Void, Never>?
    private var startupWatchdog: Task<Void, Never>?
    private var sawReport = false

    var isRunning: Bool { process?.isRunning == true }

    func start() {
        guard process == nil else { return }
        generation = UUID()
        let token = generation
        let task = Process(), pipe = Pipe(), errorPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["stream", "--level", "debug", "--style", "ndjson", "--predicate",
            "process == 'BTLEServer' AND subsystem == 'com.apple.bluetooth' AND category == 'BTLEServer' AND eventMessage BEGINSWITH 'Updated input report for ID #2:'"]
        task.standardOutput = pipe
        task.standardError = errorPipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, !data.isEmpty else { return }
                self.consume(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, !data.isEmpty else { return }
                self.onStatus?("蓝牙兼容日志读取失败，请检查当前应用权限和日志配置。")
                self.onInterrupted?()
            }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.stop()
                self.onStatus?("蓝牙兼容监听已退出，请关闭后重新开启兼容入口。")
            }
        }
        process = task; output = pipe; errors = errorPipe
        sawReport = false
        do {
            try task.run()
            onStatus?("短报文兼容已监听 · 等待遥控器按下和松开")
            startupWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let self, self.generation == token, !self.sawReport else { return }
                self.onStatus?("未收到可读按键 · 请按遥控器；日志配置未生效时无法修复短报文")
            }
        } catch {
            stop()
            onStatus?("无法启动蓝牙兼容监听：\(error.localizedDescription)")
        }
    }

    func stop() {
        generation = UUID()
        releaseWatchdog?.cancel(); releaseWatchdog = nil
        startupWatchdog?.cancel(); startupWatchdog = nil
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; output = nil; errors = nil; buffer.removeAll()
        onInterrupted?()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            guard line.count <= 16_384 else { continue }
            switch ChromecastLogParser.parse(Data(line)) {
            case .ignored: break
            case .redacted:
                sawReport = true
                releaseWatchdog?.cancel()
                onInterrupted?()
                onStatus?("报告内容仍为 <private> · 兼容配置未生效，映射未执行")
            case .report(let keys):
                sawReport = true
                releaseWatchdog?.cancel()
                onReport?(keys)
                onStatus?(keys.isEmpty ? "已确认松开 · 兼容入口工作中" : "已识别按下 · 等待松开")
                if !keys.isEmpty {
                    let token = generation
                    releaseWatchdog = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(15))
                        guard !Task.isCancelled, let self, self.generation == token else { return }
                        // A missing release cancels the gesture. Never fabricate an
                        // up event that could trigger a click, host switch or voice job.
                        self.onInterrupted?()
                        self.onStatus?("15 秒未收到松开 · 已取消按键和录音，请重新短按")
                    }
                }
            }
        }
        if buffer.count > 16_384 { buffer.removeAll(); onInterrupted?() }
    }
}
