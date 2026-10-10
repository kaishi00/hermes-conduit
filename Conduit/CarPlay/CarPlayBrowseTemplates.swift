//
//  CarPlayBrowseTemplates.swift
//  Conduit
//
//  The screens the voice screen's top-bar buttons open: the chat list
//  under Chats, and under More a grid of Voice Jobs, Shortcuts, and the
//  voice mode and agent picker. Nothing goes deeper than the third level,
//  the voice screen included, which is CarPlay's limit for voice apps.
//  Rows carry titles, status and an icon only, never a reply: answers are
//  always spoken.
//
//  The row models are pure so what each screen lists is testable without
//  a car; the factory turns them into CarPlay templates.
//

import CarPlay
import UIKit

// MARK: - Row models

struct CarPlayChatRow: Equatable {
    let sessionID: String
    let storedSessionID: String?
    let title: String
    let detail: String
    /// The row's icon: what kind of chat it is.
    var symbol: String = CarPlayBrowse.chatSymbol

    /// Whether this row is the chat `id` names, by either of its ids.
    func matches(_ id: String?) -> Bool {
        guard let id else { return false }
        return id == sessionID || id == storedSessionID
    }

    var thread: VoiceThreadTarget {
        VoiceThreadTarget(runtimeSessionID: sessionID, storedSessionID: storedSessionID, title: title)
    }
}

struct CarPlayJobRow: Equatable {
    let id: UUID
    let title: String
    let status: String
    var symbol: String = "hourglass"
    /// A settled job can be heard again; a running one has nothing to say yet.
    let canReplay: Bool
}

struct CarPlayOptionRow: Equatable {
    let title: String
    let isSelected: Bool
}

struct CarPlayModeRow: Equatable {
    let mode: CarPlayVoiceMode
    let title: String
    let isSelected: Bool
    var symbol: String { mode.symbol }
}

/// The chats the car's chat list offers: pinned ones first, then recent.
struct CarPlayChatList: Equatable {
    var pinned: [CarPlayChatRow]
    var recent: [CarPlayChatRow]
}

enum CarPlayBrowse {
    /// Chats in the list; with the New voice chat row the list holds twelve,
    /// what CarPlay shows of a list while driving.
    static let maximumChats = 11

    /// Pinned chats first, then the most recent others, together at most
    /// `maximumChats`. Pinned chats are newest first too.
    static func chatList(
        from sessions: [SessionSummary],
        isPinned: (SessionSummary) -> Bool
    ) -> CarPlayChatList {
        let pinnedSessions = sessions.filter(isPinned)
        let pinned = recentChats(from: pinnedSessions).map { row in
            var pinnedRow = row
            pinnedRow.symbol = pinSymbol
            return pinnedRow
        }
        let others = sessions.filter { !isPinned($0) }
        let recent = Array(recentChats(from: others).prefix(maximumChats - pinned.count))
        return CarPlayChatList(pinned: pinned, recent: recent)
    }

    /// The most recent unarchived chats, newest first. Rows without an
    /// activity time keep their listed order after the dated ones.
    static func recentChats(from sessions: [SessionSummary]) -> [CarPlayChatRow] {
        sessions.enumerated()
            .filter { !$0.element.isArchived }
            .sorted { lhs, rhs in
                switch (lhs.element.lastActivityAt, rhs.element.lastActivityAt) {
                case let (left?, right?) where left != right: return left > right
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.offset < rhs.offset
                }
            }
            .prefix(maximumChats)
            .map { _, session in
                let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return CarPlayChatRow(
                    sessionID: session.id,
                    storedSessionID: session.storedSessionId,
                    title: title.isEmpty ? AppLocalization.string("New Chat") : title,
                    detail: session.updatedLabel,
                    symbol: chatSymbol(for: session.source)
                )
            }
    }

    static let chatSymbol = "bubble.left.fill"
    static let pinSymbol = "pin.fill"

    /// Saved calls and voice jobs look like what they are; every other
    /// chat is a speech bubble.
    static func chatSymbol(for source: SessionSource) -> String {
        switch source {
        case .voice: return "waveform"
        case .voiceJob: return "checklist"
        case .cron: return "clock.fill"
        case .chat, .discord, .telegram, .api, .webhook, .other: return chatSymbol
        }
    }

    /// Background Voice Jobs, newest first.
    static func jobRows(from jobs: [VoiceBackgroundJob]) -> [CarPlayJobRow] {
        jobs.filter { !$0.isThreadTurn }
            .sorted { $0.startedAt > $1.startedAt }
            .map { job in
                CarPlayJobRow(
                    id: job.id,
                    title: job.title,
                    status: statusText(job.status),
                    symbol: statusSymbol(job.status),
                    canReplay: !job.status.isActive
                )
            }
    }

    static func statusText(_ status: VoiceBackgroundJob.Status) -> String {
        switch status {
        case .starting, .running: return AppLocalization.string("Running")
        case .needsInput: return AppLocalization.string("Waiting for you")
        case .finished: return AppLocalization.string("Done")
        case .failed: return AppLocalization.string("Failed")
        case .cancelled: return AppLocalization.string("Cancelled")
        }
    }

