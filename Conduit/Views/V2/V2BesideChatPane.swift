//
//  V2BesideChatPane.swift
//  Conduit
//
//  The chat kept beside the one on screen in a wide window (all-live stage
//  2, AppState+BesideChat.swift): its newest rows, and its reply as it
//  streams. The pane only shows. Swap opens its chat in the chat's own
//  column, where it can be written to, and keeps the other here.
//
//  On an iPad and a Mac the pane's chat can move to a window of its own
//  (V2ChatWindow, AppState+ChatWindows.swift), drawn by this same view.
//  Both take a plain message under the rows (AppState+KeptChatSend.swift).
//

import SwiftUI

struct V2BesideChatPane: View {
    @EnvironmentObject private var appState: AppState
    let chat: BackgroundChat
    /// What its window opened as, where this draws a chat window and not
    /// the pane.
    var windowKey: String?
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            V2Backdrop(drifts: false, glowProfile: chat.profile)
            VStack(spacing: 0) {
                header
                V2BesideChatRows(
                    live: appState.besideChatLive.notice(for: chat),
                    chat: chat,
                    gatewayResolver: appState.gatewayMediaResolver(for: chat.profile)
                )
                // Its draft is this chat's: Swap empties the box.
                V2KeptChatComposer(live: appState.besideChatLive.notice(for: chat), chat: chat)
                    .id(chat.sessionIDs)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(verbatim: chat.title)
                .scaledFont(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let windowKey {
                Button {
                    Haptics.selection()
                    if appState.openWindowChatInMainWindow(windowKey) {
                        // The main window was closed: open it to show the chat.
                        openWindow(id: "conduit-primary")
                    }
                } label: {
                    Image(systemName: "arrow.down.left.square")
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(AppLocalization.string("Open in Main Window", table: .chat))
                .accessibilityHint(AppLocalization.string("Opens this chat to write in, and closes this window.", table: .chat))
            } else {
                paneButtons
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.conduitAccent)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 52)
    }

    @ViewBuilder
    private var paneButtons: some View {
        if supportsMultipleWindows, appState.canMoveBesideChatToWindow {
            Button {
                Haptics.selection()
                if let key = appState.moveBesideChatToWindow() {
                    openWindow(id: V2ChatWindow.sceneID, value: key)
                }
            } label: {
                Image(systemName: "macwindow.badge.plus")
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(AppLocalization.string("Open in New Window", table: .chat))
            .accessibilityHint(AppLocalization.string("Moves this chat to a window of its own, and closes the pane.", table: .chat))
        }
        Button {
            Haptics.selection()
            appState.swapBesideChat()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(AppLocalization.string("Swap Chats", table: .chat))
        .accessibilityHint(AppLocalization.string("Opens this chat to write in, and keeps the other one here.", table: .chat))
        Button {
            Haptics.selection()
            appState.closeBesideChat()
        } label: {
            Image(systemName: "xmark")
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(AppLocalization.string("Close Chat Beside", table: .chat))
    }
}

/// A plain message box under a kept chat's rows: words only, sent to the
/// chat's own session while it's between turns. Attachments, commands and
/// answers to cards stay with the chat's own column (Swap).
private struct V2KeptChatComposer: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var live: BesideChatLive.Chat
    let chat: BackgroundChat
    @State private var draft = ""
    @State private var sending = false
    @State private var failed = false

    private var canSend: Bool {
        !sending && appState.canSendInKeptChat(chat)
            && draft.contains(where: { !$0.isWhitespace })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if failed {
                Text(AppLocalization.string("Couldn't send here. Try again, or open the chat to send from there.", table: .chat))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(AppLocalization.string("Message"), text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .scaledFont(.body)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    // Kept as typed until the send settles, so a failed
                    // message comes back whole.
                    .disabled(sending)
                Button(action: send) {
                    Group {
                        if sending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .scaledFont(.system(.body, weight: .semibold))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.conduitAccent : Color.secondary)
                .disabled(!canSend)
                .accessibilityLabel(sending ? AppLocalization.string("Sending…") : AppLocalization.string("Send"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func send() {
        guard canSend else { return }
        let words = draft
        draft = ""
        failed = false
        sending = true
        Task { @MainActor in
            let sent = await appState.sendInKeptChat(chat, text: words)
            sending = false
            if !sent {
                failed = true
                draft = words
            }
        }
    }
}

/// A chat in a window of its own (AppState+ChatWindows.swift). The window
/// closes once its chat is followed no longer: opened in the main window,
/// deleted, a dashboard left, or any change of profile (a switch, one
/// Hermes no longer has, one a sign-in brings). One the system brings back
/// at a relaunch has no chat to show, and closes too.
struct V2ChatWindow: View {
    static let sceneID = "conduit-chat"

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    let key: String?

    private var chat: BackgroundChat? { key.flatMap { appState.windowChat($0) } }

    var body: some View {
        Group {
            if let chat, let key {
                V2BesideChatPane(chat: chat, windowKey: key)
            } else {
                V2Backdrop(drifts: false)
            }
        }
        .onAppear { closeWithoutAChat() }
        .onChange(of: appState.windowChatIDs) { _, _ in closeWithoutAChat() }
        // On screen, it keeps the app's connection live while the main
        // window is behind it.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if let key, chat != nil { appState.noteScenePhase(phase, scene: "chat-window:\(key)") }
        }
        .onDisappear {
            if let key {
                // Gone to the background first, as the main window does, so
                // the last window closing still runs the background steps.
                // Only a window that counted: one restored at a relaunch with
                // no chat never did, and mustn't send the launch to the
                // background before the main window's first phase.
                if appState.windowScenePhases["chat-window:\(key)"] != nil {
                    appState.noteScenePhase(.background, scene: "chat-window:\(key)")
                }
                appState.noteScenePhase(nil, scene: "chat-window:\(key)")
                appState.closeChatWindow(key)
            }
        }
    }

    private func closeWithoutAChat() {
        if chat == nil { dismissWindow() }
    }
}

/// The pane's rows. They follow their own chat's notice (`BesideChatLive`),
/// so a reply streaming here redraws these and nothing else, not another
/// window's rows (issue 2625).
private struct V2BesideChatRows: View {
    @ObservedObject var live: BesideChatLive.Chat
    let chat: BackgroundChat
    let gatewayResolver: GatewayMediaDataURLResolver
    @Environment(\.v2Shell) private var shell

    /// The newest rows it draws: Swap shows the whole chat.
    private static let rowLimit = 60

    var body: some View {
        // Behind another tab the pane stays mounted: it draws no rows
        // there, so a reply streaming into it costs nothing until the tab
        // shows again, with the rows as they then stand.
        if shell.isTabActive {
            rows
        } else {
            Color.clear
        }
    }

    private var rows: some View {
        let state = chat.state
        let isRunning = chat.isRunning
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(chat.newestSettledRows(Self.rowLimit)) { row in
                    MessageBubble(message: row, gatewayResolver: gatewayResolver)
                        .equatable()
                }
                if let thinking = chat.liveThinkingRow {
                    ThinkingCard(message: thinking)
                }
                if !state.streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    StreamingBubble(text: state.streamingBuffer, active: isRunning)
                } else if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.conduitAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(AppLocalization.string("Working"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // Nothing here acts on its chat: Swap opens it to act on.
            .allowsHitTesting(false)
        }
        .defaultScrollAnchor(.bottom)
        .chatRowsBeside(profile: chat.profile, isBusy: isRunning)
    }
}
