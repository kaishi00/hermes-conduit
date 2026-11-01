//
//  BotWorkViews.swift
//  Conduit
//
//  Bot workstreams in the app: the line under a Bot Chat's title ("2
//  working · 1 needs you"), the Work panel it opens (a sheet on a phone, a
//  column beside the chat on a wide window), with Pinned, Active, Recent and
//  the Resolved list, and what a workstream's own chat shows: whose work it
//  is under its title, and Stop, Continue or Check first while it needs
//  them. The user's actions go straight to the workstream through the
//  plugin, with no Bot Chat turn.
//

import SwiftUI

/// Reads a bot's work while something shows it: often while work runs,
/// now and then otherwise, and once for a bot whose workstreams are off.
private struct BotWorkRefresh: ViewModifier {
    @EnvironmentObject private var appState: AppState
    let profile: String

    static let busyInterval: UInt64 = 5_000_000_000
    static let idleInterval: UInt64 = 20_000_000_000

    func body(content: Content) -> some View {
        content.task(id: "\(profile)\u{1F}\(appState.isConnected)\u{1F}\(appState.servesBotWorkstreams)") {
            while !Task.isCancelled {
                await appState.refreshBotWork(profile: profile)
                let snapshot = appState.botWork.snapshot(profile)
                // Off: nothing to watch until the chat opens again.
                if snapshot?.isOn == false { return }
                let busy = (snapshot?.workingCount ?? 0) > 0 || (snapshot?.items.contains { $0.status == "starting" } ?? false)
                try? await Task.sleep(nanoseconds: busy ? Self.busyInterval : Self.idleInterval)
            }
        }
    }
}

extension View {
    func refreshesBotWork(profile: String) -> some View {
        modifier(BotWorkRefresh(profile: profile))
    }
}

/// How a piece of work looks: its color and its mark.
enum BotWorkLook {
    static func tint(_ item: BotWorkItem) -> Color {
        switch item.status {
        case "needs_you", "interrupted": return .orange
        case "failed": return .red
        case "ready", "done": return .green
        case "starting", "running", "waiting": return .conduitAccent
        default: return .secondary
        }
    }

    static func symbol(_ item: BotWorkItem) -> String {
        switch item.status {
        case "needs_you", "interrupted": return "exclamationmark"
        case "failed": return "xmark"
        case "ready", "done": return "checkmark"
        case "stopped": return "stop.fill"
        case "waiting": return "hourglass"
        case "starting", "running": return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }

    /// A model's reply as the panel shows it: inline Markdown (bold, code,
    /// links) drawn, headings' marks and list dashes tidied.
    static func rendered(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var line = line
            if let range = line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(range)
            }
            if let range = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                line.replaceSubrange(range, with: "• ")
            }
            return line
        }
        let tidy = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: tidy, options: options)) ?? AttributedString(tidy)
    }
}

/// Under a Bot Chat's title while the bot has work: what's working and
/// what needs the user. It opens the Work panel.
struct BotWorkTitleLine: View {
    @ObservedObject var work: BotWorkStore
    let profile: String
    let isPanelOpen: Bool
    let onOpen: () -> Void

    var body: some View {
        // A stack, not a Group, so the read runs while nothing shows yet.
        VStack(spacing: 0) {
            if let snapshot = work.snapshot(profile), snapshot.isOn, let text = snapshot.stripText {
                let needsYou = snapshot.needsYouCount > 0
                Button {
                    Haptics.light()
                    onOpen()
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(needsYou ? Color.orange : snapshot.workingCount > 0 ? Color.conduitAccent : Color.secondary)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(text)
                            .scaledFont(.caption.weight(.semibold))
                            .foregroundStyle(needsYou ? Color.orange : Color.secondary)
                            .lineLimit(1)
                        Image(systemName: isPanelOpen ? "chevron.up" : "chevron.down")
                            .scaledFont(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Capped as the chat's other title lines are: the title
                // bar has one line's room; the panel it opens scales fully.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .accessibilityLabel(text)
                .accessibilityHint(AppLocalization.string("Shows this bot's work"))
                .accessibilityIdentifier("botWork.titleLine")
            }
        }
        .refreshesBotWork(profile: profile)
    }
}

/// Under a workstream's title: whose work it is and where it stands. It
/// goes back to the Bot Chat coordinating it.
struct WorkstreamTitleLine: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var work: BotWorkStore
    let profile: String
    let item: BotWorkItem

    private var botName: String {
        work.snapshot(profile)?.botName ?? appState.profileDisplayName(profile)
    }

    var body: some View {
        let text = AppLocalization.string("\(botName)’s work · \(item.ref) · \(item.statusText)")
        Button {
            Haptics.light()
            appState.openCoordinator(profile: profile)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: BotWorkLook.symbol(item))
                    .scaledFont(.caption2.weight(.bold))
                    .foregroundStyle(BotWorkLook.tint(item))
                    .accessibilityHidden(true)
                Text(text)
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minHeight: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Capped as the chat's other title lines are (one line's room).
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel(text)
        .accessibilityHint(AppLocalization.string("Back to \(botName)"))
        .accessibilityIdentifier("workstream.back")
    }
}

