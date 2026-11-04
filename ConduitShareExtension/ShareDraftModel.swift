//
//  ShareDraftModel.swift
//  ConduitShareExtension
//
//  What the share sheet shows and does: read the share into a staging
//  folder, pick where it goes, then write the draft for Conduit.
//

import Foundation
import UserNotifications

@MainActor
final class ShareDraftModel: ObservableObject {
    enum Outcome { case saved, cancelled }

    enum Phase: Equatable {
        case collecting
        case ready
        case saving
        case saved
        case failed(String)
    }

    @Published private(set) var phase: Phase = .collecting
    @Published private(set) var collection = ShareDraftCollection(text: "", attachments: [], problems: [])
    @Published private(set) var workspaceID: WidgetWorkspaceID?
    @Published var target: ShareDraftTarget = .newChat
    /// Whether a notification will take the user back to Conduit.
    @Published private(set) var notifiesWhenSaved = false
    var onFinish: ((Outcome) -> Void)?

    let snapshot: WidgetSnapshot?
    let fileByteLimit: Int64
    let composerLimitMegabytes: Int?
    private let inbox: ShareDraftInbox?
    private var staging: ShareDraftStagingFolder?

    init(snapshot: WidgetSnapshot?, inbox: ShareDraftInbox?, composerLimitMegabytes: Int?) {
        self.snapshot = snapshot
        self.inbox = inbox
        self.composerLimitMegabytes = composerLimitMegabytes
        fileByteLimit = ShareDraftLimits.fileByteLimit(composerMegabytes: composerLimitMegabytes)
        AppLocalization.adopt(appLanguage: snapshot?.appLanguage)
        let workspaces = snapshot?.workspaces ?? []
        if let current = snapshot?.currentWorkspaceID, workspaces.contains(where: { $0.id == current }) {
            workspaceID = current
        } else {
            workspaceID = workspaces.first?.id
        }
    }

    var workspaces: [WidgetWorkspaceSnapshot] { snapshot?.workspaces ?? [] }
    var workspace: WidgetWorkspaceSnapshot? { workspaces.first { $0.id == workspaceID } }
    var chats: [WidgetConversationChoice] { workspace?.choices ?? [] }

    func selectWorkspace(_ id: WidgetWorkspaceID) {
        guard id != workspaceID else { return }
        workspaceID = id
        // A chat from the other workspace can't come along.
        target = .newChat
    }

    func collect(_ items: [NSExtensionItem]) async {
        guard let inbox else {
            phase = .failed(AppLocalization.string("Conduit can't keep shared drafts on this device."))
            return
        }
        let staging: ShareDraftStagingFolder
        do {
            staging = try inbox.beginStaging()
        } catch {
            phase = .failed(AppLocalization.string("Conduit couldn't save the draft. Share it again."))
            return
        }
        self.staging = staging
        let collected = await ShareDraftCollector(staging: staging, fileByteLimit: fileByteLimit).collect(items)
        // Known before Add can be tapped. Quiet (provisional) notifications
        // show no banner to tap, so they aren't promised.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifiesWhenSaved = settings.authorizationStatus == .authorized
        collection = collected
        if collected.isEmpty {
            phase = .failed(AppLocalization.string("There's nothing here Conduit can add to a chat."))
        } else {
            phase = .ready
        }
    }

    func save() {
        guard phase == .ready, let inbox, let staging else { return }
        phase = .saving
        let envelope = ShareDraftEnvelope(
            createdAt: Date(),
            workspace: workspace?.id,
            target: workspace == nil ? .newChat : target,
            text: collection.text,
            attachments: collection.attachments
        )
        do {
            try inbox.commit(envelope, from: staging)
        } catch {
            phase = .failed(AppLocalization.string("Conduit couldn't save the draft. Share it again."))
            return
        }
        self.staging = nil
        // A Conduit already on screen (side by side on iPad) picks it up now.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(ShareDraftInbox.stagedNotificationName as CFString),
            nil, nil, true
        )
        if notifiesWhenSaved { postReadyNotification(for: envelope) }
        phase = .saved
    }

    func done() {
        onFinish?(.saved)
    }

    func cancel() {
        if let staging { inbox?.discard(staging) }
        staging = nil
        onFinish?(.cancelled)
    }

    /// Tapping it brings Conduit to the front, which picks up the draft:
    /// the notification itself carries nothing but its id.
    private func postReadyNotification(for envelope: ShareDraftEnvelope) {
        let content = UNMutableNotificationContent()
        content.title = AppLocalization.string("Draft ready in Conduit")
        content.body = AppLocalization.string("Tap to review it before you send it.")
        content.threadIdentifier = "conduit.share-draft"
        let request = UNNotificationRequest(
            identifier: ShareDraftInbox.notificationIdentifierPrefix + envelope.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

extension ShareDraftProblem {
    /// What the share sheet says about it. A file over the share's own
    /// maximum may still fit the composer's higher limit; one over the
    /// composer's limit needs that limit raised.
    func message(composerLimitMegabytes: Int?) -> String {
        switch self {
        case .fileTooLarge(let name, let limitBytes):
            let limit = ByteCountFormatter.string(fromByteCount: limitBytes, countStyle: .binary)
            let tooLarge = AppLocalization.string("\(name) is larger than the \(limit) a shared file can be.")
            let composerTakesMore = (composerLimitMegabytes ?? ShareDraftLimits.defaultFileMegabytes) > ShareDraftLimits.maximumFileMegabytes
            return tooLarge + " " + (composerTakesMore
                ? AppLocalization.string("Attach it from Conduit instead.")
                : AppLocalization.string("You can raise the limit in Conduit's Settings › Chat."))
        case .totalTooLarge(let name, let limitBytes):
            let limit = ByteCountFormatter.string(fromByteCount: limitBytes, countStyle: .binary)
            return AppLocalization.string("\(name) was left out: one share can carry \(limit) in all.")
        case .tooManyFiles(let droppedCount, let limitCount):
            return AppLocalization.string("\(droppedCount) more files were left out.") + " "
                + AppLocalization.string("One share can carry \(limitCount) files.")
        case .textTruncated(let limitCount):
            return AppLocalization.string("The text was cut to its first \(limitCount) characters.")
        case .unreadable(let name):
            return AppLocalization.string("\(name) couldn't be read.")
        }
    }
}
