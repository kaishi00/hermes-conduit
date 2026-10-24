//
//  AppState+AgentSettings.swift
//  Conduit
//
//  The Voice settings Conduit lets Hermes change (AgentSettings.swift), and
//  when Conduit syncs them with the notifier plugin: on every connect, when
//  a turn used the `conduit_settings` tool, and when the Voice page opens.
//  Every write goes through the same setter the Voice page uses, so a
//  change from Hermes has the same side effects as the user's own.
//
//  Left out on purpose: speech providers and keys (Hermes' own settings),
//  the wake phrase and speaker verification, Calls from Hermes, Watch
//  access, the "Let Hermes change settings" mode itself, and anything that
//  needs a permission prompt (on-device speech recognition).
//

import Foundation

extension AppState {
    /// Where review items and unsent answers belong: this dashboard and
    /// profile. The dashboard by its id: two dashboards' URLs can differ
    /// only in the case of their path.
    var agentSettingsScope: String? {
        guard let baseUrl = connection?.baseUrl else { return nil }
        return "\(activeDashboardID?.uuidString ?? baseUrl)|\(activeProfile)"
    }

    /// Syncs when the host's plugin serves it; silent otherwise.
    func syncAgentSettings() async {
        guard notifierPlugin.reports(AgentSettingsSync.capability),
              let scope = agentSettingsScope,
              let bridge = dashboardTicketBridge else { return }
        let profile = activeProfile
        await agentSettings.sync(
            scope: scope, profile: profile, catalog: agentSettingsCatalog,
            // Requests are decided only for the host and profile they came from.
            isCurrent: { [weak self] in bridge === self?.dashboardTicketBridge && profile == self?.activeProfile }
        ) { [weak self] path, body in
            // A bridge or profile swapped mid-sync belongs to another host.
            guard let self, bridge === self.dashboardTicketBridge, profile == self.activeProfile else {
                throw DashboardTicketBridgeError.notReady
            }
            return try await bridge.requestJSON(path: path, method: "PUT", body: body)
        }
        objectWillChange.send()
    }

    /// The review sheet's items for the dashboard and profile in use.
    var agentSettingsReview: [AgentSettingsReviewItem] {
        agentSettings.reviewItems(for: agentSettingsScope)
    }

    func resolveAgentSettings(_ items: [AgentSettingsReviewItem], apply: Bool) {
        guard let scope = agentSettingsScope else { return }
        agentSettings.resolve(items, apply: apply, scope: scope, catalog: agentSettingsCatalog)
        // Open settings pages reseed from the new revision.
        objectWillChange.send()
        Task { await syncAgentSettings() }
    }

    func undoAgentSettings(_ notice: AgentSettingsAppliedNotice) {
        guard let scope = agentSettingsScope else { return }
        agentSettings.undo(notice, scope: scope, catalog: agentSettingsCatalog)
        objectWillChange.send()
        Task { await syncAgentSettings() }
    }