/// What the chat's title shows of a bot's work: the Bot Chat's line, or a
/// workstream's. Watches the bots' work itself, so the toolbar redraws only
/// when this does.
struct BotWorkTitleStatus: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var work: BotWorkStore
    let isPanelOpen: Bool
    let onOpenPanel: () -> Void

    var body: some View {
        if let profile = appState.activeBotChatProfile {
            BotWorkTitleLine(work: work, profile: profile, isPanelOpen: isPanelOpen, onOpen: onOpenPanel)
        } else if let workstream = appState.activeWorkstream {
            WorkstreamTitleLine(work: work, profile: workstream.profile, item: workstream.item)
        }
    }
}

/// The bot's work: Pinned, Active, then Recent, and the way to what was
/// resolved. Each row opens to its checklist and what the user can do with
/// it; a swipe or a long press pins or resolves it.
struct BotWorkPanel: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var work: BotWorkStore
    let profile: String
    let onClose: () -> Void
    /// Rows opened and replies being typed, by ref, here rather than in
    /// each row: a row that moves between sections keeps them.
    @State private var expanded: Set<String> = []
    @State private var replies: [String: String] = [:]
    @State private var showsAllRecent = false
    @State private var showsResolved = false

    static let recentShown = 3

    private var botName: String {
        work.snapshot(profile)?.botName ?? appState.profileDisplayName(profile)
    }

    private func row(_ item: BotWorkItem) -> some View {
        BotWorkRow(
            item: item, profile: profile, isActing: work.isActing(item.ref, profile: profile),
            expanded: Binding(
                get: { expanded.contains(item.ref) },
                set: { if $0 { expanded.insert(item.ref) } else { expanded.remove(item.ref) } }
            ),
            reply: Binding(
                get: { replies[item.ref] ?? "" },
                set: { replies[item.ref] = $0.isEmpty ? nil : $0 }
            )
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if item.manage.contains(.pin) {
                manageButton(item, .pin)
            } else if item.manage.contains(.unpin) {
                manageButton(item, .unpin)
            }
        }
        // Resolve takes a tap after the swipe, so a long swipe never files
        // work away by accident.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.manage.contains(.resolve) {
                manageButton(item, .resolve)
            } else if item.manage.contains(.reopen) {
                manageButton(item, .reopen)
            }
        }
        .contextMenu {
            ForEach(item.manage, id: \.self) { action in
                manageButton(item, action)
            }
            if item.kind == .workstream, !item.sessionID.isEmpty {
                Button {
                    appState.openWorkstream(item, profile: profile)
                } label: {
                    Label(AppLocalization.string("Open \(item.ref)’s chat"), systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
    }

    private func manageButton(_ item: BotWorkItem, _ action: BotWorkItem.Action) -> some View {
        let (title, symbol, tint): (String, String, Color) = {
            switch action {
            case .pin: return (AppLocalization.string("Pin"), "pin", .orange)
            case .unpin: return (AppLocalization.string("Unpin"), "pin.slash", .gray)
            case .resolve: return (AppLocalization.string("Resolve"), "checkmark.circle", .green)
            default: return (AppLocalization.string("Reopen"), "arrow.uturn.backward.circle", .conduitAccent)
            }
        }()
        return Button {
            Haptics.light()
            Task { await appState.actOnWorkstream(item, profile: profile, action: action) }
        } label: {
            Label(title, systemImage: symbol)
        }
        .tint(tint)
        .disabled(work.isActing(item.ref, profile: profile) || !appState.isConnected)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .scaledFont(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 2, trailing: 16))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let refusal = work.refusal(profile) {
                Text(refusal)
                    .scaledFont(.footnote)
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            if showsResolved {
                resolvedList
            } else {
                openList
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .refreshesBotWork(profile: profile)
        // A refusal belongs to the panel it was tapped in. The Resolved
        // list stays, so a resolved workstream opened from it knows its
        // chat; it's read again when it shows.
        .onDisappear { work.setRefusal(nil, profile: profile) }
        .accessibilityIdentifier("botWork.panel")
    }

    private var header: some View {
        HStack(spacing: 12) {
            if showsResolved {
                Button {
                    Haptics.light()
                    withAnimation(ConduitMotion.response) { showsResolved = false }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.conduitAccent)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Back"))
            } else {
                ProfileAvatarView(
                    profile: profile,
                    displayName: botName,
                    url: appState.profileAvatarURL(for: profile),
                    size: 36
                )
                .background(Circle().fill(Color.conduitAccent.opacity(0.14)))
                .clipShape(Circle())
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(showsResolved ? AppLocalization.string("Resolved") : AppLocalization.string("\(botName)’s work"))
                    .scaledFont(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if !showsResolved, let text = work.snapshot(profile)?.stripText {
                    Text(text)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button {
                Haptics.light()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("Close"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func countChip(_ title: String, _ count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .scaledFont(.caption.weight(.semibold))
            Text("\(count)")
                .scaledFont(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(count > 0 ? tint : Color.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(count > 0 ? tint.opacity(0.14) : Color.primary.opacity(0.06)))
        .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
        .accessibilityElement(children: .combine)
    }

    private var openList: some View {
        List {
            if let snapshot = work.snapshot(profile) {
                if snapshot.items.isEmpty == false {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            countChip(AppLocalization.string("Needs you"), snapshot.needsYouCount, tint: .orange)
                            countChip(AppLocalization.string("Working"), snapshot.workingCount, tint: .conduitAccent)
                            countChip(AppLocalization.string("Ready"), snapshot.readyCount, tint: .green)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16))
                } else if snapshot.resolvedCount == 0 {
                    Text("No work yet")
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if !snapshot.pinned.isEmpty {
                    Section {
                        ForEach(snapshot.pinned) { row($0) }
                    } header: {
                        sectionHeader(AppLocalization.string("Pinned"))
                    }
                }
                if !snapshot.active.isEmpty {
                    Section {
                        ForEach(snapshot.active) { row($0) }
                    } header: {
                        sectionHeader(AppLocalization.string("Active"))
                    }
                }
                let recent = snapshot.recent
                if !recent.isEmpty {
                    Section {
                        ForEach(showsAllRecent ? recent : Array(recent.prefix(Self.recentShown))) { row($0) }
                        if recent.count > Self.recentShown {
                            Button {
                                Haptics.light()
                                withAnimation(ConduitMotion.response) { showsAllRecent.toggle() }
                            } label: {
                                Text(showsAllRecent ? AppLocalization.string("Show less")
                                     : AppLocalization.string("Show all \(String(recent.count))"))
                                    .scaledFont(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.conduitAccent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 16))
                        }
                    } header: {
                        sectionHeader(AppLocalization.string("Recent"))
                    }
                }
                if snapshot.resolvedCount > 0 {
                    Button {
                        Haptics.light()
                        withAnimation(ConduitMotion.response) { showsResolved = true }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text("Resolved")
                                .scaledFont(.body.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            Spacer(minLength: 4)
                            Text("\(snapshot.resolvedCount)")
                                .scaledFont(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .scaledFont(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
                    .accessibilityIdentifier("botWork.resolved")
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var resolvedList: some View {
        List {
            let list = work.resolvedList(profile)
            ForEach(list?.items ?? []) { row($0) }
            if list?.isLoading ?? true {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if list?.failed == true {
                Text("Couldn't reach this bot's work. Try again in a moment.")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if list?.items.isEmpty == true {
                Text("Nothing resolved yet")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if list?.more == true {
                Button {
                    Task { await appState.loadResolvedWork(profile: profile, more: true) }
                } label: {
                    Text("Show more")
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.conduitAccent)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .task(id: "\(profile)\u{1F}\(appState.isConnected)") {
            await appState.loadResolvedWork(profile: profile)
        }
    }
}

/// One piece of work as a card: its mark, title and where it is, its last
/// result, and its checklist and actions once opened.
private struct BotWorkRow: View {
    @EnvironmentObject private var appState: AppState
    let item: BotWorkItem
    let profile: String
    let isActing: Bool
    @Binding var expanded: Bool
    @Binding var reply: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var tint: Color { BotWorkLook.tint(item) }

    /// The line under the title: what it's doing, else why it stopped,
    /// else where it stands.
    private var subtitle: String {
        if item.isClosed {
            return item.resolvedBy == "bot" ? AppLocalization.string("\(item.statusText) · resolved by the bot")
                : AppLocalization.string("\(item.statusText) · resolved by you")
        }
        if let doing = item.doing { return doing }
        if item.needsYou, !item.error.isEmpty {
            return AppLocalization.string("Needs you · \(item.error)")
        }
        if !item.error.isEmpty, item.status != "done" { return "\(item.statusText) · \(item.error)" }
        return item.statusText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Haptics.light()
                withAnimation(ConduitMotion.response) { expanded.toggle() }
            } label: {
                summary
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(expanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))
            .accessibilityHint(expanded ? AppLocalization.string("Shows less") : AppLocalization.string("Shows more"))
            if expanded {
                if !item.checklist.isEmpty {
                    checklist
                }
                actions
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(item.needsYou ? Color.orange.opacity(0.09) : Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(item.needsYou ? Color.orange.opacity(0.32) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .accessibilityIdentifier("botWork.row.\(item.ref)")
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(item.needsYou ? Color.orange : tint.opacity(0.16))
                Image(systemName: BotWorkLook.symbol(item))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(item.needsYou ? Color.black.opacity(0.85) : tint)
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.ref)
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.shownTitle)
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(expanded ? nil : 1)
                    Spacer(minLength: 4)
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .scaledFont(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(AppLocalization.string("Pinned"))
                    }
                    Text(item.closedAt ?? item.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .scaledFont(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(subtitle)
                    .scaledFont(.footnote)
                    .foregroundStyle(item.needsYou ? Color.orange : Color.secondary)
                    .lineLimit(expanded ? nil : 1)
                if !item.result.isEmpty {
                    Text(BotWorkLook.rendered(item.result))
                        .scaledFont(.footnote)
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(expanded ? 12 : 2)
                        .padding(.top, 1)
                } else if item.kind != .workstream, !item.goal.isEmpty {
                    Text(BotWorkLook.rendered(item.goal))
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? 8 : 2)
                }
                if !expanded, !item.checklist.isEmpty, !item.isClosed {
                    progressBar
                        .padding(.top, 4)
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// How far its checklist is: a bar and "1 of 3".
    private var progressBar: some View {
        let total = max(1, item.checklist.count)
        return HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width * CGFloat(item.doneCount) / CGFloat(total))
                }
            }
            .frame(height: 4)
            Text(AppLocalization.string("\(String(item.doneCount)) of \(String(item.checklist.count))"))
                .scaledFont(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.string("\(String(item.doneCount)) of \(String(item.checklist.count))"))
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(item.checklist) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: line.state == .done ? "checkmark.circle.fill"
                          : line.state == .doing ? "circle.dotted" : "circle")
                        .scaledFont(.footnote)
                        .foregroundStyle(line.state == .done ? Color.green
                                         : line.state == .doing ? tint : Color.secondary)
                        .accessibilityHidden(true)
                    Text(line.text)
                        .scaledFont(.footnote)
                        .foregroundStyle(line.state == .todo ? Color.secondary : Color.primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(BotWorkItem.statusWord(line.state == .done ? "done"
                                                           : line.state == .doing ? "running" : "waiting"))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var actions: some View {
        if item.kind == .workstream {
            let controls: [BotWorkItem.Action] = [.check, .continue, .stop].filter { item.actions.contains($0) }
            if !controls.isEmpty {
                // Stacked at accessibility Text Sizes, so no label is cut.
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    ForEach(controls, id: \.self) { action in
                        controlButton(action, prominent: action == controls.first && action != .stop)
                    }
                }
                .disabled(isActing || !appState.isConnected)
            }
            if item.actions.contains(.send) {
                replyField
            }
            if !item.sessionID.isEmpty {
                Button {
                    Haptics.light()
                    appState.openWorkstream(item, profile: profile)
                } label: {
                    HStack {
                        Text(AppLocalization.string("Open \(item.ref)’s chat"))
                            .scaledFont(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .scaledFont(.caption.weight(.bold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Color.conduitAccent)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func controlButton(_ action: BotWorkItem.Action, prominent: Bool) -> some View {
        let title: String = {
            switch action {
            case .check: return AppLocalization.string("Check first")
            case .continue: return AppLocalization.string("Continue")
            default: return AppLocalization.string("Stop")
            }
        }()
        let isStop = action == .stop
        return Button {
            Haptics.light()
            Task { await appState.actOnWorkstream(item, profile: profile, action: action) }
        } label: {
            Text(title)
                .scaledFont(.subheadline.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : isStop ? Color.red : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(prominent ? Color.conduitAccent : isStop ? Color.red.opacity(0.12) : Color.primary.opacity(0.08))
                )
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var replyField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(AppLocalization.string("Reply to \(item.ref)…"), text: $reply, axis: .vertical)
                .scaledFont(.body)
                .lineLimit(2...6)
                .padding(.vertical, 6)
            Button {
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                Task {
                    if await appState.actOnWorkstream(item, profile: profile, action: .send, text: text) {
                        reply = ""
                    }
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.conduitAccent))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
            .disabled(isActing || !appState.isConnected
                      || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(AppLocalization.string("Send to \(item.ref)"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

/// Over a workstream's own chat while it needs a tap: Stop, Continue or
/// Check first, and what the plugin said when one did nothing. Its title
/// says whose work it is.
struct WorkstreamBar: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var work: BotWorkStore
    let profile: String
    let item: BotWorkItem

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var controls: [BotWorkItem.Action] { [.check, .continue, .stop].filter { item.actions.contains($0) } }

    var body: some View {
        // A stack, not a Group, so the read runs while nothing shows.
        VStack(alignment: .leading, spacing: 0) {
            let refusal = work.refusal(profile)
            if !controls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !controls.isEmpty {
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
                        layout {
                            if item.needsYou {
                                Text(AppLocalization.string("Needs you"))
                                    .scaledFont(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.orange)
                                    .lineLimit(1)
                            }
                            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                            ForEach(controls, id: \.self) { action in
                                barButton(action)
                            }
                        }
                        .disabled(work.isActing(item.ref, profile: profile) || !appState.isConnected)
                    }
                    if let refusal {
                        Text(refusal)
                            .scaledFont(.footnote)
                            .foregroundStyle(Color.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .conduitGlassSurface(cornerRadius: 16)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .accessibilityIdentifier("workstream.bar")
            }
        }
        .refreshesBotWork(profile: profile)
        .onDisappear { work.setRefusal(nil, profile: profile) }
    }

    private func barButton(_ action: BotWorkItem.Action) -> some View {
        let title: String = {
            switch action {
            case .check: return AppLocalization.string("Check first")
            case .continue: return AppLocalization.string("Continue")
            default: return AppLocalization.string("Stop")
            }
        }()
        return Button(title) {
            Haptics.light()
            Task { await appState.actOnWorkstream(item, profile: profile, action: action) }
        }
        .scaledFont(.footnote.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(action == .stop ? .red : .conduitAccent)
        .controlSize(.small)
    }
}

/// What shows over the open chat: the bar over one of a bot's workstreams
/// while it needs a tap. Watches the bots' work itself, so the chat screen
/// redraws only when this does.
struct BotWorkHeader: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var work: BotWorkStore

    /// Reads for a bot's chat its list doesn't name yet, a few seconds
    /// apart: a workstream the bot just started shows in one of them.
    static let unmatchedReads = 4
    static let unmatchedInterval: UInt64 = 3_000_000_000

    var body: some View {
        if appState.activeBotChatProfile != nil {
            // Its work shows under the title.
            EmptyView()
        } else if let workstream = appState.activeWorkstream {
            // One bar per workstream: another's refusal never shows on it.
            WorkstreamBar(work: work, profile: workstream.profile, item: workstream.item)
                .id("\(workstream.profile)\u{1F}\(workstream.item.ref)")
        } else if let id = appState.activeSessionId, !id.isEmpty,
                  appState.shownBotRoster.contains(where: { $0.name == appState.activeProfile }) {
            // A chat on a bot that its last list didn't name: a workstream
            // opened from a card, a link or a push before the list showed
            // it. Read it again a few times, so its title line shows once
            // it does.
            let profile = appState.activeProfile
            Color.clear
                .frame(height: 0)
                .task(id: "\(profile)\u{1F}\(id)") {
                    for attempt in 0..<Self.unmatchedReads {
                        if attempt > 0 {
                            try? await Task.sleep(nanoseconds: Self.unmatchedInterval)
                        }
                        guard !Task.isCancelled else { return }
                        await appState.refreshBotWork(profile: profile)
                        if work.snapshot(profile)?.isOn == false { return }
                    }
                }
        }
    }
}

/// A workstream's brief in its chat: "Brief from Hermes", the task, and
/// the user's words it answers, folded to a few lines until tapped.
struct WorkstreamBriefCard: View {
    let brief: WorkstreamBrief
    let timestamp: String
    /// The row's key in `disclosure`, so a rebuilt row stays open.
    let disclosureID: String
    @Environment(\.chatRowDisclosure) private var disclosure
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil until tapped here: a rebuilt row takes what the reader chose
    /// from `disclosure`.
    @State private var tapped: Bool?

    private var expanded: Bool {
        tapped ?? disclosure?.isExpanded(disclosureID, default: false) ?? false
    }

    var body: some View {
        Button {
            Haptics.selection()
            let opens = !expanded
            // Tells the scroller first, as every row that opens does.
            disclosure?.willToggle(disclosureID, to: opens)
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { tapped = opens }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(AppLocalization.string("Brief from \(brief.bot)"))
                        .scaledFont(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.conduitAccent)
                    Spacer(minLength: 4)
                    Text(expanded ? AppLocalization.string("Show less") : AppLocalization.string("Show all"))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .scaledFont(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if expanded {
                    MarkdownText(source: brief.task)
                        .scaledFont(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(BotWorkLook.rendered(brief.task))
                        .scaledFont(.subheadline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let words = brief.userWords {
                    Text(AppLocalization.string("For: “\(words)”"))
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 1)
                }
                if let time = MessageTimestampFormatter.displayString(for: timestamp) {
                    Text(time)
                        .scaledFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.conduitAccent.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.conduitAccent.opacity(0.18), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityValue(expanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))
        .accessibilityHint(expanded ? AppLocalization.string("Shows less") : AppLocalization.string("Shows more"))
        .accessibilityIdentifier("workstream.brief")
    }
}

/// Under a Bot Chat's "Started W3" card: where that workstream is now, as
/// the bot's last list says. Watches the bots' work itself, so the
/// transcript row redraws only when this does.
struct WorkStartStatusLine: View {
    @ObservedObject var work: BotWorkStore
    let profile: String
    let ref: String
    /// What the card said before the list named the workstream.
    var fallback: String?

    private var item: BotWorkItem? {
        work.snapshot(profile)?.items.first { $0.ref == ref }
            ?? work.resolvedList(profile)?.items.first { $0.ref == ref }
    }

    var body: some View {
        if let item {
            let detail = (item.doing ?? (item.result.isEmpty ? nil : String(BotWorkLook.rendered(item.result).characters)))?
                .replacingOccurrences(of: "\n", with: " ")
            HStack(spacing: 5) {
                Image(systemName: BotWorkLook.symbol(item))
                    .scaledFont(.caption2.weight(.bold))
                    .foregroundStyle(BotWorkLook.tint(item))
                    .accessibilityHidden(true)
                Text(detail.map { "\(item.statusText) · \($0)" } ?? item.statusText)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if let fallback {
            Text(fallback)
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
