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
                            label: entry.speaker == .user ? AppLocalization.string("You: \(entry.text)") : entry.text
                        )
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
}
