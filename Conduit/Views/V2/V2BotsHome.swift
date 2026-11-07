//
//  V2BotsHome.swift
//  Conduit
//
//  Bots Home, Conduit's first tab: every bot as a portrait, three across on
//  a phone, with Pulse and Artifacts as small shortcuts under the title.
//  A portrait and its name open the bot's Bot Chat; the ⓘ beside the name
//  opens its Bot Overview (its chat, its work and its artifacts), and so
//  does the status pill under it when its work is doing something. Group
//  Chats follow the bots
//  (designs/bot-mode-coordinator/bots-home-ui.md, layout A).
//

import SwiftUI
import UniformTypeIdentifiers
import TipKit

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

/// A sheet over Bots Home (an overview, Reorder Bots, a new room or bot)
/// covers its grid: the portraits keep still under it, and a finish waits
/// for the grid to show again. Set by BotRosterView.
private struct BotsHomeCoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var botsHomeCovered: Bool {
        get { self[BotsHomeCoveredKey.self] }
        set { self[BotsHomeCoveredKey.self] = newValue }
    }
}

/// Bots Home's Group Chats: each room a small portrait under the bots, four
/// across on a phone (Eric 2026-11-05, option B of the Group Chats canvas),
/// so the rooms read like the bots above them, smaller. A room whose bots
/// are talking now is ringed in gold and says so, in its place: like a bot,
/// a room never moves for being busy.
struct BotRoomGrid<Content: View>: View {
    /// A room's tile dropped past the last one, by its room id.
    var onDropAtEnd: ((String) -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = typeSize.isAccessibilitySize
            ? Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3)
            : [GridItem(.adaptive(minimum: 76, maximum: 110), spacing: 8, alignment: .top)]
        LazyVGrid(columns: columns, alignment: .center, spacing: 16) {
            content()
        }
        // A drop between or after the rooms, not on one: the end.
        .onDrop(of: [UTType.text], delegate: RoomTileDrop(target: nil, targeted: .constant(false)) { dragged in
            onDropAtEnd?(dragged)
        })
    }
}

/// A room's portrait: its icon in a ring, its name under it, and "Talking
/// now" while its bots talk. A room being started has a dashed ring.
struct BotRoomPortraitLabel<Icon: View>: View {
    let title: String
    var talking = false
    /// Ringed in gold: open beside the list, or the room being started.
    var highlighted = false
    var dashed = false
    var animates = false
    /// The zoom source key a room's screen grows out of (BotZoomSource).
    var zoomSource: String?
    @ViewBuilder let icon: (CGFloat) -> Icon
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 56

