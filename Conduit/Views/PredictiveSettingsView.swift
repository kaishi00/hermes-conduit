//
//  PredictiveSettingsView.swift
//  Conduit
//
//  Settings > Chat > Predictive (Predictive.swift): each guess is its own
//  switch, off by default, kept on this device.
//

import SwiftUI

/// The Predictive card in Settings > Chat, opening its page.
struct PredictiveSettingsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(Predictive.repliesKey) private var replies = false
    @AppStorage(Predictive.pauseKey) private var pause = false
    @AppStorage(Predictive.followUpKey) private var followUp = false

    private var summary: String {
        let on = [replies, pause, followUp].filter { $0 }.count
        return on == 0 ? AppLocalization.string("Off") : AppLocalization.string("\(String(on)) of 3 on")
    }

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Predictive"),
            symbol: "sparkles",
            tint: .conduitAura
        ) {
            Text("Hermes guesses what you'll say next: replies to tap after an answer, words for a draft when you pause, and a follow-up of its own while you look at a chat.")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            NavigationLink {
                PredictiveSettingsPage()
                    .v2TabBarClearance()
            } label: {
                HStack {
                    Text("Predictive")
                    Spacer(minLength: 8)
                    Text(summary).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("settings.chat.predictive")
        }
    }
}

struct PredictiveSettingsPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @AppStorage(Predictive.repliesKey) private var replies = false
    @AppStorage(Predictive.replyCountKey) private var replyCount = Predictive.defaultReplyCount
    @AppStorage(Predictive.pauseKey) private var pause = false
    @AppStorage(Predictive.pauseDelayKey) private var pauseDelay = Predictive.defaultPauseDelay
    @AppStorage(Predictive.followUpKey) private var followUp = false
    @AppStorage(Predictive.followUpDelayKey) private var followUpDelay = Predictive.defaultFollowUpDelay
    @AppStorage(Predictive.modelKey) private var model = Predictive.Model.fast.rawValue
    @State private var status: Predictive.HostStatus?
    /// Helper models lists Conduit's predictions: only then do the captions
    /// point there. An older plugin doesn't add the slot. Nil until the
    /// kept slots or Hermes tell, and the caption waits for it.
    @State private var predictionsSlotListed: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Each guess is a short extra request to your agent's model, on a copy of the chat that can't use tools. Nothing is saved to the chat, and only this device sees the guesses.")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !appState.predictiveIsServed {
                    Label {
                        Text("Needs a newer Conduit plugin on your Hermes host (\(Predictive.minimumPlugin) or later).")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                repliesSection
                pauseSection
                followUpSection
                modelSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        // Each switch's pickers slide in on the page-wide ease (Settings rows
        // a toggle reveals).
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: replies)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: pause)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: followUp)
        .navigationTitle("Predictive")
        // Again once the plugin's capabilities arrive.
        .task(id: appState.predictiveIsServed) {
            predictionsSlotListed = appState.keptHelperModelListed(task: HelperModelSlot.predictions)
            status = await appState.loadPredictiveHostStatus()
            // A read that fails keeps what the kept slots said, or reads as
            // an older plugin's when nothing is kept.
            do {
                predictionsSlotListed = try await appState.loadHelperModel(task: HelperModelSlot.predictions) != nil
            } catch {
                if predictionsSlotListed == nil { predictionsSlotListed = false }
            }
        }
    }

    private var repliesSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Suggested replies"), symbol: "text.bubble", tint: .conduitAura) {
            Text("After a reply, the messages you'll most likely send next, best first. Tap one to send it; touch and hold to edit it first.")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Suggest replies", isOn: $replies)
                .tint(.conduitAccent)
            if replies {
                ConduitMenuPicker(
                    value: replyCount,
                    choices: Predictive.replyCounts.map { (id: $0, title: "\($0)") },
                    onSelect: { replyCount = $0 }
                ) {
                    Text("How many").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var pauseSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("While I pause"), symbol: "text.cursor", tint: .conduitAura) {
            Text("When you stop typing for a moment, words to finish your message and whole messages you might mean. Your unsent draft goes to your agent's model to make them.")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Suggest while I pause", isOn: $pause)
                .tint(.conduitAccent)
            if pause {
                ConduitMenuPicker(
                    value: pauseDelay,
                    choices: Predictive.pauseDelays.map { (id: $0, title: Self.seconds($0)) },
                    onSelect: { pauseDelay = $0 }
                ) {
                    Text("Pause before asking").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var followUpSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Hermes follows up"), symbol: "sparkle", tint: .conduitAura) {
            Text("While a chat is on screen and you aren't writing, Hermes is asked now and then whether it has something useful to add. At most one follow-up per message you send, marked \"Hermes followed up\".")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Let Hermes follow up", isOn: $followUp)
                .tint(.conduitAccent)
            if followUp {
                ConduitMenuPicker(
                    value: followUpDelay,
                    choices: Predictive.followUpDelays.map { (id: $0, title: Self.wait($0)) },
                    onSelect: { followUpDelay = $0 }
                ) {
                    Text("Start asking after").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modelSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Model"), symbol: "cpu", tint: .conduitAura) {
            ConduitMenuPicker(
                value: model,
                choices: [
                    (id: Predictive.Model.fast.rawValue, title: AppLocalization.string("Fast model")),
                    (id: Predictive.Model.chat.rawValue, title: AppLocalization.string("Same as chat")),
                ],
                onSelect: { model = $0 }
            ) {
                Text("Predictions use").foregroundStyle(.secondary)
            }
            // Said once the host has answered; until then, nothing.
            if let status {
                if let predictionsSlotListed { Group {
                    if let fast = status.fastModel {
                        if predictionsSlotListed {
                            Text("Fast model on your host: \(fast). Change it in Models & providers under Helper models.")
                        } else {
                            Text("Fast model on your host: \(fast). Update the Conduit plugin to change it here.")
                        }
                    } else if predictionsSlotListed {
                        Text("Your host has no fast model set, so the chat's own model answers. Pick one in Models & providers under Helper models, as Conduit predictions.")
                    } else {
                        Text("Your host has no fast model set, so the chat's own model answers. Update the Conduit plugin to pick one here.")
                    }
                }
                .scaledFont(.footnote)
                .foregroundStyle(.secondary) }
                SettingsMetricRow(label: AppLocalization.string("Predictions today"), value: String(status.today))
            }
        }
    }

    private static func seconds(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = AppLocalization.formattingLocale
        formatter.maximumFractionDigits = 1
        let number = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return AppLocalization.string("\(number) s")
    }

    private static func wait(_ seconds: Int) -> String {
        seconds < 60
            ? AppLocalization.string("\(String(seconds)) s")
            : AppLocalization.string("\(String(seconds / 60)) min")
    }
}
