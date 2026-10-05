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

    /// Output-only policy for standalone speech (Read Aloud, TTS provider
    /// test): `.playback` never claims the microphone, and `.mixWithOthers` +
    /// `.duckOthers` let already-playing media (Spotify, Audible) continue at
    /// reduced volume while Conduit speaks instead of being interrupted.
    /// Ducking ends the moment the session deactivates, so standalone speech
    /// stops affecting other media immediately when it finishes. Deliberately
    /// not `.voiceChat`: these flows never record, and a record category
    /// keeps other media suppressed even while idle.
    /// The sample-rate fields below belong to the capture policy and are
    /// unused by playback; the values mirror the gateway speech stream.
    static let standalonePlayback = Self(
        category: .playback,
        mode: .default,
        options: [.mixWithOthers, .duckOthers],
        outputSampleRate: 24_000,
        outputChannelCount: 1
    )

    /// Standalone speech with no other media playing (#373): the same
    /// output-only `.playback`, but not mixable, so iOS makes Conduit the
    /// Now Playing app and routes lock-screen, Control Center, and headphone
    /// play/pause to Read Aloud. `.spokenAudio` lets navigation prompts pause
    /// the reply rather than talk over it, like a podcast.
    static let standaloneNowPlaying = Self(
        category: .playback,
        mode: .spokenAudio,
        options: [],
        outputSampleRate: 24_000,
        outputChannelCount: 1
    )

    /// Foreground wake phrase listening (#174): records from the microphone
    /// while letting other apps' audio keep playing at full volume. `.default`
    /// rather than `.voiceChat` so no voice processing ducks other media, and
    /// A2DP stays allowed so Bluetooth headphones keep their music route.
    /// HFP is deliberately left out: it would drop headphones to call
    /// quality, so wake listening uses the phone's own microphone.
    /// `.defaultToSpeaker`: without headphones a record category plays out of
    /// the earpiece, and other apps' audio mixed into this session can
    /// follow it there. By default wake does not listen at all while other
    /// apps play (AppState), so this matters when the user keeps it on.
    static let wakeListening = Self(
        category: .playAndRecord,
        mode: .default,
        options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker],
        outputSampleRate: 16_000,
        outputChannelCount: 1
    )
}
