//
//  ReplySpeedReader.swift
//  Conduit
//
//  Reads the open chat's reply speeds (ReplySpeeds) while Settings > Chat >
//  Show reply speed is on: as the chat opens and as each turn ends. Draws
//  nothing; the reply rows show what it read.
//

import SwiftUI

struct ReplySpeedReader: View {
    let appState: AppState
    /// The open chat: another starts with none.
    let openChatID: String?
    /// A reply runs: its speed is read once its turn ends.
    let isBusy: Bool
    /// The chat shows (the app is active, the tab and the chat on screen).
    let isShowing: Bool

    @AppStorage(ReplySpeeds.preferenceKey) private var enabled = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: "\(openChatID ?? "")|\(isBusy)|\(isShowing)|\(enabled)") {
                guard enabled else {
                    if appState.openChatReplySpeeds != nil { appState.openChatReplySpeeds = nil }
                    return
                }
                // A new turn's reply isn't the one the last read's newest turn wrote.
                if isBusy { dropUnsaved() }
                guard let asked = openChatID, isShowing, !isBusy else { return }
                let read = await appState.loadOpenChatReplySpeeds()
                guard !Task.isCancelled, openChatID == asked, enabled else { return }
                // A failed read keeps the saved rows' speeds, never an earlier turn's on the newest reply.
                guard var answer = read else { dropUnsaved(); return }
                answer.chatID = asked
                if appState.openChatReplySpeeds != answer { appState.openChatReplySpeeds = answer }
            }
    }

    private func dropUnsaved() {
        if appState.openChatReplySpeeds?.unsaved != nil { appState.openChatReplySpeeds?.unsaved = nil }
    }
}
