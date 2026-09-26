import SwiftUI

/// One hosted Group Chat room. A room is NOT a session: this surface reads
/// `appState.activeRoomSurface`'s replay and sends through `groups.send`,
/// while the gateway's driver owns every member turn. The composer never
/// waits on a bot; the room updates as polled events arrive.
struct GroupChatView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var draft = ""
    @State private var showingDisbandConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .toolbar { toolbarContent }
        .confirmationDialog(
            AppLocalization.string("Disband this group chat?"),
            isPresented: $showingDisbandConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Disband"), role: .destructive) {
                Task { await appState.disbandActiveRoom() }
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string(
                "The room, its history, and every member's session end permanently. This cannot be undone."
            ))
        }
    }

    private var surface: AppState.GroupRoomSurface? { appState.activeRoomSurface }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(appState.activeRoomReplay.events) { event in
                        GroupEventRow(event: event, members: surface?.room.members ?? [])
                    }
                    if let pending = appState.pendingRoomMessage {
                        GroupChatBubble(
                            alignment: .trailing,
                            speaker: AppLocalization.string("You"),
                            timestamp: nil,
                            tint: .conduitAccent.opacity(0.14)
                        ) {
                            Text(pending.text)
                                .foregroundStyle(.primary)
                            if appState.activeRoomSendInFlight {
                                Text(AppLocalization.string("Sending…"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                // Ambiguous outcome: the message may or may
                                // not have landed. Retry reuses the SAME
                                // event id, so the gateway deduplicates —
                                // never a twin message.
                                Button {
                                    Task { await appState.sendGroupRoomMessage(pending.text) }
                                } label: {
                                    Label(
                                        AppLocalization.string("Not delivered — retry"),
                                        systemImage: "arrow.clockwise"
                                    )
                                    .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .id("pending-row")
                    }
                    if appState.activeRoomReplay.events.isEmpty && appState.pendingRoomMessage == nil {
                        Text(AppLocalization.string("No messages yet. Say something to the room."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 32)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: appState.activeRoomReplay.cursor) { _, _ in
                if let last = appState.activeRoomReplay.events.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                } else {
                    proxy.scrollTo("pending-row", anchor: .bottom)
                }
            }
            .onAppear {
                if let last = appState.activeRoomReplay.events.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .background(Color.clear)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if appState.pendingRoomMessage != nil, !appState.activeRoomSendInFlight {
                // The pending row owns the composer; say why Send is off
                // instead of leaving a silently disabled button.
                Text(AppLocalization.string(
                    "Your previous message is still pending. Retry it from the room, or wait for it to deliver."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
            }
            if let error = appState.errorMessage, !error.isEmpty {
                // The session surface's error banner lives inside ChatView,
                // which this room surface replaces — room errors must render
                // HERE, or every failure below is invisible.
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    AppLocalization.string("Message the room"),
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .submitLabel(.send)
                .onSubmit { sendDraft() }

                Button {
                    sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(canSend ? Color.conduitAccent : Color.secondary.opacity(0.4))
                }
                .disabled(!canSend)
                .accessibilityLabel(Text(AppLocalization.string("Send")))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appState.activeRoomSendInFlight
            // An ambiguous-outcome pending message owns the composer: retry
            // it explicitly (same event id) or it stays visible — a NEW
            // message typed meanwhile would be silently swallowed.
            && appState.pendingRoomMessage == nil
            && appState.groupCapabilities?.supports("groups.send") == true
            && surface?.room.isDisbanded == false
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Haptics.light()
        Task {
            // The pending row owns the text only once AppState REGISTERS
            // the send. A declined send (connection or room changed before
            // the guards ran) hands the text back to the composer, unless
            // the user already started typing something new.
            let registered = await appState.sendGroupRoomMessage(text)
            if !registered && draft.isEmpty {
                draft = text
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                appState.closeGroupRoom()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel(Text(AppLocalization.string("Leave this group chat")))
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(surface?.room.name ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(memberSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if appState.groupCapabilities?.supports("groups.stop") == true,
                   let driver = appState.activeRoomDriverStatus,
                   driver.running || driver.working {
                    Button {
                        Task { await appState.stopActiveRoomWork() }
                    } label: {
                        Label(AppLocalization.string("Stop"), systemImage: "stop.fill")
                    }
                }
                Button(role: .destructive) {
                    showingDisbandConfirmation = true
                } label: {
                    Label(AppLocalization.string("Disband Group"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.callout.weight(.semibold))
            }
            .accessibilityLabel(Text(AppLocalization.string("Group chat actions")))
        }
    }

    private var memberSummary: String {
        let count = surface?.room.members.count ?? 0
        if let driver = appState.activeRoomDriverStatus, driver.working {
            return AppLocalization.string("\(count) members · working…")
        }
        return AppLocalization.string("\(count) members")
    }
}

// MARK: - Event rows

/// One room-log event, rendered by actor kind: user bubbles trail, member
/// bubbles lead, and every other (or unknown future) kind is a compact
/// system caption — a room this client predates still renders, never crashes.
struct GroupEventRow: View {
    let event: GroupEvent
    let members: [GroupMember]

    var body: some View {
        if event.isUserMessage {
            GroupChatBubble(
                alignment: .trailing,
                speaker: AppLocalization.string("You"),
                timestamp: event.createdAt,
                tint: .conduitAccent.opacity(0.14)
            ) {
                mentionText
            }
        } else if event.isMemberMessage {
            GroupChatBubble(
                alignment: .leading,
                speaker: speakerLabel,
                timestamp: event.createdAt,
                tint: Color.primary.opacity(0.05)
            ) {
                mentionText
            }
        } else {
            GroupSystemEventCaption(event: event)
        }
    }

    private var speakerLabel: String {
        let label = event.actor.displayLabel(members: members)
        return label.isEmpty ? AppLocalization.string("Member") : label
    }

    /// Recognized mentions render as inline accent references; unknown
    /// `@words` and e-mail addresses stay plain (presentation mirrors the
    /// gateway's routing classification, upstream `group-mention-text`).
    private var mentionText: Text {
        GroupMentionTextRenderer.render(event.messageText ?? "", members: members)
    }
}

/// Compact caption for gateway/system/unknown room events.
struct GroupSystemEventCaption: View {
    let event: GroupEvent

    var body: some View {
        Text(caption)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
    }

    private var caption: String {
        switch event.kind {
        case "room.renamed": return AppLocalization.string("The room was renamed.")
        case "room.members_changed": return AppLocalization.string("The room's members changed.")
        case "room.disbanded": return AppLocalization.string("This room was disbanded.")
        case "turn.started": return AppLocalization.string("A member started working…")
        case "turn.settled": return AppLocalization.string("The room settled.")
        case "turn.failed": return AppLocalization.string("A member's turn failed.")
        case "turn.cancelled": return AppLocalization.string("Work was stopped.")
        case "member.unavailable": return AppLocalization.string("A member is unavailable.")
        default: return AppLocalization.string("Room updated.")
        }
    }
}

/// One chat bubble: speaker label + content, leading or trailing.
struct GroupChatBubble<Content: View>: View {
    let alignment: HorizontalAlignment
    let speaker: String
    let timestamp: Double?
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let timestamp {
                        Text(Self.timestampText(timestamp))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 320, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if alignment == .leading { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }

    static func timestampText(_ value: Double) -> String {
        let date = Date(timeIntervalSince1970: value)
        // Cached (non-generic enum: generic types cannot store static
        // properties): a fresh DateFormatter per bubble per render is
        // brutally expensive across a 200-event LazyVStack.
        return GroupBubbleTimeFormatter.shared.string(from: date)
    }
}

/// MainActor-confined view code, so the shared formatter is safe.
private enum GroupBubbleTimeFormatter {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Mention text rendering

enum GroupMentionTextRenderer {
    /// Split `text` into plain prose and recognized mention spans. Kind tints
    /// differ: agent mentions (member handles), broadcast (@all/@everyone),
    /// and the human handoff (@user).
    static func render(_ text: String, members: [GroupMember]) -> Text {
        var attributed = AttributedString(text)
        guard let regex = GroupRoomMentions.mentionScanRegex else { return Text(text) }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range).reversed() {
            guard match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: text),
                  let fullRange = Range(match.range, in: text),
                  let attrRange = Range(fullRange, in: attributed) else { continue }
            let token = String(text[tokenRange])
            guard let kind = GroupRoomMentions.classify(token: token, members: members) else { continue }
            attributed[attrRange].foregroundColor = .conduitAccent
            attributed[attrRange].font = .body.weight(.semibold)
            switch kind {
            case .agent: attributed[attrRange].backgroundColor = .conduitAccent.opacity(0.10)
            case .broadcast: attributed[attrRange].backgroundColor = .orange.opacity(0.10)
            case .human: attributed[attrRange].backgroundColor = .yellow.opacity(0.12)
            }
        }
        return Text(attributed)
    }
}

// MARK: - Create sheet

/// New Group Chat: one name field plus a 2–6 bot picker restricted to the
/// current gateway's roster (cross-gateway rooms are a later parity slice).
struct GroupCreateSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var name = ""
    @State private var selected = Set<String>()
    /// The room id is minted ONCE per logical room (per sheet): a retry of
    /// an ambiguous create reuses the SAME id, so the gateway's create
    /// idempotency deduplicates instead of forking a twin room.
    @State private var roomID = GroupCreateAttempt.mintRoomID()
    /// The inputs the CURRENT `roomID` was first sent with. The id is the
    /// gateway's dedup key for exactly those inputs: a retry with an edited
    /// name or roster is a different room, so it gets a fresh id instead of
    /// recovering (or being refused as) the first attempt.
    @State private var attemptedInputs: GroupCreateAttempt.Inputs?
    @State private var isCreating = false

    private var visibleBots: [BotProfile] {
        appState.botRoster.filter { !$0.isHiddenByMeta }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selected.count >= 2 && selected.count <= 6
            && !isCreating
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = appState.errorMessage, !error.isEmpty {
                    // Create failures (handle collision, RPC refusal) must
                    // surface INSIDE the sheet — the room surface's notice
                    // is behind the dismissal.
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
                Section(AppLocalization.string("Name")) {
                    TextField(AppLocalization.string("Group name"), text: $name)
                        .submitLabel(.done)
                }
                Section {
                    ForEach(visibleBots) { bot in
                        memberToggleRow(bot)
                    }
                } header: {
                    Text(AppLocalization.string("Members (2–6)"))
                } footer: {
                    Text(AppLocalization.string(
                        "Group chats run on this gateway. The gateway drives each member's turn — closing Conduit never stops a room."
                    ))
                }
            }
            .navigationTitle(AppLocalization.string("New Group Chat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Create")) {
                        // Double-tap protection: two taps mint two ids and
                        // the gateway would host two real rooms.
                        guard !isCreating else { return }
                        isCreating = true
                        let bots = visibleBots.filter { selected.contains($0.name) }
                        let roomName = name
                        let inputs = GroupCreateAttempt.Inputs(
                            name: roomName.trimmingCharacters(in: .whitespacesAndNewlines),
                            members: selected
                        )
                        roomID = GroupCreateAttempt.roomID(
                            for: inputs, current: roomID, attempted: attemptedInputs
                        )
                        attemptedInputs = inputs
                        let pendingRoomID = roomID
                        Task {
                            let created = await appState.createGroupRoom(
                                name: roomName, bots: bots, roomID: pendingRoomID
                            )
                            isCreating = false
                            if created { dismiss() }
                        }
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }

    private func memberToggleRow(_ bot: BotProfile) -> some View {
        let isSelected = selected.contains(bot.name)
        return Button {
            toggle(bot.name)
        } label: {
            HStack(spacing: 12) {
                BotMonogramView(bot: bot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayLabel)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(bot.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                selectionGlyph(isSelected: isSelected)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectionGlyph(isSelected: Bool) -> some View {
        Group {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.conduitAccent)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private func toggle(_ botName: String) {
        Haptics.light()
        if selected.contains(botName) {
            selected.remove(botName)
        } else {
            selected.insert(botName)
        }
    }
}

// MARK: - Desktop-synced group chats

/// A roster row for a group chat Hermes Desktop created. Same card as a
/// hosted room, with the latest mirrored message as its preview.
struct DesktopGroupRosterRow: View {
    let group: DesktopGroupChat
    let onOpen: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            onOpen()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.conduitAccent.opacity(0.16))
                    Image(systemName: "person.3")
                        .font(.caption)
                        .foregroundStyle(.conduitAccent)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
        .accessibilityLabel(Text(group.name))
        .accessibilityHint(Text(AppLocalization.string("Shows this Hermes Desktop group chat.")))
    }

    private var subtitleText: String {
        if let last = group.messages.last {
            let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return AppLocalization.string("\(group.members.count) members")
    }
}

/// Read-only transcript of a Desktop group chat: the latest messages Desktop
/// mirrored to the gateway. Desktop runs the rounds for these rooms, so
/// there is no composer here — sending would need Desktop's orchestrator.
struct DesktopGroupChatView: View {
    let group: DesktopGroupChat
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared

    /// Mention styling reuses the hosted-room classifier: the projection's
    /// members carry a display name and, on current Desktop builds, the
    /// room handle.
    private var mentionMembers: [GroupMember] {
        group.members.map {
            GroupMember(
                memberID: nil,
                profile: nil,
                handle: $0.handle,
                displayName: $0.name,
                target: nil,
                extra: [:]
            )
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        Text(AppLocalization.string(
                            "Created in Hermes Desktop. Desktop runs this group's conversation, so reply from there; this shows the latest synced messages."
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 4)
                        if group.omitted > 0 {
                            Text(AppLocalization.string("Earlier messages are only in Hermes Desktop."))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(group.messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                        if group.messages.isEmpty {
                            Text(AppLocalization.string("No messages yet."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 32)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .onAppear {
                    if let last = group.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(group.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(AppLocalization.string("\(group.members.count) members"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: DesktopGroupChat.Message) -> some View {
        let speaker = message.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        GroupChatBubble(
            alignment: message.isMember ? .leading : .trailing,
            speaker: message.isMember
                ? (speaker.isEmpty ? AppLocalization.string("Member") : speaker)
                : AppLocalization.string("You"),
            timestamp: message.timestamp,
            tint: message.isMember ? Color.primary.opacity(0.05) : .conduitAccent.opacity(0.14)
        ) {
            GroupMentionTextRenderer.render(message.text, members: mentionMembers)
            if message.truncated {
                Text(AppLocalization.string("Shortened — the full message is in Hermes Desktop."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