    static func statusSymbol(_ status: VoiceBackgroundJob.Status) -> String {
        switch status {
        case .starting, .running: return "hourglass"
        case .needsInput: return "questionmark.bubble.fill"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    static func modeRows(current: CarPlayVoiceMode) -> [CarPlayModeRow] {
        CarPlayVoiceMode.all.map { CarPlayModeRow(mode: $0, title: $0.title, isSelected: $0 == current) }
    }

    /// Agents (Hermes profiles) to switch between; empty when there is only
    /// one, so the picker shows no choice that does nothing.
    static func agentRows(profiles: [String], active: String, displayName: (String) -> String) -> [CarPlayOptionRow] {
        guard profiles.count > 1 else { return [] }
        return profiles.map { CarPlayOptionRow(title: displayName($0), isSelected: $0 == active) }
    }

    /// Grid icons, given out in order so shortcuts are told apart at a glance.
    static let shortcutSymbols = [
        "sparkles", "sun.max.fill", "calendar", "envelope.fill",
        "checklist", "newspaper.fill", "house.fill", "bolt.fill",
    ]

    static func shortcutSymbol(at index: Int) -> String {
        shortcutSymbols[index % shortcutSymbols.count]
    }
}

extension CarPlayVoiceMode {
    static let all: [CarPlayVoiceMode] = [.classic, .geminiLive, .gptLive, .grokLive]

    var symbol: String {
        switch self {
        case .classic: return "mic.fill"
        case .geminiLive: return "sparkles"
        case .gptLive: return "waveform"
        case .grokLive: return "bolt.fill"
        }
    }

    var title: String {
        switch self {
        case .classic: return AppLocalization.string("Classic voice")
        case .geminiLive: return AppLocalization.string("Gemini Live")
        case .gptLive: return AppLocalization.string("GPT-Live")
        case .grokLive: return AppLocalization.string("Grok Live")
        }
    }
}

// MARK: - Templates

/// What the browse screens' rows do when tapped. MainActor-facing; the
/// coordinator bridges them into AppState.
@MainActor
struct CarPlayBrowseHandlers {
    var openChat: (CarPlayChatRow) -> Void = { _ in }
    var newVoiceChat: () -> Void = {}
    var replayJob: (UUID) -> Void = { _ in }
    var runShortcut: (CarPlayShortcut) -> Void = { _ in }
    var selectMode: (CarPlayVoiceMode) -> Void = { _ in }
    var selectAgent: (Int) -> Void = { _ in }
    var showJobs: () -> Void = {}
    var showShortcuts: () -> Void = {}
    var showVoiceOptions: () -> Void = {}
}

/// The voice screen's top-bar buttons.
enum CarPlayBarButtonKind: Equatable {
    case chats
    case more

    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right.fill"
        case .more: return "ellipsis.circle"
        }
    }
}

@MainActor
enum CarPlayBrowseTemplateFactory {
    static func barButton(_ kind: CarPlayBarButtonKind, action: @escaping () -> Void) -> CPBarButton {
        CPBarButton(image: symbolImage(kind.symbol)) { _ in action() }
    }

    static func symbolImage(_ name: String) -> UIImage {
        UIImage(systemName: name) ?? UIImage(systemName: "circle.fill") ?? UIImage()
    }

    static func chatsTemplate(
        chats: CarPlayChatList,
        placeholder: String? = nil,
        attachedChatID: String? = nil,
        handlers: CarPlayBrowseHandlers
    ) -> CPListTemplate {
        CPListTemplate(
            title: AppLocalization.string("Chats"),
            sections: chatSections(chats: chats, placeholder: placeholder, attachedChatID: attachedChatID, handlers: handlers)
        )
    }

    /// Jobs, Shortcuts and Voice, the screens the top bar's More opens.
    static func moreTemplate(handlers: CarPlayBrowseHandlers) -> CPGridTemplate {
        let buttons = [
            (AppLocalization.string("Jobs"), "checklist", handlers.showJobs),
            (AppLocalization.string("Shortcuts"), "bolt.fill", handlers.showShortcuts),
            (AppLocalization.string("Voice"), "waveform.circle.fill", handlers.showVoiceOptions),
        ].map { title, symbol, action in
            CPGridButton(titleVariants: [title], image: symbolImage(symbol)) { _ in action() }
        }
        return CPGridTemplate(title: AppLocalization.string("More"), gridButtons: buttons)
    }

