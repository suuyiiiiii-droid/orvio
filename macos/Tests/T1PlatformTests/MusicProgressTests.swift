import CoreGraphics
import XCTest
@testable import T1Platform

final class MusicProgressTests: XCTestCase {
    func testReadsThinProgressBandAndRejectsAlbumArt() throws {
        XCTAssertEqual(try XCTUnwrap(MusicProgress.read(makeImage(barWidth: 122))), 122.0 / 512, accuracy: 0.01)
        XCTAssertGreaterThan(
            try XCTUnwrap(MusicProgress.read(makeImage(barWidth: 140))),
            try XCTUnwrap(MusicProgress.read(makeImage(barWidth: 122)))
        )
        XCTAssertNil(MusicProgress.read(try makeImage(barWidth: nil)))
    }

    func testReadsSodaProgressAcrossAnArtworkColorChange() throws {
        func frame(edge: Int, grayFooter: Bool) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 600, height: 1_000, bitsPerComponent: 8, bytesPerRow: 2_400,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(gray: 0.12, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 1_000))
            if grayFooter { context.setFillColor(gray: 0.30, alpha: 1) }
            else { context.setFillColor(red: 0.32, green: 0.38, blue: 0.12, alpha: 1) }
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 120))
            context.setFillColor(red: 0.44, green: 0.50, blue: 0.17, alpha: 1)
            context.fill(CGRect(x: 0, y: 120, width: 600, height: 3))
            context.setFillColor(red: 0.80, green: 0.87, blue: 0.49, alpha: 1)
            context.fill(CGRect(x: 0, y: 120, width: edge, height: 3))
            return try XCTUnwrap(context.makeImage())
        }

        let first = try XCTUnwrap(MusicProgress.readSoda(frame(edge: 12, grayFooter: true), windowHeight: 720))
        let second = try XCTUnwrap(MusicProgress.readSoda(frame(edge: 24, grayFooter: false), windowHeight: 720))
        XCTAssertEqual(first, 0.02, accuracy: 0.003)
        XCTAssertEqual(second, 0.04, accuracy: 0.003)
        XCTAssertNil(MusicProgress.readSoda(try frame(edge: 0, grayFooter: false), windowHeight: 720))
    }

    func testTrimsOpaquePaddingWithoutCroppingVisibleWindow() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 400 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 42, y: 80, width: 280, height: 190))
        let trimmed = MusicWindowPadding.trim(try XCTUnwrap(context.makeImage()))
        XCTAssertEqual(Double(trimmed.width), 280, accuracy: 2)
        XCTAssertEqual(Double(trimmed.height), 190, accuracy: 2)
    }

    private func makeImage(barWidth: Int?) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        context.setFillColor(red: 1, green: 0.1, blue: 0.25, alpha: 1)
        context.fill(CGRect(x: 6, y: 10, width: 40, height: 36))
        if let barWidth {
            context.fill(CGRect(x: 0, y: 54, width: barWidth, height: 2))
        }
        return try XCTUnwrap(context.makeImage())
    }
}
