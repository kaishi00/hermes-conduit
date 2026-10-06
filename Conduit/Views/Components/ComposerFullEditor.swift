//
//  ComposerFullEditor.swift
//  Conduit
//
//  The composer's full-screen editor (#335): the same draft in a
//  full-height sheet, for long prompts and long dictations. It edits the
//  composer's own text binding, so nothing is copied and the draft store
//  sees every change.
//

import SwiftUI

struct ComposerFullEditor<Attachments: View, DictateButton: View, ActionButton: View>: View {
    @Binding var text: String
    let placeholder: String
    let enabled: Bool
    /// Every change made while the editor has focus, with the new text:
    /// typing, or dictation writing the draft.
    let onUserEdit: (String) -> Void
    let onCollapse: () -> Void
    /// The staged attachments, so what Send will include stays visible
    /// and removable here.
    @ViewBuilder let attachments: () -> Attachments
    /// The composer's own dictate button, so a dictation started inline
    /// can be stopped here, and a new one started.
    @ViewBuilder let dictateButton: () -> DictateButton
    @ViewBuilder let actionButton: () -> ActionButton

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    Haptics.selection()
                    onCollapse()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Collapse editor"))
                .accessibilityIdentifier("composer.collapse-editor")
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                // Return always inserts a newline here, whatever the
                // Return-sends preference: this is the long-form editor,
                // and Send is the button.
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .accessibilityLabel(Text(placeholder))
                    .disabled(!enabled)
                    .onChange(of: text) { _, newText in
                        if isFocused { onUserEdit(newText) }
                    }
            }
            .padding(.horizontal, 16)

            attachments()

            HStack(spacing: 8) {
                Spacer()
                dictateButton()
                actionButton()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .task {
            // After the sheet has settled; focus set while it is still
            // presenting often leaves the keyboard down.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isFocused = enabled
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}
