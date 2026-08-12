import AVFAudio
import XCTest
@testable import Conduit

final class VoiceAudioSessionConfigurationTests: XCTestCase {
    func testCaptureUsesInputCapableVoiceChatBluetoothPolicy() {
        let configuration = VoiceAudioSessionConfiguration.capture

        XCTAssertEqual(configuration.category.rawValue, AVAudioSession.Category.playAndRecord.rawValue)
        XCTAssertEqual(configuration.mode.rawValue, AVAudioSession.Mode.voiceChat.rawValue)
        XCTAssertTrue(configuration.options.contains(.allowBluetooth))
        XCTAssertTrue(configuration.options.contains(.defaultToSpeaker))
        XCTAssertFalse(configuration.options.contains(.allowBluetoothA2DP))
    }

    func testCapturePreservesCanonicalProviderFormat() {
        let configuration = VoiceAudioSessionConfiguration.capture

        XCTAssertEqual(configuration.outputSampleRate, 16_000)
        XCTAssertEqual(configuration.outputChannelCount, 1)
    }
}
