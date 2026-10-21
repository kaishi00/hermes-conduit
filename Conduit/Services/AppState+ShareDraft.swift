//
//  AppState+ShareDraft.swift
//  Conduit
//
//  Drafts shared from other apps (#812). The share extension leaves each one
//  in the App Group's ShareInbox (Shared/ShareDraft) with the dashboard,
//  profile and chat it is for. When Conduit comes to the front it takes the
//  oldest, opens that chat the way a widget does (WidgetLaunchCoordinator),
//  and puts the text and files in the chat's composer, like words a waiting
//  message gives back. Nothing is sent: the user reviews it and sends it.
//
//  A draft with no dashboard of its own (shared before Conduit listed any
//  chats) goes to the only dashboard, or the user picks one.
//

import Foundation
import UniformTypeIdentifiers
import UserNotifications

/// A shared draft whose chat is opening.
struct SharedDraftLaunch: Equatable {
    let envelopeID: UUID
    let link: WidgetLaunchLink
}

/// A shared draft waiting for the user to say which dashboard it's for.
struct SharedDraftChoice: Identifiable, Equatable {
    let id: UUID
    let dashboards: [SavedDashboard]
}

/// What became of a shared draft's files on their way into the composer.
struct SharedDraftStagedFiles: Equatable {
    var attachments: [Attachment] = []
    var oversized: [String] = []
    var failed: [String] = []
}

extension AppState {
    var shareDraftInbox: ShareDraftInbox? {
        shareDraftInboxOverride ?? ShareDraftInbox.production
    }

    /// The composer's attachment limit, for the share sheet to cap files
    /// the same way.
    func publishShareDraftSettings() {
        let stored = UserDefaults.standard.integer(forKey: AttachmentSizeLimit.preferenceKey)
        ShareDraftSettings.publishComposerLimit(
            megabytes: AttachmentSizeLimit.clampedMegabytes(stored),
            to: shareDraftSettingsDefaultsOverride ?? ShareDraftSettings.groupDefaults
        )
    }

    // MARK: Picking up

    /// Takes the oldest shared draft, if Conduit isn't busy with one, and
    /// opens its chat. On the sign-in screen or in a call, drafts wait
    /// (until they expire); a draft already handed to the composer, or one
    /// the user put off, is skipped.
    func pickUpSharedDrafts(now: Date = Date()) {
        guard sharedDraftLaunch == nil, !isDeliveringSharedDraft, sharedDraftChoice == nil,
              !showLogin, !isVoiceCallInProgress,
              let inbox = shareDraftInbox,
              !savedDashboardRegistry.dashboards.isEmpty else { return }
        let inComposer = Set(composerRestoreRequests.compactMap(\.sharedDraftID))
        guard let next = inbox.pending(now: now).first(where: {
            !inComposer.contains($0.envelope.id) && !postponedSharedDraftIDs.contains($0.envelope.id)
        }) else { return }
        let envelope = next.envelope
        if let workspace = envelope.workspace, savedDashboardRegistry.dashboard(with: workspace.dashboardID) != nil {
            launchSharedDraft(envelope, workspace: workspace)
            return
        }
        // Shared without a dashboard, or for one since removed: its chat
        // can't be found, so it starts a new one where the user says.
        let dashboards = savedDashboardRegistry.dashboards
        if dashboards.count == 1, let only = dashboards.first {
            launchSharedDraft(envelope, workspace: sharedDraftWorkspace(on: only.id), startsNewChat: true)
        } else {
            sharedDraftChoice = SharedDraftChoice(id: envelope.id, dashboards: dashboards)
        }
    }

    /// The Darwin notification the extension posts: a Conduit already on
    /// screen takes the draft now.
    func sharedDraftWasStaged() {
        guard isSceneActive else { return }
        pickUpSharedDrafts()
    }

    /// The user picked the dashboard for a draft that didn't say. The
    /// dialog may already have cleared the choice as it closed.
    func chooseDashboardForSharedDraft(_ dashboardID: UUID, for choice: SharedDraftChoice) {
        if sharedDraftChoice?.id == choice.id { sharedDraftChoice = nil }
        guard sharedDraftLaunch == nil, !isDeliveringSharedDraft else { return }
        guard choice.dashboards.contains(where: { $0.id == dashboardID }),
              savedDashboardRegistry.dashboard(with: dashboardID) != nil,
              let draft = shareDraftInbox?.pending(id: choice.id) else { return }
        launchSharedDraft(draft.envelope, workspace: sharedDraftWorkspace(on: dashboardID), startsNewChat: true)
    }

    /// The user threw the draft away instead. The next one is offered once
    /// the dialog has gone.
    func discardSharedDraft(_ choice: SharedDraftChoice) {
        if sharedDraftChoice?.id == choice.id { sharedDraftChoice = nil }
        removeSharedDraft(choice.id)
        Task { @MainActor [weak self] in self?.pickUpSharedDrafts() }
    }

