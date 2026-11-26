import AppKit
import SwiftUI
import T1Core
import OSLog

private let modeFeedbackLog = Logger(subsystem: "local.t1controller.app", category: "ModeHUD")

/// Desktop feedback works without notification permission or changing keyboard focus.
@MainActor
final class RemoteModeHUD {
    static let shared = RemoteModeHUD()
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(_ mode: RemoteMode, player: String) {
        present(ModeHUDContent(mode: mode, player: player))
    }

    func showSystemMute(_ muted: Bool, device: String) {
        present(ModeHUDContent(mode: .native, player: device,
            titleOverride: muted ? "系统已静音" : "系统已取消静音", detailOverride: device,
            symbolOverride: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", showModes: false))
    }

    func showPlayerMute(_ muted: Bool, player: String) {
        present(ModeHUDContent(mode: .media, player: player,
            titleOverride: muted ? "播放器已静音" : "播放器已取消静音", detailOverride: player,
            symbolOverride: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", showModes: false))
    }

    func showVoice(title: String, detail: String) {
        present(ModeHUDContent(mode: .native, player: "", titleOverride: title, detailOverride: detail,
                               symbolOverride: "waveform", showModes: false))
    }

    private func present(_ content: ModeHUDContent) {
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        dismissal?.cancel()
        let panel: NSPanel
        if let existing = self.panel { panel = existing }
        else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 112),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.title = "Orvio模式提示"
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            self.panel = panel
        }
        panel.contentView = NSHostingView(rootView: content)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - 185, y: area.minY + 68))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let focusUnchanged = foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier
        let kind = content.showModes ? content.mode.rawValue : "system-audio"
        modeFeedbackLog.notice("mode=\(kind, privacy: .public) visible=\(panel.isVisible) keyWindow=\(panel.isKeyWindow) focusUnchanged=\(focusUnchanged)")
        dismissal = Task { @MainActor [weak self, weak panel] in
            do { try await Task.sleep(for: .milliseconds(2400)) } catch { return }
            guard !Task.isCancelled, let panel else { return }
            panel.orderOut(nil)
            modeFeedbackLog.notice("dismissed visible=\(panel.isVisible)")
            self?.dismissal = nil
        }
    }
}

private struct ModeHUDContent: View {
    let mode: RemoteMode
    let player: String
    var titleOverride: String? = nil
    var detailOverride: String? = nil
    var symbolOverride: String? = nil
    var showModes = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: symbolOverride ?? (mode == .native ? "keyboard" : mode == .media ? "music.note" : "display.2"))
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(T1Design.accent)
                .frame(width: 54, height: 54)
                .background(T1Design.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 5) {
                Text(titleOverride ?? "\(mode.title)模式").font(.system(size: 20, weight: .semibold))
                Text(detailOverride ?? (mode == .native ? "原生按键与语音输入已恢复" :
                     mode == .media ? "音乐控制 · \(player)" : "使用已绑定的按键切换电脑"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 5) {
                    if showModes {
                        ForEach(RemoteMode.allCases) { item in
                            Capsule().fill(item == mode ? T1Design.accent : Color.secondary.opacity(0.20))
                                .frame(width: item == mode ? 20 : 7, height: 4)
                        }
                    }
                    Text("ORVIO").font(.system(size: 8, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                }.padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(width: 370, height: 112)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(.white.opacity(0.28)))
        .scaleEffect(appeared ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { appeared = true } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Orvio，\(titleOverride ?? mode.title)")
    }
}

enum T1Design {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.67, green: 0.73, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: 0.25, green: 0.31, blue: 0.78, alpha: 1)
    })

    static var windowBackdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [accent.opacity(0.16), .clear], center: .topTrailing, startRadius: 10, endRadius: 660)
            RadialGradient(colors: [Color.cyan.opacity(0.08), .clear], center: .bottomLeading, startRadius: 20, endRadius: 480)
        }
        .ignoresSafeArea()
    }

    static let menuMark: NSImage = {
        let image = NSImage(size: NSSize(width: 19, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            let top = NSBezierPath()
            top.move(to: NSPoint(x: 1, y: 10))
            top.curve(to: NSPoint(x: 18, y: 2), controlPoint1: NSPoint(x: 4, y: 5), controlPoint2: NSPoint(x: 10, y: 5))
            top.curve(to: NSPoint(x: 10, y: 10), controlPoint1: NSPoint(x: 16, y: 7), controlPoint2: NSPoint(x: 13, y: 9))
            top.curve(to: NSPoint(x: 1, y: 10), controlPoint1: NSPoint(x: 7, y: 11), controlPoint2: NSPoint(x: 3, y: 13))
            top.close()
            top.fill()
            let bottom = NSBezierPath()
            bottom.move(to: NSPoint(x: 4, y: 16))
            bottom.curve(to: NSPoint(x: 16, y: 9), controlPoint1: NSPoint(x: 7, y: 13), controlPoint2: NSPoint(x: 12, y: 14))
            bottom.curve(to: NSPoint(x: 6, y: 17), controlPoint1: NSPoint(x: 14, y: 14), controlPoint2: NSPoint(x: 10, y: 17))
            bottom.curve(to: NSPoint(x: 4, y: 16), controlPoint1: NSPoint(x: 4, y: 17), controlPoint2: NSPoint(x: 3, y: 17))
            bottom.close()
            bottom.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    static let productIcon = Bundle.main.url(forResource: "T1Mark", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }
}

struct ProductMark: View {
    var body: some View {
        if let icon = T1Design.productIcon {
            Image(nsImage: icon).resizable().scaledToFit()
        } else {
            Image(nsImage: T1Design.menuMark)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .padding(9)
                .foregroundStyle(T1Design.accent)
        }
    }
}

extension View {
    func t1Panel(radius: CGFloat = 23) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return background(.thinMaterial, in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.35), lineWidth: 1).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.055), radius: 20, x: 0, y: 8)
    }

    @ViewBuilder
    func t1Glass() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.42), lineWidth: 1).allowsHitTesting(false) }
        }
    }
}
