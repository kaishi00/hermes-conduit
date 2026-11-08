//
//  AuthorityQueueDock.swift
//  Conduit
//
//  Above the composer, on the gateway's own listener (the Webapp): the
//  chat's messages waiting their turn, each with Send now, Edit and Remove,
//  and a turn a gateway restart cut off, with Resend and Discard, since
//  nothing after it runs until one is chosen. AuthorityQueue.swift holds
//  the queue, AppState+AuthorityQueue.swift what the buttons do.
//

import SwiftUI

struct AuthorityQueueDock: View {
    @ObservedObject var store: AuthorityQueueStore
    let appState: AppState
    /// The open chat: passed so the dock redraws when another opens.
    let openChatID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing: QueuedPrompt?
    @State private var editText = ""

    private var shows: Bool {
        openChatID != nil && appState.authorityQueueIsOpenChat(store.sessionID) && !store.isEmpty
    }

    var body: some View {
        Group {
            if shows {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.lost) { row in
                        lostCard(row)
                    }
                    ForEach(store.queued) { row in
                        queuedRow(row)
                    }
                    if let notice = store.notice {
                        Text(verbatim: notice)
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, 12)
        .padding(.bottom, shows ? 6 : 0)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: store.rows)
        .onChange(of: store.notice) {
            if let notice = store.notice { UIAccessibility.post(notification: .announcement, argument: notice) }
        }
        .alert("Edit queued message", isPresented: editingBinding) {
            TextField("Message", text: $editText, axis: .vertical)
            Button("Save") {
                guard let row = editing else { return }
                let text = editText
                Task { await appState.editQueuedPrompt(row, text: text) }
            }
            .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes to the back of the line. To withdraw it, use Remove from queue.")
        }
    }

    private var editingBinding: Binding<Bool> {
        Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
    }

    // MARK: - A message waiting its turn

    private func queuedRow(_ row: QueuedPrompt) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .scaledFont(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Queued")
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: row.text)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if store.working.contains(row.admissionID) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44, height: 44)
            } else {
                queuedMenu(row)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .conduitGlassControl(cornerRadius: 20, interactive: false)
    }

    private func queuedMenu(_ row: QueuedPrompt) -> some View {
        Menu {
            if row.canSendNow {
                Button {
                    Task { await appState.sendQueuedPromptNow(row) }
                } label: {
                    Label("Send now", systemImage: "arrow.up.circle")
                }
            }
            if row.canEdit {
                Button {
                    editText = row.text
                    editing = row
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
            Button(role: .destructive) {
                Task { await appState.cancelQueuedPrompt(row) }
            } label: {
                Label("Remove from queue", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Queued message options"))
    }

    // MARK: - A turn a restart cut off

    private func lostCard(_ row: QueuedPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Hermes restarted before it finished this.", systemImage: "exclamationmark.arrow.circlepath")
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if !row.text.isEmpty {
                Text(verbatim: row.text)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text("Messages after it wait until you choose.")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            if !row.text.isEmpty {
                Text("Resend sends the words only, without any files.")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if store.working.contains(row.admissionID) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minHeight: 44)
                } else {
                    if !row.text.isEmpty {
                        Button {
                            Task { await appState.resendLostPrompt(row) }
                        } label: {
                            Text("Resend")
                                .scaledFont(.subheadline.weight(.semibold))
                                .frame(minHeight: 44)
                                .padding(.horizontal, 14)
                        }
                        .buttonStyle(.plain)
                        .conduitGlassControl(cornerRadius: 22, tint: .conduitAccent.opacity(0.16))
                        .accessibilityHint(Text("Sends these words again as a new message, without any files it had."))
                    }
                    Button {
                        Task { await appState.discardLostPrompt(row) }
                    } label: {
                        Text("Discard")
                            .scaledFont(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                    .conduitGlassControl(cornerRadius: 22)
                    .accessibilityHint(Text("Lets the messages waiting behind it go on."))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .conduitGlassControl(cornerRadius: 20, interactive: false)
        .accessibilityElement(children: .contain)
    }
}
