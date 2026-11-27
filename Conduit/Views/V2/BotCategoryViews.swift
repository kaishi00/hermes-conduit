//
//  BotCategoryViews.swift
//  Conduit
//
//  Bots Home's category headings (BotCategories; Eric, 2026-11-27, option
//  A): each category a heading over its own bots, Other last. A tap folds
//  it, and a folded one shows its faces small and the count of what its
//  bots wait on you for, so no question hides behind a fold. Its long press
//  renames, moves or deletes it; a bot dropped on it files there. A bot's
//  menu files it from its Category submenu, and so does a group chat's,
//  which then shows under the heading after its bots.
//

import SwiftUI
import UniformTypeIdentifiers

/// One category's heading on Bots Home.
struct BotCategoryHeading: View {
    let section: BotCategorySection<CombinedBotsHomeItem>
    let folded: Bool
    /// Its group chats, counted with its bots.
    var roomCount = 0
    let onToggle: () -> Void
    /// Nil for Other, which has no menu.
    var onRename: (() -> Void)?
    var onMoveEarlier: (() -> Void)?
    var onMoveLater: (() -> Void)?
    var onDelete: (() -> Void)?
    /// A bot dropped on the heading (its drag's name or key).
    let onDropBot: (String) -> Bool
    /// A group chat's tile dropped on the heading (its room id).
    var onDropRoom: ((String) -> Bool)?
    /// Re-drawn as the bots' waits change.
    @ObservedObject var work: BotWorkStore
    @ObservedObject var needsYou: NeedsYouStore

    @EnvironmentObject private var updates: V2ShownUpdates
    private var appState: AppState { updates.appState }
    @State private var isTargeted = false

    private var title: String { section.name ?? AppLocalization.string("Other") }

    /// What its bots wait on you for, counted while it's folded.
    private var waiting: Int {
        section.items.reduce(0) { sum, item in
            if case .needsYou(let count) = appState.botsHomeStatus(item) { return sum + count }
            return sum
        }
    }

