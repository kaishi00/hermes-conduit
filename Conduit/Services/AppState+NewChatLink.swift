//
//  AppState+NewChatLink.swift
//  Conduit
//
//  `conduit://new?text=…&profile=…&title=…&send=0|1` (issue 3389): another
//  app, a widget or an automation opens Conduit on a new chat with text
//  ready. It is the New Chat shortcut's launch (switching profile, waiting
//  for the connection, the keyboard up, its failures in its words); once
//  that launch opens the chat, the title is set and the text goes in the
//  composer. A link with `send=1` asks first, showing the text: any app,
//  web page, QR code or NFC tag can open a link, and Hermes acts on what it
//  reads, so nothing reaches Hermes unseen (Eric 2026-11-27).
//

import Foundation

/// A new chat link's launch.
struct NewChatLinkLaunch: Equatable {
    let link: WidgetLaunchLink
    let request: NewChatLink
}

/// A link's text waiting for the user's Send, in the chat it opened.
struct NewChatLinkConfirmation: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let dashboardID: UUID
    let key: ComposerDraftKey
    /// The title the link gave its chat, for the notice when the text
    /// waits in that chat's draft instead.
    var title: String? = nil

    /// Longest text a link may send. The sheet shows it whole, since the
    /// user is agreeing to all of it; longer text waits in the composer,
    /// where it can all be read, instead.
    static let maximumCharacters = 2_000

    static func preview(of text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func canAsk(_ text: String) -> Bool {
        preview(of: text).count <= maximumCharacters
    }
}

extension AppState {
    /// Starts the new chat a link asks for. A link with only a profile is
    /// the New Chat shortcut as it is.
    func startNewChatFromLink(_ request: NewChatLink) {
        newChatLinkConfirmation = nil
        guard !request.isPlainNewChat else {
            startNewChatFromShortcut(profile: request.profile)
            return
        }
        // With no dashboard signed in, Conduit opens on its sign-in, as
        // for the shortcut.
        guard let link = newChatShortcutLaunchLink(profile: request.profile) else { return }
        cancelChatResumeRestoration()
        // The same New Chat already on its way goes on as that launch, and
        // the link's text lands in the chat it opens all the same. Not a
        // shared draft's: that launch's own text would land on top of the
        // link's, so the link starts nothing, as a draft doesn't ride a
        // launch in flight either (issue 2870).
        if !receiveLaunch(link, origin: .shortcut), sharedDraftLaunch?.link == link { return }
        newChatLinkLaunch = NewChatLinkLaunch(link: link, request: request)
        if showsPendingNewChat { revealChatForWidgetLaunch() }
    }

    /// The coordinator ended a launch. A link's, when it opened its chat,
    /// names the chat and hands it the text; one that failed says so in the
    /// shortcut's words, and the text goes with it.
    func newChatLinkLaunchEnded(_ link: WidgetLaunchLink, outcome: WidgetLaunchOutcome?) {
        guard let launch = newChatLinkLaunch, launch.link == link else { return }
        newChatLinkLaunch = nil
        guard outcome == .handled, let dashboardID = activeDashboardID else { return }
        let request = launch.request
        let key = composerDraftKeyOnScreen
        if let title = request.title {
            // The chat the launch opened, taken now: another that opens
            // before the rename runs keeps its own title.
            let session = chatOnScreenSessionSummary
            Task { @MainActor [weak self] in await self?.nameNewChatFromLink(title, session: session) }
        }
        guard !request.text.isEmpty else { return }
        if request.sends, NewChatLinkConfirmation.canAsk(request.text) {
            newChatLinkConfirmation = NewChatLinkConfirmation(text: request.text, dashboardID: dashboardID, key: key, title: request.title)
        } else {
            putNewChatLinkText(request.text, dashboardID: dashboardID, key: key)
        }
    }

    /// The user tapped Send: the text goes as the chat's first message.
    /// On another chat by now, or refused, it waits in its own chat's
    /// composer instead.
    func sendNewChatLinkText(_ confirmation: NewChatLinkConfirmation) {
        if newChatLinkConfirmation?.id == confirmation.id { newChatLinkConfirmation = nil }
        guard activeDashboardID == confirmation.dashboardID,
              composerDraftKeysAreSameChat(confirmation.key, composerDraftKeyOnScreen) else {
            putNewChatLinkText(confirmation.text, dashboardID: confirmation.dashboardID, key: confirmation.key)
            showNewChatLinkTextNotice(confirmation)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sent: Bool
            if let override = self.newChatLinkSendOverride {
                sent = await override(confirmation.text)
            } else {
                // A link's text is literal: "/…" never runs a command.
                sent = await self.submitComposer(text: confirmation.text, onBusy: {}, runsSlashCommands: false)
            }
            guard !sent else { return }
            self.putNewChatLinkText(confirmation.text, dashboardID: confirmation.dashboardID, key: confirmation.key)
            self.showNewChatLinkTextNotice(confirmation)
        }
    }

    /// The user tapped Edit: the text goes in the composer, ready to change.
    func editNewChatLinkText(_ confirmation: NewChatLinkConfirmation) {
        if newChatLinkConfirmation?.id == confirmation.id { newChatLinkConfirmation = nil }
        putNewChatLinkText(confirmation.text, dashboardID: confirmation.dashboardID, key: confirmation.key)
    }

    /// The user tapped Cancel: nothing is sent and the chat stays empty.
    func discardNewChatLinkText(_ confirmation: NewChatLinkConfirmation) {
        if newChatLinkConfirmation?.id == confirmation.id { newChatLinkConfirmation = nil }
    }

    /// Says where an unsent link's text went: in the chat that holds it,
    /// that it's in the composer; on another one, that it's back in the new
    /// chat's draft, as a refused message's notice does.
    private func showNewChatLinkTextNotice(_ confirmation: NewChatLinkConfirmation) {
        guard activeDashboardID == confirmation.dashboardID else { return }
        if composerDraftKeysAreSameChat(confirmation.key, composerDraftKeyOnScreen) {
            composerNotice = AppLocalization.string("Conduit couldn't send this, so it's in the composer. Send it when you're ready.", table: .chat)
        } else {
            let named = confirmation.title ?? AppLocalization.string("New chat")
            composerNotice = AppLocalization.string("Your message to “\(named)” wasn't sent. It's back in that chat's draft.", table: .chat)
        }
        composerNoticeSystemImage = "exclamationmark.circle"
    }

    private func putNewChatLinkText(_ text: String, dashboardID: UUID, key: ComposerDraftKey) {
        composerRestoreRequests.append(ComposerRestoreRequest(
            dashboardID: key.dashboard ?? dashboardID,
            key: key,
            draft: ComposerDraft(text: text, attachments: []),
            focuses: true,
            pending: nil
        ))
    }

    /// Names the chat the link opened, as its title menu's Rename does.
    private func nameNewChatFromLink(_ title: String, session: SessionSummary?) async {
        if let override = newChatLinkTitleOverride {
            await override(title)
            return
        }
        guard let session else { return }
        await renameSession(session, to: title)
    }
}
