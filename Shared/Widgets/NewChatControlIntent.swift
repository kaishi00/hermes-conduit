//
//  NewChatControlIntent.swift
//  Conduit and its widgets
//
//  The New Chat control's action (issue 2860): Control Center, the Lock
//  Screen and the Action Button open Conduit on a new chat with the
//  keyboard up, as the New Chat shortcut does. Built into the app and the
//  widget extension, as a control that opens its app needs: an
//  `OpenIntent`, so `perform()` runs in the app, which sets the handler at
//  launch; the extension has none and only opens the app.
//
//  The control binds to this type's name: never rename it.
//

import AppIntents
import Foundation

struct OpenNewChatIntent: OpenIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description = IntentDescription("Open Conduit on a new chat, ready to type.")
    /// The New Chat shortcut is the one Shortcuts and Siri list.
    static let isDiscoverable: Bool = false

    @Parameter(title: "New Chat")
    var target: NewChatControlTarget

    init() { target = .newChat }

    @MainActor
    func perform() async throws -> some IntentResult {
        NewChatControlRequests.handler?()
        return .result()
    }
}

/// What the control opens: only a new chat.
enum NewChatControlTarget: String, AppEnum {
    case newChat

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "New Chat"
    static let caseDisplayRepresentations: [NewChatControlTarget: DisplayRepresentation] = [
        .newChat: "New Chat",
    ]
}

/// Where the control's new chat goes: the app sets it at launch.
enum NewChatControlRequests {
    @MainActor static var handler: (@MainActor () -> Void)?
}