    var body: some View {
        let waiting = folded ? waiting : 0
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: folded ? "chevron.right" : "chevron.down")
                    .scaledFont(.caption.weight(.semibold))
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .lineLimit(1)
                Text(verbatim: String(section.items.count + roomCount))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if folded {
                    faces
                    if waiting > 0 {
                        Text(verbatim: String(waiting))
                            .scaledFont(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Capsule().fill(Color.orange))
                    }
                }
            }
            .scaledFont(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.14) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu }
        .onDrop(of: [UTType.text], delegate: CategoryHeadingDrop(
            bot: LiftedBotDrop(
                entered: { isTargeted = true },
                exited: { isTargeted = false },
                perform: { dragged in
                    isTargeted = false
                    return onDropBot(dragged)
                }
            ),
            entered: { isTargeted = true },
            exited: { isTargeted = false },
            room: onDropRoom
        ))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: [
            folded ? AppLocalization.string("Collapsed") : AppLocalization.string("Expanded"),
            waiting > 0 ? AppLocalization.string("Needs you") : "",
        ].filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(.isHeader)
        .accessibilityActions { menu }
    }

    /// Up to four of its bots' faces, small, overlapping.
    private var faces: some View {
        HStack(spacing: -6) {
            ForEach(section.items.prefix(4)) { item in
                Circle()
                    .fill(color(item))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }

    private func color(_ item: CombinedBotsHomeItem) -> Color {
        switch item.kind {
        case .own(let bot): return appState.botColor(bot)
        case .other(let bot, let section): return section.color(bot)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let onRename {
            Button(action: onRename) {
                Label(AppLocalization.string("Rename…"), systemImage: "pencil")
            }
        }
        if let onMoveEarlier {
            Button(action: onMoveEarlier) {
                Label(AppLocalization.string("Move Earlier"), systemImage: "arrow.up")
            }
        }
        if let onMoveLater {
            Button(action: onMoveLater) {
                Label(AppLocalization.string("Move Later"), systemImage: "arrow.down")
            }
        }
        if let onDelete {
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label(AppLocalization.string("Delete Category", table: .bots), systemImage: "trash")
            }
        }
    }
}

/// A heading's drop: a bot as LiftedBotDrop takes it, or a group chat's
/// tile, which LiftedBotDrop refuses, when rooms can be filed here.
struct CategoryHeadingDrop: DropDelegate {
    let bot: LiftedBotDrop
    let entered: () -> Void
    let exited: () -> Void
    let room: ((String) -> Bool)?

    private var liftedRoom: String? { room == nil ? nil : RoomDragPayload.lifted }

    func validateDrop(info: DropInfo) -> Bool {
        liftedRoom != nil || bot.validateDrop(info: info)
    }

    func dropEntered(info: DropInfo) {
        if liftedRoom != nil { entered() } else { bot.dropEntered(info: info) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard liftedRoom != nil else { return bot.dropUpdated(info: info) }
        RoomDragPayload.seen()
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if liftedRoom != nil { exited() } else { bot.dropExited(info: info) }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let roomID = liftedRoom, let room else { return bot.performDrop(info: info) }
        RoomDragPayload.lifted = nil
        exited()
        return room(roomID)
    }
}

/// A bot's Category submenu: the categories on Bots Home, New Category…
/// and, for a filed bot, Remove from Category.
struct BotCategoryMenu: View {
    let current: String?
    let names: [String]
    let onFile: (String?) -> Void
    let onNew: () -> Void

    var body: some View {
        Menu {
            ForEach(names, id: \.self) { name in
                Button {
                    onFile(name)
                } label: {
                    if BotCategories.same(current, name) {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: name)
                    }
                }
            }
            Button(action: onNew) {
                Label(AppLocalization.string("New Category…", table: .bots), systemImage: "folder.badge.plus")
            }
            if current != nil {
                Button {
                    onFile(nil)
                } label: {
                    Label(AppLocalization.string("Remove from Category", table: .bots), systemImage: "folder.badge.minus")
                }
            }
        } label: {
            Label(AppLocalization.string("Category"), systemImage: "folder")
        }
    }
}

/// The name asked for by New Category… and Rename….
enum BotCategoryPrompt: Identifiable {
    /// A new category, filing the bot whose menu asked.
    case new(CombinedBotsHomeItem)
    /// A new category, filing the group chat whose menu asked.
    case newForRoom(String)
    case rename(String)

    var id: String {
        switch self {
        case .new(let item): return "new|\(item.id)"
        case .newForRoom(let roomID): return "room|\(roomID)"
        case .rename(let name): return "rename|\(name)"
        }
    }

    var title: String {
        switch self {
        case .new, .newForRoom: return AppLocalization.string("New Category", table: .bots)
        case .rename: return AppLocalization.string("Rename Category", table: .bots)
        }
    }

    var initialName: String {
        if case .rename(let name) = self { return name }
        return ""
    }
}

extension View {
    /// A menu of just a bot's Category, where it has one.
    @ViewBuilder
    func botCategoryContextMenu(_ menu: BotCategoryMenu?) -> some View {
        if let menu {
            contextMenu { menu }
        } else {
            self
        }
    }
}

extension AppState {
    /// A Bots Home bot's status, as its portrait shows it: this
    /// dashboard's from its work and chats, another combined dashboard's
    /// from what its kept connection read.
    func botsHomeStatus(_ item: CombinedBotsHomeItem) -> BotPortraitStatus {
        switch item.kind {
        case .own(let bot):
            let snapshot = servesBotWorkstreams ? botWork.snapshot(bot.name) : nil
            return .of(snapshot,
                       talkingIn: talkingRooms(of: bot.name).map(\.name),
                       chats: botLiveChats(bot.name, leavingOut: snapshot?.knownSessionIDs ?? []))
        case .other(let bot, let section):
            return combinedBotStatus(bot, in: section.dashboardID)
        }
    }
}