    var body: some View {
        let gold = talking || highlighted
        VStack(spacing: 6) {
            icon(size)
                .frame(width: size, height: size)
                .padding(4)
                .modifier(BotZoomSource(name: zoomSource))
                .overlay {
                    Circle().strokeBorder(
                        gold ? Color.conduitAccent.opacity(0.85) : Color.primary.opacity(0.14),
                        style: StrokeStyle(lineWidth: 2, dash: dashed ? [5, 4] : [])
                    )
                }
                .shadow(color: talking ? Color.conduitAccent.opacity(0.35) : .clear, radius: 8)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if talking {
                HStack(spacing: 4) {
                    BotsLiveDot(animates: animates)
                    Text(AppLocalization.string("Talking now"))
                        .scaledFont(.caption2.weight(.semibold))
                        .foregroundStyle(Color.conduitAccent)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

/// What a room's tile on Bots Home does beyond its tap: its menu (the open
/// room's own, less what needs the room open) and its drag.
struct GroupRoomTileActions {
    /// Asks for the room's Group Settings, where Hermes keeps them, then
    /// opens the room with the open it's handed (the tile's own, so it zooms
    /// as a tap does), which says whether the room opened.
    var settings: ((_ open: (@escaping @MainActor (Bool) -> Void) -> Void) -> Void)?
    /// Chooses, generates or removes its picture, where the plugin keeps
    /// pictures.
    var picture: ((GroupRoomPictureRequest) -> Void)?
    let reorder: () -> Void
    /// Asks first (the dialog is Bots Home's, not the menu's).
    var disband: (() -> Void)?
    /// Another room's tile held over this one, or dropped on it: it takes
    /// this one's place.
    let onDrop: (String) -> Void
}

/// A hosted room on Bots Home; a tap opens it, a touch and hold has its
/// menu, and a drag moves it among the rooms, as a bot's portrait does.
struct GroupRoomPortrait: View {
    let room: GroupRoom
    var actions: GroupRoomTileActions?
    /// Another room's tile is over this one.
    @State private var dropTarget = false
    /// Held over it a moment, the tile in hand takes its place.
    @State private var slide: Task<Void, Never>?
    /// The tile in hand already took this one's place: let go here, it
    /// stays where it went rather than moving again.
    @State private var placed = false
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2OpenBeside) private var openBeside
    @Environment(\.v2Shell) private var shell
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.botsHomeCovered) private var covered
    @ObservedObject private var devicePower = DevicePowerState.shared

    private var talking: Bool { appState.talkingRoomIDs.contains(room.roomID) }
    private var selection: V2RowSelection { .room(room.roomID, beside: openBeside) }
    private var animates: Bool {
        shell.isTabActive && !shell.isRootCovered && !covered && scenePhase == .active
            && !reduceMotion && !devicePower.isLowPowerModeEnabled
    }

    private var zoomKey: String { BotZoomArm.roomKey(room.roomID) }

    var body: some View {
        Button {
            appState.groupSettingsOnOpen = nil
            open()
        } label: {
            BotRoomPortraitLabel(title: room.name, talking: talking, highlighted: selection == .open,
                                 animates: animates, zoomSource: zoomKey) { size in
                GroupRoomIcon(picture: appState.groupRoomPicture(roomID: room.roomID), members: room.members, size: size)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .contextMenu {
            if let actions { menu(actions) }
        }
        .modifier(RoomTileDrag(roomID: room.roomID, enabled: actions != nil) {
            // Drawn outside the view's environment, as a bot's preview.
            GroupRoomIcon(picture: appState.groupRoomPicture(roomID: room.roomID), members: room.members, size: 56)
                .environmentObject(appState)
        })
        // A move, not a copy, so the tile in hand shows no + over it. Held
        // over this tile a moment, it takes its place while still in hand
        // and the others slide aside, as apps do on the Home Screen
        // (Eric, 2026-11-06); then it's over its own tile.
        // Dropped back on its own tile, it's taken here and left where it
        // was, so the grid around it never reads it as a drop at the end.
        .onChange(of: dropTarget) { _, over in
            slide?.cancel()
            slide = nil
            // The drop ends the hover before it lands, so `placed` outlives
            // it, as a bot's does, and starts over only on the next hover.
            guard over else { return }
            placed = false
            guard let dragged = RoomDragPayload.lifted else { return }
            slide = Task { @MainActor in
                try? await Task.sleep(for: BotDragPayload.slideDwell)
                guard !Task.isCancelled, dropTarget, RoomDragPayload.lifted == dragged else { return }
                placed = true
                actions?.onDrop(dragged)
            }
        }
        .onDrop(of: [UTType.text], delegate: RoomTileDrop(target: actions == nil ? nil : room.roomID,
                                                          targeted: $dropTarget) { dragged in
            guard !placed else { return }
            actions?.onDrop(dragged)
        })
        .accessibilityLabel(Text(room.name))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint(Text(AppLocalization.string("Opens this group chat.")))
        .accessibilityIdentifier("bots.room.\(room.roomID)")
        .v2SelectedTrait(selection)
    }

    /// Its screen opens in Bots whatever chat was open before, and grows out
    /// of this portrait as a Bot Chat does from its bot's
    /// (BotZoomDestination), unless it opens beside the list. `done` hears
    /// whether the room opened.
    private func open(then done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        Haptics.light()
        appState.beginOpeningBotChat(zoomKey)
        if openBeside == nil { appState.botZoom.tap(zoomKey) }
        Task {
            await appState.openGroupRoom(room)
            let opened = appState.activeRoomSurface?.room.roomID == room.roomID
            if !opened { appState.botZoom.openFailed(zoomKey) }
            appState.endOpeningBotChat(zoomKey)
            done(opened)
        }
    }

    /// The room's menu, from its tile: what its own menu has that needs no
    /// open room, then Reorder Group Chats, as a bot's has Reorder Bots.
    @ViewBuilder
    private func menu(_ actions: GroupRoomTileActions) -> some View {
        if let settings = actions.settings {
            Button { settings { done in open(then: done) } } label: {
                Label(AppLocalization.string("Group Settings"), systemImage: "gearshape")
            }
        }
        if let picture = actions.picture {
            Button { picture(.choose) } label: {
                Label(AppLocalization.string("Choose Group Picture"), systemImage: "photo")
            }
            if appState.canGeneratePictures {
                Button { picture(.generate) } label: {
                    Label(AppLocalization.string("Generate Group Picture"), systemImage: "sparkles")
                }
            }
            if ImagePlaygroundPicture.current == .available {
                Button { picture(.playground) } label: {
                    Label(AppLocalization.string("Image Playground"), systemImage: "apple.image.playground")
                }
            }
            if appState.hasCustomGroupRoomPicture(roomID: room.roomID) {
                Button {
                    Task { await appState.setGroupRoomPicture(nil, roomID: room.roomID) }
                } label: {
                    Label(AppLocalization.string("Remove Group Picture"), systemImage: "photo.badge.minus")
                }
            }
        }
        Button(action: actions.reorder) {
            Label(AppLocalization.string("Reorder Group Chats"), systemImage: "arrow.up.arrow.down")
        }
        if let disband = actions.disband {
            Divider()
            Button(role: .destructive, action: disband) {
                Label(AppLocalization.string("Disband Group"), systemImage: "trash")
            }
        }
    }

    private var accessibilityValue: String {
        let members = AppLocalization.string("\(room.members.count) members")
        return talking ? "\(AppLocalization.string("Talking now")), \(members)" : members
    }
}

/// A room's tile picked up by a touch and hold that moves: dropped on
/// another room it moves before it, past the last one to the end. Its
/// payload is marked as a room's, so a bot's portrait never takes it for a
/// bot, nor a room's tile a bot for a room.
struct RoomTileDrag<Preview: View>: ViewModifier {
    let roomID: String
    let enabled: Bool
    @ViewBuilder let preview: () -> Preview

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                RoomDragPayload.lift(roomID)
            } preview: {
                preview()
            }
        } else {
            content
        }
    }
}

/// What a dragged room's tile carries: its room id, marked.
enum RoomDragPayload {
    static let prefix = "conduit-room:"

    static func lift(_ roomID: String) -> NSItemProvider {
        // A room in hand isn't a bot: no face swells for it.
        BotDragPayload.lifted = nil
        let provider = NSItemProvider(object: payload(for: roomID) as NSString)
        liftedID = roomID
        liftedSeenAt = Date()
        liftedProvider = provider
        return provider
    }

    /// The room whose tile is being dragged, set as its drag starts. It
    /// counts while the drag's item lives, or a drop target saw it within
    /// `BotDragPayload.liftedGrace`, as a bot's does, so a cancelled drag
    /// leaves nothing for a later drop to borrow.
    static var lifted: String? {
        get { lifted(at: Date()) }
        set {
            liftedID = newValue
            liftedSeenAt = Date()
            if newValue == nil { liftedProvider = nil }
        }
    }
    private static var liftedID: String?
    private static weak var liftedProvider: NSItemProvider?
    private static var liftedSeenAt = Date.distantPast

    static func lifted(at now: Date) -> String? {
        guard let liftedID else { return nil }
        if liftedProvider != nil { return liftedID }
        return now.timeIntervalSince(liftedSeenAt) < BotDragPayload.liftedGrace ? liftedID : nil
    }

    /// A drop target saw the tile in hand: it still counts for a while.
    static func seen(at now: Date = Date()) {
        if lifted(at: now) != nil { liftedSeenAt = now }
    }

    /// Whether the drag that set `lifted` still holds its item. Only then
    /// is a drop surely that tile; a drop within the grace alone is read
    /// from its own text, so a foreign drop never borrows the room.
    static var isLive: Bool { liftedID != nil && liftedProvider != nil }

    static func payload(for roomID: String) -> String { prefix + roomID }

    static func roomID(from payload: String) -> String? {
        guard payload.hasPrefix(prefix) else { return nil }
        let id = String(payload.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}

/// Where a room's tile can land: on another tile (`target`) or the grid
/// around them (nil, the end). It proposes a move, where a plain drop
/// destination proposes a copy and so a + badge, as if the room were being
/// added somewhere. A dragged bot passes by, and text only moves a room
/// when it carries a room tile's mark.
struct RoomTileDrop: DropDelegate {
    let target: String?
    @Binding var targeted: Bool
    let onDrop: (String) -> Void

    /// A tile in hand, or, should the drag have let go of the room it set
    /// as it began, any text, read for a room's mark as it lands. Never a
    /// bot's portrait.
    func validateDrop(info: DropInfo) -> Bool {
        guard BotDragPayload.lifted == nil else { return false }
        return RoomDragPayload.lifted != nil || info.hasItemsConforming(to: [UTType.text])
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = RoomDragPayload.lifted, let target else { return }
        targeted = dragged != target
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // A bot carried over the rooms stays in hand too, or its + comes
        // back once the system lets go of its item.
        RoomDragPayload.seen()
        BotDragPayload.seen()
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        // A move only for our own tile: text from elsewhere is a copy, so
        // its source never deletes what this may not take.
        return DropProposal(operation: RoomDragPayload.lifted != nil ? .move : .copy)
    }

    func dropExited(info: DropInfo) { targeted = false }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let target = target
        let onDrop = onDrop
        if RoomDragPayload.isLive, let dragged = RoomDragPayload.lifted {
            RoomDragPayload.lifted = nil
            if dragged != target { onDrop(dragged) }
            return true
        }
        // Past its item, the tile in hand is only a guess: read the drop's
        // own text (a tile's carries its mark).
        RoomDragPayload.lifted = nil
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let dragged = RoomDragPayload.roomID(from: text),
                  dragged != target else { return }
            DispatchQueue.main.async { onDrop(dragged) }
        }
        return true
    }
}

/// A group chat Hermes Desktop mirrored, on Bots Home: read-only, so a tap
/// shows its latest messages. A small computer marks it as Desktop's.
struct DesktopGroupPortrait: View {
    let group: DesktopGroupChat
    let onOpen: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            onOpen()
        } label: {
            BotRoomPortraitLabel(title: group.name) { size in
                GroupRoomIcon(
                    picture: GroupRoomPictureImages.image(from: group.imageData),
                    members: group.groupMembers,
                    size: size
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color(.secondarySystemBackground)))
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 4, y: 4)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(group.name))
        .accessibilityValue(Text(AppLocalization.string("\(group.members.count) members")))
        .accessibilityHint(Text(AppLocalization.string("Shows this Hermes Desktop group chat.")))
    }
}

/// Where Bots Home's faces and the room being started sit, so a bot that
/// joins the room can fly from its portrait into the room's icon.
struct BotsHomeAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }

    static let newRoom = "room:new"
    static func bot(_ name: String) -> String { "bot:" + name.lowercased() }
}

/// The room being started, among the rooms: its bots' faces overlapping as
/// a room's icon does, in a dashed gold ring, under the name typed for it.
/// A bot dropped on it joins; a tap goes to its name in the bar. Faces still flying in from their portraits aren't drawn
/// yet, so each arrives.
struct NewRoomPortrait: View {
    let bots: [BotProfile]
    /// Bots whose faces are still on their way.
    let flying: Set<String>
    /// The name typed in the bar, or "New room".
    let name: String
    /// Its bots' names, for VoiceOver.
    let members: String
    let onTap: () -> Void
    /// Whether the dragged bot can join: never a hidden bot, one already
    /// in, or one past the room's limit. Without it the tile never swells.
    let canJoin: (String) -> Bool
    let onDrop: (String) -> Bool
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false