    /// Every setting Hermes may see, read and written for the active profile.
    /// Built for each sync or answer and never stored, so its closures hold
    /// AppState strongly for that long only.
    var agentSettingsCatalog: [AgentSettingDescriptor] {
        var catalog: [AgentSettingDescriptor] = []
        catalog.append(voiceModeDescriptor)
        catalog.append(contentsOf: liveStyleDescriptors)
        catalog.append(choiceDescriptor(
            key: "voice.gemini.voice", section: "Gemini Live", title: "Gemini Live voice",
            description: "The voice Gemini Live speaks with. default is Gemini's own default voice.",
            tier: .small, displayTitle: { AppLocalization.string("Gemini Live voice") },
            choices: [(value: "default", title: "Gemini's default")] + GeminiLiveVoice.all.map { (value: $0.name, title: "\($0.name) (\($0.style))") },
            display: { $0 == "default" ? AppLocalization.string("Default") : $0 },
            read: { self.geminiLiveVoice ?? "default" },
            write: { self.setGeminiLiveVoice($0 == "default" ? nil : $0) }
        ))
        catalog.append(choiceDescriptor(
            key: "voice.gemini.search", section: "Gemini Live", title: "Gemini Live lookups",
            description: "Where Gemini Live searches for quick facts: automatic (Hermes' web search when the host has one, else Google), hermes, google, or off.",
            tier: .ask, displayTitle: { AppLocalization.string("Gemini Live lookups") },
            choices: [(value: "automatic", title: "Automatic"), (value: "hermes", title: "Hermes web search"), (value: "google", title: "Google Search"), (value: "off", title: "Off")],
            display: { value in
                switch value {
                case "hermes": return AppLocalization.string("Hermes")
                case "google": return AppLocalization.string("Google")
                case "off": return AppLocalization.string("Off")
                default: return AppLocalization.string("Automatic")
                }
            },
            read: { self.geminiLiveSearchMode.rawValue },
            write: { self.setGeminiLiveSearchMode(GeminiLiveSearchMode(rawValue: $0) ?? .automatic) }
        ))
        catalog.append(choiceDescriptor(
            key: "voice.gpt.voice", section: "GPT-Live", title: "GPT-Live voice",
            description: "The voice GPT-Live speaks with. default is the host's configured voice (voice.gpt_live in Hermes config, cove unless changed).",
            tier: .small, displayTitle: { AppLocalization.string("GPT-Live voice") },
            choices: [(value: "default", title: "Host's configured voice")] + GPTLiveVoice.all.map { (value: $0.name, title: "\($0.name) (\($0.style))") },
            display: { $0 == "default" ? AppLocalization.string("Default") : $0.capitalized },
            read: { self.gptLiveVoice ?? "default" },
            write: { self.setGPTLiveVoice($0 == "default" ? nil : $0) }
        ))
        for (engine, title, company) in [("gemini", "Gemini Live", "Google"), ("gpt", "GPT-Live", "OpenAI"), ("grok", "Grok Live", "xAI")] {
            catalog.append(boolDescriptor(
                key: "voice.\(engine).memory", section: title, title: "\(title) memory",
                description: "Gives \(title) what Hermes remembers about the user. This sends that memory to \(company).",
                tier: .ask, displayTitle: { AppLocalization.string("\(title) memory") },
                read: {
                    switch engine {
                    case "gemini": return self.geminiLiveMemoryEnabled
                    case "gpt": return self.gptLiveMemoryEnabled
                    default: return self.grokLiveMemoryEnabled
                    }
                },
                write: { enabled in
                    switch engine {
                    case "gemini": self.setGeminiLiveMemoryEnabled(enabled)
                    case "gpt": self.setGPTLiveMemoryEnabled(enabled)
                    default: self.setGrokLiveMemoryEnabled(enabled)
                    }
                }
            ))
            catalog.append(boolDescriptor(
                key: "voice.\(engine).personality", section: title, title: "\(title) personality",
                description: "Makes \(title) speak as this Hermes profile's persona (SOUL.md). This sends SOUL.md to \(company).",
                tier: .ask, displayTitle: { AppLocalization.string("\(title) personality") },
                read: {
                    switch engine {
                    case "gemini": return self.geminiLivePersonalityEnabled
                    case "gpt": return self.gptLivePersonalityEnabled
                    default: return self.grokLivePersonalityEnabled
                    }
                },
                write: { enabled in
                    switch engine {
                    case "gemini": self.setGeminiLivePersonalityEnabled(enabled)
                    case "gpt": self.setGPTLivePersonalityEnabled(enabled)
                    default: self.setGrokLivePersonalityEnabled(enabled)
                    }
                }
            ))
        }
        catalog.append(boolDescriptor(
            key: "voice.live.save_calls", section: "Live voice", title: "Save live calls",
            description: "Saves each live voice call (Gemini Live, GPT-Live, Grok Live) to Hermes' chat history. Off means calls aren't kept.",
            tier: .ask, displayTitle: { AppLocalization.string("Save live calls") },
            read: { self.voiceCallSavingEnabled },
            write: { self.setVoiceCallSavingEnabled($0) }
        ))
        catalog.append(boolDescriptor(
            key: "voice.live.speaker_talk_over", section: "Live voice", title: "Talk over Hermes on the speaker",
            description: "Keeps the microphone open while a live model speaks on the loudspeaker or in the car, so the user can interrupt (echo cancelling, experimental).",
            tier: .ask, displayTitle: { AppLocalization.string("Talk over Hermes on the speaker") },
            read: { self.liveVoiceSpeakerBargeInEnabled },
            write: { self.setLiveVoiceSpeakerBargeInEnabled($0) }
        ))
        catalog.append(boolDescriptor(
            key: "voice.continuous_conversation", section: "Conversation", title: "Continuous Conversation",
            description: "In Classic voice, listens again after each reply instead of waiting for a tap.",
            // It keeps the microphone on: asks, like every such setting.
            tier: .ask, displayTitle: { AppLocalization.string("Continuous Conversation") },
            read: { self.continuousConversationEnabled },
            write: { _ = self.setContinuousConversation($0) }
        ))
        catalog.append(boolDescriptor(
            key: "voice.keep_listening_when_locked", section: "Conversation", title: "Keep listening when locked",
            description: "Keeps a Classic voice conversation listening with the phone locked or Conduit in the background.",
            tier: .ask, displayTitle: { AppLocalization.string("Keep listening when locked") },
            read: { self.keepVoiceListeningWhenLocked },
            write: { _ = self.setKeepVoiceListeningWhenLocked($0) }
        ))
        catalog.append(boolDescriptor(
            key: "voice.push_to_talk", section: "Conversation", title: "Push to talk",
            description: "In Classic voice, the user holds the voice screen's main button to speak and releases it to send, instead of a pause ending the turn. CarPlay and calls from Hermes stay hands-free.",
            tier: .ask, displayTitle: { AppLocalization.string("Push to talk") },
            read: { self.voicePushToTalkEnabled },
            write: { _ = self.setVoicePushToTalk($0) }
        ))
        catalog.append(choiceDescriptor(
            key: "voice.chat_button", section: "Conversation", title: "Chat voice button",
            description: "What the round button beside a chat's message box does on this profile. app: follow the app-wide choice in Settings > Appearance. live_call: start a live voice call in the chat. voice_message: record an audio message (sent with its transcript). dictation: type what the user says into the message. A live call stays in the chat's top bar either way.",
            tier: .small, displayTitle: { AppLocalization.string("Chat voice button") },
            choices: [(value: "app", title: "App setting")]
                + ChatVoiceButtonAction.offered.map { (value: $0.rawValue, title: $0.title) },
            display: { value in
                ChatVoiceButtonAction.offeredChoice(value)?.title ?? AppLocalization.string("App setting")
            },
            read: { ChatVoiceButtonAction.offeredChoice(self.chatVoiceButtonOverride)?.rawValue ?? "app" },
            write: { _ = self.setChatVoiceButtonOverride(ChatVoiceButtonAction.offeredChoice($0)) }
        ))
        return catalog
    }

