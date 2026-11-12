//
//  KeyboardShortcuts.swift
//  Conduit
//
//  Hardware-keyboard shortcuts on an iPad and a Mac (issue 2219). One
//  catalog says which key does what: the menu bar's commands, the shortcuts
//  a screen keeps for itself (⌘F on the chat list, ⌘. in a chat), the
//  composer's ⌘Return and the Keyboard Shortcuts sheet all read it, so the
//  list a person sees can't drift from the keys that work.
//

import Combine
import SwiftUI
import UIKit

/// Every shortcut Conduit answers, and the key it answers to.
enum ConduitKeyboardShortcut: String, CaseIterable, Identifiable {
    case newChat
    case search
    case send
    case stop
    case chatList
    case artifacts
    case settings
    case biggerText
    case smallerText
    case normalText
    case shortcutList

    var id: String { rawValue }

    var key: KeyEquivalent {
        switch self {
        case .newChat: return "n"
        case .search: return "f"
        case .send: return .return
        case .stop: return "."
        case .chatList: return "s"
        case .artifacts: return "a"
        case .settings: return ","
        case .biggerText: return "+"
        case .smallerText: return "-"
        case .normalText: return "0"
        case .shortcutList: return "/"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .chatList: return [.command, .control]
        case .artifacts: return [.command, .option]
        default: return .command
        }
    }

    var shortcut: KeyboardShortcut { KeyboardShortcut(key, modifiers: modifiers) }

    /// What the Keyboard Shortcuts sheet calls it.
    var title: String {
        switch self {
        case .newChat: return AppLocalization.string("New Chat")
        case .search: return AppLocalization.string("Search")
        case .send: return AppLocalization.string("Send")
        case .stop: return AppLocalization.string("Stop")
        case .chatList: return AppLocalization.string("Show chat list")
        case .artifacts: return AppLocalization.string("Show artifacts")
        case .settings: return AppLocalization.string("Settings")
        case .biggerText: return AppLocalization.string("Make Text Bigger", table: .settings)
        case .smallerText: return AppLocalization.string("Make Text Smaller", table: .settings)
        case .normalText: return AppLocalization.string("Make Text Normal Size", table: .settings)
        case .shortcutList: return AppLocalization.string("Keyboard Shortcuts", table: .settings)
        }
    }

    /// The keys as the menu bar writes them: ⌃⌥⇧⌘ in Apple's order, then
    /// the key.
    var glyphs: String { Self.glyphs(key: key, modifiers: modifiers) }

    static func glyphs(key: KeyEquivalent, modifiers: EventModifiers) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .return: text += "↩"
        case "-": text += "−"
        default: text += String(key.character).uppercased()
        }
        return text
    }

    /// ⌘1 to ⌘4: the tabs in the bar's order.
    static func tabShortcut(_ tab: V2Tab) -> KeyboardShortcut? {
        guard let index = V2Tab.destinations.firstIndex(of: tab) else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
    }

    static func tabGlyphs(_ tab: V2Tab) -> String? {
        tabShortcut(tab).map { glyphs(key: $0.key, modifiers: $0.modifiers) }
    }
}

/// What the menu bar's commands do, and what they hand the screens that
/// own the state (the shell's tabs, the shortcut list's sheet).
@MainActor
enum KeyboardCommands {
    /// A tab asked for from the keyboard. V2Shell selects it; the drawer
    /// shell, which has no tabs, opens Settings for `.settings`.
    static let tabRequests = PassthroughSubject<V2Tab, Never>()
    /// ⌘/: MainView opens the Keyboard Shortcuts sheet, or closes it.
    static let shortcutListRequests = PassthroughSubject<Void, Never>()

    /// A menu shortcut works whatever is on screen, and so does a key a
    /// screen behind a sheet keeps: nothing should change behind a sheet,
    /// an alert or the call screen. Every presentation is a presented view
    /// controller on the key window's root.
    static var nothingInFront: Bool {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              let root = window.rootViewController else { return true }
        guard let presented = root.presentedViewController else { return true }
        return presented.isBeingDismissed
    }

    static func newChat() {
        guard nothingInFront else { return }
        let appState = AppStateRuntimeRegistry.shared.appState
        guard appState.canTapNewChat, !appState.showLogin else { return }
        Haptics.medium()
        appState.startNewChat()
    }

    static func show(_ tab: V2Tab) {
        guard nothingInFront else { return }
        tabRequests.send(tab)
    }

    static func toggleShortcutList() {
        shortcutListRequests.send(())
    }

    /// ⌘+, ⌘− and ⌘0, with nothing in front.
    static func changeChatTextSize(by step: Int) {
        guard nothingInFront else { return }
        stepChatTextSize(by: step)
    }

    /// The chat text size Settings > Chat sets, a step at a time. Written where Settings writes it, so Sync across devices
    /// shares it as it shares the slider's.
    static func stepChatTextSize(by step: Int, defaults: UserDefaults = .standard) {
        let next = chatTextSize(after: ChatTypography.stored(in: defaults), step: step)
        defaults.set(next.rawValue, forKey: ChatTypography.preferenceKey)
    }