    /// New voice chat, then the pinned and recent chats. `placeholder`
    /// stands in for the chats while there are none yet because the list
    /// is still on its way (#514).
    /// `attachedChatID` is the chat Listen talks in, which the list marks
    /// the way music apps mark what is playing.
    static func chatSections(
        chats: CarPlayChatList,
        placeholder: String? = nil,
        attachedChatID: String? = nil,
        handlers: CarPlayBrowseHandlers
    ) -> [CPListSection] {
        let newChat = CPListItem(
            text: AppLocalization.string("New voice chat"),
            detailText: nil,
            image: symbolImage("plus.bubble.fill")
        )
        newChat.handler = { _, completion in
            handlers.newVoiceChat()
            completion()
        }
        var sections = [CPListSection(items: [newChat])]
        if !chats.pinned.isEmpty {
            sections.append(CPListSection(
                items: chatItems(chats.pinned, attachedChatID: attachedChatID, handlers: handlers),
                header: AppLocalization.string("Pinned"),
                sectionIndexTitle: nil
            ))
        }
        if !chats.recent.isEmpty {
            sections.append(CPListSection(
                items: chatItems(chats.recent, attachedChatID: attachedChatID, handlers: handlers),
                header: AppLocalization.string("Recent"),
                sectionIndexTitle: nil
            ))
        }
        if let placeholder, chats.pinned.isEmpty, chats.recent.isEmpty {
            let waiting = CPListItem(text: placeholder, detailText: nil)
            waiting.isEnabled = false
            sections.append(CPListSection(items: [waiting]))
        }
        return sections
    }

    private static func chatItems(
        _ rows: [CarPlayChatRow],
        attachedChatID: String?,
        handlers: CarPlayBrowseHandlers
    ) -> [CPListItem] {
        rows.map { row in
            let item = CPListItem(
                text: row.title,
                detailText: row.detail.isEmpty ? nil : row.detail,
                image: symbolImage(row.symbol)
            )
            if row.matches(attachedChatID) {
                item.isPlaying = true
                item.playingIndicatorLocation = .trailing
            }
            item.handler = { _, completion in
                handlers.openChat(row)
                completion()
            }
            return item
        }
    }

    static func jobsTemplate(rows: [CarPlayJobRow], handlers: CarPlayBrowseHandlers) -> CPListTemplate {
        let template = CPListTemplate(title: AppLocalization.string("Voice Jobs"), sections: jobSections(rows: rows, handlers: handlers))
        template.emptyViewTitleVariants = [AppLocalization.string("No Voice Jobs")]
        template.emptyViewSubtitleVariants = [AppLocalization.string("Start one from a shortcut or by asking during a call.")]
        return template
    }

    static func jobSections(rows: [CarPlayJobRow], handlers: CarPlayBrowseHandlers) -> [CPListSection] {
        let items = rows.map { row in
            let item = CPListItem(text: row.title, detailText: row.status, image: symbolImage(row.symbol))
            item.handler = { _, completion in
                if row.canReplay { handlers.replayJob(row.id) }
                completion()
            }
            return item
        }
        return [CPListSection(items: items)]
    }

    /// A grid of shortcuts, or an empty list saying where to add them.
    static func shortcutsTemplate(shortcuts: [CarPlayShortcut], handlers: CarPlayBrowseHandlers) -> CPTemplate {
        let title = AppLocalization.string("Shortcuts")
        guard !shortcuts.isEmpty else {
            let empty = CPListTemplate(title: title, sections: [])
            empty.emptyViewTitleVariants = [AppLocalization.string("No shortcuts yet")]
            empty.emptyViewSubtitleVariants = [AppLocalization.string("Add them on your iPhone in Settings, Voice.")]
            return empty
        }
        let buttons = shortcuts.prefix(CarPlayPreferences.maximumShortcuts).enumerated().map { index, shortcut in
            CPGridButton(
                titleVariants: [shortcut.title],
                image: symbolImage(CarPlayBrowse.shortcutSymbol(at: index))
            ) { _ in
                handlers.runShortcut(shortcut)
            }
        }
        return CPGridTemplate(title: title, gridButtons: Array(buttons))
    }

    static func voiceTemplate(
        modes: [CarPlayModeRow],
        agents: [CarPlayOptionRow],
        handlers: CarPlayBrowseHandlers
    ) -> CPListTemplate {
        var sections = [CPListSection(
            items: modes.map { row in
                optionItem(title: row.title, symbol: row.symbol, isSelected: row.isSelected) { handlers.selectMode(row.mode) }
            },
            header: AppLocalization.string("Voice mode"),
            sectionIndexTitle: nil
        )]
        if !agents.isEmpty {
            sections.append(CPListSection(
                items: agents.enumerated().map { index, row in
                    optionItem(title: row.title, symbol: "person.crop.circle.fill", isSelected: row.isSelected) { handlers.selectAgent(index) }
                },
                header: AppLocalization.string("Agent"),
                sectionIndexTitle: nil
            ))
        }
        return CPListTemplate(title: AppLocalization.string("Voice"), sections: sections)
    }

    private static func optionItem(title: String, symbol: String, isSelected: Bool, select: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(
            text: title,
            detailText: nil,
            image: symbolImage(symbol),
            accessoryImage: isSelected ? UIImage(systemName: "checkmark") : nil,
            accessoryType: .none
        )
        item.handler = { _, completion in
            select()
            completion()
        }
        return item
    }
}