    var body: some View {
        Button {
            onTap()
        } label: {
            BotRoomPortraitLabel(title: name, highlighted: true, dashed: true) { size in
                faces(size)
                    .anchorPreference(key: BotsHomeAnchorKey.self, value: .bounds) { [BotsHomeAnchorKey.newRoom: $0] }
                    .scaleEffect(isTargeted && !reduceMotion ? 1.12 : 1)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .onDrop(of: [UTType.text], delegate: LiftedBotDrop(
            entered: {
                let joins = BotDragPayload.lifted.map(canJoin) == true
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { isTargeted = joins }
            },
            exited: {
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { isTargeted = false }
            },
            perform: onDrop
        ))
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(verbatim: members))
        .accessibilityHint(Text(AppLocalization.string("Names the room in the bar below.")))
        .accessibilityIdentifier("bots.newRoom.tile")
    }

    private func faces(_ size: CGFloat) -> some View {
        let shown = Array(bots.prefix(3))
        let spots = GroupRoomIcon.layout(count: shown.count)
        return ZStack {
            // Brighter under a bot that can join, Reduce Motion too.
            Circle().fill(Color.conduitAccent.opacity(isTargeted ? 0.30 : 0.10))
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, bot in
                let spot = spots[index]
                BotAvatarView(
                    name: bot.name,
                    label: bot.displayLabel,
                    colorString: bot.appearanceColor,
                    image: appState.botAvatarImage(for: bot),
                    size: size * spot.diameter
                )
                .overlay {
                    if shown.count > 1 {
                        Circle().strokeBorder(Color.conduitBackgroundColor, lineWidth: max(1, size * 0.03))
                    }
                }
                .offset(x: size * spot.x, y: size * spot.y)
                .opacity(flying.contains(bot.name.lowercased()) ? 0 : 1)
            }
        }
        .frame(width: size, height: size)
    }

    /// Where the face of the bot at `index` of `count` lands in the icon
    /// at `rect`: its center and diameter. Past the third it sinks into the
    /// middle, as the icon shows three.
    static func slot(index: Int, count: Int, in rect: CGRect) -> (center: CGPoint, diameter: CGFloat) {
        let spots = GroupRoomIcon.layout(count: min(count, 3))
        guard index < spots.count else {
            return (CGPoint(x: rect.midX, y: rect.midY), rect.width * 0.3)
        }
        let spot = spots[index]
        return (CGPoint(x: rect.midX + rect.width * spot.x, y: rect.midY + rect.height * spot.y),
                rect.width * spot.diameter)
    }
}

/// A face on its way from a portrait into the room being started.
struct BotRoomFlight: Identifiable, Equatable {
    let id = UUID()
    /// The bot's name, lowercased.
    let name: String
    var landed = false

    /// Quick and a little playful: the faces shrink as they go and settle
    /// with a small bounce.
    static let motion = Animation.spring(duration: 0.5, bounce: 0.28)
}

/// While Bots Home shows, asks which group rooms talk every
/// `BotsTalkingRoomsReader.every` (AppState.refreshTalkingRooms), for the
/// live rooms and the portraits' "In <room>" pills.
struct BotsTalkingRoomsReader: ViewModifier {
    static let every: Duration = .seconds(12)
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        // Under a sheet too: the pills still say where each bot talks.
        let shown = shell.isTabActive && !shell.isRootCovered && scenePhase == .active
        content.task(id: "\(shown)\u{1F}\(appState.isConnected)\u{1F}\(appState.groupRoomsListed)") {
            guard shown else { return }
            while !Task.isCancelled {
                await appState.refreshTalkingRoomsIfDue(every: Self.every)
                try? await Task.sleep(for: Self.every)
            }
        }
    }
}

/// A live room's dot: it breathes while the room talks and Bots Home shows.
struct BotsLiveDot: View {
    let animates: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animates)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = animates ? CGFloat(1 - cos(t / 1.4 * 2 * .pi)) / 2 : 0
            Circle()
                .fill(Color.conduitAccent)
                .frame(width: 7, height: 7)
                .opacity(0.55 + 0.45 * Double(pulse))
                .scaleEffect(1 + 0.25 * pulse)
        }
        .accessibilityHidden(true)
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
        // A drop between or after the portraits, not on one: the end. A
        // grid with no end to drop at (the hidden bots) takes no drop, so
        // it never offers a move it would refuse.
        .onDrop(of: onDropAtEnd == nil ? [] : [UTType.text], delegate: LiftedBotDrop { dragged in
            guard let onDropAtEnd else { return false }
            onDropAtEnd(dragged)
            return true
        })
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

/// Bots Home's one tip (Eric, 2026-11-06, #1850): touch and hold a bot for
/// its menu, drag it to move it, hold it over another to start a room.
/// Shown once, under the bots, when there are two or more; it goes for good
/// when it's closed, a bot is dragged, Reorder Bots opens or a room is begun.
struct BotsHomeGesturesTip: Tip {
    /// Bots Home shows two or more bots, so there's something to arrange.
    @Parameter static var hasBotsToArrange: Bool = false

    var title: Text { Text(AppLocalization.string("Arrange your bots")) }

    var message: Text? {
        // A Mac has no touch and hold: its menu is a right-click.
        Text(ProcessInfo.processInfo.isiOSAppOnMac
             ? AppLocalization.string("Right-click a bot for its menu. Drag it to move it, or hold it over another bot to start a room.")
             : AppLocalization.string("Touch and hold a bot for its menu. Drag it to move it, or hold it over another bot to start a room."))
    }

    var image: Image? { Image(systemName: "hand.draw") }

    var rules: [Rule] {
        [#Rule(Self.$hasBotsToArrange) { $0 == true }]
    }

    /// UI tests and the App Store screenshots run without tips, and without
    /// the inline hints that do a tip's job (the empty Group Chats' line),
    /// so what they find stays put.
    static var hiddenForTesting: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CONDUIT_UITEST"] == "1" || environment["CONDUIT_HIDE_TIPS"] == "1"
    }

    /// The person has used what the tip shows.
    static func learned() {
        BotsHomeGesturesTip().invalidate(reason: .actionPerformed)
    }
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
                BotsHomeGesturesTip.learned()
                return BotDragPayload.lift(name)
            } preview: {
                preview()
            }
        } else {
            content
        }
    }
}

/// Where a bot's portrait can land: on another bot, the grid's end, or the
/// room being started. It proposes a move, where a plain drop destination
/// proposes a copy, so the bot in hand showed a + from the moment it was
/// lifted (Eric, 2026-11-06). A dragged room passes by, and text only lands
/// when it carries a portrait's mark.
struct LiftedBotDrop: DropDelegate {
    var entered: () -> Void = {}
    var exited: () -> Void = {}
    /// Where the bot in hand is as it moves: documented to be in the drop
    /// target's own space; a portrait cell checks (BotDragPayload.cellPoint).
    var updated: (CGPoint) -> Void = { _ in }
    let perform: (String) -> Bool

    /// A portrait in hand, or, should the drag have let go of the name it
    /// set as it began, any text, read for a portrait's mark as it lands.
    /// Never a room's tile.
    func validateDrop(info: DropInfo) -> Bool {
        guard RoomDragPayload.lifted == nil else { return false }
        return BotDragPayload.lifted != nil || info.hasItemsConforming(to: [UTType.text])
    }

    func dropEntered(info: DropInfo) { entered() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        BotDragPayload.seen()
        RoomDragPayload.seen()
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        updated(info.location)
        // A move only for our own portrait: text from elsewhere is a copy,
        // so its source never deletes what this may not take.
        return DropProposal(operation: BotDragPayload.lifted != nil ? .move : .copy)
    }

    func dropExited(info: DropInfo) { exited() }

    func performDrop(info: DropInfo) -> Bool {
        if BotDragPayload.isLive, let dragged = BotDragPayload.lifted {
            BotDragPayload.lifted = nil
            // The target reads its own hover state first (a merge), then
            // ends it.
            let landed = perform(dragged)
            exited()
            return landed
        }
        // Past its item, the portrait in hand is only a guess: read the
        // drop's own text (a portrait's carries its mark).
        BotDragPayload.lifted = nil
        exited()
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        let perform = perform
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let dragged = BotDragPayload.botName(from: text) else { return }
            DispatchQueue.main.async { _ = perform(dragged) }
        }
        return true
    }
}

