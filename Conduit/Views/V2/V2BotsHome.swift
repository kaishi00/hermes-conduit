//
//  V2BotsHome.swift
//  Conduit
//
//  Bots Home, Conduit's first tab: every bot as a portrait, three across on
//  a phone, with Pulse and Artifacts as small shortcuts under the title.
//  A portrait opens the bot's Bot Chat; the pill under its name opens its
//  Bot Overview (its chat, its work and its artifacts) and says what its
//  work is doing. Group Chats follow the bots
//  (designs/bot-mode-coordinator/bots-home-ui.md, layout A).
//

import SwiftUI

/// A named shortcut under Bots Home's title: Pulse, Artifacts.
struct V2ShortcutPill: View {
    let systemImage: String
    let title: String
    var tint: Color = .primary
    /// Something new behind it (Pulse's unseen cards).
    var dot = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            if dot {
                Circle()
                    .fill(Color.conduitAccent)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .conduitGlassControl(cornerRadius: 20, interactive: false)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Pulse and Artifacts, under Bots Home's title. Both are global: Pulse
/// isn't any one bot's, and Artifacts lists every bot's with the
/// profile's own.
struct BotsHomeShortcuts: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            if appState.showsPulseScreen {
                V2PulseButton(named: true)
            }
            NavigationLink(value: V2Route.artifacts) {
                V2ShortcutPill(systemImage: "square.grid.2x2", title: AppLocalization.string("Artifacts"))
            }
            .buttonStyle(PressableButtonStyle())
            .simultaneousGesture(TapGesture().onEnded { Haptics.selection() })
            .accessibilityLabel(AppLocalization.string("Artifacts"))
            .accessibilityIdentifier("bots.artifacts")
            Spacer(minLength: 0)
        }
    }
}

/// The bots as a grid of portraits. Three across on a phone; as many as
/// fit at about the same size on a wider column, and fewer at the largest
/// Text Sizes, where a name needs the room.
struct BotPortraitGrid<Cell: View>: View {
    let bots: [BotProfile]
    /// A portrait dropped past the last one.
    var onDropAtEnd: ((String) -> Void)?
    @ViewBuilder let cell: (BotProfile) -> Cell
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
            : [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 10)]
        LazyVGrid(columns: columns, alignment: .center, spacing: 22) {
            ForEach(bots) { bot in
                cell(bot)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
        // A drop between or after the portraits, not on one: the end.
        .dropDestination(for: String.self) { items, _ in
            guard let onDropAtEnd, let dragged = items.first.flatMap(BotDragPayload.botName(from:)) else { return false }
            BotDragPayload.lifted = nil
            onDropAtEnd(dragged)
            return true
        }
    }
}

/// Where Bots Home is in starting a room.
enum BotPortraitRoom: Equatable {
    /// No room being started.
    case off
    /// One is: this bot is in it, or could be added.
    case member
    case notMember
}

/// A portrait picked up by a touch and hold that moves: dropped on another
/// it moves before it, past the last one to the end, and held over one's
/// face it starts a room with it. The payload names the bot, marked, so text dragged in from another
/// app is never taken for one.
struct BotPortraitDrag<Preview: View>: ViewModifier {
    let name: String
    let enabled: Bool
    @ViewBuilder let preview: () -> Preview

    func body(content: Content) -> some View {
        if enabled {
            // onDrag, not draggable: its closure runs as the drag starts,
            // so the portraits can tell which bot is lifted.
            content.onDrag {
                BotDragPayload.lift(name)
            } preview: {
                preview()
            }
        } else {
            content
        }
    }
}

/// What a dragged portrait carries.
enum BotDragPayload {
    /// How long a dragged bot stays over another's face before letting go
    /// starts a room instead of moving it (as making a folder on the Home
    /// Screen).
    static var mergeDwell: Duration { .milliseconds(500) }

    static let prefix = "conduit-bot:"

    /// The bot whose portrait is being dragged, set as its drag starts.
    /// The drag session holds its item provider until it ends, dropped or
    /// not, so the name counts only while that provider lives: a cancelled
    /// drag leaves no name for a later drag from another app to borrow.
    static var lifted: String? {
        get { liftedProvider == nil ? nil : liftedName }
        set {
            liftedName = newValue
            if newValue == nil { liftedProvider = nil }
        }
    }
    private static var liftedName: String?
    private static weak var liftedProvider: NSItemProvider?

    /// Starts a portrait's drag: its item, and the name the portraits read.
    static func lift(_ name: String) -> NSItemProvider {
        let provider = NSItemProvider(object: payload(for: name) as NSString)
        liftedName = name
        liftedProvider = provider
        return provider
    }

