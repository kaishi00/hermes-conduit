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

struct ComposerFullEditor<ActionButton: View>: View {
    @Binding var text: String
    let placeholder: String
    let enabled: Bool
    let onUserEdit: () -> Void
    let onCollapse: () -> Void
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
                }
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .disabled(!enabled)
                    .onChange(of: text) { _, _ in
                        // Dictation ends when the sheet opens, so a change
                        // while it has focus is typing.
                        if isFocused { onUserEdit() }
                    }
            }
            .padding(.horizontal, 16)

            HStack {
                Spacer()
                actionButton()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear { isFocused = enabled }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}
