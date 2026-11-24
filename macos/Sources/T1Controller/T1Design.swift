import AppKit
import SwiftUI

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
