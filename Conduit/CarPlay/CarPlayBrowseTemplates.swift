//
//  CarPlayBrowseTemplates.swift
//  Conduit
//
//  The screens the voice screen's top-bar buttons open: recent chats,
//  Voice Jobs, Shortcuts, and the voice mode and agent picker. Each is one
//  level below the voice screen (CarPlay allows three). Rows carry titles
//  and status only, never a reply: answers are always spoken.
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

    var thread: VoiceThreadTarget {
        VoiceThreadTarget(runtimeSessionID: sessionID, storedSessionID: storedSessionID, title: title)
    }
}

struct CarPlayJobRow: Equatable {
    let id: UUID
    let title: String
    let status: String
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
}

enum CarPlayBrowse {
    static let maximumChats = 12

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
                    detail: session.updatedLabel
                )
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
    var replayJob: (UUID) -> Void = { _ in }
    var runShortcut: (CarPlayShortcut) -> Void = { _ in }
    var selectMode: (CarPlayVoiceMode) -> Void = { _ in }
    var selectAgent: (Int) -> Void = { _ in }
}

@MainActor
enum CarPlayBrowseTemplateFactory {
    static func chatsTemplate(rows: [CarPlayChatRow], handlers: CarPlayBrowseHandlers) -> CPListTemplate {
        let items = rows.map { row in
            let item = CPListItem(text: row.title, detailText: row.detail.isEmpty ? nil : row.detail)
            item.handler = { _, completion in
                handlers.openChat(row)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: AppLocalization.string("Chats"), sections: [CPListSection(items: items)])
        template.emptyViewTitleVariants = [AppLocalization.string("No chats yet")]
        return template
    }

    static func jobsTemplate(rows: [CarPlayJobRow], handlers: CarPlayBrowseHandlers) -> CPListTemplate {
        let template = CPListTemplate(title: AppLocalization.string("Voice Jobs"), sections: jobSections(rows: rows, handlers: handlers))
        template.emptyViewTitleVariants = [AppLocalization.string("No Voice Jobs")]
        template.emptyViewSubtitleVariants = [AppLocalization.string("Start one from a shortcut or by asking during a call.")]
        return template
    }

    static func jobSections(rows: [CarPlayJobRow], handlers: CarPlayBrowseHandlers) -> [CPListSection] {
        let items = rows.map { row in
            let item = CPListItem(text: row.title, detailText: row.status)
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
                image: UIImage(systemName: CarPlayBrowse.shortcutSymbol(at: index)) ?? UIImage()
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
                optionItem(title: row.title, isSelected: row.isSelected) { handlers.selectMode(row.mode) }
            },
            header: AppLocalization.string("Voice mode"),
            sectionIndexTitle: nil
        )]
        if !agents.isEmpty {
            sections.append(CPListSection(
                items: agents.enumerated().map { index, row in
                    optionItem(title: row.title, isSelected: row.isSelected) { handlers.selectAgent(index) }
                },
                header: AppLocalization.string("Agent"),
                sectionIndexTitle: nil
            ))
        }
        return CPListTemplate(title: AppLocalization.string("Voice"), sections: sections)
    }

    private static func optionItem(title: String, isSelected: Bool, select: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(
            text: title,
            detailText: nil,
            image: nil,
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
