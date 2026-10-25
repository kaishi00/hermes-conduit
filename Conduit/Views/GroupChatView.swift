import SwiftUI
import UIKit

/// One hosted Group Chat room. A room is NOT a session: this surface reads
/// `appState.activeRoomSurface`'s replay and sends through `groups.send`,
/// while the gateway's driver owns every member turn. The composer never
/// waits on a bot; the room updates as polled events arrive.
struct GroupChatView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    /// Set by V2's conversation screen: the composer floats over the
    /// transcript under soft edges, and the header's menu holds the room's
    /// actions.
    @Environment(\.v2ComposerRests) private var isV2
    @State private var showingDisbandConfirmation = false
    @State private var choosingPicture: GroupRoomPictureRequest?
    /// Following the latest event, or browsing history (GroupRoomFollow).
    /// The flag decides scrolling; the published copy draws the button.
    @State private var followFlag = GroupRoomFollowFlag()
    @State private var isFollowingLatest = true
    /// Bumped by the jump-to-latest button; the transcript scrolls on it.
    @State private var latestJumps = 0
    /// The last row before the newest events, so a member message among
    /// them can land at its top (GroupRoomFollow.replyStart).
    @State private var lastSeenEventID: String?

    var body: some View {
        Group {
            if isV2 {
                transcript
                    .v2EdgeBar(.bottom) {
                        bottomBar
                            .modifier(V2LegacyScrollEdge(edge: .bottom))
                    }
            } else {
                VStack(spacing: 0) {
                    transcript
                    bottomBar
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.minimisedLiveVoice)
        // Each bot's color, for its name, bubble, tags and "To" chip.
        .environment(\.groupMemberTints, appState.groupMemberTints(members))
        .toolbar { toolbarContent }
        // V2's screen hosts this view and owns the room menu and picker.
        .modifier(GroupRoomPicturePicker(request: $choosingPicture, isEnabled: !isV2))
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

    private var bottomBar: some View {
        VStack(spacing: 0) {
            pendingApprovals
            MinimisedLiveVoiceBar()
            GroupRoomComposer(members: members)
        }
        .overlay(alignment: .topTrailing) {
            if !isFollowingLatest {
                jumpToLatestButton
                    .alignmentGuide(.top) { $0[.bottom] + 10 }
            }
        }
    }

    /// Shown while browsing, as on the chat screen.
    private var jumpToLatestButton: some View {
        Button {
            followLatest()
            latestJumps += 1
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 44, height: 44)
        }
        .conduitGlassControl(cornerRadius: 22, tint: Color.conduitAccent.opacity(0.14))
        .accessibilityLabel(AppLocalization.string("Scroll to latest message"))
        .padding(.trailing, 18)
    }

    private var surface: AppState.GroupRoomSurface? { appState.activeRoomSurface }

    /// Named as the bots are now, not as they were when they joined.
    private var members: [GroupMember] {
        GroupRoomTurns.members(surface?.room.members ?? [], namedBy: appState.botRoster)
    }

    /// Log events that earn a row: a member turn that posted settles
    /// silently, since its bubble already says so.
    private var visibleEvents: [GroupEvent] {
        appState.activeRoomReplay.events.filter(GroupRoomTurns.isVisible)
    }

    /// The member whose turn is running (memoized by AppState).
    private var respondingMember: GroupMember? {
        appState.activeRoomResponder.flatMap { GroupRoomTurns.members([$0], namedBy: appState.botRoster).first }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let rendered = self.visibleEvents
                LazyVStack(spacing: 14) {
                    ForEach(Array(rendered.enumerated()), id: \.element.id) { index, event in
                        // A member's run of replies shows its picture and
                        // name once, like a group thread in Messages.
                        let previous = index > 0 ? rendered[index - 1] : nil
                        GroupEventRow(
                            event: event,
                            members: members,
                            continuesRun: previous.map { GroupEventRow.sameSpeaker($0, event) } ?? false
                        )
                    }
                    if let pending = appState.pendingRoomMessage {
                        GroupUserBubble(text: pending.text, members: members, timestamp: nil) {
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
                                    // A retry keeps its event id, so the
                                    // send observer won't see it.
                                    followLatest()
                                    latestJumps += 1
                                    Task { await appState.sendGroupRoomMessage(pending.text) }
                                } label: {
                                    Label(
                                        AppLocalization.string("Not delivered — retry"),
                                        systemImage: "arrow.clockwise"
                                    )
                                    .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.conduitAccent)
                            }
                        }
                        .id("pending-row")
                    }
                    if let responder = respondingMember {
                        GroupRespondingRow(member: responder)
                            .id("responding-row")
                    }
                    if rendered.isEmpty && appState.pendingRoomMessage == nil && respondingMember == nil {
                        emptyState
                    }
                }
                .background { GroupRoomScrollLocator(flag: followFlag, isFollowing: $isFollowingLatest) }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .modifier(V2SoftTopScrollEdge(isOn: isV2))
            .simultaneousGesture(TapGesture().onEnded {
                // A tap on the transcript puts the keyboard away.
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                )
            })
            // New events and a member starting its turn move the transcript
            // only while it follows the latest; a reader scrolled up stays.
            .onChange(of: appState.activeRoomReplay.cursor) { _, _ in
                let previousLastID = lastSeenEventID
                lastSeenEventID = visibleEvents.last?.id
                guard followFlag.isFollowing else { return }
                if ChatReplyStartPreference.isOn,
                   let start = GroupRoomFollow.replyStart(in: visibleEvents, after: previousLastID) {
                    landAtTop(of: start, proxy)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { scrollToBottom(proxy) }
                }
            }
            .onChange(of: respondingMember?.identityKey) { _, _ in
                guard followFlag.isFollowing else { return }
                withAnimation(.easeOut(duration: 0.2)) { scrollToBottom(proxy) }
            }
            // Sending returns to the latest, as in a chat.
            .onChange(of: appState.pendingRoomMessage?.eventID) { _, eventID in
                guard eventID != nil else { return }
                followLatest()
                withAnimation(.easeOut(duration: 0.2)) { scrollToBottom(proxy) }
            }
            .onChange(of: latestJumps) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { scrollToBottom(proxy) }
            }
            .onAppear {
                lastSeenEventID = visibleEvents.last?.id
                followLatest()
                scrollToBottom(proxy)
            }
        }
        .background(Color.clear)
        // Cross-block selection chrome, and Quote on selected text into the
        // room's draft, as in a chat.
        .overlay { MarkdownSelectionChromeRoot() }
        // As in a chat, text draws until a touch needs its text view, and
        // a drawn bubble sizes to its text.
        .environment(\.selectableTextDrawsUntilTouched, true)
        .environment(
            \.chatQuoteAction,
            ChatQuoteAction(
                owner: appState,
                isAvailable: appState.canQuoteIntoRoom,
                handler: appState.quoteIntoRoomComposer
            )
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            GroupRoomIcon(
                picture: surface.flatMap { appState.groupRoomPicture(roomID: $0.room.roomID) },
                members: members,
                size: 56
            )
            Text(AppLocalization.string("No messages yet. Say something to the room."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private func followLatest() {
        followFlag.isFollowing = true
        isFollowingLatest = true
    }

    /// A new member message goes to the top of the screen, and the room
    /// stops following there, as a long chat reply does (#365); one that
    /// fits clamps at the bottom, where following picks up again.
    private func landAtTop(of eventID: String, _ proxy: ScrollViewProxy) {
        followFlag.isFollowing = false
        followFlag.isLanding = true
        followFlag.landingGeneration &+= 1
        let generation = followFlag.landingGeneration
        isFollowingLatest = false
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(eventID, anchor: .top) }
        // Decide from where it lands once the animation is over (it may not
        // move the offset at all).
        Task { @MainActor [followFlag] in
            try? await Task.sleep(for: .milliseconds(300))
            guard followFlag.landingGeneration == generation else { return }
            // Over even if the locator has gone (the room closed).
            followFlag.isLanding = false
            followFlag.reevaluate?()
        }
    }

    /// The bottom-most row: the responding member, else the pending send,
    /// else the last visible event.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if respondingMember != nil {
            proxy.scrollTo("responding-row", anchor: .bottom)
        } else if appState.pendingRoomMessage != nil {
            proxy.scrollTo("pending-row", anchor: .bottom)
        } else if let last = visibleEvents.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !isV2 {
            // V2 pushes the room like a chat and keeps the system Back
            // button, so the edge swipe leaves it too (V2Shell closes the
            // room when its screen is popped).
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    appState.closeGroupRoom()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel(Text(AppLocalization.string("Leave this group chat")))
            }
        }
        ToolbarItem(placement: .principal) {
            GroupRoomTitle(
                name: surface?.room.name ?? "",
                subtitle: memberSummary,
                members: members,
                picture: surface.flatMap { appState.groupRoomPicture(roomID: $0.room.roomID) }
            )
        }
        if !isV2 {
            // V2's conversation menu carries these with the gateway's state.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    GroupRoomActionItems(
                        onDisband: { showingDisbandConfirmation = true },
                        onChoosePicture: { choosingPicture = $0 }
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.callout.weight(.semibold))
                }
                .accessibilityLabel(Text(AppLocalization.string("Group chat actions")))
            }
        }
    }

    // MARK: - Approvals

    /// A member's tool call the room is holding for the user. These are
    /// driver state, not log events, so they sit above the composer until
    /// they are answered or the gateway drops them.
    @ViewBuilder
    private var pendingApprovals: some View {
        let approvals = appState.activeRoomPendingApprovals
        if !approvals.isEmpty {
            let cards = VStack(spacing: 8) {
                ForEach(approvals) { approval in
                    GroupApprovalCard(
                        approval: approval,
                        memberName: memberName(for: approval.memberID),
                        answer: appState.roomApprovalAnswers[approval.id]
                    ) { choice in
                        Task { await appState.respondToRoomApproval(approval, choice: choice) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if approvals.count == 1 {
                cards
            } else {
                // Several members waiting at once scroll in a bounded strip,
                // so the transcript and composer keep their room.
                ScrollView { cards }
                    .frame(maxHeight: 300)
            }
        }
    }

    /// The driver names a member by whichever id its task carries.
    private func memberName(for memberID: String) -> String {
        if let member = GroupRoomTurns.member(withID: memberID, in: members) {
            return GroupRoomTurns.displayName(of: member)
        }
        let key = memberID.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? AppLocalization.string("A member") : key
    }

    private var memberSummary: String {
        let count = surface?.room.members.count ?? 0
        if !appState.activeRoomPendingApprovals.isEmpty {
            return AppLocalization.string("Approval needed")
        }
        if let responder = respondingMember {
            return AppLocalization.string("\(GroupRoomTurns.displayName(of: responder)) is responding…")
        }
        if let driver = appState.activeRoomDriverStatus, driver.working {
            return AppLocalization.string("\(count) members · working…")
        }
        return AppLocalization.string("\(count) members")
    }
}

/// The open room's actions: Stop while its members are working, and
/// Disband. In the room's own menu (drawer shell) or V2's conversation menu.
struct GroupRoomActionItems: View {
    @EnvironmentObject private var appState: AppState
    let onDisband: () -> Void
    let onChoosePicture: (GroupRoomPictureRequest) -> Void

    var body: some View {
        if appState.canSetGroupRoomPictures, let roomID = appState.activeRoomSurface?.room.roomID {
            Button {
                onChoosePicture(.choose)
            } label: {
                Label(AppLocalization.string("Choose Group Picture"), systemImage: "photo")
            }
            if appState.canGeneratePictures {
                Button {
                    onChoosePicture(.generate)
                } label: {
                    Label(AppLocalization.string("Generate Group Picture"), systemImage: "sparkles")
                }
            }
            if appState.hasCustomGroupRoomPicture(roomID: roomID) {
                Button {
                    Task { await appState.setGroupRoomPicture(nil, roomID: roomID) }
                } label: {
                    Label(AppLocalization.string("Remove Group Picture"), systemImage: "photo.badge.minus")
                }
            }
        }
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
            onDisband()
        } label: {
            Label(AppLocalization.string("Disband Group"), systemImage: "trash")
        }
    }
}

/// The room's title in the header: its members' pictures and its name in
/// one glass capsule, with who is talking under the name.
struct GroupRoomTitle: View {
    let name: String
    let subtitle: String
    let members: [GroupMember]
    var picture: UIImage? = nil

    var body: some View {
        HStack(spacing: 8) {
            GroupRoomIcon(picture: picture, members: members, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
        .conduitGlassSurface(cornerRadius: 20, tint: .conduitAccent.opacity(0.06))
        // The navigation bar doesn't grow; touch and hold shows it large.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(subtitle))
        .accessibilityShowsLargeContentViewer { Text(name) }
    }
}

// MARK: - Approval card

/// One member's pending approval. Rooms answer Run (once) or Reject only:
/// session and permanent grants aren't offered for a room member's turn.
struct GroupApprovalCard: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let approval: GroupPendingApproval
    let memberName: String
    let answer: AppState.RoomApprovalAnswer?
    let respond: (String) -> Void

    private var submitting: Bool { answer == .submitting }

    private var failure: String? {
        if case .failed(let message) = answer { return message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                // One VoiceOver stop for who is asking and why, so the
                // command and buttons that follow keep their context.
                VStack(alignment: .leading, spacing: 2) {
                    Text(submitting
                        ? AppLocalization.string("SENDING DECISION")
                        : (failure == nil ? AppLocalization.string("APPROVAL NEEDED") : AppLocalization.string("TRY AGAIN")))
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(failure == nil ? Color.orange : Color.red)
                    Text(memberName)
                        .font(.subheadline.weight(.semibold))
                    if !approval.description.isEmpty {
                        Text(verbatim: ApprovalDisplayText.revealingHidden(approval.description))
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if submitting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text(AppLocalization.string("SENDING DECISION")))
                }
            }
            if !approval.command.isEmpty {
                ApprovalCommandBox(
                    maxHeight: ApprovalCommandBox<EmptyView>.maxLines
                        * UIFont.preferredFont(forTextStyle: .caption1).lineHeight
                ) {
                    Text(verbatim: ApprovalDisplayText.revealingHidden(approval.command))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                    .padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            // Large text and longer translations stack the buttons rather
            // than truncating them, like the chat approval card.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    runButton
                    Spacer(minLength: 0)
                    rejectButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    runButton
                    rejectButton
                }
            }
            .font(.subheadline.weight(.medium))
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .conduitGlassSurface(cornerRadius: 20, tint: Color.orange.opacity(0.08))
    }

    private var runButton: some View {
        Button {
            respond("once")
        } label: {
            Label(AppLocalization.string("Run"), systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!approval.allows("once") || submitting)
    }

    private var rejectButton: some View {
        Button(AppLocalization.string("Reject"), role: .destructive) {
            respond("deny")
        }
        .buttonStyle(.bordered)
        .disabled(!approval.allows("deny") || submitting)
    }
}

// MARK: - Event rows

/// One room-log event, rendered by actor kind: the user's messages trail in
/// the accent bubble a chat uses, members' lead with their picture, and
/// every other (or unknown future) kind is a compact system caption — a room
/// this client predates still renders, never crashes.
struct GroupEventRow: View {
    let event: GroupEvent
    let members: [GroupMember]
    /// The previous row is the same speaker's: no picture or name again.
    var continuesRun = false

    var body: some View {
        if event.isUserMessage {
            GroupUserBubble(text: event.messageText ?? "", members: members, timestamp: event.createdAt) {
                EmptyView()
            }
        } else if event.isMemberMessage {
            GroupMemberBubble(
                member: GroupRoomTurns.member(for: event, members: members),
                name: speakerLabel,
                text: event.messageText ?? "",
                members: members,
                timestamp: event.createdAt,
                continuesRun: continuesRun,
                roomEventID: event.id
            )
        } else {
            GroupSystemEventCaption(event: event, members: members)
        }
    }

    private var speakerLabel: String {
        let label = event.actor.displayLabel(members: members)
        return label.isEmpty ? AppLocalization.string("Member") : label
    }

    /// Two rows in a row from one member (or both from the user).
    nonisolated static func sameSpeaker(_ previous: GroupEvent, _ next: GroupEvent) -> Bool {
        if previous.isUserMessage && next.isUserMessage { return true }
        guard previous.isMemberMessage, next.isMemberMessage else { return false }
        let key = previous.actor.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && key == next.actor.id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A message's files and text. Files a message opens with (`@file:` lines,
/// how Conduit sends a room its uploads) show as chips above the text.
struct GroupMessageParts {
    let text: String
    let files: [Attachment]

    init(_ source: String) {
        let split = MessageNormalizer.splitLeadingFileReferences(source, messageId: "room")
        text = split.content
        files = split.attachments
    }
}

private struct GroupMessageFiles: View {
    let files: [Attachment]
    var onAccent = false

    var body: some View {
        ForEach(files) { file in
            HStack(spacing: 8) {
                Image(systemName: AttachmentTypePolicy.symbolName(for: file))
                    .font(.callout)
                    .frame(width: 30, height: 30)
                    .background(
                        (onAccent ? Color.white.opacity(0.18) : Color.primary.opacity(0.07)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                Text(file.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(onAccent ? Color.white : Color.primary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(AppLocalization.string("Attached: \(file.name)")))
        }
    }
}

/// The user's message: the chat's accent bubble on the trailing side, its
/// time and a Copy button under it. `footer` carries a pending send's state.
struct GroupUserBubble<Footer: View>: View {
    let text: String
    let members: [GroupMember]
    let timestamp: Double?
    @ViewBuilder let footer: Footer

    var body: some View {
        let parts = GroupMessageParts(text)
        // A message that quoted a whole room message shows a compact
        // "Replying to" card instead of the full quote.
        let reply = GroupRoomReplyQuote.parse(parts.text)
        let ownText = reply?.message ?? parts.text
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 2) {
                VStack(alignment: .leading, spacing: 8) {
                    GroupMessageFiles(files: parts.files, onAccent: true)
                    if let reply {
                        ReplyReferenceQuoteCard(quote: reply.quote, authorName: reply.author)
                    }
                    if !ownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HugsIdealWidth {
                            MarkdownText(
                                source: GroupRoomMentions.linkingMarkdown(ownText, members: members),
                                foregroundStyle: .white,
                                usesAccentSurface: true
                            )
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [.conduitUserBubble, .conduitUserBubbleShade],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 21, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                }
                .shadow(color: Color.conduitAccent.opacity(0.16), radius: 14, y: 6)
                HStack(spacing: 2) {
                    footer
                    if let timestamp {
                        Text(GroupBubbleTime.text(timestamp))
                            .font(.caption2)
                            .foregroundStyle(.conduitTertiary)
                    }
                    // Like a chat, Copy takes only what the user wrote.
                    if !ownText.isEmpty {
                        GroupMessageCopyButton(text: GroupRoomMentions.refanged(ownText), label: .message)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A member's message: its picture beside a soft bubble, its name and time
/// above (once per run), and the Copy button under it.
struct GroupMemberBubble: View {
    let member: GroupMember?
    let name: String
    let text: String
    let members: [GroupMember]
    let timestamp: Double?
    var continuesRun = false
    /// A hosted room's event id: its messages can be quoted and read
    /// aloud. A Desktop group, read-only here, passes none.
    var roomEventID: String? = nil
    @Environment(\.groupMemberTints) private var tints

    static let avatarSize: CGFloat = 30

    private var tint: CustomAccentColor? { member.flatMap { tints[$0.identityKey] } }

    /// The member's tag, when the room can be addressed to it.
    private var handle: String? {
        guard roomEventID != nil,
              let handle = member?.handle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !handle.isEmpty else { return nil }
        return handle
    }

    var body: some View {
        let parts = GroupMessageParts(text)
        HStack(alignment: .top, spacing: 9) {
            Group {
                if continuesRun {
                    Color.clear
                } else if let handle {
                    // Tapping a bot's picture picks it in the "To" row.
                    GroupMemberMentionButton(handle: handle, name: name) {
                        GroupMemberAvatar(member: member, name: name, size: Self.avatarSize)
                    }
                } else {
                    GroupMemberAvatar(member: member, name: name, size: Self.avatarSize)
                }
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            VStack(alignment: .leading, spacing: 3) {
                if !continuesRun {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint.map { Color(uiColor: $0.readableColor) } ?? .secondary)
                            .lineLimit(1)
                        if let timestamp {
                            Text(GroupBubbleTime.text(timestamp))
                                .font(.caption2)
                                .foregroundStyle(.conduitTertiary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    GroupMessageFiles(files: parts.files)
                    if !parts.text.isEmpty {
                        HugsIdealWidth {
                            MarkdownText(source: GroupRoomMentions.linkingMarkdown(parts.text, members: members, tints: tints))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .groupMemberBubbleSurface(tint: tint)
                if !parts.text.isEmpty {
                    HStack(spacing: 2) {
                        GroupMessageCopyButton(text: GroupRoomMentions.refanged(parts.text), label: .response)
                        if let roomEventID {
                            GroupMessageQuoteButton(text: parts.text, authorName: name, authorHandle: handle)
                            GroupReadAloudButton(eventID: roomEventID, text: parts.text, memberProfile: member?.profile)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact caption for gateway/system/unknown room events.
struct GroupSystemEventCaption: View {
    let event: GroupEvent
    let members: [GroupMember]

    var body: some View {
        Text(caption)
            .font(.caption2)
            .foregroundStyle(.conduitTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
    }

    /// `turn.*` events are one member's turn, never the whole room: they
    /// name the member. Only `room.activity` speaks for the room.
    private var caption: String {
        let name = GroupRoomTurns.member(for: event, members: members).map { GroupRoomTurns.displayName(of: $0) } ?? ""
        switch event.kind {
        case "room.renamed": return AppLocalization.string("The room was renamed.")
        case "room.members_changed": return AppLocalization.string("The room's members changed.")
        case "room.disbanded": return AppLocalization.string("This room was disbanded.")
        case "room.stop_requested": return AppLocalization.string("Stop requested.")
        case "room.activity":
            switch GroupRoomTurns.roomActivityOutcome(event) {
            case .settled: return AppLocalization.string("The room settled.")
            case .bounded: return AppLocalization.string("The conversation reached its turn limit.")
            case .other: return AppLocalization.string("Room updated.")
            }
        case "turn.settled":
            return name.isEmpty
                ? AppLocalization.string("A member passed.")
                : AppLocalization.string("\(name) passed.")
        case "turn.failed":
            return name.isEmpty
                ? AppLocalization.string("A member's turn failed.")
                : AppLocalization.string("\(name)'s turn failed.")
        case "turn.cancelled":
            return name.isEmpty
                ? AppLocalization.string("Work was stopped.")
                : AppLocalization.string("\(name)'s turn was stopped.")
        case "member.unavailable":
            return name.isEmpty
                ? AppLocalization.string("A member is unavailable.")
                : AppLocalization.string("\(name) is unavailable.")
        default: return AppLocalization.string("Room updated.")
        }
    }
}


/// The member whose turn is running, as a placeholder bubble where their
/// reply will land.
struct GroupRespondingRow: View {
    let member: GroupMember
    @Environment(\.groupMemberTints) private var tints

    var body: some View {
        let name = GroupRoomTurns.displayName(of: member)
        let tint = tints[member.identityKey]
        HStack(alignment: .top, spacing: 9) {
            GroupMemberAvatar(member: member, name: name, size: GroupMemberBubble.avatarSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint.map { Color(uiColor: $0.readableColor) } ?? .secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(AppLocalization.string("Responding…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .groupMemberBubbleSurface(tint: tint)
            }
            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AppLocalization.string("\(name) is responding…")))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A room member's picture: the bot's own (its profile's avatar), else its
/// colored initial.
struct GroupMemberAvatar: View {
    @EnvironmentObject private var appState: AppState
    let member: GroupMember?
    let name: String
    let size: CGFloat

    /// The roster bot this member is.
    private var bot: BotProfile? { appState.groupMemberBot(member, name: name) }

    var body: some View {
        if let bot {
            BotAvatarView(
                name: bot.name,
                label: bot.displayLabel,
                colorString: bot.appearanceColor,
                image: appState.botAvatarImage(for: bot),
                size: size
            )
            .task(id: "\(bot.name)|\(bot.hasAvatar)|\(appState.botAvatarGeneration)") {
                await appState.loadBotAvatarRetrying(bot)
            }
            .accessibilityHidden(true)
        } else {
            BotAvatarView(name: name, label: name, colorString: nil, image: nil, size: size)
                .accessibilityHidden(true)
        }
    }
}

/// How the open room's new picture is made: picked from Photos, or
/// generated by Hermes.
enum GroupRoomPictureRequest: String, Identifiable {
    case choose, generate
    var id: String { rawValue }
}

/// Picks or generates a picture for the open room and saves it. On the
/// screen, not in its menu: a sheet raised as a menu closes may never show.
struct GroupRoomPicturePicker: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @Binding var request: GroupRoomPictureRequest?
    var isEnabled = true
    @State private var picked: UIImage?
    @State private var room: GroupRoom?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            picker(content)
        } else {
            content
        }
    }

    private func picker(_ content: Content) -> some View {
        content
            .sheet(item: $request) { request in
                switch request {
                case .choose:
                    ImagePicker(image: $picked)
                case .generate:
                    // One room for the prompt and the save: the open one
                    // (the capture below may still hold the last one while
                    // this sheet is first built).
                    let target = appState.activeRoomSurface?.room ?? room
                    GeneratePictureSheet(
                        defaultPrompt: PictureGeneration.groupPrompt(
                            name: target?.name ?? "",
                            members: target?.members.map { GroupRoomTurns.displayName(of: $0) } ?? []
                        ),
                        forGroup: true
                    ) { image in
                        guard let roomID = target?.roomID else { return }
                        Task { await appState.setGroupRoomPicture(image, roomID: roomID) }
                    }
                    .environmentObject(appState)
                }
            }
            .onChange(of: request) { _, request in
                // The room the menu was for, even if another opens meanwhile.
                if request != nil { room = appState.activeRoomSurface?.room }
            }
            .onChange(of: picked) { _, image in
                guard let image else { return }
                picked = nil
                guard let roomID = room?.roomID else { return }
                Task { await appState.setGroupRoomPicture(image, roomID: roomID) }
            }
            // Whether the menu offers Generate Group Picture: asked only
            // where a room is open, again for each room.
            .task(id: "\(appState.activeRoomSurface?.room.roomID ?? "")|\(appState.canSetGroupRoomPictures)") {
                guard appState.activeRoomSurface != nil, appState.canSetGroupRoomPictures else { return }
                await appState.refreshPictureGeneration()
            }
    }
}

/// A group chat's picture: the one set for it, else up to three members'
/// pictures packed into one circle, like a group in Messages, else a quiet
/// gray glyph.
struct GroupRoomIcon: View {
    let picture: UIImage?
    let members: [GroupMember]
    let size: CGFloat

    /// Where each of `count` member pictures sits, as offsets from the
    /// center and a diameter, all in fractions of the icon's size. Every
    /// circle stays inside the icon.
    nonisolated static func layout(count: Int) -> [(x: CGFloat, y: CGFloat, diameter: CGFloat)] {
        switch count {
        case ..<1: return []
        case 1: return [(0, 0, 1)]
        case 2: return [(-0.17, -0.17, 0.64), (0.17, 0.17, 0.64)]
        default: return [(0, -0.22, 0.54), (-0.22, 0.17, 0.54), (0.22, 0.17, 0.54)]
        }
    }

    var body: some View {
        Group {
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if members.isEmpty {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.08))
                    Image(systemName: "person.3")
                        .font(.system(size: size * 0.32))
                        .foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
            } else {
                let shown = Array(members.prefix(3))
                let spots = Self.layout(count: shown.count)
                ZStack {
                    ForEach(shown.indices, id: \.self) { index in
                        let spot = spots[index]
                        let diameter = size * spot.diameter
                        GroupMemberAvatar(
                            member: shown[index],
                            name: GroupRoomTurns.displayName(of: shown[index]),
                            size: diameter
                        )
                        .overlay {
                            if shown.count > 1 {
                                Circle().strokeBorder(Color.conduitBackgroundColor, lineWidth: max(1, size * 0.03))
                            }
                        }
                        .offset(x: size * spot.x, y: size * spot.y)
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Copies a whole message, mirroring a single chat's response Copy button
/// (same icon, haptic, and brief checkmark).
struct GroupMessageCopyButton: View {
    enum Kind { case response, message }

    let text: String
    let label: Kind
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    private var copiedTitle: String {
        label == .response ? AppLocalization.string("Response copied") : AppLocalization.string("Message copied")
    }

    private var title: String {
        label == .response ? AppLocalization.string("Copy response") : AppLocalization.string("Copy message")
    }

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            Haptics.light()
            copied = true
            UIAccessibility.post(notification: .announcement, argument: copiedTitle)
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.footnote.weight(.semibold))
                // A full-size tap target in the footer's 32 pt.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .padding(-6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? Color.conduitAccent : Color.secondary)
        .accessibilityLabel(copied ? copiedTitle : title)
        .onDisappear { resetTask?.cancel() }
    }
}

/// Only view bodies format, so the shared formatter stays on the main actor.
@MainActor
enum GroupBubbleTime {
    // A fresh DateFormatter per bubble per render is brutally expensive
    // across a 200-event LazyVStack.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    static func text(_ value: Double) -> String {
        formatter.string(from: Date(timeIntervalSince1970: value))
    }
}

// MARK: - Room message actions

/// Attaches a whole room message to the next one, as the "Replying to…"
/// chip in the room composer.
struct GroupMessageQuoteButton: View {
    @EnvironmentObject private var appState: AppState
    let text: String
    let authorName: String
    /// The author's tag: replying also addresses the next message to it.
    var authorHandle: String? = nil

    var body: some View {
        Button {
            appState.replyInRoomComposer(text: text, authorName: authorName, authorHandle: authorHandle)
        } label: {
            Image(systemName: "quote.bubble")
                .font(.footnote.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .padding(-6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!appState.canQuoteIntoRoom())
        .accessibilityLabel(
            authorHandle == nil
                ? AppLocalization.string("Quote this response")
                : AppLocalization.string("Reply to \(authorName)")
        )
    }
}

/// A bot's picture in the room: tapping it picks the bot in the composer's
/// "To" row.
struct GroupMemberMentionButton<Label: View>: View {
    @EnvironmentObject private var appState: AppState
    let handle: String
    let name: String
    @ViewBuilder let label: Label

    var body: some View {
        Button {
            Haptics.selection()
            appState.mentionInRoomComposer(handle: handle)
        } label: {
            label
        }
        .buttonStyle(.plain)
        .disabled(!appState.canQuoteIntoRoom())
        .accessibilityLabel(AppLocalization.string("Mention \(name)"))
    }
}

extension View {
    /// A member's bubble: a wash of the bot's color, else the neutral one.
    func groupMemberBubbleSurface(tint: CustomAccentColor?) -> some View {
        let fill = tint.map { Color(uiColor: $0.readableColor).opacity(0.10) } ?? Color.primary.opacity(0.06)
        let stroke = tint.map { Color(uiColor: $0.readableColor).opacity(0.18) } ?? Color.primary.opacity(0.06)
        return background(fill, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            }
    }
}

private struct GroupMemberTintsKey: EnvironmentKey {
    static let defaultValue: [String: CustomAccentColor] = [:]
}

extension EnvironmentValues {
    /// The open room's member colors by `identityKey`.
    var groupMemberTints: [String: CustomAccentColor] {
        get { self[GroupMemberTintsKey.self] }
        set { self[GroupMemberTintsKey.self] = newValue }
    }
}

/// Reads a room message aloud, like a chat reply's button. The only part
/// of a member's bubble that observes the read aloud controller.
struct GroupReadAloudButton: View {
    @EnvironmentObject private var appState: AppState
    let eventID: String
    let text: String
    /// The bot's profile, whose own voice reads the message.
    var memberProfile: String? = nil

    var body: some View {
        GroupReadAloudControl(
            controller: appState.messageReadAloudController,
            messageID: appState.activeRoomSurface.map {
                AppState.roomReadAloudID(roomID: $0.room.roomID, eventID: eventID)
            } ?? "",
            unavailable: appState.readAloudUnavailableReason != nil,
            toggle: { appState.toggleRoomReadAloud(eventID: eventID, text: text, memberProfile: memberProfile) }
        )
    }
}

private struct GroupReadAloudControl: View {
    @ObservedObject var controller: MessageReadAloudController
    let messageID: String
    let unavailable: Bool
    let toggle: () -> Void

    private var isActive: Bool { controller.isActiveMessage(messageID) }
    private var isPaused: Bool { isActive && controller.isPaused }

    var body: some View {
        Button {
            if isPaused {
                Haptics.light()
                controller.resume()
                return
            }
            if isActive { Haptics.medium() } else { Haptics.light() }
            toggle()
        } label: {
            Group {
                if case .preparing(let id) = controller.state, id == messageID {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isPaused ? "play.fill" : isActive ? "stop.fill" : "speaker.wave.2")
                }
            }
            .font(.footnote.weight(.semibold))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .padding(-6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.conduitAccent : Color.secondary)
        .disabled(unavailable && !isActive)
        .opacity(unavailable && !isActive ? 0.45 : 1)
        .accessibilityLabel(
            isPaused ? AppLocalization.string("Resume reading response")
                : isActive ? AppLocalization.string("Stop reading response")
                : AppLocalization.string("Read response aloud")
        )
    }
}

/// The @mention picker shown above a composer while a trailing `@query`
/// is being typed. Tapping a row completes the tag.
struct MentionSuggestionList: View {
    let candidates: [MentionAutocomplete.Candidate]
    let onSelected: (MentionAutocomplete.Candidate) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 44

    /// The hairlines between the visible rows (at most five).
    private var dividerAllowance: CGFloat { CGFloat(max(0, min(candidates.count, 5) - 1)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    Button {
                        Haptics.selection()
                        onSelected(candidate)
                    } label: {
                        HStack(spacing: 10) {
                            Text(candidate.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(verbatim: "@\(candidate.tag)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(AppLocalization.string("Inserts this mention.")))
                    if index < candidates.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
        // Sized to its rows (a bare max height would stretch two rows to
        // the cap), scrolling past five; the row height follows Dynamic Type.
        .frame(height: min(rowHeight * 5, CGFloat(candidates.count) * rowHeight) + dividerAllowance)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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

    /// `preselected`: bots already picked, as from a bot's Groups menu.
    init(preselected: Set<String> = []) {
        _selected = State(initialValue: preselected)
    }

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
            RosterIconRow(title: group.name, subtitle: subtitleText, trailingSymbol: "desktopcomputer") { size in
                GroupRoomIcon(
                    picture: GroupRoomPictureImages.image(from: group.imageData),
                    members: group.groupMembers,
                    size: size
                )
            }
        }
        .buttonStyle(.plain)
        .rosterListRow()
        .accessibilityLabel(Text(group.name))
        .accessibilityValue(Text(subtitleText))
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
    private var mentionMembers: [GroupMember] { group.groupMembers }

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
                                .foregroundStyle(.conduitTertiary)
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
                    GroupRoomTitle(
                        name: group.name,
                        subtitle: AppLocalization.string("\(group.members.count) members"),
                        members: mentionMembers,
                        picture: GroupRoomPictureImages.image(from: group.imageData)
                    )
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
        VStack(alignment: message.isMember ? .leading : .trailing, spacing: 2) {
            if message.isMember {
                GroupMemberBubble(
                    member: nil,
                    name: speaker.isEmpty ? AppLocalization.string("Member") : speaker,
                    text: message.text,
                    members: mentionMembers,
                    timestamp: message.timestamp
                )
            } else {
                GroupUserBubble(text: message.text, members: mentionMembers, timestamp: message.timestamp) {
                    EmptyView()
                }
            }
            if message.truncated {
                Text(AppLocalization.string("Shortened — the full message is in Hermes Desktop."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, message.isMember ? GroupMemberBubble.avatarSize + 9 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isMember ? .leading : .trailing)
    }
}
