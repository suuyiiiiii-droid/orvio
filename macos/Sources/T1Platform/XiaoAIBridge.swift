import Foundation

public struct XiaoAIBridge: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        public var enabled = false
        public var homeAssistantURL = ""
        public var notifyEntity = ""
        public var topic = "t1music006"
        public var switchCommand = "打开电脑音乐开关"
        public var includeSilentParameter = true
        public var pythonPath = ""

        public init() {}
    }

    public struct Credentials: Codable, Sendable {
        public let bemfaUID: String
        public let homeAssistantToken: String

        public init(bemfaUID: String, homeAssistantToken: String) {
            self.bemfaUID = bemfaUID
            self.homeAssistantToken = homeAssistantToken
        }
    }

    private struct Request: Encodable {
        let topic: String
        let bemfaUID: String
        let homeAssistantURL: String
        let homeAssistantToken: String
        let notifyEntity: String
        let switchCommand: String
        let includeSilentParameter: Bool
    }

    private struct Reply: Decodable {
        let event: String
        let message: String?
    }

    public init() {}

    public func requestDailyPlayback(using settings: Settings, credentials: Credentials) async -> PlatformResult {
        guard let script = Bundle.main.resourceURL?.appending(path: "XiaoAIBridge/xiaoai_daily.py"),
              FileManager.default.isReadableFile(atPath: script.path) else {
            return .init(.unavailable, "找不到小爱桥接组件，请使用完整安装包。")
        }
        let python = settings.pythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        // 0.1.7 used a launcher tied to the original signed bundle's location.
        let usesLegacyLauncher = python.hasSuffix("/T1-xiaoai-runtime/python3")
        let path = python.isEmpty || usesLegacyLauncher ? "/usr/bin/python3" : python
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            return .init(.unavailable, "找不到可执行的 Python 3，请在语音页填入绝对路径。")
        }
        let request = Request(topic: settings.topic.trimmingCharacters(in: .whitespacesAndNewlines),
                              bemfaUID: credentials.bemfaUID,
                              homeAssistantURL: settings.homeAssistantURL.trimmingCharacters(in: .whitespacesAndNewlines),
                              homeAssistantToken: credentials.homeAssistantToken,
                              notifyEntity: settings.notifyEntity.trimmingCharacters(in: .whitespacesAndNewlines),
                              switchCommand: settings.switchCommand.trimmingCharacters(in: .whitespacesAndNewlines),
                              includeSilentParameter: settings.includeSilentParameter)
        do {
            let result = try await LocalProcess.run(URL(filePath: path), arguments: ["-E", "-s", "-B", "-X", "utf8", script.path],
                                                    input: JSONEncoder().encode(request), timeout: 45)
            guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(result.stdout.utf8)) else {
                return .init(.failed, "小爱桥接组件未返回有效结果。请检查 Python 3 和安装包。")
            }
            if result.status == 0, reply.event == "triggered" {
                return .init(.confirmed, "收到巴法开关信号，正在打开网易云每日推荐。")
            }
            if result.status != 0, ["error", "timeout"].contains(reply.event) {
                return .init(.failed, reply.message ?? "小爱链路未完成。")
            }
            return .init(.failed, "小爱桥接组件返回了未知状态。")
        } catch LocalProcess.Failure.timeout {
            return .init(.failed, "小爱链路连接超时。请检查 Home Assistant 与巴法连接。")
        } catch {
            return .init(.failed, "小爱桥接组件启动失败。请检查 Python 3。")
        }
    }
}