    static func payload(for name: String) -> String { prefix + name }

    static func botName(from payload: String) -> String? {
        guard payload.hasPrefix(prefix) else { return nil }
        let name = String(payload.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }
}

/// What a bot's Overview pill says: what needs the user first, then what's
/// working, else just "Overview". It never names the policy: that's a
/// setting, in Edit Bot.
enum BotPortraitStatus: Equatable {
    case needsYou(Int)
    case working(Int)
    case idle

    static func of(_ snapshot: BotWorkSnapshot?) -> BotPortraitStatus {
        guard let snapshot, snapshot.isOn else { return .idle }
        if snapshot.needsYouCount > 0 { return .needsYou(snapshot.needsYouCount) }
        if snapshot.workingCount > 0 { return .working(snapshot.workingCount) }
        return .idle
    }

    var title: String {
        switch self {
        case .needsYou(let count): return AppLocalization.string("\(count) needs you")
        case .working(let count): return AppLocalization.string("\(count) working")
        case .idle: return AppLocalization.string("Overview")
        }
    }

    var tint: Color {
        switch self {
        case .needsYou: return .orange
        case .working: return .conduitAccent
        case .idle: return .secondary
        }
    }

    var symbol: String? {
        switch self {
        case .needsYou: return "exclamationmark.circle.fill"
        case .working: return "arrow.triangle.2.circlepath"
        case .idle: return nil
        }
    }
}

/// One bot on Bots Home: its portrait in its own color, its name, and its
/// Overview pill. The portrait and name open the Bot Chat; the pill opens
/// the overview. A long press has the Bots list's row menu.
struct BotPortraitCell<MenuContent: View>: View {
    let bot: BotProfile
    @ObservedObject var work: BotWorkStore
    let menu: MenuContent
    let onOverview: () -> Void
    /// A room being started on Bots Home: whether this bot is in it.
    /// While one is, a tap on a portrait adds or takes out its bot instead
    /// of opening its chat.
    var room: BotPortraitRoom = .off
    /// Another bot dropped on this one: `merge` when it was held over the
    /// face long enough to start (or join) a room, else moved before it.
    var onDrop: ((_ dragged: String, _ merge: Bool) -> Void)?
    /// Whether the bot being dragged can start a room with this one: never
    /// with itself, nor when either is hidden or rooms can't start here.
    /// Without it the face never swells, and a drop only moves.
    var canMerge: ((_ dragged: String) -> Bool)?
    var onToggleRoom: (() -> Void)?
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2OpenBeside) private var openBeside
    @Environment(\.v2Shell) private var shell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A dragged bot is over this one; `mergeReady` once it has stayed
    /// over the face for half a second (BotDragPayload.mergeDwell).
    @State private var isTargeted = false
    @State private var mergeReady = false
    @State private var dwell: Task<Void, Never>?

    /// Without the plugin's workstreams, nothing to show, even if a read
    /// from before is still kept (the overview hides Work then too).
    private var status: BotPortraitStatus {
        appState.servesBotWorkstreams ? .of(work.snapshot(bot.name)) : .idle
    }

    private var color: Color { BotAvatarView.color(for: bot.appearanceColor, name: bot.name) }

    /// Beside its open Bot Chat on a split window.
    private var selection: V2RowSelection {
        .chat(isActive: appState.activeBotChatProfile == bot.name, beside: openBeside, faintAlone: false)
    }

