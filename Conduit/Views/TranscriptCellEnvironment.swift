//
//  TranscriptCellEnvironment.swift
//  Conduit
//
//  What a transcript row reads from the chat's environment, handed to the
//  row's own hosting controller (#1533, the transcript rewrite).
//

import SwiftUI

/// What a transcript row reads from the chat's environment (#1533, the
/// transcript rewrite). Each row draws in a hosting controller of its own,
/// the root of its own SwiftUI hierarchy, so it inherits nothing from
/// ChatView: every value a row reads comes through here.
/// scripts/check-transcript-environment.py fails when one of Conduit's
/// environment keys is neither copied here nor listed in `setInsideRows`.
struct TranscriptCellEnvironment: Equatable {
    /// Keys the rows set themselves, where they read them, for what they
    /// hold: they aren't copied from the chat (the checker reads this
    /// list). The checker sees only that something in Conduit sets each,
    /// not where, so a key set above the transcript is copied, never
    /// listed here.
    static let setInsideRows = [
        "richSourceActionsOnRow",
        "textSelectionTint",
        "markupDrawsInPlace",
        "markdownReferences",
        "chatPinReplyAction",
        "richChecklistContext",
        "richChecklistInChat",
        "richCardActions",
        // The call screen's control row sets it for its own buttons; no
        // transcript row reads it.
        "liveVoiceCallButtonSlotWidth",
        // The shell sets it for the main button in a Duo's status strip;
        // no transcript row reads it.
        "v2MainButtonDiameter",
    ]

    // Conduit's
    var chatRowState: ChatRowState
    var chatRowActions: ChatRowActions?
    var chatRowDisclosure: ChatRowDisclosure?
    var imageGallery: ImageGallerySource?
    var selectableTextDrawsUntilTouched: Bool
    var composerStaysExpanded: Bool
    var chatWidthTextSteps: Int
    var columnText: ColumnText?
    var chatTextSize: ChatTextAppearance
    var markdownTablePlainCells: Bool
    var quotedReplyJump: QuotedReplyJumpAction?
    var chatQuoteAction: ChatQuoteAction?
    var markdownJoinsProseRuns: Bool
    var gatewayMediaFiles: GatewayMediaDataURLResolver?
    var roomFilePictures: GatewayMediaDataURLResolver?
    var roomFileReads: GatewayMediaDataURLResolver?
    var v2Shell: V2ShellContext
    var v2OpenBeside: V2OpenBeside?
    var botZoomNamespace: Namespace.ID?
    var botsHomeCovered: Bool
    var botChatZoomed: Bool
    var rosterRowsInScroll: Bool
    var v2TabBarClearance: CGFloat
    /// The side safe area the chat's column takes (#1900); no row reads it yet.
    var windowSideInsets: WindowSideInsets?
    var v2ComposerRests: Bool
    var groupMemberTints: [String: CustomAccentColor]
    var groupRoomLooks: RoomLooks
    var conduitAccent: ConduitAccent
    var settingsGlowTint: Color?
    // SwiftUI's that the chat or the app sets (traits carry the rest)
    var locale: Locale
    var dynamicTypeSize: DynamicTypeSize
    var font: Font?
    var colorScheme: ColorScheme
    var layoutDirection: LayoutDirection
    var horizontalSizeClass: UserInterfaceSizeClass?
    var scenePhase: ScenePhase
    var isEnabled: Bool
    /// Not compared: an action has no equality, and the app's is set once.
    var openURL: OpenURLAction

