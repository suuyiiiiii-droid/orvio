import Carbon
import XCTest
@testable import T1Platform

final class PlayerRoutingTests: XCTestCase {
    func testSodaUsesItsAppShortcutsForPlaybackAndTrackSelection() {
        XCTAssertEqual(SodaPlaybackShortcut(action: .toggle)?.keyCode, kVK_Space)
        XCTAssertEqual(SodaPlaybackShortcut(action: .toggle)?.flags, [])
        XCTAssertEqual(SodaPlaybackShortcut(action: .next)?.keyCode, kVK_RightArrow)
        XCTAssertEqual(SodaPlaybackShortcut(action: .previous)?.keyCode, kVK_LeftArrow)
        XCTAssertTrue(SodaPlaybackShortcut.next.flags.contains(.maskCommand))
        XCTAssertNil(SodaPlaybackShortcut(action: .play))
        XCTAssertNil(SodaPlaybackShortcut(action: .pause))
    }

    @MainActor
    func testObsoletePlayerRequestStopsBeforeLaunchingAnyApplication() async {
        let result = await PlayerController().perform(.next, on: PlayerProfile(bundleID: "test.nonexistent.player", name: "过期目标"),
                                                    isCurrent: { false })
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertTrue(result.message.contains("播放器选择已变更"))
    }
}