/// A bot's cell on Bots Home, the space its drop reports locations in.
enum BotPortraitCellSpace {
    static let name = "botPortraitCell"
}

/// What a dragged portrait carries.
enum BotDragPayload {
    /// How long a dragged bot stays over another's face before letting go
    /// starts a room instead of moving it (as making a folder on the Home
    /// Screen).
    static var mergeDwell: Duration { .milliseconds(500) }
    /// How long a portrait or room tile in hand waits over another before
    /// taking its place, so one carried past on the way elsewhere moves
    /// nothing (the Home Screen's pause); shorter than `mergeDwell`.
    static var slideDwell: Duration { .milliseconds(300) }

    /// How far the bot in hand may drift and still count as held still over
    /// a face: a move further starts the dwell again, so a bot carried
    /// across faces to reorder never swells one (Eric, 2026-11-06: reordering
    /// kept starting rooms instead).
    static let mergeStillness: CGFloat = 12

    /// How far past a face's edge, above and beside it, a hold still
    /// starts a room: a bot carried in slows down before it gets to the
    /// face, and held there it would otherwise take the face's place and
    /// slide it away (Eric, 2026-11-06, TestFlight: holding over a face
    /// never started a room).
    static let mergeMargin: CGFloat = 14

    /// Where a merge needs the bot held: the face and a ring around it, not
    /// the gaps between cells or the name under the face, where it moves.
    static func mergeZone(face: CGRect) -> CGRect {
        CGRect(x: face.minX - mergeMargin, y: face.minY - mergeMargin,
               width: face.width + mergeMargin * 2, height: face.height + mergeMargin)
    }

    /// A drop's location in the cell's own space. `DropInfo.location` is
    /// documented to be in the drop view's space, but holding a bot over a
    /// face never swelled it on a phone (Eric, 2026-11-06, TestFlight), which
    /// is what a location in the window's space would do. A drop target only
    /// hears hovers over itself, so a point outside the cell's own bounds that
    /// lies in its frame in the window shows the locations come in the
    /// window's space; from then on every one is read that way, even one that
    /// would also fit the cell's own bounds (a first-row cell near the
    /// window's corner). Until then a point inside them is taken as documented.
    static func cellPoint(_ location: CGPoint, cellInWindow: CGRect) -> CGPoint {
        cellPoint(location, cellInWindow: cellInWindow, windowSpace: &locationsInWindowSpace)
    }

    /// Whether a drop location has shown it came in the window's space.
    static var locationsInWindowSpace = false

    static func cellPoint(_ location: CGPoint, cellInWindow: CGRect, windowSpace: inout Bool) -> CGPoint {
        guard cellInWindow.size != .zero, cellInWindow.contains(location) else { return location }
        if !windowSpace {
            if CGRect(origin: .zero, size: cellInWindow.size).contains(location) { return location }
            windowSpace = true
        }
        return CGPoint(x: location.x - cellInWindow.minX, y: location.y - cellInWindow.minY)
    }

    /// Whether the hover at `location` keeps the dwell that began at
    /// `anchor` going.
    static func staysStill(_ location: CGPoint, from anchor: CGPoint) -> Bool {
        hypot(location.x - anchor.x, location.y - anchor.y) <= mergeStillness
    }

    /// How long after a merge-ready hover ends its drop still merges: the
    /// hover ends as the drop begins, before the drop is handed over.
    static let mergeDropGrace: TimeInterval = 1

    /// Whether a drop merges: the face is still swollen, or it was until
    /// the drop ended the hover a moment ago.
    static func dropMerges(mergeReady: Bool, endedAt: Date?, now: Date = Date()) -> Bool {
        if mergeReady { return true }
        guard let endedAt else { return false }
        return now.timeIntervalSince(endedAt) < mergeDropGrace
    }

    /// Whether a drop on a portrait does anything: a bot that already slid
    /// into its place stays there (dropped again it would move back), but
    /// one held still for a room since still starts it.
    static func dropActs(placed: Bool, merges: Bool) -> Bool {
        !placed || merges
    }

    static let prefix = "conduit-bot:"

    /// The bot whose portrait is being dragged, set as its drag starts.
    /// It counts while the drag's item provider lives, or a drop target saw
    /// it within `liftedGrace` (`seen()`): the system can let go of the
    /// provider before the drag ends (Eric, 2026-11-06: a + came back now
    /// and then). A drop trusts it only while the provider lives
    /// (`isLive`), so a cancelled drag leaves no name for a later drag from
    /// another app to borrow.
    static var lifted: String? {
        get { lifted(at: Date()) }
        set {
            liftedName = newValue
            liftedSeenAt = Date()
            if newValue == nil { liftedProvider = nil }
        }
    }
    private static var liftedName: String?
    private static weak var liftedProvider: NSItemProvider?
    private static var liftedSeenAt = Date.distantPast

    /// How long a drag no drop target has seen still counts as in hand once
    /// its provider is gone; a cancelled drag is forgotten after it.
    static let liftedGrace: TimeInterval = 3

    static func lifted(at now: Date) -> String? {
        guard let liftedName else { return nil }
        if liftedProvider != nil { return liftedName }
        return now.timeIntervalSince(liftedSeenAt) < liftedGrace ? liftedName : nil
    }

    /// A drop target saw the drag in hand: it still counts for a while.
    static func seen(at now: Date = Date()) {
        if lifted(at: now) != nil { liftedSeenAt = now }
    }

    /// Whether the drag that set `lifted` still holds its item. Only then
    /// is a drop surely that portrait; a drop within the grace alone is
    /// read from its own text, so a foreign drop never borrows the name.
    static var isLive: Bool { liftedName != nil && liftedProvider != nil }

