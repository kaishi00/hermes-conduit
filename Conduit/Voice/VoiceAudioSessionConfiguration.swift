import AVFAudio

struct VoiceAudioSessionConfiguration: Equatable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    let outputSampleRate: Double
    let outputChannelCount: AVAudioChannelCount

    static let capture = Self(
        category: .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetoothHFP, .defaultToSpeaker],
        outputSampleRate: 16_000,
        outputChannelCount: 1
    )
}
