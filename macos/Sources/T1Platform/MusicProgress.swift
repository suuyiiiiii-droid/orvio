import CoreGraphics

enum MusicProgress {
    static func readSoda(_ image: CGImage, windowHeight: CGFloat) -> Double? {
        guard windowHeight.isFinite, windowHeight > 320 else { return nil }
        let width = 600
        let height = 1_000
        let expectedRow = Int(Double(height) * (1 - 88 / windowHeight))
        guard (12..<(height - 12)).contains(expectedRow),
              let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: color,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func brightness(_ x: Int, _ y: Int) -> Int {
            let index = (y * width + x) * 4
            return (Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])) / 3
        }
        var edges: [Int] = []
        // The track sits on the upper edge of the 88-point footer. Its colors follow the artwork.
        for row in (expectedRow - 7)...(expectedRow + 7) {
            let background = brightness(width - 18, row)
            let fill = brightness(2, row)
            guard background >= brightness(width - 18, row + 4) + 9, fill - background >= 28 else { continue }
            let threshold = (fill + background) / 2
            let edge = (2..<(width - 18)).first(where: { brightness($0, row) < threshold })
            guard let edge, edge >= 3, edge < width - 24,
                  abs(brightness(edge + 4, row) - background) < 10 else { continue }
            edges.append(edge)
        }
        guard (1...6).contains(edges.count), let first = edges.min(), let last = edges.max(),
              last - first <= 3 else { return nil }
        return Double(last) / Double(width)
    }

    static func read(_ image: CGImage) -> Double? {
        let width = 512
        let height = 512
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: color,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // NetEase places a thin, left-anchored progress strip just above its playback controls.
        var candidates: [Int] = []
        var firstCandidate: Int?
        for row in Int(0.84 * Double(height))..<Int(0.94 * Double(height)) {
            let base = row * width * 4
            func isFilled(_ column: Int) -> Bool {
                let index = base + column * 4
                let red = Int(pixels[index])
                let green = Int(pixels[index + 1])
                let blue = Int(pixels[index + 2])
                return red > 125 && red > green + 42 && red > blue + 23
            }
            if isFilled(1) && isFilled(2) {
                if firstCandidate == nil { firstCandidate = row }
                var edge = 3
                while edge < width && isFilled(edge) { edge += 1 }
                if edge >= 5 { candidates.append(edge) }
            } else if firstCandidate != nil {
                break
            }
        }
        guard (1...6).contains(candidates.count), let low = candidates.min(), let high = candidates.max(),
              high - low <= 6 else { return nil }
        return Double(high) / Double(width)
    }
}
