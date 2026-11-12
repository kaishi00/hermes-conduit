//
//  RoomDraftViews.swift
//  Conduit
//
//  Rooms with people you've linked, before they start (designs/
//  cross-owner-agents, C3b): a draft's row in Group Chats, and its sheet,
//  which shows who's invited and how they answered, with Start now and
//  Take back. The drafts are read with the room list (RoomDrafts.swift),
//  and every 5 s while a sheet is up.
//

import OSLog
import SwiftUI

private let roomDraftsLogger = Logger(subsystem: "com.milim.relay", category: "RoomDrafts")

/// A draft in Group Chats: who it waits for, or why it ended.
struct RoomDraftRosterRow: View {
    let draft: RoomDraft
    let onOpen: () -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let line = RoomDraftText.line(for: draft)
        Button {
            Haptics.light()
            onOpen()
        } label: {
            RosterGlyphRow(symbol: draft.status == "ended" ? "exclamationmark.circle" : "hourglass", title: draft.name, subtitle: line)
        }
        .buttonStyle(.plain)
        .rosterListRow()
        .accessibilityLabel(Text(verbatim: draft.name))
        .accessibilityValue(Text(verbatim: line))
        .accessibilityHint(Text(AppLocalization.string("Shows who's invited and how they answered.", table: .rooms)))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if draft.status == "ended" {
                Button(AppLocalization.string("Remove")) {
                    appState.dismissRoomDraft(draft.id)
                }
            }
        }
    }
}

/// A linked person where New Group Chat and a draft's sheet list them:
/// Links carry no picture.
struct RoomPersonGlyph: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.16))
            Image(systemName: "person.fill")
                .scaledFont(.body)
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A draft's sheet: each person invited and how they answered, when the
/// invites run out, and Start now and Take back; for one that ended, why,
/// and Remove. Once the room starts and the room list has it, the sheet
/// opens it.
struct RoomDraftSheet: View {
    let roomID: String
    /// The draft as its row showed it, while the list doesn't have it.
    let initial: RoomDraft
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var busy = false
    /// Start now went through: the rooms loop starts it on its next pass.
    @State private var startRequested = false
    @State private var actionError: String?
    @State private var confirmingStart = false
    @State private var confirmingTakeBack = false
    @State private var opening = false

    init(draft: RoomDraft) {
        roomID = draft.id
        initial = draft
    }

    private var draft: RoomDraft {
        appState.linkedRoomDraft(roomID) ?? initial
    }