    /// One step bigger or smaller, held at the ends; a step of 0 is the
    /// default size.
    nonisolated static func chatTextSize(after size: ChatTextSize, step: Int) -> ChatTextSize {
        guard step != 0 else { return ChatTypography.defaultSize }
        let all = ChatTextSize.allCases
        let index = all.firstIndex(of: size) ?? all.firstIndex(of: ChatTypography.defaultSize) ?? 0
        return all[max(0, min(all.count - 1, index + step))]
    }
}

/// The menu bar on a Mac and an iPad (and ⌘ held on an iPad). Reads no
/// observed state, so AppState's publishes never rebuild the menus; each
/// command checks what it needs when it's pressed.
struct ConduitKeyboardCommands: Commands {
    var body: some Commands {
        // ⌘N was the system's New Window, which Conduit's one-window guard
        // closed at once (issue 2219).
        CommandGroup(replacing: .newItem) {
            Button(ConduitKeyboardShortcut.newChat.title) { KeyboardCommands.newChat() }
                .keyboardShortcut(ConduitKeyboardShortcut.newChat.shortcut)
        }
        CommandGroup(replacing: .appSettings) {
            Button(AppLocalization.string("Settings…", table: .settings)) { KeyboardCommands.show(.settings) }
                .keyboardShortcut(ConduitKeyboardShortcut.settings.shortcut)
        }
        CommandGroup(before: .sidebar) {
            ForEach(V2Tab.destinations) { tab in
                if let shortcut = ConduitKeyboardShortcut.tabShortcut(tab) {
                    Button(tab.title) { KeyboardCommands.show(tab) }
                        .keyboardShortcut(shortcut)
                }
            }
            Divider()
            Button(ConduitKeyboardShortcut.biggerText.title) { KeyboardCommands.changeChatTextSize(by: 1) }
                .keyboardShortcut(ConduitKeyboardShortcut.biggerText.shortcut)
            Button(ConduitKeyboardShortcut.smallerText.title) { KeyboardCommands.changeChatTextSize(by: -1) }
                .keyboardShortcut(ConduitKeyboardShortcut.smallerText.shortcut)
            Button(ConduitKeyboardShortcut.normalText.title) { KeyboardCommands.changeChatTextSize(by: 0) }
                .keyboardShortcut(ConduitKeyboardShortcut.normalText.shortcut)
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button(ConduitKeyboardShortcut.shortcutList.title) { KeyboardCommands.toggleShortcutList() }
                .keyboardShortcut(ConduitKeyboardShortcut.shortcutList.shortcut)
        }
    }
}

/// ⌘/, and Settings > Keyboard: every shortcut, grouped as the menus are.
struct KeyboardShortcutsSheet: View {
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @Environment(\.dismiss) private var dismiss
    /// The drawer shell has no tabs and no chat list or Artifacts toggles:
    /// the sheet leaves out the keys it doesn't answer.
    @AppStorage(V2ShellPreference.key) private var usesTabs = V2ShellPreference.defaultValue

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(.newChat)
                    row(.search)
                    row(.send)
                    row(.stop)
                    if usesTabs {
                        row(.chatList)
                        row(.artifacts)
                    }
                } header: {
                    Text(AppLocalization.string("Chats"))
                } footer: {
                    // The chat list and Artifacts toggles exist only in a
                    // window with room for a column beside the chat.
                    if usesTabs {
                        Text(AppLocalization.string("Show chat list and Show artifacts work in a window wide enough to put that column beside the chat.", table: .settings))
                    }
                }
                Section(AppLocalization.string("Go to", table: .settings)) {
                    if usesTabs {
                        ForEach(V2Tab.destinations) { tab in
                            if let glyphs = ConduitKeyboardShortcut.tabGlyphs(tab) {
                                row(title: tab.title, glyphs: tab == .settings
                                    ? [glyphs, ConduitKeyboardShortcut.settings.glyphs]
                                    : [glyphs])
                            }
                        }
                    } else {
                        row(.settings)
                    }
                }
                Section(AppLocalization.string("Chat text size")) {
                    row(.biggerText)
                    row(.smallerText)
                    row(.normalText)
                }
                Section {
                    row(.shortcutList)
                } footer: {
                    if !ProcessInfo.processInfo.isiOSAppOnMac {
                        Text(AppLocalization.string("On an iPad, hold ⌘ to see the shortcuts for the screen you're on.", table: .settings))
                    }
                }
            }
            .navigationTitle(AppLocalization.string("Keyboard Shortcuts", table: .settings))
            .navigationBarTitleDisplayMode(.inline)
            // ⌘/ closes it, from ⌘/ or from Settings > Keyboard alike.
            .onReceive(KeyboardCommands.shortcutListRequests) { _ in dismiss() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    private func row(_ shortcut: ConduitKeyboardShortcut) -> some View {
        row(title: shortcut.title, glyphs: [shortcut.glyphs])
    }

    private func row(title: String, glyphs: [String]) -> some View {
        HStack {
            Text(title)
                .scaledFont(.body)
            Spacer(minLength: 12)
            ForEach(glyphs, id: \.self) { glyph in
                Text(verbatim: glyph)
                    .scaledFont(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
