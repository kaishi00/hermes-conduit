//
//  AskHermesPromptView.swift
//  Conduit
//
//  A copyable "Ask Hermes" prompt card used across the Connection Setup
//  wizard. Purely clipboard-based: nothing is ever sent to Hermes from here,
//  and the prompts contain no secrets.
//

import SwiftUI
import UIKit

struct AskHermesPromptView: View {
    let title: String
    let prompt: String

    @State private var copied = false
    @State private var copyCount = 0
    // Keep the successful copy available as durable accessibility state even
    // after the intentionally short visual confirmation disappears. Tying it
    // to the prompt prevents a reused view from claiming a different prompt
    // was copied.
    @State private var lastCopiedPrompt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.conduitAccent)

            Text(prompt)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("setup.prompt-text")

            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = prompt
                    copied = true
                    lastCopiedPrompt = prompt
                    copyCount += 1
                } label: {
                    Label("Copy Prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote.weight(.semibold))
                }
                .accessibilityIdentifier("setup.copy-prompt")
                .accessibilityValue(Text(lastCopiedPrompt == prompt ? "Copied" : ""))

                if copied {
                    Text("Copied")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("setup.copied-confirmation")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))
        // Keyed to the copy count so each tap replaces the previous
        // confirmation task (SwiftUI cancels the old one on id change).
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            await Self.runCopiedConfirmation {
                copied = false
            }
        }
    }

    /// The "Copied" confirmation window. Cancellation-aware by contract:
    /// when a newer copy tap replaces this task, SwiftUI cancels the sleeping
    /// task, and a cancelled task must return WITHOUT clearing — only the
    /// currently active confirmation may reset the flag. MainActor-isolated
    /// because onExpire mutates view state. Sleep and duration are injectable
    /// so the cancellation race has deterministic unit coverage; any error
    /// from the sleep (in practice, cancellation) leaves the flag untouched.
    @MainActor
    static func runCopiedConfirmation(
        duration: Duration = .seconds(2),
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onExpire: @escaping () -> Void
    ) async {
        do {
            try await sleep(duration)
        } catch {
            return
        }
        // A sleep that resolved in the same tick its task was cancelled is
        // still a replaced task: it must not win the race against the
        // confirmation that replaced it.
        guard !Task.isCancelled else { return }
        onExpire()
    }
}