    var body: some View {
        let draft = self.draft
        NavigationStack {
            // Settings' own pieces, as Bots Home's sheets are (Sheets in Settings' look).
            SettingsDetailContainer {
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(.red)
                }
                ConduitSettingsSection(title: AppLocalization.string("Room", table: .rooms), symbol: "bubble.left.and.bubble.right", tint: .conduitAccent) {
                    Text(verbatim: line(for: draft))
                        .scaledFont(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if draft.status == "waiting", let expiresAt = draft.expiresAt {
                        Text(AppLocalization.string("Invites work until \(RoomDraftText.until(expiresAt))", table: .rooms))
                            .settingsCaption()
                    }
                }
                if !draft.people.isEmpty {
                    ConduitSettingsSection(title: AppLocalization.string("Invited", table: .rooms), symbol: "person.2", tint: .conduitAccent) {
                        ForEach(draft.people) { person in
                            personRow(person)
                        }
                    }
                }
                if !draft.agents.isEmpty {
                    ConduitSettingsSection(title: AppLocalization.string("Your bots", table: .rooms), symbol: "person.crop.square", tint: .conduitAccent) {
                        ForEach(Array(draft.agents.enumerated()), id: \.offset) { _, agent in
                            Text(verbatim: agent)
                                .frame(minHeight: 32, alignment: .leading)
                        }
                    }
                }
                actions(draft)
            }
            .refreshable {
                await readAgain()
                _ = settled()
            }
            .navigationTitle(draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
            .confirmationDialog(
                AppLocalization.string("Start without \(RoomDraftText.names(draft.waiting.map(\.name)))?", table: .rooms),
                isPresented: $confirmingStart,
                titleVisibility: .visible
            ) {
                Button(AppLocalization.string("Start now", table: .rooms)) { start() }
                Button(AppLocalization.string("Cancel"), role: .cancel) {}
            } message: {
                Text(AppLocalization.string("They're told it started without them.", table: .rooms))
            }
            .confirmationDialog(
                AppLocalization.string("Take back \(draft.name)?", table: .rooms),
                isPresented: $confirmingTakeBack,
                titleVisibility: .visible
            ) {
                Button(AppLocalization.string("Take back"), role: .destructive) { takeBack() }
                Button(AppLocalization.string("Cancel"), role: .cancel) {}
            } message: {
                Text(AppLocalization.string("Everyone you invited is told, and their agents' joins are undone.", table: .rooms))
            }
        }
        .task(id: roomID) { await follow() }
        // Another dashboard's drafts are another Hermes'.
        .onChange(of: appState.activeDashboardID) { _, _ in dismiss() }
    }

    private func line(for draft: RoomDraft) -> String {
        if startRequested, draft.status == "waiting" { return AppLocalization.string("Starting…") }
        return RoomDraftText.line(for: draft)
    }

    private func personRow(_ person: RoomDraft.Person) -> some View {
        HStack(spacing: 12) {
            RoomPersonGlyph()
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: person.name)
                    .scaledFont(.body)
                if let status = RoomDraftText.status(of: person) {
                    Text(verbatim: status)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actions(_ draft: RoomDraft) -> some View {
        if draft.status == "waiting" {
            VStack(spacing: 10) {
                if !startRequested, draft.canStartNow {
                    Button(AppLocalization.string("Start now", table: .rooms)) { confirmingStart = true }
                        .buttonStyle(.settingsPrimary)
                        .disabled(busy)
                }
                Button(AppLocalization.string("Take back"), role: .destructive) { confirmingTakeBack = true }
                    .buttonStyle(.settingsDestructive)
                    .disabled(busy)
            }
        } else if draft.status == "ended" {
            Button(AppLocalization.string("Remove"), role: .destructive) {
                appState.dismissRoomDraft(draft.id)
                dismiss()
            }
            .buttonStyle(.settingsDestructive)
        }
    }

    private func start() {
        guard !busy else { return }
        busy = true
        actionError = nil
        let client = appState.roomDraftsClient
        Task { @MainActor in
            defer { busy = false }
            do {
                let started = try await client.start(roomID)
                appState.adoptLinkedRoomDraft(started, from: client.dashboardID)
                startRequested = true
                Haptics.success()
            } catch {
                guard !(error is CancellationError) else { return }
                Haptics.error()
                roomDraftsLogger.notice("Start now refused: \(LogRedaction.message(error), privacy: .public)")
                actionError = AppLocalization.string("Could not start it: \(RoomDraftsClient.message(for: error))", table: .rooms)
            }
        }
    }

    private func takeBack() {
        guard !busy else { return }
        busy = true
        actionError = nil
        let client = appState.roomDraftsClient
        Task { @MainActor in
            defer { busy = false }
            do {
                let withdrawn = try await client.withdraw(roomID)
                appState.adoptLinkedRoomDraft(withdrawn, from: client.dashboardID)
            } catch {
                guard !(error is CancellationError) else { return }
                roomDraftsLogger.notice("Take back refused: \(LogRedaction.message(error), privacy: .public)")
                // One whose answer didn't come may have gone through: the list says.
                await appState.refreshLinkedRoomDrafts(readingPeople: false)
                guard appState.linkedRoomDraft(roomID)?.reason == "withdrawn" else {
                    Haptics.error()
                    actionError = AppLocalization.string("Could not take it back: \(RoomDraftsClient.message(for: error))", table: .rooms)
                    return
                }
            }
            Haptics.success()
            appState.dismissRoomDraft(roomID)
            dismiss()
        }
    }

    /// Every 5 s while the sheet is up, for up to 10 minutes: answers come
    /// in as each person's Hermes reads its invite, and a room that started
    /// opens once the room list has it. One that ended won't change. A tick
    /// while Conduit is in the background or not connected is skipped, as
    /// the room's own poll skips them. Pull to read it again.
    private func follow() async {
        for _ in 0..<120 {
            guard !Task.isCancelled, !settled() else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard appState.isSceneActive, appState.isConnected else { continue }
            await readAgain()
        }
        _ = settled()
    }

    /// Opens a room that started once the room list has it. True when
    /// there's nothing left to wait for: it opened, or the draft ended.
    private func settled() -> Bool {
        let draft = self.draft
        if draft.status == "started", let room = appState.groupRooms.first(where: { $0.roomID == roomID }) {
            open(room)
            return true
        }
        return draft.status == "ended"
    }

    private func readAgain() async {
        await appState.refreshLinkedRoomDrafts(readingPeople: false)
        if draft.status == "started" {
            await appState.refreshGroupRooms()
        }
    }

    private func open(_ room: GroupRoom) {
        guard !opening else { return }
        opening = true
        appState.dismissSidebarDrawer()
        // Not in the sheet's task, which ends with the sheet.
        Task { @MainActor in await appState.openGroupRoom(room) }
        dismiss()
    }
}