    /// The values at the transcript, the chat's disclosure in place of any
    /// other (the stack set it on the rows).
    init(_ values: EnvironmentValues, disclosure: ChatRowDisclosure?) {
        chatRowState = values.chatRowState
        chatRowActions = values.chatRowActions
        chatRowDisclosure = disclosure
        imageGallery = values.imageGallery
        selectableTextDrawsUntilTouched = values.selectableTextDrawsUntilTouched
        composerStaysExpanded = values.composerStaysExpanded
        chatWidthTextSteps = values.chatWidthTextSteps
        columnText = values.columnText
        chatTextSize = values.chatTextSize
        markdownTablePlainCells = values.markdownTablePlainCells
        quotedReplyJump = values.quotedReplyJump
        chatQuoteAction = values.chatQuoteAction
        markdownJoinsProseRuns = values.markdownJoinsProseRuns
        gatewayMediaFiles = values.gatewayMediaFiles
        roomFilePictures = values.roomFilePictures
        roomFileReads = values.roomFileReads
        v2Shell = values.v2Shell
        v2OpenBeside = values.v2OpenBeside
        botZoomNamespace = values.botZoomNamespace
        botsHomeCovered = values.botsHomeCovered
        botChatZoomed = values.botChatZoomed
        rosterRowsInScroll = values.rosterRowsInScroll
        v2TabBarClearance = values.v2TabBarClearance
        windowSideInsets = values.windowSideInsets
        v2ComposerRests = values.v2ComposerRests
        groupMemberTints = values.groupMemberTints
        groupRoomLooks = values.groupRoomLooks
        conduitAccent = values.conduitAccent
        settingsGlowTint = values.settingsGlowTint
        locale = values.locale
        dynamicTypeSize = values.dynamicTypeSize
        font = values.font
        colorScheme = values.colorScheme
        layoutDirection = values.layoutDirection
        horizontalSizeClass = values.horizontalSizeClass
        scenePhase = values.scenePhase
        isEnabled = values.isEnabled
        openURL = values.openURL
    }

    /// What a row's height hangs on besides its width and content: the
    /// text's size and face, at the chat's and the system's size.
    var textScope: String {
        "\(chatTextSize)|\(dynamicTypeSize)|\(chatWidthTextSteps)|\(String(describing: columnText))|\(String(describing: font))"
    }

    /// Whether a row could measure differently under `other` (issue 1763,
    /// #2341 review): equal apart from what only colors or pauses a row, or
    /// what no row reads (the app's phase, enabled state and color scheme,
    /// Bots Home's cover, the roster's scroll, the tab bar's clearance, the
    /// side insets, the tints). Those leave every row's measured height
    /// current (TranscriptLayout.forgetCurrentMeasurements).
    func measuresLike(_ other: Self) -> Bool {
        var same = other
        same.scenePhase = scenePhase
        same.isEnabled = isEnabled
        same.colorScheme = colorScheme
        same.botsHomeCovered = botsHomeCovered
        same.rosterRowsInScroll = rosterRowsInScroll
        same.v2TabBarClearance = v2TabBarClearance
        same.windowSideInsets = windowSideInsets
        same.conduitAccent = conduitAccent
        same.settingsGlowTint = settingsGlowTint
        same.groupMemberTints = groupMemberTints
        return self == same
    }

