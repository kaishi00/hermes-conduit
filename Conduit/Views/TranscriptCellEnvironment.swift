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
    var v2Shell: V2ShellContext
    var v2OpenBeside: V2OpenBeside?
    var v2TabBarClearance: CGFloat
    var v2ComposerRests: Bool
    var groupMemberTints: [String: CustomAccentColor]
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
        v2Shell = values.v2Shell
        v2OpenBeside = values.v2OpenBeside
        v2TabBarClearance = values.v2TabBarClearance
        v2ComposerRests = values.v2ComposerRests
        groupMemberTints = values.groupMemberTints
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
            && lhs.v2Shell == rhs.v2Shell
            && lhs.v2OpenBeside == rhs.v2OpenBeside
            && lhs.v2TabBarClearance == rhs.v2TabBarClearance
            && lhs.v2ComposerRests == rhs.v2ComposerRests
            && lhs.groupMemberTints == rhs.groupMemberTints
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
            .environment(\.v2Shell, values.v2Shell)
            .environment(\.v2OpenBeside, values.v2OpenBeside)
            .environment(\.v2TabBarClearance, values.v2TabBarClearance)
            .environment(\.v2ComposerRests, values.v2ComposerRests)
            .environment(\.groupMemberTints, values.groupMemberTints)
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
