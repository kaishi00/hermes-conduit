//
//  RoomCopyViews.swift
//  Conduit
//
//  Rooms other people host (designs/cross-owner-agents, C4a): a room's row
//  in Group Chats, which opens its room screen from your Hermes' copy and
//  deletes one that ended; your agents' approvals in it, over its composer
//  (C5a) or, when it can't be posted in, a line in the composer's place;
//  and Group Info's Hosted by section.
//

import SwiftUI

/// A room someone else hosts, in Group Chats: who hosts it and how it
/// stands. One that ended, or that your agents left, can be deleted.
struct RoomCopyRosterRow: View {
    let copy: RoomCopy
    @EnvironmentObject private var appState: AppState
    @State private var confirmingDelete = false

    private var canDelete: Bool { copy.isOver && appState.canDeleteRoomCopies }

    var body: some View {
        let line = RoomCopyText.line(for: copy)
        Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            Task { await appState.openRoomCopy(copy) }
        } label: {
            RosterIconRow(title: copy.name, subtitle: line) { size in
                RoomCopyIcon(copy: copy, size: size)
            }
        }
        .buttonStyle(.plain)
        .rosterListRow()
        .accessibilityLabel(Text(verbatim: copy.name))
        .accessibilityValue(Text(verbatim: [AppLocalization.string("With linked people"), line].joined(separator: ", ")))
        .accessibilityHint(Text(AppLocalization.string("Opens this group chat.")))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canDelete {
                Button(AppLocalization.string("Delete"), role: .destructive) {
                    confirmingDelete = true
                }
            }
        }
        .contextMenu {
            if canDelete {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label(AppLocalization.string("Delete"), systemImage: "trash")
                }
            }
        }
        .modifier(RoomCopyDelete(copy: copy, confirming: $confirmingDelete))
    }
}

/// A room someone else hosts, on Bots Home: a portrait among your own
/// rooms, marked as a room over Links, with the same menu as its row.
struct RoomCopyPortrait: View {
    let copy: RoomCopy
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2OpenBeside) private var openBeside
    @State private var confirmingDelete = false

    private var canDelete: Bool { copy.isOver && appState.canDeleteRoomCopies }
    private var selection: V2RowSelection { .room(copy.roomID, beside: openBeside) }

    private var zoomKey: String { BotZoomArm.roomKey(copy.roomID) }

    var body: some View {
        let line = RoomCopyText.line(for: copy)
        Button {
            open()
        } label: {
            BotRoomPortraitLabel(title: copy.name, highlighted: selection == .open, zoomSource: zoomKey) { size in
                RoomCopyIcon(copy: copy, size: size)
            }
            // One that's over reads as over at a glance.
            .opacity(copy.isOver ? 0.55 : 1)
        }
        .buttonStyle(PressableButtonStyle())
        .contextMenu {
            if canDelete {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label(AppLocalization.string("Delete"), systemImage: "trash")
                }
            }
        }
        .modifier(RoomCopyDelete(copy: copy, confirming: $confirmingDelete))
        .accessibilityLabel(Text(verbatim: copy.name))
        .accessibilityValue(Text(verbatim: [AppLocalization.string("With linked people"), line].joined(separator: ", ")))
        .accessibilityHint(Text(AppLocalization.string("Opens this group chat.")))
        .accessibilityIdentifier("bots.roomCopy.\(copy.roomID)")
        .v2SelectedTrait(selection)
    }

    /// Opens in Bots and grows out of this portrait, as a hosted room's
    /// tile does (GroupRoomPortrait), unless it opens beside the list.
    private func open() {
        Haptics.light()
        appState.beginOpeningBotChat(zoomKey)
        if openBeside == nil { appState.botZoom.tap(zoomKey) }
        Task {
            await appState.openRoomCopy(copy)
            if appState.activeRoomSurface?.room.roomID != copy.roomID { appState.botZoom.openFailed(zoomKey) }
            appState.endOpeningBotChat(zoomKey)
        }
    }
}

/// A room someone else hosts' picture: its members as their own Conduits
/// draw them, marked as a room over Links.
struct RoomCopyIcon: View {
    let copy: RoomCopy
    let size: CGFloat
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GroupRoomIcon(picture: nil, members: copy.room.members, size: size)
            .environment(\.groupRoomLooks, appState.homeRoomLooks(roomID: copy.roomID))
            .modifier(RoomTileBadge(systemImage: RoomTileBadge.linked))
    }
}

/// Reads how Group Chats' rooms over Links look while they show, so
/// their pictures draw other people's agents as the room screen does: on
/// showing, when the rooms change, and every 30 s.
struct HomeRoomLooksReader: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        // Not while hidden behind another tab or a pushed screen, or in the
        // background: the open room's own reads keep its tile's faces.
        let shown = shell.isTabActive && !shell.isRootCovered && scenePhase == .active
        content.task(id: "\(shown)|\(appState.isConnected)|\(appState.homeLinkedRoomIDs.joined(separator: ","))") {
            guard shown, appState.isConnected, !appState.homeLinkedRoomIDs.isEmpty else { return }
            while !Task.isCancelled {
                await appState.readHomeRoomLooks()
                try? await Task.sleep(for: .seconds(AppState.roomLooksReadInterval))
            }
        }
    }
}

