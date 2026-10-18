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

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(call.turns) { entry in
                        LiveVoiceTranscriptBubble(
                            entry: entry,
                            label: label(for: entry)
                        )
                        if !entry.cards.isEmpty {
                            RichCardsView(cards: entry.cards)
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
        case nil: return entry.text
        }
    }
}
