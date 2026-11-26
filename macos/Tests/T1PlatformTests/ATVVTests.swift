import Foundation
import XCTest
@testable import T1Platform

final class ATVVTests: XCTestCase {
    func testNegotiationAndCommandsUseVersionSpecificLayoutsAndStreamIDs() throws {
        let protocolState = ATVVProtocol()
        XCTAssertEqual(protocolState.getCapabilitiesCommand, Data([0x0A, 1, 0, 0, 3, 3]))
        XCTAssertThrowsError(try protocolState.micOpenCommand())
        let v10 = try XCTUnwrap(ATVVProtocol.parseCapabilities(Data([0x0B, 1, 0, 2, 3, 0, 160, 0, 0])))
        XCTAssertEqual(v10.version, .v10)
        XCTAssertEqual(v10.frameSize, 160)
        XCTAssertEqual(v10.selectedCodec, .adpcm16k)
        try protocolState.acceptCapabilities(v10)
        XCTAssertEqual(try protocolState.micOpenCommand(), Data([0x0C, 0]))
        XCTAssertEqual(try protocolState.micCloseCommand(streamID: 7), Data([0x0D, 7]))
        XCTAssertEqual(protocolState.parseControl(Data([4, 3, 2, 7])), .audioStart(reason: 3, codec: .adpcm16k, streamID: 7))
        XCTAssertEqual(protocolState.parseControl(Data([0, 2])), .audioStop(reason: 2))
        let legacy = try XCTUnwrap(ATVVProtocol.parseCapabilities(Data([0x0B, 0, 4, 0, 3, 0, 134, 0, 0])))
        try protocolState.acceptCapabilities(legacy)
        XCTAssertEqual(try protocolState.micOpenCommand(), Data([0x0C, 0, 2]))
        XCTAssertEqual(try protocolState.micCloseCommand(streamID: 7), Data([0x0D]))
    }

    func testTruncatedAndUnknownControlCannotGuessARecordingStart() throws {
        let protocolState = ATVVProtocol()
        let caps = try XCTUnwrap(ATVVProtocol.parseCapabilities(Data([0x0B, 1, 0, 2, 3, 0, 160])))
        try protocolState.acceptCapabilities(caps)
        for bytes: [UInt8] in [[], [4], [4, 3], [4, 3, 9, 1], [0x0A, 2, 0, 0, 0, 0, 89]] {
            let data = Data(bytes)
            XCTAssertEqual(protocolState.parseControl(data), .unknown(data))
        }
        XCTAssertNil(ATVVProtocol.parseCapabilities(Data([0x0B, 2, 0, 2, 3, 0, 160])))
        XCTAssertThrowsError(try protocolState.acceptCapabilities(.init(version: .v10, codecs: 0, interactionModel: 3, frameSize: 160)))
    }

    func testADPCMUsesHighNibbleFirstAndPreservesStateAcrossNotifications() {
        var decoder = ADPCMDecoder()
        decoder.reset(predictor: 0, stepIndex: 0)
        XCTAssertEqual(decoder.decode([0x70]), [11, 13])
        var split = ADPCMDecoder(), complete = ADPCMDecoder()
        XCTAssertEqual(split.decode([0x70]) + split.decode([0xF0]), complete.decode([0x70, 0xF0]))
        decoder.reset(predictor: 32760, stepIndex: 88)
        XCTAssertEqual(decoder.decode([0x77]).first, Int16.max)
        decoder.reset(predictor: -32760, stepIndex: 88)
        XCTAssertEqual(decoder.decode([0xFF]).first, Int16.min)
    }

    func testSyncAndNewSessionResetDecoderState() throws {
        let protocolState = ATVVProtocol()
        try protocolState.acceptCapabilities(.init(version: .v10, codecs: 2, interactionModel: 3, frameSize: 160))
        protocolState.applyAudioSync(codec: .adpcm16k, sequence: 42, predictor: 100, stepIndex: 0)
        XCTAssertEqual(protocolState.decodeAudio(Data([0x70]))?.samples, [111, 113])
        protocolState.resetAudio()
        XCTAssertEqual(protocolState.decodeAudio(Data([0x70]))?.samples, [11, 13])
        XCTAssertEqual(protocolState.parseControl(Data([0x0A, 2, 0, 42, 0xFF, 0x9C, 0])),
                       .audioSync(codec: .adpcm16k, sequence: 42, predictor: -100, stepIndex: 0))
    }

    func testLegacyFramesRejectWrongLengthAndInvalidStepBeforeDecoding() throws {
        let protocolState = ATVVProtocol()
        try protocolState.acceptCapabilities(.init(version: .v04, codecs: 2, interactionModel: 0, frameSize: 7))
        XCTAssertEqual(protocolState.decodeAudio(Data([0, 1, 0, 0, 100, 0, 0x70]))?.samples, [100, 111, 113])
        XCTAssertNil(protocolState.decodeAudio(Data([0, 1, 0, 0, 100, 89, 0x70])))
        XCTAssertNil(protocolState.decodeAudio(Data([0, 1, 0, 0, 100, 0])))
    }

    @MainActor
    func testInvalidBluetoothPCMStopsBeforeMicrophoneOrSpeechPermission() async {
        let recognizer = PushToTalk()
        for (samples, rate): ([Float], Double) in [([], 16_000), ([.nan], 16_000), (Array(repeating: 0, count: 4000), 16_000),
                                                    (Array(repeating: 0.1, count: 4000), 44_100)] {
            let result = await recognizer.recognizePCM(samples, sampleRate: rate)
            XCTAssertNil(result.transcript)
            XCTAssertEqual(result.result.status, .unavailable)
            XCTAssertFalse(recognizer.isRecording)
        }
    }
}