    var body: some View {
        let status = status
        VStack(spacing: 6) {
            Button {
                Haptics.light()
                if room != .off, let onToggleRoom {
                    onToggleRoom()
                    return
                }
                appState.dismissSidebarDrawer()
                Task { await appState.openBotChat(for: bot) }
            } label: {
                VStack(spacing: 8) {
                    portrait(status)
                    Text(bot.displayLabel)
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .contextMenu { menu }
            .modifier(BotPortraitDrag(name: bot.name, enabled: onDrop != nil) {
                BotMonogramView(bot: bot, size: 64)
            })
            .dropDestination(for: String.self) { items, _ in
                guard let onDrop, let dragged = items.first.flatMap(BotDragPayload.botName(from:)),
                      dragged.caseInsensitiveCompare(bot.name) != .orderedSame else { return false }
                let merge = mergeReady
                BotDragPayload.lifted = nil
                endTargeting()
                onDrop(dragged, merge)
                return true
            } isTargeted: { targeted in
                guard onDrop != nil else { return }
                targeted ? beginTargeting() : endTargeting()
            }
            .accessibilityLabel(Text(bot.displayLabel))
            .accessibilityValue(Text(accessibilityValue(status)))
            .accessibilityHint(Text(portraitHint))
            .v2SelectedTrait(selection)

            Button {
                Haptics.light()
                onOverview()
            } label: {
                pill(status)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text(AppLocalization.string("\(bot.displayLabel)’s overview")))
            .accessibilityValue(Text(verbatim: status == .idle ? "" : status.title))
            .accessibilityIdentifier("bots.overview.\(bot.name)")
        }
        // The pill's words: read once each time Bots Home shows or
        // connects, not polled (the Bot Chat and its overview poll).
        // The shell keeps a visited tab mounted, so the tab showing again is
        // part of the key.
        .task(id: "\(bot.name)\u{1F}\(appState.isConnected)\u{1F}\(appState.servesBotWorkstreams)\u{1F}\(shell.isTabActive)") {
            guard shell.isTabActive else { return }
            await appState.refreshBotWork(profile: bot.name)
        }
    }

    private var portraitHint: String {
        switch room {
        case .off: return AppLocalization.string("Opens this bot's chat.")
        case .member: return AppLocalization.string("Takes this bot out of the new room.")
        case .notMember: return AppLocalization.string("Adds this bot to the new room.")
        }
    }

    private func beginTargeting() {
        // Only a portrait being dragged, and not over its own place: text
        // from another app, or a bot over itself, shows nothing.
        guard let lifted = BotDragPayload.lifted,
              lifted.caseInsensitiveCompare(bot.name) != .orderedSame else { return }
        isTargeted = true
        dwell?.cancel()
        guard canMerge?(lifted) == true else { return }
        dwell = Task { @MainActor in
            try? await Task.sleep(for: BotDragPayload.mergeDwell)
            guard !Task.isCancelled, isTargeted else { return }
            Haptics.medium()
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { mergeReady = true }
        }
    }

    private func endTargeting() {
        dwell?.cancel()
        dwell = nil
        isTargeted = false
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { mergeReady = false }
    }

    private func portrait(_ status: BotPortraitStatus) -> some View {
        let ringed = selection == .open || room == .member || mergeReady
        // 72 at the default Text Size; the monogram scales it once, up to
        // accessibility1 (about 115), so a two-column cell still holds it.
        return BotMonogramView(bot: bot, size: 72)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .padding(4)
            .modifier(BotZoomSource(name: bot.name))
            .overlay {
                Circle()
                    .strokeBorder(ringed ? Color.conduitAccent : color.opacity(0.85),
                                  lineWidth: ringed ? 3 : 2)
            }
            .shadow(color: (mergeReady ? Color.conduitAccent : color).opacity(mergeReady ? 0.7 : 0.45),
                    radius: mergeReady ? 20 : 14)
            .scaleEffect(mergeReady ? 1.1 : 1)
            // Held over, not yet merging: a bar where the dragged bot will
            // land, before this one.
            .overlay(alignment: .leading) {
                if isTargeted && !mergeReady {
                    Capsule()
                        .fill(Color.conduitAccent)
                        .frame(width: 4)
                        .padding(.vertical, 8)
                        .offset(x: -9)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if mergeReady || room == .member {
                    Image(systemName: mergeReady ? "plus" : "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.conduitAccent))
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 2, y: 2)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if case .needsYou = status {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.orange))
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
    }

    private func pill(_ status: BotPortraitStatus) -> some View {
        HStack(spacing: 4) {
            if let symbol = status.symbol {
                Image(systemName: symbol)
                    .scaledFont(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            Text(verbatim: status.title)
                .scaledFont(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 11)
        .frame(minHeight: 28)
        .background(Capsule().fill(status == .idle ? Color.primary.opacity(0.07) : status.tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(status == .idle ? Color.primary.opacity(0.10) : status.tint.opacity(0.35),
                                        lineWidth: 1))
        // A 44-point target round the smaller pill.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        // Past accessibility2 the pill's words outgrow a two-column cell
        // and truncate to nothing; the overview sheet says them in full.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func accessibilityValue(_ status: BotPortraitStatus) -> String {
        let parts = [
            bot.isPinned ? AppLocalization.string("Pinned") : "",
            room == .member ? AppLocalization.string("In the new room") : "",
            status == .idle ? "" : status.title,
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A bot's overview: who it is, its chat a tap away, its work (the Work
/// panel's list) and what its chats produced. From Bots Home's pill, and
/// from the line under a Bot Chat's title on a phone, where Chat just
/// closes it.
struct BotOverviewSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var work: BotWorkStore
    let profile: String
    /// Edit Bot, for a bot that can be edited here; nil hides it.
    var onEdit: ((BotProfile) -> Void)?
    /// Its Bot Chat: opens it from Bots Home, closes the sheet over it.
    let onChat: () -> Void
    let onClose: () -> Void

    enum Section: Hashable {
        case work
        case artifacts
    }

    @State private var section: Section = .work

    private var bot: BotProfile? {
        appState.shownBotRoster.first { AppState.profilesMatch($0.name, profile) }
    }

    private var botName: String {
        bot?.displayLabel ?? work.snapshot(profile)?.botName ?? appState.profileDisplayName(profile)
    }

    /// Work shows where the plugin keeps a bot's work; elsewhere the
    /// overview is its chat and its artifacts.
    private var showsWork: Bool { appState.servesBotWorkstreams }

    private var shown: Section { showsWork ? section : .artifacts }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Button {
                    Haptics.light()
                    onChat()
                } label: {
                    Label(AppLocalization.string("Chat with \(botName)"), systemImage: "bubble.left.fill")
                        .scaledFont(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.conduitAccent)
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .accessibilityIdentifier("botOverview.chat")
                if showsWork {
                    Picker(AppLocalization.string("Overview"), selection: $section) {
                        Text(AppLocalization.string("Work")).tag(Section.work)
                        Text(AppLocalization.string("Artifacts")).tag(Section.artifacts)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                }
                switch shown {
                case .work:
                    BotWorkPanel(work: work, profile: profile, onClose: onClose, showsHeader: false)
                case .artifacts:
                    BotArtifactsList(profile: profile, willShowInChat: onClose)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // A workstream opened from its list shows its own chat.
        .onChange(of: appState.activeSessionId) { _, _ in onClose() }
        .accessibilityIdentifier("botOverview")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let bot {
                    BotMonogramView(bot: bot, size: 52)
                } else {
                    ProfileAvatarView(profile: profile, displayName: botName,
                                      url: appState.profileAvatarURL(for: profile), size: 52)
                        .clipShape(Circle())
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: botName)
                    .scaledFont(.title3.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if showsWork, let text = work.snapshot(profile)?.stripText {
                    Text(verbatim: text)
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let bot, let onEdit {
                Button {
                    Haptics.light()
                    onEdit(bot)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Edit Bot"))
            }
            Button {
                Haptics.light()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("Close"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

/// Reorder Bots, from a portrait's menu: the bots as a list with handles,
/// for VoiceOver, a pointer, or anyone who'd rather not drag in the grid.
/// The same order as the grid's drags (BotOrder).
struct BotReorderSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let bots = appState.shownBotRoster
        NavigationStack {
            List {
                ForEach(bots) { bot in
                    HStack(spacing: 12) {
                        BotMonogramView(bot: bot)
                        Text(bot.displayLabel)
                            .scaledFont(.body)
                        if bot.isHiddenByMeta {
                            Text("Hidden")
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { source, destination in
                    appState.moveBots(fromOffsets: source, toOffset: destination, shown: bots.map(\.name))
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(AppLocalization.string("Reorder Bots"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Portrait to chat

/// The namespace a Bots Home portrait and the Bot Chat it opens share, so
/// the chat grows out of the portrait (iOS 18's zoom) and Back shrinks it
/// back in. Nil outside the Bots stack, and split, where the chat opens
/// beside the list rather than over it.
private struct BotZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var botZoomNamespace: Namespace.ID? {
        get { self[BotZoomNamespaceKey.self] }
        set { self[BotZoomNamespaceKey.self] = newValue }
    }
}

/// The portrait the chat grows from: a circle, keyed by its bot.
struct BotZoomSource: ViewModifier {
    let name: String
    @Environment(\.botZoomNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace, !reduceMotion {
            content.matchedTransitionSource(id: name, in: namespace) { source in
                source.clipShape(Circle())
            }
        } else {
            content
        }
    }
}

/// A Bot Chat pushed in the Bots stack: it zooms from its bot's portrait.
/// Any other page, a plain session, or Reduce Motion: the usual push.
struct BotZoomDestination: ViewModifier {
    let route: V2Route
    let namespace: Namespace.ID
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), route == .conversation, !reduceMotion,
           let bot = appState.activeBotChatProfile {
            content.navigationTransition(.zoom(sourceID: bot, in: namespace))
        } else {
            content
        }
    }
}