    /// Starts a portrait's drag: its item, and the name the portraits read.
    static func lift(_ name: String) -> NSItemProvider {
        // A bot in hand isn't a room, whatever an earlier room drag left.
        RoomDragPayload.lifted = nil
        let provider = NSItemProvider(object: payload(for: name) as NSString)
        liftedName = name
        liftedSeenAt = Date()
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

/// What a bot's status line on Bots Home says: what needs the user first,
/// then what's working, else nothing. It never names the policy: that's a
/// setting, in Edit Bot.
enum BotPortraitStatus: Equatable {
    case needsYou(Int)
    /// Answering another bot's ask (an open ask_in), by that bot's name.
    case helping(String)
    case working(Int)
    /// Talking in group rooms now (their driver works), by room name,
    /// talked in last first.
    case inRooms([String])
    /// Its own ask to another bot is unanswered (an ask_out waiting).
    case waitingOn(String)
    case idle

    /// What needs the user first, then helping another bot, its own work,
    /// talking in a room, and waiting on another bot. `rooms`: the talking
    /// rooms it's in, which show without the plugin's workstreams too.
    static func of(_ snapshot: BotWorkSnapshot?, talkingIn rooms: [String] = []) -> BotPortraitStatus {
        let quiet: BotPortraitStatus = rooms.isEmpty ? .idle : .inRooms(rooms)
        guard let snapshot, snapshot.isOn else { return quiet }
        if snapshot.needsYouCount > 0 { return .needsYou(snapshot.needsYouCount) }
        if let ask = snapshot.items.first(where: {
            $0.kind == .askIn && !$0.isClosed && ["starting", "running"].contains($0.status) && !$0.otherBot.isEmpty
        }) {
            return .helping(ask.otherBot)
        }
        if snapshot.workingCount > 0 { return .working(snapshot.workingCount) }
        if !rooms.isEmpty { return quiet }
        if let ask = snapshot.items.first(where: {
            $0.kind == .askOut && !$0.isClosed && $0.status == "waiting" && !$0.otherBot.isEmpty
        }) {
            return .waitingOn(ask.otherBot)
        }
        return quiet
    }

    /// The other bot of a hand-off, by the name it had when it asked.
    var otherBot: String? {
        switch self {
        case .helping(let name), .waitingOn(let name): return name
        default: return nil
        }
    }

    /// That bot among `bots`, by its name or the profile's; nil once it's
    /// renamed or gone.
    func otherBot(in bots: [BotProfile]) -> BotProfile? {
        guard let name = otherBot else { return nil }
        return bots.first { $0.displayLabel == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var title: String {
        switch self {
        case .needsYou(let count): return AppLocalization.string("\(count) needs you")
        case .helping(let name): return AppLocalization.string("Helping \(name)")
        case .working(let count): return AppLocalization.string("\(count) working")
        case .inRooms(let rooms) where rooms.count == 1: return AppLocalization.string("In \(rooms[0])")
        case .inRooms(let rooms): return AppLocalization.string("In \(rooms.count) rooms")
        case .waitingOn(let name): return AppLocalization.string("Waiting on \(name)")
        // Idle says nothing: the portrait's still ring says it.
        case .idle: return ""
        }
    }

    var tint: Color {
        switch self {
        case .needsYou: return .orange
        case .helping, .working, .inRooms: return .conduitAccent
        case .waitingOn, .idle: return .secondary
        }
    }

    var symbol: String? {
        switch self {
        case .needsYou: return "exclamationmark.circle.fill"
        case .helping: return "arrowshape.turn.up.left.fill"
        case .working: return "arrow.triangle.2.circlepath"
        case .inRooms: return "bubble.left.and.bubble.right.fill"
        case .waitingOn: return "hourglass"
        case .idle: return nil
        }
    }
}

/// One bot on Bots Home: its portrait in its own color, its name with an ⓘ,
/// and its status. The portrait and name open the Bot Chat; the ⓘ opens the
/// overview, and so does the status pill when it says something (a tap on
/// "Needs you" goes to what needs the user). Idle shows nothing there. A
/// long press has the Bots list's row menu.
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
    /// face long enough to start (or join) a room, else it takes this
    /// one's place.
    var onDrop: ((_ dragged: String, _ merge: Bool) -> Void)?
    /// Whether the bot being dragged can start a room with this one: never
    /// with itself, nor when either is hidden or rooms can't start here.
    /// Without it the face never swells, and a drop only moves.
    var canMerge: ((_ dragged: String) -> Bool)?
    /// A bot held over this one a moment, off its face and the ring around
    /// it (or anywhere, when they can't make a room): it takes this one's place
    /// while still in hand.
    var onSlide: ((_ dragged: String) -> Void)?
    var onToggleRoom: (() -> Void)?
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2OpenBeside) private var openBeside
    @Environment(\.v2Shell) private var shell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// A dragged bot is over this one; `mergeReady` once it has been held
    /// still over the face (or just beside it) for half a second
    /// (BotDragPayload.mergeDwell, mergeStillness, mergeZone).
    @State private var isTargeted = false
    @State private var mergeReady = false
    /// The wait before the bot in hand takes this one's place.
    @State private var slide: Task<Void, Never>?
    /// The bot in hand already took this one's place: let go here, it
    /// stays where it went rather than moving again.
    @State private var placed = false
    /// Where the bot in hand was when the slide's wait began: carried on
    /// further, the wait starts again, so passing over on the way to a
    /// face never slides it away (Eric, 2026-11-06).
    @State private var slideAnchor: CGPoint?
    /// When a merge-ready hover ended. A drop ends the hover before it
    /// lands, so the drop reads this rather than `mergeReady`, which has
    /// already gone (Eric 2026-11-04: dropping a bot on another never
    /// started a room).
    @State private var mergeReadyEndedAt: Date?
    @State private var dwell: Task<Void, Never>?
    /// Where the dwell over the face began; a move away starts it again.
    @State private var dwellAnchor: CGPoint?
    /// The face, in the cell's own space (where a drop's location is).
    @State private var faceFrame: CGRect = .zero
    /// The cell's frame in the window, to read a drop's location in
    /// (BotDragPayload.cellPoint).
    @State private var cellInWindow: CGRect = .zero
    @Environment(\.scenePhase) private var scenePhase
    /// Low Power Mode as it changes, so the motion stops when it turns on.
    @ObservedObject private var devicePower = DevicePowerState.shared
    @Environment(\.botsHomeCovered) private var covered
    /// When the bot last finished something (its ready count went up),
    /// for the ripple; nil once it has settled.
    @State private var finishedAt: Date?
    @State private var finishPending = false

    /// Without the plugin's workstreams, nothing to show, even if a read
    /// from before is still kept (the overview hides Work then too).
    private var status: BotPortraitStatus {
        .of(appState.servesBotWorkstreams ? work.snapshot(bot.name) : nil,
            talkingIn: appState.talkingRooms(of: bot.name).map(\.name))
    }

    private var color: Color { appState.botColor(bot) }

    /// Beside its open Bot Chat on a split window.
    private var selection: V2RowSelection {
        .chat(isActive: appState.activeBotChatProfile == bot.name, beside: openBeside, faintAlone: false)
    }

    var body: some View {
        let status = status
        VStack(spacing: 2) {
            Button(action: tapped) {
                portrait(status)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .contextMenu { menu }
            .modifier(BotPortraitDrag(name: bot.name, enabled: onDrop != nil) {
                // A drag preview is drawn outside the view's environment:
                // without AppState handed in, a long press crashed as the
                // lift began (build 248).
                BotMonogramView(bot: bot, size: 64)
                    .environmentObject(appState)
            })
            .accessibilityLabel(Text(bot.displayLabel))
            .accessibilityValue(Text(accessibilityValue(status)))
            .accessibilityHint(Text(portraitHint))
            .accessibilityAction(named: Text(AppLocalization.string("Overview"))) { onOverview() }
            .v2SelectedTrait(selection)

            // The name, and the ⓘ beside it; at accessibility sizes the ⓘ
            // goes to the status line so the name keeps the cell's width.
            HStack(spacing: 0) {
                Button(action: tapped) {
                    Text(bot.displayLabel)
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .contextMenu { menu }
                // The portrait says it, name and all.
                .accessibilityHidden(true)
                if !typeSize.isAccessibilitySize { infoButton }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                statusLine(status)
                if typeSize.isAccessibilitySize { infoButton }
            }
        }
        // The whole cell, pill included, takes a dropped bot, so a drop
        // under a face lands there rather than at the end.
        // A move, not a copy, so the bot in hand shows no +; the face it's
        // over swells for a merge instead (LiftedBotDrop).
        .coordinateSpace(name: BotPortraitCellSpace.name)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cellInWindow = $0 }
        .onDrop(of: [UTType.text], delegate: LiftedBotDrop(
            entered: { if onDrop != nil { beginTargeting() } },
            exited: { if onDrop != nil { endTargeting() } },
            updated: { location in if onDrop != nil { hover(at: location) } }
        ) { dragged in
            guard let onDrop else { return false }
            // Back on its own place: taken here and left where it was.
            guard dragged.caseInsensitiveCompare(bot.name) != .orderedSame else { return true }
            let merge = BotDragPayload.dropMerges(mergeReady: mergeReady, endedAt: mergeReadyEndedAt)
            // It already slid into this one's place: as a move it stays
            // there, but held still since for a room, the room still starts
            // (a slide across pinned bots may have moved nothing).
            if !BotDragPayload.dropActs(placed: placed, merges: merge) {
                endTargeting()
                mergeReadyEndedAt = nil
                return true
            }
            endTargeting()
            // After endTargeting, which stamps it when the hover hadn't
            // ended yet: this drop has used it.
            mergeReadyEndedAt = nil
            onDrop(dragged, merge)
            return true
        })
        // The pill's words: read once each time Bots Home shows or
        // connects, not polled (the Bot Chat and its overview poll).
        // The shell keeps a visited tab mounted, so the tab showing again is
        // part of the key.
        .task(id: "\(bot.name)\u{1F}\(appState.isConnected)\u{1F}\(appState.servesBotWorkstreams)\u{1F}\(shell.isTabActive)") {
            guard shell.isTabActive else { return }
            await appState.refreshBotWork(profile: bot.name)
        }
        .onChange(of: work.snapshot(bot.name)?.readyCount) { old, new in
            if let old, let new, new > old { noteFinished() }
        }
        .onChange(of: isShown) { _, shown in
            if shown && finishPending { noteFinished() }
        }
    }

    /// The portrait's and the name's tap: the Bot Chat, or, while a room is
    /// being started, in or out of it.
    private func tapped() {
        Haptics.light()
        if room != .off, let onToggleRoom {
            onToggleRoom()
            return
        }
        appState.beginOpeningBotChat(bot.name)
        // This chat grows out of this portrait (BotZoomDestination),
        // unless it opens beside the list, or doesn't open.
        if openBeside == nil { appState.botZoom.tap(bot.name) }
        Task {
            if await !appState.openBotChat(for: bot) { appState.botZoom.openFailed(bot.name) }
            appState.endOpeningBotChat(bot.name)
        }
    }

    /// The ⓘ: the bot's overview, always. A small glyph with a 44-point-tall
    /// target that stops at the name.
    private var infoButton: some View {
        Button {
            Haptics.light()
            onOverview()
        } label: {
            Image(systemName: "info.circle")
                .scaledFont(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                // A 44-point square target that takes 30 points of the row:
                // drawn over the name's button, it wins the overlap.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .fixedSize()
        .padding(.horizontal, -7)
        .help(AppLocalization.string("Overview"))
        .accessibilityLabel(Text(AppLocalization.string("\(bot.displayLabel)’s overview")))
        .accessibilityIdentifier("bots.overview.\(bot.name)")
    }

    /// What the bot is doing: nothing when idle (its still ring says so),
    /// in the same height so a row doesn't jump when a bot starts work;
    /// anything else a pill that opens the overview, where its work is. VoiceOver hears it as the
    /// portrait's value, and the ⓘ opens the overview.
    @ViewBuilder
    private func statusLine(_ status: BotPortraitStatus) -> some View {
        if status == .idle {
            Color.clear
                .frame(width: 1, height: 44)
                .accessibilityHidden(true)
        } else {
            Button {
                Haptics.light()
                onOverview()
            } label: {
                pill(status)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityHidden(true)
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
        placed = false
        mergeReady = false
        mergeReadyEndedAt = nil
        dwell?.cancel()
        dwellAnchor = nil
    }

    /// The bot in hand moved over this cell, as on the Home Screen: held
    /// still over the face (or just beside it) for `mergeDwell`, it swells for a
    /// room (a folder there); carried on, the dwell starts again and a
    /// swollen face lets go. Off the face and the ring around it, or when the two
    /// can't make a room, it takes this one's place after `slideDwell` and
    /// the others slide aside, while it's still in hand.
    private func hover(at reported: CGPoint) {
        guard isTargeted, let lifted = BotDragPayload.lifted else { return }
        let location = BotDragPayload.cellPoint(reported, cellInWindow: cellInWindow)
        guard canMerge?(lifted) == true, BotDragPayload.mergeZone(face: faceFrame).contains(location) else {
            dwell?.cancel()
            dwell = nil
            dwellAnchor = nil
            if mergeReady {
                // Moved off the face: this drop moves, it doesn't merge.
                mergeReadyEndedAt = nil
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { mergeReady = false }
            }
            beginSlide(lifted, at: location)
            return
        }
        // Over the face: a room, not a move, unless it's
        // carried off again.
        slide?.cancel()
        slide = nil
        slideAnchor = nil
        if let anchor = dwellAnchor, BotDragPayload.staysStill(location, from: anchor) { return }
        if mergeReady {
            // Carried on across a swollen face: it lets go, and a drop now
            // moves until the bot is held still again.
            mergeReadyEndedAt = nil
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { mergeReady = false }
        }
        dwellAnchor = location
        dwell?.cancel()
        dwell = Task { @MainActor in
            try? await Task.sleep(for: BotDragPayload.mergeDwell)
            // The same bot still in hand: a drag that ended unseen never
            // swells a face for a later drop.
            guard !Task.isCancelled, isTargeted, BotDragPayload.lifted == lifted else { return }
            Haptics.medium()
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { mergeReady = true }
        }
    }

    /// Starts the wait before `lifted` takes this one's place, held still
    /// (`mergeStillness`) for `slideDwell`: passing over on the way
    /// somewhere, a face included, moves nothing.
    private func beginSlide(_ lifted: String, at location: CGPoint) {
        // Once it has slid here, staying over this one moves nothing more.
        guard !placed, let onSlide else { return }
        // Held still: the wait already running goes on. Carried on: it
        // starts again from here.
        if slide != nil, let anchor = slideAnchor, BotDragPayload.staysStill(location, from: anchor) { return }
        slide?.cancel()
        slideAnchor = location
        slide = Task { @MainActor in
            try? await Task.sleep(for: BotDragPayload.slideDwell)
            guard !Task.isCancelled, isTargeted, BotDragPayload.lifted == lifted else { return }
            slide = nil
            placed = true
            onSlide(lifted)
        }
    }

    private func endTargeting() {
        if mergeReady { mergeReadyEndedAt = Date() }
        dwell?.cancel()
        dwell = nil
        slide?.cancel()
        slide = nil
        slideAnchor = nil
        // `placed` outlives the hover on purpose: a drop ends the hover
        // before it lands, and the drop reads it (beginTargeting clears it).
        dwellAnchor = nil
        isTargeted = false
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { mergeReady = false }
    }

    private func portrait(_ status: BotPortraitStatus) -> some View {
        let ringed = selection == .open || room == .member || mergeReady
        // 72 at the default Text Size; the monogram scales it once, up to
        // accessibility1 (about 115), so a two-column cell still holds it.
        return BotMonogramView(bot: bot, size: 72, animates: animates)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            // Where its face flies from when it joins a room being started.
            .anchorPreference(key: BotsHomeAnchorKey.self, value: .bounds) { [BotsHomeAnchorKey.bot(bot.name): $0] }
            // Where a merge's hold counts (BotDragPayload.mergeZone).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BotPortraitCellSpace.name)) } action: { faceFrame = $0 }
            .padding(4)
            .modifier(BotZoomSource(name: bot.name))
            .modifier(BotPortraitMotion(
                status: status,
                color: mergeReady ? Color.conduitAccent : color,
                highlighted: ringed,
                animates: animates,
                finishedAt: finishedAt,
                askerColor: askerColor(status)
            ))
            .scaleEffect(mergeReady ? 1.1 : 1)
            .overlay(alignment: .topLeading) {
                // Pinned: first among the bots, as in Hermes Desktop.
                if bot.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color(.secondarySystemBackground)))
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        .offset(x: -2, y: -2)
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
                if finishedAt != nil, !isNeedsYou(status) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.green))
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 2, y: -2)
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                // Waiting on another bot: its face on the badge.
                if case .waitingOn = status, finishedAt == nil,
                   let other = status.otherBot(in: appState.shownBotRoster) {
                    BotMonogramView(bot: other, size: 24)
                        .dynamicTypeSize(.large)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if case .needsYou(let count) = status {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.orange))
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 2, y: -2)
                        // One small nudge when it first shows, and when more
                        // comes to need the user.
                        .symbolEffect(.bounce, options: .nonRepeating, value: count)
                        .accessibilityHidden(true)
                }
            }
    }