    /// Dismissed without a choice: asked again next time Conduit comes to
    /// the front, and drafts behind it go ahead meanwhile.
    func postponeSharedDraftChoice(_ choice: SharedDraftChoice) {
        guard sharedDraftChoice?.id == choice.id else { return }
        sharedDraftChoice = nil
        postponedSharedDraftIDs.insert(choice.id)
        Task { @MainActor [weak self] in self?.pickUpSharedDrafts() }
    }

    /// Sign-out: drafts shared for that dashboard go with it, and a pending
    /// question about drafts is dropped (its list of dashboards is stale).
    func discardSharedDrafts(forDashboard dashboardID: UUID) {
        sharedDraftChoice = nil
        shareDraftInbox?.removeAll { $0.workspace?.dashboardID == dashboardID }
        pruneSharedDraftNotifications()
    }

    private func removeSharedDraft(_ id: UUID) {
        shareDraftInbox?.remove(id: id)
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [ShareDraftInbox.notificationIdentifierPrefix + id.uuidString]
        )
    }

    /// "Draft ready" notifications whose draft is gone (opened, discarded,
    /// expired or signed out) leave Notification Center.
    func pruneSharedDraftNotifications() {
        guard let inbox = shareDraftInbox else { return }
        let waiting = Set(inbox.pending().map { ShareDraftInbox.notificationIdentifierPrefix + $0.envelope.id.uuidString })
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let delivered = await center.deliveredNotifications().map(\.request.identifier)
            let stale = delivered.filter { $0.hasPrefix(ShareDraftInbox.notificationIdentifierPrefix) && !waiting.contains($0) }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    /// The profile a draft opens in on a dashboard it didn't name: the one
    /// in use there, or the one last used.
    private func sharedDraftWorkspace(on dashboardID: UUID) -> WidgetWorkspaceID {
        if dashboardID == activeDashboardID { return WidgetWorkspaceID(dashboardID: dashboardID, profile: activeProfile) }
        let remembered = widgetStore?.read()?.workspaces.first { $0.id.dashboardID == dashboardID }?.id.profile
        return WidgetWorkspaceID(dashboardID: dashboardID, profile: remembered ?? "default")
    }

    private func launchSharedDraft(_ envelope: ShareDraftEnvelope, workspace: WidgetWorkspaceID, startsNewChat: Bool = false) {
        let link: WidgetLaunchLink?
        if !startsNewChat, case .conversation(let reference) = envelope.target {
            link = WidgetLaunchLink(action: .resume, workspace: workspace, reference: reference)
        } else {
            link = WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil)
        }
        guard let link else {
            // A target no launch can name: unusable.
            shareDraftInbox?.remove(id: envelope.id)
            return
        }
        cancelChatResumeRestoration()
        newChatLaunchStartedInApp = false
        widgetLaunchCoordinator.receive(link)
        // Recorded after receive: a launch for the same link that receive
        // supersedes isn't this one.
        sharedDraftLaunch = SharedDraftLaunch(envelopeID: envelope.id, link: link)
        if showsPendingNewChat { revealChatForWidgetLaunch() }
    }

    // MARK: Delivering

    /// The coordinator ended a launch. A shared draft's goes in the composer
    /// on screen: its chat's, when the launch opened it; otherwise the
    /// chat the user is in, and they're told why. Superseded by something
    /// newer the user did (a widget, a link, a chat they opened), it stays
    /// in the inbox for the next time Conduit comes to the front, rather
    /// than land in a chat it wasn't for.
    func sharedDraftLaunchEnded(_ link: WidgetLaunchLink, outcome: WidgetLaunchOutcome?) {
        guard let launch = sharedDraftLaunch, launch.link == link else { return }
        sharedDraftLaunch = nil
        guard let outcome else { return }
        // The finish that follows is this draft's.
        sharedDraftLaunchOwnsFinish = true
        guard let dashboardID = activeDashboardID else { return }
        let opened = outcome == .handled
        isDeliveringSharedDraft = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let delivered = await self.deliverSharedDraft(launch.envelopeID, openedItsChat: opened, dashboardID: dashboardID)
            self.isDeliveringSharedDraft = false
            if delivered { self.pickUpSharedDrafts() }
        }
    }

    /// Moves the draft's files into the composer's staging folder (checked
    /// against the composer's limit, pictures normalized as when attached
    /// in Conduit) and hands its text and files to the composer on screen.
    /// The draft leaves the inbox once the composer has it
    /// (`sharedDraftReachedComposer`). Nothing is sent. False when the
    /// dashboard or the chat on screen changed meanwhile: the draft waits.
    @discardableResult
    func deliverSharedDraft(_ id: UUID, openedItsChat: Bool, dashboardID: UUID) async -> Bool {
        guard let inbox = shareDraftInbox, let draft = inbox.pending(id: id) else { return false }
        let stored = UserDefaults.standard.integer(forKey: AttachmentSizeLimit.preferenceKey)
        let limit = AttachmentSizeLimit.clampedMegabytes(stored)
        // The chat the draft lands in, as it is on screen now: the user
        // can move to another one while the files are copied.
        let destinationKey = composerDraftKeyOnScreen
        let staged = await Task.detached(priority: .userInitiated) {
            Self.stageSharedFiles(draft, from: inbox, limitMegabytes: limit)
        }.value
        // Signed out, or on another dashboard, while the files were copied.
        guard activeDashboardID == dashboardID, inbox.pending(id: id) != nil else {
            staged.attachments.forEach(Self.deleteStagedScreenshot)
            return false
        }
        // Moved to another chat (or profile) while the files were copied:
        // the draft waits in the inbox rather than land in a chat it
        // wasn't for.
        guard composerDraftKeysAreSameChat(destinationKey, composerDraftKeyOnScreen) else {
            staged.attachments.forEach(Self.deleteStagedScreenshot)
            return false
        }
        let content = ComposerDraft(text: draft.envelope.text, attachments: staged.attachments)
        guard !content.isEmpty else {
            removeSharedDraft(id)
            reportSharedDraftProblems(staged, limitMegabytes: limit, openedItsChat: true)
            return true
        }
        composerRestoreRequests.append(ComposerRestoreRequest(
            dashboardID: dashboardID,
            // The key the composer on screen is loaded with: a resumed chat
            // runs under a new runtime id, which its stored id doesn't match.
            key: composerDraftKeyOnScreen,
            draft: content,
            focuses: false,
            pending: nil,
            sharedDraftID: id
        ))
        composerNotice = AppLocalization.string("Shared from another app. Review it, then send it.")
        composerNoticeSystemImage = "square.and.arrow.down"
        reportSharedDraftProblems(staged, limitMegabytes: limit, openedItsChat: openedItsChat)
        return true
    }

    /// The composer took a shared draft: it leaves the inbox, and its
    /// "Draft ready" notification goes.
    func sharedDraftReachedComposer(_ id: UUID) {
        removeSharedDraft(id)
    }

    private func reportSharedDraftProblems(_ staged: SharedDraftStagedFiles, limitMegabytes: Int, openedItsChat: Bool) {
        var messages: [String] = []
        if !openedItsChat {
            messages.append(AppLocalization.string("Conduit couldn't open the chat you picked, so the shared draft is in this one."))
        }
        if !staged.oversized.isEmpty {
            messages.append(AttachmentSizeLimit.tooLargeMessage(names: staged.oversized, megabytes: limitMegabytes))
        }
        if !staged.failed.isEmpty {
            let list = staged.failed.joined(separator: ", ")
            messages.append(AppLocalization.string("Could not prepare \(list) for upload."))
        }
        guard !messages.isEmpty else { return }
        errorMessage = messages.joined(separator: "\n")
    }

    nonisolated static func stageSharedFiles(
        _ draft: ShareDraftPending,
        from inbox: ShareDraftInbox,
        limitMegabytes: Int
    ) -> SharedDraftStagedFiles {
        var result = SharedDraftStagedFiles()
        for file in draft.envelope.attachments {
            let name = file.displayName
            guard let source = inbox.file(for: file, in: draft) else {
                result.failed.append(name)
                continue
            }
            if let size = AttachmentSizeLimit.fileSize(at: source),
               !AttachmentSizeLimit.allows(byteCount: size, megabytes: limitMegabytes) {
                result.oversized.append(name)
                continue
            }
            let type = file.typeIdentifier.flatMap { UTType($0) }
                ?? UTType(filenameExtension: (name as NSString).pathExtension)
            do {
                let staged = try AttachmentStaging.destination(for: name)
                try FileManager.default.copyItem(at: source, to: staged)
                switch AttachmentStaging.finishStaging(fileAt: staged, name: name, type: type, limitMegabytes: limitMegabytes) {
                case .staged(let attachment): result.attachments.append(attachment)
                case .tooLarge(let tooLarge): result.oversized.append(tooLarge)
                case .failed(let failed): result.failed.append(failed)
                }
            } catch {
                result.failed.append(name)
            }
        }
        return result
    }
}

/// Listens for the share extension's "a draft is in place" Darwin
/// notification while Conduit runs.
enum SharedDraftStagedObserver {
    private final class Token {}
    private static let token = Token()
    @MainActor private static var isObserving = false

    @MainActor static func start() {
        guard !isObserving else { return }
        isObserving = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(token).toOpaque(),
            { _, _, _, _, _ in
                Task { @MainActor in
                    AppStateRuntimeRegistry.shared.appState.sharedDraftWasStaged()
                }
            },
            ShareDraftInbox.stagedNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }
}