/// Deleting a room someone else hosts once it's over: asked first, and
/// a refusal said.
private struct RoomCopyDelete: ViewModifier {
    let copy: RoomCopy
    @Binding var confirming: Bool
    @EnvironmentObject private var appState: AppState
    @State private var refusal: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(RoomCopyText.deleteTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button(AppLocalization.string("Delete"), role: .destructive) {
                    Task { @MainActor in
                        if case .refused(let message) = await appState.deleteLinkedRoomCopy(copy) {
                            Haptics.error()
                            refusal = message
                        }
                    }
                }
                Button(AppLocalization.string("Cancel"), role: .cancel) {}
            } message: {
                Text(RoomCopyText.deleteMessage)
            }
            .alert(
                AppLocalization.string("Could not delete this room"),
                isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
            ) {
                Button(AppLocalization.string("OK"), role: .cancel) { refusal = nil }
            } message: {
                Text(verbatim: refusal ?? "")
            }
    }
}

/// In a room someone else hosts: your agents' approvals in it, then its
/// composer while it takes your posts, or who hosts it and why it can't be
/// posted in.
struct RoomCopyBottomBar: View {
    let copy: RoomCopy
    let members: [GroupMember]
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    /// Where each card's answer stands, by approval.
    @State private var answers: [String: AppState.RoomApprovalAnswer] = [:]

    var body: some View {
        let approvals = appState.activeRoomCopyApprovals
        let takesPosts = appState.activeRoomCopyTakesPosts
        let cards = VStack(spacing: 8) {
            ForEach(approvals) { approval in
                GroupApprovalCard(
                    approval: approval.card,
                    memberName: name(of: approval),
                    answer: answers[approval.id]
                ) { choice in
                    respond(approval, choice: choice)
                }
            }
        }
        VStack(spacing: 0) {
            if !approvals.isEmpty || !takesPosts {
                VStack(spacing: 8) {
                    if approvals.count > 1 {
                        // Several waiting at once scroll in a bounded strip, as the
                        // room screen's own approvals do.
                        ScrollView { cards }
                            .frame(maxHeight: 300)
                    } else {
                        cards
                    }
                    if !takesPosts {
                        Label {
                            Text(verbatim: RoomCopyText.readOnly(for: copy, canPost: appState.canPostInRoomCopies))
                        } icon: {
                            Image(systemName: "eye")
                                .accessibilityHidden(true)
                        }
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .conduitGlassSurface(cornerRadius: 20, tint: Color.conduitAccent.opacity(0.06))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, takesPosts ? 0 : 8)
            }
            if takesPosts {
                GroupRoomComposer(members: members)
            }
        }
        // One answered elsewhere drops its card, and its answer with it.
        .onChange(of: appState.activeRoomCopyApprovals.map(\.id)) { _, ids in
            answers = answers.filter { ids.contains($0.key) }
        }
    }

    /// The agent by its name in the room.
    private func name(of approval: RoomApproval) -> String {
        if let member = members.first(where: { !$0.isPeer && $0.profile == approval.agentProfile }) {
            return GroupRoomTurns.displayName(of: member)
        }
        return RoomApprovalText.line(for: approval)
    }

    private func respond(_ approval: RoomApproval, choice: String) {
        guard answers[approval.id] != .submitting else { return }
        answers[approval.id] = .submitting
        Task { @MainActor in
            let result = await appState.answerLinkedRoomApproval(approval, choice: choice)
            // A card already gone keeps no answer behind.
            if appState.activeRoomCopyApprovals.contains(where: { $0.id == approval.id }) {
                answers[approval.id] = result
            } else {
                answers[approval.id] = nil
            }
            if result == .sent {
                Haptics.success()
            } else {
                Haptics.error()
            }
        }
    }
}

/// Group Info's first section for a room someone else hosts.
struct RoomCopyHostSection: View {
    let copy: RoomCopy

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: RoomCopyText.host(for: copy))
                if copy.isOver {
                    Text(verbatim: RoomCopyText.line(for: copy))
                        .settingsCaption()
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Under your pending post's bubble in a room someone else hosts: sending,
/// not delivered (retried under its id), or why it wasn't posted, with
/// Retry when posting it again could go differently and Edit to take its
/// text back into the composer. In a room that takes no more posts, Copy
/// and Dismiss instead: there's no composer to edit it in.
struct RoomCopyPostFooter: View {
    let state: RoomPostText.RowState
    let retry: () -> Void
    let edit: () -> Void
    let copy: () -> Void
    let dismiss: () -> Void
    @ObservedObject private var appLanguage = AppLanguageStore.shared

    var body: some View {
        switch state {
        case .sending:
            Text(AppLocalization.string("Sending…"))
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
        case .notDelivered:
            Button(action: retry) {
                Label(AppLocalization.string("Not delivered — retry"), systemImage: "arrow.clockwise")
                    .scaledFont(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.conduitAccent)
        case .refused(let why, let canRetry):
            VStack(alignment: .trailing, spacing: 4) {
                Text(verbatim: why)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    if canRetry {
                        Button(AppLocalization.string("Retry"), action: retry)
                    }
                    Button(AppLocalization.string("Edit"), action: edit)
                }
                .scaledFont(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.conduitAccent)
            }
        case .closed(let why):
            VStack(alignment: .trailing, spacing: 4) {
                Text(verbatim: why)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button(AppLocalization.string("Copy"), action: copy)
                    Button(AppLocalization.string("Dismiss"), action: dismiss)
                }
                .scaledFont(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.conduitAccent)
            }
        }
    }
}
