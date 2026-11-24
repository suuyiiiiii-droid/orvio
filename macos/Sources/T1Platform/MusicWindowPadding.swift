import CoreGraphics

enum MusicWindowPadding {
    static func trim(_ image: CGImage) -> CGImage {
        let size = 512
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: color,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        func isPadding(_ x: Int, _ y: Int) -> Bool {
            let index = (y * size + x) * 4
            return pixels[index + 3] < 12 ||
                (pixels[index] > 247 && pixels[index + 1] < 8 && pixels[index + 2] > 247)
        }
        let corners = [isPadding(0, 0), isPadding(size - 1, 0),
                       isPadding(0, size - 1), isPadding(size - 1, size - 1)]
        guard corners.filter({ $0 }).count >= 2 else { return image }
        var left = size, right = -1, top = size, bottom = -1
        for y in 0..<size {
            guard let first = (0..<size).first(where: { !isPadding($0, y) }),
                  let last = (0..<size).last(where: { !isPadding($0, y) }) else { continue }
            left = min(left, first)
            right = max(right, last)
            top = min(top, y)
            bottom = y
        }
        guard right - left >= 128, bottom - top >= 128 else { return image }
        let sx = CGFloat(image.width) / CGFloat(size)
        let sy = CGFloat(image.height) / CGFloat(size)
        let rect = CGRect(x: CGFloat(left) * sx, y: CGFloat(top) * sy,
                          width: CGFloat(right - left + 1) * sx, height: CGFloat(bottom - top + 1) * sy)
        return image.cropping(to: rect.integral) ?? image
    }
}