    private var voiceModeDescriptor: AgentSettingDescriptor {
        choiceDescriptor(
            key: "voice.mode", section: "Voice mode", title: "Voice mode",
            description: "Which voice engine voice conversations use. classic: Hermes' own speech to text and voice (works with any server). gemini: Gemini Live, needs a Gemini key on the host. gpt: GPT-Live on the host's ChatGPT sign-in. grok: Grok Live on the host's SuperGrok sign-in. local: Local Live, a call through the user's own speech server with a fast model answering and Hermes doing the work as jobs (classic includes the hands-free speech-server option, where Hermes answers each turn). Live modes need the notifier plugin.",
            tier: .ask, displayTitle: { AppLocalization.string("Voice mode") },
            choices: [(value: "classic", title: "Classic"), (value: "gemini", title: "Gemini Live"), (value: "qwen", title: "Qwen Live"), (value: "gpt", title: "GPT-Live"), (value: "grok", title: "Grok Live"), (value: "local", title: "Local Live")],
            display: { value in
                switch value {
                case "gemini": return AppLocalization.string("Gemini Live")
                case "qwen": return AppLocalization.string("Qwen Live")
                case "gpt": return AppLocalization.string("GPT-Live")
                case "grok": return AppLocalization.string("Grok Live")
                case "local": return AppLocalization.string("Local Live")
                default: return AppLocalization.string("Classic")
                }
            },
            read: {
                if self.isGeminiLiveEnabled { return "gemini" }
                if self.isQwenLiveEnabled { return "qwen" }
                if self.isGPTLiveEnabled { return "gpt" }
                if self.isGrokLiveEnabled { return "grok" }
                if self.isLocalLiveEnabled && self.isLocalLiveAgent { return "local" }
                return "classic"
            },
            write: { value in
                switch value {
                case "gemini": self.setGeminiLiveEnabled(true)
                case "qwen": self.setQwenLiveEnabled(true)
                case "gpt": self.setGPTLiveEnabled(true)
                case "grok": self.setGrokLiveEnabled(true)
                case "local":
                    self.setLocalLiveAgent(true)
                    self.setLocalLiveEnabled(true)
                default:
                    self.setQwenLiveEnabled(false)
                    self.setGeminiLiveEnabled(false)
                    self.setGPTLiveEnabled(false)
                    self.setGrokLiveEnabled(false)
                    // Classic keeps its hands-free speech-server option.
                    if self.isLocalLiveAgent { self.setLocalLiveEnabled(false) }
                }
            }
        )
    }

