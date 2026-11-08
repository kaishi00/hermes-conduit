//
//  RoomApprovalViews.swift
//  Conduit
//
//  Your agents' approvals in rooms other people host (designs/
//  cross-owner-agents, C3d): an approval's row in Group Chats, and its
//  card, the room screen's own (GroupApprovalCard), which answers it once
//  or deny through the plugin (RoomApprovals.swift).
//

import SwiftUI

/// An approval in Group Chats: the agent and the room it waits in.
struct RoomApprovalRosterRow: View {
    let approval: RoomApproval
    let onOpen: () -> Void

    var body: some View {
        let line = RoomApprovalText.line(for: approval)
        Button {
            Haptics.light()
            onOpen()
        } label: {
            RosterGlyphRow(symbol: "checkmark.shield", title: AppLocalization.string("Approval needed"), subtitle: line)
        }
        .buttonStyle(.plain)
        .rosterListRow()
        .accessibilityLabel(Text(AppLocalization.string("Approval needed")))
        .accessibilityValue(Text(verbatim: line))
        .accessibilityHint(Text(AppLocalization.string("Shows what it asks, to run or reject it.")))
    }
}

/// An approval's card: what the agent asks, and Run or Reject. Taken, it
/// closes; refused, it says why. One a read no longer lists says so.
struct RoomApprovalSheet: View {
    let approval: RoomApproval
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var answer: AppState.RoomApprovalAnswer?

    var body: some View {
        NavigationStack {
            // Settings' backdrop, as Bots Home's sheets have (Sheets in Settings' look).
            SettingsDetailContainer {
                if appState.linkedRoomApprovalIsGone(approval.id), answer != .submitting {
                    SettingsCard {
                        Text(verbatim: RoomApprovalText.line(for: approval))
                            .scaledFont(.subheadline.weight(.semibold))
                        Text(AppLocalization.string("This approval isn't waiting any more."))
                            .settingsCaption()
                    }
                } else {
                    GroupApprovalCard(
                        approval: approval.card,
                        memberName: RoomApprovalText.line(for: approval),
                        answer: answer,
                        respond: respond
                    )
                }
            }
            .refreshable { await appState.refreshLinkedRoomApprovals() }
            .navigationTitle(AppLocalization.string("Approval needed"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
        // Another dashboard's approvals are another Hermes'.
        .onChange(of: appState.activeDashboardID) { _, _ in dismiss() }
    }

    private func respond(_ choice: String) {
        guard answer != .submitting else { return }
        answer = .submitting
        Task { @MainActor in
            let result = await appState.answerLinkedRoomApproval(approval, choice: choice)
            answer = result
            if result == .sent {
                Haptics.success()
                dismiss()
            } else {
                Haptics.error()
            }
        }
    }
}
