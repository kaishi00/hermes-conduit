//
//  DesktopCardBlock.swift
//  Conduit
//
//  A Hermes Desktop plugin's card in a reply (#1522). A Desktop plugin with
//  a client half (hermes-rich-ui's `::richui{id="…"}`) has the agent write a
//  directive that only Desktop draws. Conduit doesn't rebuild those
//  renderers; it shows a card in the directive's place that says what was
//  there and where it opens, so nothing goes missing without a trace and
//  the raw line never shows.
//
//  For hermes-rich-ui the card also carries the card's title and the plain
//  summary its author wrote as the fallback, read from the plugin's own
//  read-only route on the connected Hermes. Anything else, or a card that
//  can't be read, keeps the plain "made for Hermes Desktop" card. A tap
//  opens the full summary and the directive as written.
//
//  The card's height never changes as it loads: one title line and two
//  summary lines are held from the first frame.
//

import SwiftUI

extension DesktopCardDirective {
    /// Said or shown where the card is when the reply is read rather than
    /// drawn (Read Aloud, voice read-backs, a chat's preview line).
    static var spokenNote: String { AppLocalization.string("(There's a card here for Hermes Desktop.)") }
    static var previewNote: String { AppLocalization.string("Card for Hermes Desktop") }
}

extension TranscriptDirectives {
    /// `text` for places that read a reply rather than render it (Read
    /// Aloud, voice read-backs): previews go, a Desktop card is a short note.
    static func readable(from text: String) -> String {
        rewriting(text, preview: { _ in nil }, card: { _ in DesktopCardDirective.spokenNote })
    }
}

/// What a Desktop card says about itself.
struct DesktopCardContent: Equatable {
    let title: String
    let summary: String

    /// hermes-rich-ui's card record: `meta.title` and `meta.summary` are
    /// the plain-text fallback its author wrote (CONTRACTS §1).
    init?(richUIResponse json: [String: Any]) {
        guard json["ok"] as? Bool == true,
              let card = json["card"] as? [String: Any],
              let surface = (card["surface"] as? [String: Any])?["createSurface"] as? [String: Any] else { return nil }
        let meta = (surface["dataModel"] as? [String: Any])?["meta"] as? [String: Any] ?? [:]
        let rootTitle = (surface["components"] as? [[String: Any]])?
            .first { $0["id"] as? String == "root" }?["title"] as? String
        let metaTitle = Self.cleaned(meta["title"] as? String, limit: 200)
        let title = metaTitle.isEmpty ? Self.cleaned(rootTitle, limit: 200) : metaTitle
        let summary = Self.cleaned(meta["summary"] as? String, limit: 2_000)
        guard !title.isEmpty || !summary.isEmpty else { return nil }
        self.title = title
        self.summary = summary
    }

    init(title: String, summary: String) {
        self.title = title
        self.summary = summary
    }

    private static func cleaned(_ value: String?, limit: Int) -> String {
        String((value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

/// Cards read this launch, so a row scrolled back into view doesn't ask
/// again. One that couldn't be read is asked again after a while: the
/// plugin may have been installed since, or the network was down.
@MainActor
enum DesktopCardContents {
    private enum Entry {
        case found(DesktopCardContent)
        case missing(Date)
    }

    private static var entries: [String: Entry] = [:]
    static let retryInterval: TimeInterval = 300

    static func content(for card: DesktopCardDirective, resolver: GatewayMediaDataURLResolver?) async -> DesktopCardContent? {
        guard let id = card.richUICardID, let resolver else { return nil }
        let key = "\(resolver.dashboardID?.uuidString ?? "")|\(id)"
        switch entries[key] {
        case .found(let content): return content
        case .missing(let since) where Date().timeIntervalSince(since) < retryInterval: return nil
        default: break
        }
        guard let json = await resolver.pluginJSON(path: "/api/plugins/hermes-rich-ui/cards/\(id)") else {
            if !Task.isCancelled { entries[key] = .missing(Date()) }
            return nil
        }
        guard let content = DesktopCardContent(richUIResponse: json) else {
            entries[key] = .missing(Date())
            return nil
        }
        entries[key] = .found(content)
        return content
    }

    /// What's already known, for a card's first frame.
    static func cached(for card: DesktopCardDirective, resolver: GatewayMediaDataURLResolver?) -> DesktopCardContent? {
        guard let id = card.richUICardID, let resolver,
              case .found(let content) = entries["\(resolver.dashboardID?.uuidString ?? "")|\(id)"] else { return nil }
        return content
    }
}

extension GatewayMediaDataURLResolver {
    /// A plugin's read-only JSON route on the connected Hermes, or nil when
    /// it can't be read (not installed, not signed in, no network).
    func pluginJSON(path: String) async -> [String: Any]? {
        guard let bridge = connectedDashboardBridge else { return nil }
        do {
            let json = try await bridge.requestJSON(path: path, maxResponseBytes: DataURLLimits.maxJSONResponseBytes)
            return connectedDashboardBridge === bridge ? json : nil
        } catch {
            return nil
        }
    }
}

/// The card in the reply.
struct DesktopCardBlock: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let card: DesktopCardDirective

    @Environment(\.gatewayMediaFiles) private var gatewayMediaFiles
    /// What was read, with the card it was read for: a view reused for
    /// another card never shows the last one's text.
    @State private var loaded: (card: DesktopCardDirective, content: DesktopCardContent?)?
    @State private var showsDetails = false

    var body: some View {
        let content = loaded?.card == card ? loaded?.content : DesktopCardContents.cached(for: card, resolver: gatewayMediaFiles)
        Button {
            showsDetails = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label {
                        Text(verbatim: card.plugin).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: "rectangle.on.rectangle")
                    }
                    .scaledFont(.caption2.monospaced().weight(.semibold))
                    Spacer(minLength: 8)
                    if content != nil {
                        Text("Full card in Hermes Desktop")
                            .scaledFont(.caption2)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
                Group {
                    if let title = content?.title, !title.isEmpty {
                        Text(verbatim: title)
                    } else {
                        Text("Card for Hermes Desktop")
                    }
                }
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                Group {
                    if let summary = content?.summary, !summary.isEmpty {
                        Text(verbatim: summary)
                    } else {
                        Text("Open this chat in Hermes Desktop to see it.")
                    }
                }
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.secondary.opacity(0.20), lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: card) {
            guard loaded?.card != card else { return }
            let content = await DesktopCardContents.content(for: card, resolver: gatewayMediaFiles)
            guard !Task.isCancelled else { return }
            loaded = (card, content)
        }
        .sheet(isPresented: $showsDetails) {
            DesktopCardSheet(card: card, content: content)
        }
    }
}

/// The card's details: its whole summary, where it opens, and the
/// directive as the reply wrote it.
struct DesktopCardSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let card: DesktopCardDirective
    let content: DesktopCardContent?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let title = content?.title, !title.isEmpty {
                        Text(verbatim: title)
                            .scaledFont(.title3.weight(.semibold))
                            .textSelection(.enabled)
                    }
                    if let summary = content?.summary, !summary.isEmpty {
                        Text(verbatim: summary)
                            .scaledFont(.body)
                            .textSelection(.enabled)
                    }
                    Text("Open this chat in Hermes Desktop to see it.")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                    Text(verbatim: card.source)
                        .scaledFont(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(Text(verbatim: card.plugin))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
