//
//  VoiceChatCallTranscriptSheet.swift
//  Conduit
//
//  The transcript behind a chat's voice call card when the call is kept
//  with the chat rather than as a session of its own (#556): what was said
//  on the call, read from the host when the card is tapped.
//

import SwiftUI

struct VoiceChatCallTranscriptSheet: View {
    let call: VoiceChatCall

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                let latestLiveTurns = call.latestLiveTurns
                LazyVStack(spacing: 10) {
                    ForEach(call.turns) { entry in
                        if entry.speaker == .assistant, let note = VoiceJobLinkNote(text: entry.text) {
                            VoiceJobLinkCard(note: note) {
                                // The chat opens under the sheet: close it first.
                                dismiss()
                                openURL(note.link.url)
                            }
                            .frame(maxWidth: 360, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            LiveVoiceTranscriptBubble(
                                entry: entry,
                                label: label(for: entry)
                            )
                        }
                        if !entry.cards.isEmpty {
                            // A live card shows only where it was last brought up to date.
                            let cards = call.currentCards(for: entry, latestLiveTurns: latestLiveTurns)
                            if cards.isEmpty {
                                RichLiveUpdatedLine(title: entry.cards.first?.title)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                RichCardsView(cards: cards)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .navigationTitle(Text("Voice call"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Who spoke each line, as the live call sheet says it.
    private func label(for entry: VoiceConversationTranscriptEntry) -> String {
        guard entry.speaker == .assistant else { return AppLocalization.string("You: \(entry.text)") }
        switch call.engine {
        case .gptLive: return AppLocalization.string("GPT-Live: \(entry.text)")
        case .grokLive: return AppLocalization.string("Grok: \(entry.text)")
        case .localLive: return AppLocalization.string("Hermes: \(entry.text)")
        case .geminiLive: return AppLocalization.string("Gemini: \(entry.text)")
        case .qwenLive: return AppLocalization.string("Qwen: \(entry.text)")
        case nil: return entry.text
        }
    }
}