    /// Which rows could measure differently under this environment than
    /// under `other` (issue 2358). A turn starting or ending, or a reply
    /// landing, moves only the rows' state that names its rows (the
    /// running turn's, the newest reply, the follow-ups' board, a run's
    /// summary, a teammate's reply), so only those rows forget their
    /// heights; anything else changing still forgets every row's.
    func measurementChange(from other: Self) -> TranscriptMeasurementChange {
        if measuresLike(other) { return .none }
        let new = chatRowState
        let old = other.chatRowState
        var rest = other
        rest.chatRowState.isBusy = new.isBusy
        rest.chatRowState.cardsCanSend = new.cardsCanSend
        rest.chatRowState.latestAssistantMessageID = new.latestAssistantMessageID
        rest.chatRowState.retryableReplyID = new.retryableReplyID
        rest.chatRowState.followUpBoardRowID = new.followUpBoardRowID
        rest.chatRowState.teammateReplies = new.teammateReplies
        rest.chatRowState.stepSummaries = new.stepSummaries
        rest.chatRowState.stepSummariesAsked = new.stepSummariesAsked
        guard measuresLike(rest) else { return .all }
        // `cardsCanSend` only enables a card's buttons; the follow-ups it
        // shows or hides go with `followUpBoardRowID`.
        var messages: Set<String> = []
        for (before, after) in [
            (old.latestAssistantMessageID, new.latestAssistantMessageID),
            (old.retryableReplyID, new.retryableReplyID),
            (old.followUpBoardRowID, new.followUpBoardRowID),
        ] where before != after {
            if let before { messages.insert(before) }
            if let after { messages.insert(after) }
        }
        for id in Set(old.teammateReplies.keys).union(new.teammateReplies.keys)
        where old.teammateReplies[id] != new.teammateReplies[id] {
            messages.insert(id)
        }
        var runs: Set<String> = []
        for key in Set(old.stepSummaries.keys).union(new.stepSummaries.keys)
        where old.stepSummaries[key] != new.stepSummaries[key] {
            runs.insert(key)
        }
        runs.formUnion(old.stepSummariesAsked.symmetricDifference(new.stepSummariesAsked))
        return .rows(messages: messages, runs: runs, turn: old.isBusy != new.isBusy)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chatRowState == rhs.chatRowState
            && lhs.chatRowActions == rhs.chatRowActions
            && lhs.chatRowDisclosure === rhs.chatRowDisclosure
            && lhs.imageGallery === rhs.imageGallery
            && lhs.selectableTextDrawsUntilTouched == rhs.selectableTextDrawsUntilTouched
            && lhs.composerStaysExpanded == rhs.composerStaysExpanded
            && lhs.chatWidthTextSteps == rhs.chatWidthTextSteps
            && lhs.columnText == rhs.columnText
            && lhs.chatTextSize == rhs.chatTextSize
            && lhs.markdownTablePlainCells == rhs.markdownTablePlainCells
            && lhs.quotedReplyJump == rhs.quotedReplyJump
            && lhs.chatQuoteAction == rhs.chatQuoteAction
            && lhs.markdownJoinsProseRuns == rhs.markdownJoinsProseRuns
            && lhs.gatewayMediaFiles === rhs.gatewayMediaFiles
            && lhs.roomFilePictures === rhs.roomFilePictures
            && lhs.roomFileReads === rhs.roomFileReads
            && lhs.v2Shell == rhs.v2Shell
            && lhs.v2OpenBeside == rhs.v2OpenBeside
            && lhs.botZoomNamespace == rhs.botZoomNamespace
            && lhs.botsHomeCovered == rhs.botsHomeCovered
            && lhs.botChatZoomed == rhs.botChatZoomed
            && lhs.rosterRowsInScroll == rhs.rosterRowsInScroll
            && lhs.v2TabBarClearance == rhs.v2TabBarClearance
            && lhs.windowSideInsets == rhs.windowSideInsets
            && lhs.v2ComposerRests == rhs.v2ComposerRests
            && lhs.groupMemberTints == rhs.groupMemberTints
            && lhs.groupRoomLooks == rhs.groupRoomLooks
            && lhs.conduitAccent == rhs.conduitAccent
            && lhs.settingsGlowTint == rhs.settingsGlowTint
            && lhs.locale == rhs.locale
            && lhs.dynamicTypeSize == rhs.dynamicTypeSize
            && lhs.font == rhs.font
            && lhs.colorScheme == rhs.colorScheme
            && lhs.layoutDirection == rhs.layoutDirection
            && lhs.horizontalSizeClass == rhs.horizontalSizeClass
            && lhs.scenePhase == rhs.scenePhase
            && lhs.isEnabled == rhs.isEnabled
    }
}

extension View {
    /// Applies what the chat's environment had for the rows.
    func transcriptCellEnvironment(_ values: TranscriptCellEnvironment) -> some View {
        modifier(TranscriptCellConduitEnvironment(values: values))
            .modifier(TranscriptCellSystemEnvironment(values: values))
    }
}

private struct TranscriptCellConduitEnvironment: ViewModifier {
    let values: TranscriptCellEnvironment

    func body(content: Content) -> some View {
        content
            .environment(\.chatRowState, values.chatRowState)
            .environment(\.chatRowActions, values.chatRowActions)
            .environment(\.chatRowDisclosure, values.chatRowDisclosure)
            .environment(\.imageGallery, values.imageGallery)
            .environment(\.selectableTextDrawsUntilTouched, values.selectableTextDrawsUntilTouched)
            .environment(\.composerStaysExpanded, values.composerStaysExpanded)
            .environment(\.chatWidthTextSteps, values.chatWidthTextSteps)
            .environment(\.columnText, values.columnText)
            .environment(\.chatTextSize, values.chatTextSize)
            .environment(\.markdownTablePlainCells, values.markdownTablePlainCells)
            .modifier(TranscriptCellConduitEnvironmentMore(values: values))
    }
}

