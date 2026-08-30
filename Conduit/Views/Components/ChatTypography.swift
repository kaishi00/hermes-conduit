//
//  ChatTypography.swift
//  Conduit
//
//  Central authority for transcript-content typography (issue #85).
//
//  The chat text-size preference is a local, device-only presentation
//  setting backed by UserDefaults via @AppStorage (the same pattern as
//  ComposerReturnKey). It is never synchronized to Hermes, profiles, the
//  gateway, or any backend configuration.
//
//  The selected size is a FIRST-CLASS rendering input that AUGMENTS — never
//  replaces — iOS Dynamic Type: every transcript font resolves as
//
//      system Dynamic Type size × Conduit chat text scale
//
//  so `Default` renders byte-identically to the pre-feature transcript at
//  the user's current system text size, and accessibility text sizing keeps
//  working at every position. All five values stay monotonically ordered
//  and preserve the visual hierarchy (headings above body above captions;
//  code stays monospaced) because the scale multiplies already-hierarchical
//  Dynamic Type fonts.
//
//  Only readable message/transcript content resolves fonts through this
//  type. Interface chrome — timestamps, identity labels, copy/branch/
//  read-aloud buttons, navigation, Settings, composer controls, selection
//  chrome, tool/status cards — keeps its existing typography.
//
//  Mermaid and KaTeX previews render inside WKWebView with their own HTML/CSS
//  and intentionally keep their internal size; the surrounding source cards
//  DO use this typography (see RenderCard/MarkupPreviewSheet/GuardedSourceCard).
//

import SwiftUI
import UIKit

/// The stepped chat text-size preference. The enum POSITION (raw value) is
/// what persists — the scale factors live in `ChatTypography` so they can be
/// tuned later without migrating stored preferences.
enum ChatTextSize: Int, CaseIterable, Equatable {
    case smallest = 0
    case smaller
    case `default`
    case larger
    case largest

    /// Relative scale applied on top of the current system Dynamic Type size.
    var scale: CGFloat {
        switch self {
        case .smallest: 0.85
        case .smaller: 0.925
        case .default: 1.00
        case .larger: 1.125
        case .largest: 1.25
        }
    }

    /// Human-readable name, used by the Settings slider's accessibility value.
    var displayName: String {
        switch self {
        case .smallest: "Smallest"
        case .smaller: "Smaller"
        case .default: "Default"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }

    /// Stable identity for typography-sensitive caches (render cache, table
    /// measurement, flow-chunk memos, code-slice identity). A different
    /// position MUST produce a different identity so no cache can serve
    /// attributed output laid out at another size.
    var cacheIdentity: String { String(rawValue) }
}

/// Sole authority for transcript-content font resolution. Both UIKit
/// (UIFont-returning) and SwiftUI (point-size/CGFloat-returning) consumers
/// resolve through here so settled Markdown, streaming Markdown, tables,
/// code, large documents, and source cards agree at the selected size.
enum ChatTypography {
    /// Local, device-only preference key. Namespaced like ComposerReturnKey.
    static let preferenceKey = "conduit.chatTextSize"

    /// Initial/fallback value: existing users keep today's appearance.
    static let defaultSize: ChatTextSize = .default

    // MARK: Preference resolution

    /// Safe resolution of a persisted raw value: a missing or out-of-range
    /// value falls back to `.default` instead of trapping or clamping.
    static func resolve(rawValue: Int?) -> ChatTextSize {
        guard let rawValue, let size = ChatTextSize(rawValue: rawValue) else { return .default }
        return size
    }

    /// Reads the stored preference through UserDefaults (what @AppStorage
    /// uses), so the app and tests agree on one resolution path.
    static func stored(in defaults: UserDefaults = .standard) -> ChatTextSize {
        resolve(rawValue: defaults.object(forKey: preferenceKey) as? Int)
    }

    // MARK: Semantic roles

