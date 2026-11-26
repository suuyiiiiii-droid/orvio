import AppKit
import ApplicationServices

/// A dictation session is attached to the editable control focused at key-down.
/// It never changes focus, uses the clipboard, or falls back to executing a command.
@MainActor
public final class NativeTextInput {
    private let pid: pid_t
    private let element: AXUIElement
    private let selection: CFRange?
    private init(pid: pid_t, element: AXUIElement, selection: CFRange?) {
        self.pid = pid; self.element = element; self.selection = selection
    }

    public static func capture() -> NativeTextInput? {
        prepareForeground()
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              let element = focusedElement(app.processIdentifier), isEditable(element) else { return nil }
        return NativeTextInput(pid: app.processIdentifier, element: element, selection: selectedRange(element))
    }

    /// Electron documents this accessibility switch. Warm its tree when the
    /// user activates an app, so the first voice press can find its rich editor.
    public static func prepareForeground() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, isElectron(app) else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    public func insert(_ text: String) async -> PlatformResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(.unavailable, "没有可输入的转写文字。")
        }
        guard isCurrent, sameSelection else {
            return .init(.unavailable, "输入焦点或光标已变化；转写文字已保留在语音页。")
        }
        // Do not assign AXSelectedText, even when the setter returns success.
        // Some editors accept the accessibility write without committing an
        // edit to their input model. Use the focused system keyboard path.
        guard CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .privateState) else {
            return .init(.unavailable, "向文本框输入需要当前 Orvio 的辅助功能权限；文字已保留。")
        }
        var start = text.startIndex
        while start < text.endIndex {
            guard !Task.isCancelled, isCurrent else {
                return .init(.unavailable, "输入焦点已变化，已停止继续输入；完整文字保留在语音页。")
            }
            let end = text.index(start, offsetBy: 8, limitedBy: text.endIndex) ?? text.endIndex
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return .init(.failed, "未能创建文字输入事件。")
            }
            let units = Array(text[start..<end].utf16)
            units.withUnsafeBufferPointer { down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            down.flags = []; up.flags = []
            down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
            start = end
            if start < text.endIndex {
                do { try await Task.sleep(for: .milliseconds(40)) }
                catch { return .init(.unavailable, "本次文字输入已取消，转写文字已保留。") }
            }
        }
        return .init(.submitted, "已向原文本框发送语音文字，请核对实际输入。")
    }

    private var isCurrent: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid &&
            Self.focusedElement(pid).map { CFEqual($0, element) && Self.isEditable($0) } == true
    }

    private var sameSelection: Bool {
        guard let selection else { return true }
        guard let current = Self.selectedRange(element) else { return false }
        return selection.location == current.location && selection.length == current.length
    }

    private static func focusedElement(_ pid: pid_t) -> AXUIElement? {
        for root in [AXUIElementCreateSystemWide(), AXUIElementCreateApplication(pid)] {
            guard var element = elementAttribute(root, kAXFocusedUIElementAttribute) else { continue }
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { continue }
            // Chromium can expose the selection's inline child as focused.
            for _ in 0..<6 {
                if isEditable(element) { return element }
                if stringAttribute(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return nil }
                guard let parent = elementAttribute(element, kAXParentAttribute) else { break }
                element = parent
            }
        }
        return nil
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        guard stringAttribute(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { return false }
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { return true }
        var editable: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success &&
            (editable as? Bool) == true
    }

    private static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: url.appending(path: "Contents/Frameworks/Electron Framework.framework").path)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }
}

@MainActor
public final class NativeTextFocusObservation {
    private var token: (any NSObjectProtocol)?
    public init(enabled: @escaping @MainActor () -> Bool) {
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                  object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if enabled() { NativeTextInput.prepareForeground() } }
        }
    }
    isolated deinit { if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) } }
}
