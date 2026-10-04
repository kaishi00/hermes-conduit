import AVFAudio
import XCTest
@testable import Conduit

final class VoiceAudioSessionConfigurationTests: XCTestCase {
    func testCaptureUsesInputCapableVoiceChatBluetoothPolicy() {
        let configuration = VoiceAudioSessionConfiguration.capture

        XCTAssertEqual(configuration.category.rawValue, AVAudioSession.Category.playAndRecord.rawValue)
        XCTAssertEqual(configuration.mode.rawValue, AVAudioSession.Mode.voiceChat.rawValue)
        XCTAssertTrue(configuration.options.contains(.allowBluetoothHFP))
        XCTAssertTrue(configuration.options.contains(.defaultToSpeaker))
        XCTAssertFalse(configuration.options.contains(.allowBluetoothA2DP))
    }

    func testCapturePreservesCanonicalProviderFormat() {
        let configuration = VoiceAudioSessionConfiguration.capture

        XCTAssertEqual(configuration.outputSampleRate, 16_000)
        XCTAssertEqual(configuration.outputChannelCount, 1)
    }

    func testStandalonePlaybackUsesOutputOnlyMediaCoexistencePolicy() {
        let configuration = VoiceAudioSessionConfiguration.standalonePlayback

        XCTAssertEqual(configuration.category.rawValue, AVAudioSession.Category.playback.rawValue)
        XCTAssertFalse(configuration.options.contains(.allowBluetoothHFP))
        XCTAssertTrue(configuration.options.contains(.mixWithOthers))
        XCTAssertTrue(configuration.options.contains(.duckOthers))
    }

    func testStandaloneNowPlayingIsOutputOnlyAndNotMixable() {
        let configuration = VoiceAudioSessionConfiguration.standaloneNowPlaying

        XCTAssertEqual(configuration.category.rawValue, AVAudioSession.Category.playback.rawValue)
        XCTAssertEqual(configuration.mode.rawValue, AVAudioSession.Mode.spokenAudio.rawValue)
        XCTAssertFalse(configuration.options.contains(.mixWithOthers))
        XCTAssertFalse(configuration.options.contains(.duckOthers))
        XCTAssertFalse(configuration.options.contains(.allowBluetoothHFP))
    }
}
