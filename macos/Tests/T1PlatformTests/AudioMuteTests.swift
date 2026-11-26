import XCTest
@testable import T1Platform

final class AudioMuteTests: XCTestCase {
    func testPlayerMuteOwnsMainAndAudioHelpersButNeverOtherPlayers() {
        let player = URL(fileURLWithPath: "/Applications/Soda Music.app")
        XCTAssertTrue(AudioProcessOwner.contains(executable: player.appending(path: "Contents/MacOS/Soda Music"), in: player))
        XCTAssertTrue(AudioProcessOwner.contains(executable: player.appending(path: "Contents/Frameworks/Helper.app/Contents/MacOS/Helper"), in: player))
        XCTAssertFalse(AudioProcessOwner.contains(executable: URL(fileURLWithPath: "/Applications/NeteaseMusic.app/Contents/MacOS/cloudmusic"), in: player))
        XCTAssertFalse(AudioProcessOwner.contains(executable: URL(fileURLWithPath: "/Applications/Soda Music.app.backup/Contents/MacOS/Helper"), in: player))
        XCTAssertFalse(AudioProcessOwner.contains(executable: player.appending(path: "../Other.app/Contents/MacOS/Other"), in: player))
    }
}