    private var liveStyleDescriptors: [AgentSettingDescriptor] {
        let profile = activeProfile
        func update(_ change: (inout LiveVoiceStyle) -> Void) {
            var style = liveVoiceStyle
            change(&style)
            setLiveVoiceStyle(style, profile: profile)
        }
        return [
            choiceDescriptor(
                key: "voice.live.tone", section: "Live voice", title: "Tone",
                description: "How every live voice mode sounds. default keeps the voice model's own tone.",
                tier: .small, displayTitle: { AppLocalization.string("Tone") },
                choices: [(value: "default", title: "Model's own")] + LiveVoiceTone.allCases.map { (value: $0.rawValue, title: $0.rawValue.capitalized) },
                display: { LiveVoiceTone(rawValue: $0)?.label ?? AppLocalization.string("Default") },
                read: { self.liveVoiceStyle.tone?.rawValue ?? "default" },
                write: { value in update { $0.tone = LiveVoiceTone(rawValue: value) } }
            ),
            choiceDescriptor(
                key: "voice.live.answer_length", section: "Live voice", title: "Answer length",
                description: "How much live models say when asked something: concise (the point), standard (the answer with the details that make it useful), detailed.",
                tier: .small, displayTitle: { AppLocalization.string("Answer length") },
                choices: LiveVoiceAnswerLength.allCases.map { (value: $0.rawValue, title: $0.rawValue.capitalized) },
                display: { LiveVoiceAnswerLength(rawValue: $0)?.label ?? AppLocalization.string("Default") },
                read: { self.liveVoiceStyle.answerLength.rawValue },
                write: { value in update { $0.answerLength = LiveVoiceAnswerLength(rawValue: value) ?? .standard } }
            ),
            boolDescriptor(
                key: "voice.live.backchannels", section: "Live voice", title: "Backchannels",
                description: "Whether live models say short \"mm-hmm\" sounds while the user talks.",
                tier: .small, displayTitle: { AppLocalization.string("Backchannels") },
                read: { self.liveVoiceStyle.backchannels },
                write: { enabled in update { $0.backchannels = enabled } }
            ),
            boolDescriptor(
                key: "voice.live.ask_before_sending", section: "Live voice", title: "Ask before sending to Hermes",
                description: "Live calls start by reading each request back and waiting for the user's OK before it goes to Hermes.",
                tier: .ask, displayTitle: { AppLocalization.string("Ask before sending to Hermes") },
                read: { self.liveVoiceStyle.asksBeforeSending },
                write: { enabled in update { $0.asksBeforeSending = enabled } }
            ),
        ]
    }

    private func boolDescriptor(
        key: String, section: String, title: String, description: String, tier: AgentSettingTier,
        displayTitle: @escaping () -> String,
        read: @escaping @MainActor () -> Bool, write: @escaping @MainActor (Bool) -> Void
    ) -> AgentSettingDescriptor {
        AgentSettingDescriptor(
            key: key, section: section, title: title, description: description, kind: .bool, tier: tier,
            displayTitle: displayTitle,
            displayValue: AgentSettingDescriptor.onOff,
            read: { .bool(read()) },
            write: { value in if case .bool(let on) = value { write(on) } }
        )
    }

    private func choiceDescriptor(
        key: String, section: String, title: String, description: String, tier: AgentSettingTier,
        displayTitle: @escaping () -> String,
        choices: [(value: String, title: String)],
        display: @escaping (String) -> String,
        read: @escaping @MainActor () -> String, write: @escaping @MainActor (String) -> Void
    ) -> AgentSettingDescriptor {
        AgentSettingDescriptor(
            key: key, section: section, title: title, description: description, kind: .choice(choices), tier: tier,
            displayTitle: displayTitle,
            displayValue: { value in if case .string(let text) = value { return display(text) } else { return "" } },
            read: { .string(read()) },
            write: { value in if case .string(let text) = value { write(text) } }
        )
    }
}