    private func askerColor(_ status: BotPortraitStatus) -> Color? {
        guard case .helping = status, let asker = status.otherBot(in: appState.shownBotRoster) else { return nil }
        return appState.botColor(asker)
    }

    private func isNeedsYou(_ status: BotPortraitStatus) -> Bool {
        if case .needsYou = status { return true }
        return false
    }

    /// Bots Home is on screen: its tab shows and nothing is pushed over it
    /// (split, the chat beside the grid leaves it showing).
    private var isShown: Bool { shell.isTabActive && !shell.isRootCovered && !covered }

    /// The portrait moves only while Bots Home is on screen and the person
    /// hasn't asked for less motion or for Low Power Mode.
    private var animates: Bool {
        isShown && scenePhase == .active && !reduceMotion
            && !devicePower.isLowPowerModeEnabled
    }

    /// A result came back (the bot's ready count went up): one ripple and a
    /// check on the badge, then still. Off screen, it waits for Bots Home
    /// to show again.
    private func noteFinished() {
        guard isShown else {
            finishPending = true
            return
        }
        finishPending = false
        let finished = Date()
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { finishedAt = finished }
        Task { @MainActor in
            try? await Task.sleep(for: BotPortraitMotion.finishShown)
            // A later finish keeps its own check up for its full time.
            guard finishedAt == finished else { return }
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { finishedAt = nil }
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
        .background(Capsule().fill(status.tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(status.tint.opacity(0.35), lineWidth: 1))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Low Power Mode as it changes, so the motion stops when it turns on.
    @ObservedObject private var devicePower = DevicePowerState.shared
    @ObservedObject var work: BotWorkStore
    let profile: String
    /// Edit Bot, for a bot that can be edited here; nil hides it.
    var onEdit: ((BotProfile) -> Void)?
    /// Its Bot Chat: opens it from Bots Home, closes the sheet over it.
    let onChat: () -> Void
    let onClose: () -> Void
    /// Runs just before its Work list opens a workstream's chat. On Bots
    /// Home it arms the zoom, so that chat, and the Bot Chat after it,
    /// shrink back into the portrait.
    var onWillOpenWork: (() -> Void)? = nil

    enum Section: Hashable {
        case work
        case artifacts
    }

    @State private var section: Section = .work
    @State private var screenTarget: BotScreenTarget?

    private var bot: BotProfile? {
        appState.shownBotRoster.first { AppState.profilesMatch($0.name, profile) }
    }

    private var botName: String {
        bot?.displayLabel ?? work.snapshot(profile)?.botName ?? appState.profileDisplayName(profile)
    }

    /// Work shows where the plugin keeps a bot's work; elsewhere the
    /// overview is its chat and its artifacts.
    private var showsWork: Bool { appState.servesBotWorkstreams }

    private var headerStatus: BotPortraitStatus {
        .of(showsWork ? work.snapshot(profile) : nil, talkingIn: appState.talkingRooms(of: profile).map(\.name))
    }

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
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                // Settings' primary button, as every sheet's.
                .buttonStyle(.settingsPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                // Without Work's picker under it, the artifacts' search
                // field comes next: room between them.
                .padding(.bottom, showsWork ? 0 : 12)
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
                    BotWorkPanel(work: work, profile: profile, onClose: onClose, showsHeader: false, onWillOpen: onWillOpenWork)
                case .artifacts:
                    BotArtifactsList(profile: profile, willShowInChat: onClose)
                }
            }
            // Settings' backdrop, as every sheet (see Sheets in Settings' look).
            .background { SettingsBackdrop().ignoresSafeArea() }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Opened from a Bot Chat too, where Bots Home doesn't ask, so the
        // header's "In <room>" doesn't go stale (a read already running
        // from Bots Home this round is shared).
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await appState.refreshTalkingRoomsIfDue(every: BotsTalkingRoomsReader.every)
                try? await Task.sleep(for: BotsTalkingRoomsReader.every)
            }
        }
        // A workstream opened from its list shows its own chat.
        .onChange(of: appState.activeSessionId) { _, _ in onClose() }
        .sheet(item: $screenTarget) { target in
            BotScreenSheet(target: target)
                .environmentObject(appState)
        }
        .accessibilityIdentifier("botOverview")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let bot {
                    // The same life as its portrait on Bots Home, its
                    // moving picture included.
                    BotMonogramView(bot: bot, size: 52, animates: true)
                        .modifier(BotPortraitMotion(
                            status: headerStatus,
                            color: appState.botColor(bot),
                            highlighted: false,
                            animates: scenePhase == .active && !reduceMotion
                                && !devicePower.isLowPowerModeEnabled,
                            finishedAt: nil,
                            askerColor: { () -> Color? in
                                guard case .helping = headerStatus,
                                      let asker = headerStatus.otherBot(in: appState.shownBotRoster) else { return nil }
                                return appState.botColor(asker)
                            }()
                        ))
                } else {
                    ProfileAvatarView(profile: profile, displayName: botName,
                                      url: appState.profileAvatarURL(for: profile), size: 52,
                                      animates: true)
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
                    // Wraps rather than cutting a count off, as a Settings
                    // row's second line does.
                    Text(verbatim: text)
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Where it talks now, as its portrait's pill says.
                let rooms = appState.talkingRooms(of: profile).map(\.name)
                if !rooms.isEmpty {
                    let inRooms = BotPortraitStatus.inRooms(rooms)
                    Label {
                        Text(verbatim: inRooms.title)
                    } icon: {
                        Image(systemName: inRooms.symbol ?? "bubble.left.and.bubble.right.fill")
                    }
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(Color.conduitAccent)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // Its screen (Bot Screen), once its host said it can have one.
            BotScreenButton(support: appState.botScreens, profile: profile, open: {
                Haptics.light()
                screenTarget = BotScreenTarget(profile: profile, botName: botName)
            }, title: AppLocalization.string("\(botName)'s Screen"), iconOnly: true)
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
            ConduitList {
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

/// Reorder Group Chats, from a room's menu: the hosted rooms as a list with
/// handles, for VoiceOver, a pointer, or anyone who'd rather not drag. The
/// same order as the tiles' drags.
struct GroupRoomReorderSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rooms = appState.shownGroupRooms
        NavigationStack {
            ConduitList {
                ForEach(rooms) { room in
                    HStack(spacing: 12) {
                        GroupRoomIcon(picture: appState.groupRoomPicture(roomID: room.roomID), members: room.members, size: 36)
                            .accessibilityHidden(true)
                        Text(verbatim: room.name)
                            .scaledFont(.body)
                    }
                }
                .onMove { source, destination in
                    appState.moveGroupRooms(fromOffsets: source, toOffset: destination, shown: rooms.map(\.roomID))
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(AppLocalization.string("Reorder Group Chats"))
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

private struct BotChatZoomedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// This chat grew out of its portrait on Bots Home. The zoom's own
    /// swipe back starts only where the transcript has no text, so the chat
    /// adds one that starts anywhere (V2ConversationScreen).
    var botChatZoomed: Bool {
        get { self[BotChatZoomedKey.self] }
        set { self[BotChatZoomedKey.self] = newValue }
    }
}

/// The portrait the chat grows from: a circle, keyed by its bot, or by
/// its room (`BotZoomArm.roomKey`). No key: no source.
struct BotZoomSource: ViewModifier {
    let name: String?
    @Environment(\.botZoomNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace, let name, !reduceMotion {
            // The source is a copy behind the portrait, not the portrait:
            // iOS hides a zoom's source while it runs, and on a phone a
            // source sometimes stayed hidden afterwards, leaving empty rings
            // on Bots Home (build 248). The copy draws the same picture, so
            // the chat still grows out of it.
            content.background {
                GeometryReader { proxy in
                    content
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .matchedTransitionSource(id: name, in: namespace) { source in
                            // Only a RoundedRectangle may clip a source: half
                            // the portrait's side is its circle.
                            source.clipShape(RoundedRectangle(
                                cornerRadius: min(proxy.size.width, proxy.size.height) / 2))
                        }
                }
            }
        } else {
            content
        }
    }
}

/// A Bot Chat or a room pushed in the Bots stack: it zooms from its bot's
/// or its room's portrait. Any other page, a plain session, or Reduce
/// Motion: the usual push.
struct BotZoomDestination: ViewModifier {
    let route: V2Route
    let namespace: Namespace.ID
    /// The chat was pushed on Bots Home itself, where its portrait shows.
    let fromHome: Bool
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // A workstream opened from the Bot Chat shows in the same pushed
        // screen: it counts as its bot's, so the zoom holds through the
        // visit and Back still shrinks the Bot Chat home. A transition
        // changed on a pushed screen leaves Back with no animation.
        if #available(iOS 18.0, *), route == .conversation, fromHome, !reduceMotion,
           let source = appState.botZoom.source(open: appState.botZoomRoomKey
                ?? appState.activeBotChatProfile ?? appState.activeWorkstream?.profile) {
            content
                .navigationTransition(.zoom(sourceID: source, in: namespace))
                .environment(\.botChatZoomed, true)
        } else {
            content
        }
    }
}

/// Which Bot Chat or room grows out of its portrait, by its key: a bot's
/// name, or `roomKey` for a room. A portrait's tap arms it for a
/// few seconds; the push that follows takes it, and it lasts while that
/// chat is in the Bots stack, so Back shrinks it home. A Bot Chat a
/// notification, widget, Shortcut, call or link opens finds nothing armed
/// and pushes as usual, and so does any open once the arm has gone stale.
struct BotZoomArm: Equatable {
    /// How long a tap waits for its chat to be pushed.
    static let window: TimeInterval = 3

    /// A room's key, apart from any bot's name.
    static func roomKey(_ roomID: String) -> String { "room:" + roomID }

    private(set) var tapped: String?
    private(set) var tappedAt: Date?
    /// The bot whose chat is in the Bots stack, grown from its portrait.
    private(set) var zooming: String?
    /// Its chat has landed (it is the open Bot Chat). The shell pushes the
    /// conversation as the list closes, before the open lands, while the
    /// chat open before is still the active one (#1700), so until then the
    /// zoom holds whatever chat is named open.
    private(set) var landed = false

    mutating func tap(_ name: String, now: Date = Date()) {
        tapped = name
        tappedAt = now
    }

    /// Its open failed: only this tap's arm goes, and a push it made that
    /// never landed zooms no more.
    mutating func openFailed(_ name: String) {
        if tapped == name {
            tapped = nil
            tappedAt = nil
        }
        if zooming == name && !landed { zooming = nil }
    }

    /// The Bots stack now shows a conversation: a fresh tap's chat zooms
    /// until it leaves, whichever chat is still named open; otherwise
    /// nothing does.
    mutating func pushed(open: String?, now: Date = Date()) {
        zooming = freshTap(now: now) ?? source(open: open, now: now)
        landed = Self.same(zooming, open)
        tapped = nil
        tappedAt = nil
    }

    /// `open` is now the open Bot Chat. Another bot's chat landing first
    /// (a notification's, a link's) means the push carried that one: it
    /// zooms no more.
    mutating func opened(_ open: String?) {
        if Self.same(zooming, open) {
            landed = true
        } else if open != nil, zooming != nil, !landed {
            zooming = nil
        }
    }

    /// The chat left the Bots stack, or closed.
    mutating func left() {
        self = BotZoomArm()
    }

    /// The portrait name the pushed chat grows from (its source key), or
    /// nil for the usual push. Before the tapped chat lands, `open` is
    /// still the chat open before it.
    func source(open: String?, now: Date = Date()) -> String? {
        if let zooming { return !landed || Self.same(zooming, open) ? zooming : nil }
        return freshTap(now: now)
    }

    private func freshTap(now: Date) -> String? {
        guard let tapped, let tappedAt, now.timeIntervalSince(tappedAt) < Self.window else { return nil }
        return tapped
    }

    private static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}

extension AppState {
    /// The open room's zoom key (`BotZoomArm.roomKey`): a room shows over
    /// the chat under it, so it comes before the open Bot Chat.
    var botZoomRoomKey: String? {
        activeRoomSurface.map { BotZoomArm.roomKey($0.room.roomID) }
    }
}

/// A portrait's life (Eric, 2026-11-03): still when idle; a comet of the
/// bot's color circling the ring while it works; a slow orange breath when
/// something needs the user; one ripple when a result comes back. With
/// `animates` off (Reduce Motion, Low Power Mode, Bots Home off screen)
/// every state is still: a bright ring for working, the orange ring for
/// needs you, and the check alone for finished.
struct BotPortraitMotion: ViewModifier {
    let status: BotPortraitStatus
    let color: Color
    /// Ringed in the accent: the open chat beside the list, a bot in the
    /// room being started, or a drop about to start one.
    let highlighted: Bool
    let animates: Bool
    let finishedAt: Date?
    /// Helping another bot: that bot's color, a stripe in the comet.
    var askerColor: Color? = nil

    /// One lap of the working comet.
    static let lap: Double = 6
    /// One breath of needs you.
    static let breath: Double = 2.6
    /// The finished ripple, and how long the check shows.
    static let ripple: Double = 1.2
    static let finishShown: Duration = .milliseconds(1600)

    private var isWorking: Bool {
        switch status {
        case .working, .helping: return true
        default: return false
        }
    }
    private var isNeedsYou: Bool { if case .needsYou = status { return true } else { return false } }
    private var isWaiting: Bool { if case .waitingOn = status { return true } else { return false } }

    func body(content: Content) -> some View {
        let moving = animates && (isWorking || isNeedsYou || isWaiting || finishedAt != nil)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 0 to 1 and back, once a breath.
            let breath: CGFloat = animates && isNeedsYou ? CGFloat(1 - cos(t / Self.breath * 2 * .pi)) / 2 : 0
            let lap = Angle.degrees((t / Self.lap).truncatingRemainder(dividingBy: 1) * 360)
            content
                .overlay { ring(lap: lap) }
                .shadow(color: glowColor.opacity(glowOpacity(breath)), radius: isNeedsYou ? 14 + 6 * breath : 14)
                .scaleEffect(1 + 0.04 * breath)
                .overlay { ripple(now: context.date) }
        }
    }

    private var glowColor: Color {
        if highlighted { return .conduitAccent }
        return isNeedsYou ? .orange : color
    }

    private func glowOpacity(_ breath: CGFloat) -> Double {
        if isNeedsYou { return 0.3 + 0.4 * Double(breath) }
        if isWorking { return animates ? 0.3 : 0.45 }
        return highlighted ? 0.45 : 0
    }

    @ViewBuilder
    private func ring(lap: Angle) -> some View {
        if highlighted {
            Circle().strokeBorder(Color.conduitAccent, lineWidth: 3)
        } else if isNeedsYou {
            Circle().strokeBorder(Color.orange, lineWidth: 2.5)
        } else if isWorking && animates {
            ZStack {
                Circle().strokeBorder(color.opacity(0.35), lineWidth: 2)
                Circle()
                    .strokeBorder(
                        AngularGradient(gradient: Gradient(stops: cometStops), center: .center),
                        lineWidth: 3
                    )
                    .rotationEffect(lap)
                    .shadow(color: color.opacity(0.8), radius: 4)
            }
        } else if isWorking {
            Circle().strokeBorder(color, lineWidth: 2.5)
        } else if isWaiting {
            // Slow dashes: it waits on another bot, whose face is on the
            // badge. They creep round while Bots Home shows.
            Circle()
                .inset(by: 1)
                .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 6],
                                                                dashPhase: animates ? -CGFloat(lap.degrees / 360) * 44 : 0))
        } else {
            Circle().strokeBorder(color.opacity(0.45), lineWidth: 2)
        }
    }

    /// The comet's tail: the bot's color, led by the asking bot's when it
    /// helps another.
    private var cometStops: [Gradient.Stop] {
        guard let askerColor else {
            return [.init(color: color.opacity(0), location: 0), .init(color: color.opacity(0), location: 0.55),
                    .init(color: color, location: 0.97), .init(color: color.opacity(0), location: 1)]
        }
        return [.init(color: askerColor.opacity(0), location: 0), .init(color: askerColor.opacity(0), location: 0.5),
                .init(color: askerColor, location: 0.8), .init(color: color, location: 0.96),
                .init(color: color.opacity(0), location: 1)]
    }

    @ViewBuilder
    private func ripple(now: Date) -> some View {
        if animates, let finishedAt {
            let progress = CGFloat(min(max(now.timeIntervalSince(finishedAt) / Self.ripple, 0), 1))
            Circle()
                .stroke(Color.green, lineWidth: 2)
                .scaleEffect(1 + 0.9 * progress)
                .opacity(0.9 * (1 - progress))
                .allowsHitTesting(false)
        }
    }
}
