import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

@MainActor
public enum MusicAgentDesktop {
    private static let finderBundleID = "com.apple.finder"
    private static let dockBundleID = "com.apple.dock"
    private static var lastClick: ClickReceipt?

    static func bringToFront(_ player: PlayerProfile) async throws -> NSRunningApplication {
        if let music = NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID)
            .first(where: { !$0.isTerminated }) {
            _ = music.activate()
            let pid = music.processIdentifier
            if try await wait(for: .milliseconds(550), until: {
                isFrontmost(pid) && hasVisibleMusicWindow(pid: pid) ? true : nil
            }) != nil {
                return music
            }
            if !hasVisibleMusicWindow(pid: pid), restoreMusicWindowFromDock(music) {
                return try await waitForMusicWindow(player, pid: pid)
            }
        }

        try requireAccessibility()
        guard let url = verifiedMusicApplicationURL(player) else { throw DesktopError.applicationMissing(player.name) }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID)
            .first(where: { !$0.isTerminated }) else { throw DesktopError.finderUnavailable }

        // Revealing the app only selects its file in Finder. Finder handles the actual open command.
        NSWorkspace.shared.activateFileViewerSelecting([url])
        let finderPID = finder.processIdentifier
        let finderApp = AXUIElementCreateApplication(finderPID)
        AXUIElementSetMessagingTimeout(finderApp, 0.25)
        guard try await wait(for: .seconds(4), until: {
            isFrontmost(finderPID) && finderSelected(url, in: finderApp) ? true : nil
        }) != nil else { throw DesktopError.selectionUnverified }

        // Recheck after returning from the async wait before dispatching the shortcut.
        guard isFrontmost(finderPID), finderSelected(url, in: finderApp) else {
            throw DesktopError.selectionUnverified
        }
        try sendKey(CGKeyCode(kVK_ANSI_O), flags: .maskCommand, pid: finderPID)
        return try await waitForMusicWindow(player, pid: nil)
    }

    static func focusExisting(_ player: PlayerProfile, pid: pid_t) async throws {
        try Task.checkCancellation()
        guard !isFrontmost(pid) else { return }
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated, app.bundleIdentifier == player.bundleID else {
            throw DesktopError.musicDidNotActivate
        }
        _ = app.activate()
        _ = try await waitForMusicWindow(player, pid: pid)
    }

    private static func movePointer(to point: CGPoint, source: CGEventSource?) async throws {
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left) else {
            throw DesktopError.eventUnavailable
        }
        if let origin = CGEvent(source: nil)?.location {
            move.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - origin.x).rounded()))
            move.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - origin.y).rounded()))
        }
        move.flags = []
        move.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(180))
    }

    static func scrollRecommendationUp(at point: CGPoint, pid: pid_t) async throws {
        try requireAccessibility()
        let receipt = try verifyClick(at: point, pid: pid)
        let source = CGEventSource(stateID: .hidSystemState)
        try await movePointer(to: point, source: source)
        for _ in 0..<3 {
            let current = try verifyClick(at: point, pid: pid)
            guard CFEqual(receipt.window, current.window),
                  let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                      wheel1: 950, wheel2: 0, wheel3: 0) else {
                throw DesktopError.unverifiedClick
            }
            event.location = point
            event.flags = []
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    public static func click(at point: CGPoint, pid: pid_t, count: Int = 1) async throws {
        lastClick = nil
        try requireAccessibility()
        guard (1...2).contains(count), point.x.isFinite, point.y.isFinite else {
            throw DesktopError.unverifiedClick
        }
        let receipt = try verifyClick(at: point, pid: pid)
        let source = CGEventSource(stateID: .hidSystemState)
        try await movePointer(to: point, source: source)

        for index in 1...count {
            try Task.checkCancellation()
            let current = try verifyClick(at: point, pid: pid)
            guard CFEqual(receipt.window, current.window) else { throw DesktopError.focusChanged }
            guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                     mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                   mouseCursorPosition: point, mouseButton: .left) else {
                throw DesktopError.eventUnavailable
            }
            for event in [down, up] {
                event.setIntegerValueField(.mouseEventClickState, value: Int64(index))
                event.flags = []
            }
            down.post(tap: .cghidEventTap)
            // Always release a posted mouse-down, including when the task was cancelled.
            try? await Task.sleep(for: .milliseconds(55))
            up.timestamp = DispatchTime.now().uptimeNanoseconds
            if isFrontmost(pid) {
                up.post(tap: .cghidEventTap)
            } else {
                up.postToPid(pid)
                throw DesktopError.focusChanged
            }
            try Task.checkCancellation()
        }
        lastClick = receipt
    }

    static func replaceSearchText(
        _ text: String, pid: pid_t, requiredPlaceholder: String? = nil,
        beforeSubmit: (() async -> Void)? = nil
    ) async throws {
        try requireAccessibility()
        guard !text.isEmpty, text.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw DesktopError.invalidSearchText
        }
        guard isFrontmost(pid) else { throw DesktopError.focusChanged }
        let desktop = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(desktop, 0.25)
        if let focused = element(kAXFocusedUIElementAttribute, of: desktop),
           attribute(kAXSubroleAttribute, of: focused) as? String == kAXSecureTextFieldSubrole {
            throw DesktopError.searchFieldUnverified
        }
        var field = focusedTextField(in: desktop, pid: pid)
        if let requiredPlaceholder {
            func expectedField() -> AXUIElement? {
                guard let focused = focusedTextField(in: desktop, pid: pid),
                      attribute(kAXPlaceholderValueAttribute, of: focused) as? String == requiredPlaceholder else { return nil }
                return focused
            }
            field = try await wait(for: .milliseconds(450), until: expectedField)
            if field == nil, let search = searchField(pid: pid, placeholder: requiredPlaceholder),
               isFrontmost(pid),
               AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
                field = try await wait(for: .milliseconds(450), until: expectedField)
            }
            guard field != nil else {
                throw DesktopError.searchFieldUnverified
            }
        }
        let receipt: ClickReceipt?
        if field == nil {
            guard let lastClick, lastClick.pid == pid,
                  lastClick.time.duration(to: .now) <= .seconds(5) else {
                throw DesktopError.searchFieldUnverified
            }
            try verifySearchClick(lastClick)
            receipt = lastClick
        } else {
            receipt = nil
        }
        lastClick = nil

        try sendKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand, pid: pid)
        try await Task.sleep(for: .milliseconds(100))
        try await typeText(text, pid: pid)
        if let field {
            func inputMatches() -> Bool? {
                guard let focused = focusedTextField(in: desktop, pid: pid), CFEqual(focused, field),
                      let value = attribute(kAXValueAttribute, of: focused) as? String,
                      value == text else { return nil }
                return true
            }
            guard try await wait(for: .seconds(1), until: inputMatches) == true,
                  inputMatches() == true else { throw DesktopError.searchTextUnverified }
            if let beforeSubmit {
                await beforeSubmit()
                guard inputMatches() == true else { throw DesktopError.searchTextUnverified }
            }
        } else if let receipt {
            // This application does not expose its web text fields through AX.
            // The caller verifies the visually identified search result after submission.
            try await Task.sleep(for: .milliseconds(120))
            try verifySearchClick(receipt)
            if let beforeSubmit {
                await beforeSubmit()
                try verifySearchClick(receipt)
            }
        }
        try Task.checkCancellation()
        try sendKey(CGKeyCode(kVK_Return), pid: pid)
    }

    static func searchFieldBounds(pid: pid_t, placeholder: String) -> CGRect? {
        searchField(pid: pid, placeholder: placeholder).flatMap { accessibilityBounds(of: $0) }
    }

    private static func searchField(pid: pid_t, placeholder: String) -> AXUIElement? {
        let fields = windowNodes(pid: pid).filter { node in
            attribute(kAXRoleAttribute, of: node) as? String == kAXTextFieldRole &&
            attribute(kAXPlaceholderValueAttribute, of: node) as? String == placeholder &&
            attribute(kAXSubroleAttribute, of: node) as? String != kAXSecureTextFieldSubrole
        }
        return fields.count == 1 ? fields.first : nil
    }

    private static func windowNodes(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = element(kAXMainWindowAttribute, of: app)
                ?? element(kAXFocusedWindowAttribute, of: app) else { return [] }
        var pending = [window]
        var visited = Set<AXUIElement>()
        while let node = pending.popLast(), visited.count < 700 {
            guard visited.insert(node).inserted else { continue }
            pending.append(contentsOf: attribute(kAXChildrenAttribute, of: node) as? [AXUIElement] ?? [])
        }
        return Array(visited)
    }

    private struct ClickReceipt {
        let pid: pid_t
        let point: CGPoint
        let window: AXUIElement
        let quartzWindowID: CGWindowID?
        let time: ContinuousClock.Instant
    }

    private static func verifyClick(at point: CGPoint, pid: pid_t) throws -> ClickReceipt {
        guard isFrontmost(pid) else { throw DesktopError.focusChanged }
        let desktop = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(desktop, 0.25)
        var hit: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(desktop, Float(point.x), Float(point.y), &hit)
        if let hit, let hitPID = processID(of: hit), hitPID != pid {
            throw DesktopError.unverifiedClick
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = element(kAXFocusedWindowAttribute, of: app)
                ?? element(kAXMainWindowAttribute, of: app),
              processID(of: window) == pid else { throw DesktopError.unverifiedClick }
        var quartzWindowID: CGWindowID?
        if hitStatus == .success, let hit {
            guard processID(of: hit) == pid else { throw DesktopError.unverifiedClick }
            let role = attribute(kAXRoleAttribute, of: hit) as? String
            let hitWindow = role == kAXWindowRole ? hit : element(kAXWindowAttribute, of: hit)
            guard hitWindow.map({ CFEqual(window, $0) }) != false else { throw DesktopError.unverifiedClick }
        } else {
            quartzWindowID = visibleQuartzWindow(at: point, pid: pid, focusedWindow: window)
            guard quartzWindowID != nil else { throw DesktopError.unverifiedClick }
        }
        guard isFrontmost(pid) else { throw DesktopError.focusChanged }
        return ClickReceipt(pid: pid, point: point, window: window, quartzWindowID: quartzWindowID, time: .now)
    }

    private static func verifySearchClick(_ receipt: ClickReceipt) throws {
        let current = try verifyClick(at: receipt.point, pid: receipt.pid)
        guard CFEqual(current.window, receipt.window) else { throw DesktopError.focusChanged }
        if let expectedID = receipt.quartzWindowID {
            let currentID = current.quartzWindowID
                ?? visibleQuartzWindow(at: receipt.point, pid: receipt.pid, focusedWindow: current.window)
            guard currentID == expectedID else { throw DesktopError.focusChanged }
        }
    }

    private static func visibleQuartzWindow(at point: CGPoint, pid: pid_t, focusedWindow: AXUIElement) -> CGWindowID? {
        var display = CGDirectDisplayID(0)
        var displayCount: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &displayCount) == .success, displayCount == 1,
              let focusedBounds = accessibilityBounds(of: focusedWindow),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        // Quartz returns onscreen windows in front-to-back order. Never click through another window.
        var match: CGWindowID?
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue >= 0,
                  let opacity = window[kCGWindowAlpha as String] as? NSNumber, opacity.doubleValue > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(point) else { continue }
            let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let matchesFocus = owner == pid && abs(focusedBounds.minX - frame.minX) <= 2
                && abs(focusedBounds.minY - frame.minY) <= 2 && abs(focusedBounds.width - frame.width) <= 2
                && abs(focusedBounds.height - frame.height) <= 2
            if match != nil {
                if matchesFocus { return nil }
                continue
            }
            guard matchesFocus,
                  let number = window[kCGWindowNumber as String] as? NSNumber else { return nil }
            match = number.uint32Value
        }
        return match
    }

    private static func accessibilityBounds(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(kAXPositionAttribute, of: window),
              let dimensions = attribute(kAXSizeAttribute, of: window),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(dimensions, to: AXValue.self), .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func verifiedMusicApplicationURL(_ player: PlayerProfile) -> URL? {
        let fileName = player.bundleID == PlayerProfile.netease.bundleID ? "NeteaseMusic.app" : "\(player.name).app"
        let standard = URL(fileURLWithPath: "/Applications/\(fileName)", isDirectory: true)
        return (NSWorkspace.shared.urlsForApplications(withBundleIdentifier: player.bundleID) + [standard])
            .first { $0.isFileURL && Bundle(url: $0)?.bundleIdentifier == player.bundleID }
    }

    private static func waitForMusicWindow(_ player: PlayerProfile, pid: pid_t?) async throws -> NSRunningApplication {
        guard let music = try await wait(for: .seconds(7), until: {
            guard let frontmost = NSWorkspace.shared.frontmostApplication,
                  !frontmost.isTerminated, frontmost.bundleIdentifier == player.bundleID,
                  pid == nil || pid == frontmost.processIdentifier,
                  hasVisibleMusicWindow(pid: frontmost.processIdentifier) else { return nil as NSRunningApplication? }
            return frontmost
        }) else { throw DesktopError.musicDidNotActivate }
        return music
    }

    private static func hasVisibleMusicWindow(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return frame.width >= 420 && frame.height >= 320
        }
    }

    private static func restoreMusicWindowFromDock(_ music: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted(), let url = music.bundleURL,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID).first else { return false }
        let path = comparablePath(url)
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var pending = [app]
        var visited = Set<AXUIElement>()
        var matches: [AXUIElement] = []
        while let node = pending.popLast(), visited.count < 180 {
            guard visited.insert(node).inserted else { continue }
            if attribute(kAXRoleAttribute, of: node) as? String == "AXDockItem" {
                if let itemURL = attribute(kAXURLAttribute, of: node) as? URL {
                    if comparablePath(itemURL) == path { matches.append(node) }
                } else if music.bundleIdentifier == PlayerProfile.netease.bundleID,
                          attribute(kAXTitleAttribute, of: node) as? String == music.localizedName {
                    matches.append(node)
                }
            }
            pending.append(contentsOf: (attribute(kAXChildrenAttribute, of: node) as? [AXUIElement] ?? []).prefix(120))
        }
        guard matches.count == 1, let item = matches.first else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private static func finderSelected(_ expected: URL, in app: AXUIElement) -> Bool {
        guard let window = element(kAXFocusedWindowAttribute, of: app)
            ?? element(kAXMainWindowAttribute, of: app) else { return false }

        // Finder list and column views expose selected rows; icon views expose selected children.
        var containers = [window]
        var visited = Set<AXUIElement>()
        let expectedPath = comparablePath(expected)
        while let node = containers.popLast(), visited.count < 120 {
            guard visited.insert(node).inserted else { continue }
            let role = attribute(kAXRoleAttribute, of: node) as? String
            let children = attribute(kAXChildrenAttribute, of: node) as? [AXUIElement] ?? []
            for key in [kAXSelectedRowsAttribute, kAXSelectedChildrenAttribute] {
                if let selected = attribute(key, of: node) as? [AXUIElement], selected.count == 1,
                   finderPaths(in: selected) == [expectedPath] {
                    return true
                }
            }
            if role == kAXOutlineRole || role == kAXTableRole || role == kAXListRole {
                // Fall back to visible rows if a Finder view omits its selected rows attribute.
                let selected = children.prefix(60).filter { attribute(kAXSelectedAttribute, of: $0) as? Bool == true }
                if selected.count == 1 && finderPaths(in: Array(selected)) == [expectedPath] { return true }
                continue
            }
            containers.append(contentsOf: children.prefix(60).reversed())
        }
        return false
    }

    private static func finderPaths(in nodes: [AXUIElement]) -> Set<String> {
        var pending = nodes
        var selectedPaths = Set<String>()
        var visited = Set<AXUIElement>()
        while let node = pending.popLast(), visited.count < 60 {
            guard visited.insert(node).inserted else { continue }
            if let url = attribute(kAXURLAttribute, of: node) as? URL, url.isFileURL {
                selectedPaths.insert(comparablePath(url))
            }
            let children = attribute(kAXChildrenAttribute, of: node) as? [AXUIElement] ?? []
            pending.append(contentsOf: children.prefix(30).reversed())
        }
        return selectedPaths
    }

    private static func comparablePath(_ url: URL) -> String {
        let pathURL = (url as NSURL).filePathURL ?? url
        return pathURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func focusedTextField(in desktop: AXUIElement, pid: pid_t) -> AXUIElement? {
        guard isFrontmost(pid), let field = element(kAXFocusedUIElementAttribute, of: desktop),
              processID(of: field) == pid, let role = attribute(kAXRoleAttribute, of: field) as? String,
              [kAXTextFieldRole, kAXComboBoxRole].contains(role),
              attribute(kAXSubroleAttribute, of: field) as? String != kAXSecureTextFieldSubrole else { return nil }
        return field
    }

    private static func sendKey(_ code: CGKeyCode, flags: CGEventFlags = [], pid: pid_t) throws {
        guard isFrontmost(pid) else { throw DesktopError.focusChanged }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw DesktopError.eventUnavailable
        }
        for event in [down, up] {
            event.flags = flags
            event.postToPid(pid)
        }
    }

    private static func typeText(_ text: String, pid: pid_t) async throws {
        let source = CGEventSource(stateID: .privateState)
        var start = text.startIndex
        while start < text.endIndex {
            try Task.checkCancellation()
            guard isFrontmost(pid) else { throw DesktopError.focusChanged }
            let end = text.index(start, offsetBy: 8, limitedBy: text.endIndex) ?? text.endIndex
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw DesktopError.eventUnavailable
            }
            let units = Array(text[start..<end].utf16)
            for event in [down, up] {
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event.postToPid(pid)
            }
            start = end
            if start < text.endIndex { try await Task.sleep(for: .milliseconds(70)) }
        }
    }

    private static func requireAccessibility() throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw DesktopError.accessibilityUnavailable
        }
    }

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        pid > 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func processID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private static func element(_ key: String, of node: AXUIElement) -> AXUIElement? {
        guard let value = attribute(key, of: node), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func attribute(_ key: String, of node: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
    }

    private static func wait<T>(for duration: Duration, until condition: () -> T?) async throws -> T? {
        let deadline = ContinuousClock.now.advanced(by: duration)
        repeat {
            try Task.checkCancellation()
            if let value = condition() { return value }
            try await Task.sleep(for: .milliseconds(80))
        } while ContinuousClock.now < deadline
        return nil
    }

    private enum DesktopError: LocalizedError {
        case accessibilityUnavailable, applicationMissing(String), finderUnavailable, selectionUnverified
        case musicDidNotActivate, focusChanged, unverifiedClick, eventUnavailable
        case invalidSearchText, searchFieldUnverified, searchTextUnverified

        var errorDescription: String? {
            switch self {
            case .accessibilityUnavailable: "请为 Orvio 开启辅助功能权限。"
            case .applicationMissing(let player): "找不到已安装的\(player)。"
            case .finderUnavailable: "访达不可用，无法打开播放器。"
            case .selectionUnverified: "访达未选中预期的播放器应用。"
            case .musicDidNotActivate: "播放器尚未切到前台。"
            case .focusChanged: "前台应用已切换，请重新执行。"
            case .unverifiedClick: "点击位置无法确认为当前目标窗口。"
            case .eventUnavailable: "系统无法创建桌面输入事件。"
            case .invalidSearchText: "搜索文字为空或含换行等控制字符。"
            case .searchFieldUnverified: "未确认当前焦点是播放器的文本输入框。"
            case .searchTextUnverified: "未读回已输入的搜索词，请查看搜索框。"
            }
        }
    }
}