private struct TranscriptCellConduitEnvironmentMore: ViewModifier {
    let values: TranscriptCellEnvironment

    func body(content: Content) -> some View {
        content
            .environment(\.quotedReplyJump, values.quotedReplyJump)
            .environment(\.chatQuoteAction, values.chatQuoteAction)
            .environment(\.markdownJoinsProseRuns, values.markdownJoinsProseRuns)
            .environment(\.gatewayMediaFiles, values.gatewayMediaFiles)
            .environment(\.roomFilePictures, values.roomFilePictures)
            .environment(\.roomFileReads, values.roomFileReads)
            .environment(\.v2Shell, values.v2Shell)
            .environment(\.v2OpenBeside, values.v2OpenBeside)
            .environment(\.botZoomNamespace, values.botZoomNamespace)
            .environment(\.botsHomeCovered, values.botsHomeCovered)
            .environment(\.botChatZoomed, values.botChatZoomed)
            .environment(\.rosterRowsInScroll, values.rosterRowsInScroll)
            .environment(\.v2TabBarClearance, values.v2TabBarClearance)
            .environment(\.windowSideInsets, values.windowSideInsets)
            .environment(\.v2ComposerRests, values.v2ComposerRests)
            .environment(\.groupMemberTints, values.groupMemberTints)
            .environment(\.groupRoomLooks, values.groupRoomLooks)
            .environment(\.conduitAccent, values.conduitAccent)
            .environment(\.settingsGlowTint, values.settingsGlowTint)
    }
}

private struct TranscriptCellSystemEnvironment: ViewModifier {
    let values: TranscriptCellEnvironment

    func body(content: Content) -> some View {
        content
            .environment(\.locale, values.locale)
            .environment(\.dynamicTypeSize, values.dynamicTypeSize)
            .environment(\.font, values.font)
            .environment(\.colorScheme, values.colorScheme)
            .environment(\.layoutDirection, values.layoutDirection)
            .environment(\.horizontalSizeClass, values.horizontalSizeClass)
            .environment(\.scenePhase, values.scenePhase)
            .environment(\.isEnabled, values.isEnabled)
            .environment(\.openURL, values.openURL)
            .tint(Color.conduitAccent)
    }
}

/// Which of the transcript's rows forget their measured heights when its
/// environment changes (TranscriptCellEnvironment.measurementChange).
enum TranscriptMeasurementChange: Equatable {
    /// None: nothing a row's height reads changed.
    case none
    /// Every row, on screen or not.
    case all
    /// The rows of `messages`, the rows of the step runs whose summary key
    /// is in `runs`, and with `turn` every row after the last message sent
    /// (the running turn's: its run draws live while Hermes works).
    case rows(messages: Set<String>, runs: Set<String>, turn: Bool)

    /// The ids of `rows` this change reaches; nil for every row.
    func rowIDs(in rows: [TranscriptRow]) -> Set<String>? {
        switch self {
        case .none: return []
        case .all: return nil
        case let .rows(messages, runs, turn):
            var ids: Set<String> = []
            if turn {
                let lastSent = rows.lastIndex { row in
                    if case .message(let target) = row.kind { return target.message.role == .user }
                    return false
                }
                for row in rows[(lastSent.map { $0 + 1 } ?? 0)...] { ids.insert(row.id) }
            }
            guard !messages.isEmpty || !runs.isEmpty else { return ids }
            var runKeys: [String: String?] = [:]
            for row in rows {
                guard case .message(let target) = row.kind else { continue }
                if messages.contains(target.message.id) { ids.insert(row.id) }
                guard !runs.isEmpty, let group = target.step?.group else { continue }
                let key = runKeys[group.id] ?? group.summaryKey
                runKeys[group.id] = key
                if let key, runs.contains(key) { ids.insert(row.id) }
            }
            return ids
        }
    }
}