    /// Transcript-content roles. Each maps to the same base Dynamic Type
    /// style the renderer used before this abstraction existed, so
    /// `.default` preserves today's exact appearance.
    enum Role: Equatable {
        /// Paragraphs, list items, quotes (with caller-applied styling
        /// handled here), callout bodies, columns, streaming text.
        case body
        /// Markdown headings by level (1...n).
        case heading(level: Int)
        /// Quote text — italic, like today.
        case quote
        /// Table header cells — bold caption.
        case tableHeader
        /// Table body cells.
        case tableBody
        /// Readable reasoning/thinking text.
        case thinking
        /// Fenced code blocks — monospaced.
        case blockCode
        /// Source text shown around rich Markdown previews (Mermaid/LaTeX
        /// render cards, guarded oversized sources) — monospaced caption.
        case sourceCode
    }

    // MARK: Scale

    static func scale(for size: ChatTextSize) -> CGFloat { size.scale }

    /// Scales an already-resolved (Dynamic Type aware) font. The descriptor
    /// — family, weight, symbolic traits — is preserved; only the point
    /// size grows or shrinks.
    static func scaledFont(_ base: UIFont, chatSize: ChatTextSize) -> UIFont {
        guard chatSize != .default else { return base }
        return base.withSize(base.pointSize * chatSize.scale)
    }

    /// Scales a fixed layout dimension (e.g. list-marker column widths) so
    /// chrome-adjacent content geometry keeps up with the text it hosts.
    static func dimension(_ value: CGFloat, chatSize: ChatTextSize) -> CGFloat {
        value * chatSize.scale
    }

    // MARK: Font resolution

    /// Resolves a role's font at the selected chat size. The optional trait
    /// collection makes Dynamic Type behavior unit-testable; production
    /// call sites pass nil and resolve against the current system setting
    /// (identical to the pre-feature `UIFont.preferredFont` calls).
    static func font(
        for role: Role,
        chatSize: ChatTextSize,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        scaledFont(baseFont(for: role, compatibleWith: traits), chatSize: chatSize)
    }

    /// The unscaled (Dynamic Type only) base font for a role. Kept separate
    /// so `Default` resolution is exactly the historical font.
    static func baseFont(
        for role: Role,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        switch role {
        case .body:
            return preferred(.body, traits)
        case .heading(let level):
            return preferred(headingStyle(for: level), traits).withTraits(.traitBold)
        case .quote:
            return preferred(.body, traits).withTraits(.traitItalic)
        case .tableHeader:
            return preferred(.caption1, traits).withTraits(.traitBold)
        case .tableBody:
            return preferred(.footnote, traits)
        case .thinking:
            return preferred(.callout, traits)
        case .blockCode:
            return .monospacedSystemFont(ofSize: preferred(.footnote, traits).pointSize, weight: .regular)
        case .sourceCode:
            return .monospacedSystemFont(ofSize: preferred(.caption1, traits).pointSize, weight: .regular)
        }
    }

    /// Dynamic Type text style for a Markdown heading level — the same
    /// mapping MarkdownHeading has always used (h1 → title2 … h4+ →
    /// subheadline), bold applied above.
    static func headingStyle(for level: Int) -> UIFont.TextStyle {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
    }

    private static func preferred(_ style: UIFont.TextStyle, _ traits: UITraitCollection?) -> UIFont {
        if let traits {
            return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        }
        return UIFont.preferredFont(forTextStyle: style)
    }
}

// MARK: - Environment

/// Environment propagation of the selected chat text size. The default is
/// `.default` — subtrees that never receive the injection (Settings,
/// Kanban, previews, tests) keep rendering exactly as before, which is what
/// keeps this a chat-only preference rather than an app-wide one.
private struct ChatTextSizeEnvironmentKey: EnvironmentKey {
    static let defaultValue: ChatTextSize = .default
}

extension EnvironmentValues {
    /// The transcript typography this subtree renders content with. Injected
    /// at the chat root; read by MarkdownText and friends.
    var chatTextSize: ChatTextSize {
        get { self[ChatTextSizeEnvironmentKey.self] }
        set { self[ChatTextSizeEnvironmentKey.self] = newValue }
    }
}
