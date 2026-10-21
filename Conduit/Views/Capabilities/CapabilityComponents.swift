//
//  CapabilityComponents.swift
//  Conduit
//
//  The pieces Settings > Capabilities' four tabs share: a named section
//  over a card of rows (as the other V2 settings pages), a row with its
//  glyph, pills and count, and a small pill.
//

import SwiftUI

enum CapabilitiesTab: String, CaseIterable, Identifiable {
    case skills
    case tools
    case connectors
    case plugins

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skills: return AppLocalization.string("Skills")
        case .tools: return AppLocalization.string("Tools")
        case .connectors: return AppLocalization.string("Connectors")
        case .plugins: return AppLocalization.string("Plugins")
        }
    }
}

/// A small word in a capsule: a provenance, a state, a tier.
struct CapabilityPill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }
}

struct CapabilityPillModel: Hashable {
    let text: String
    var tint: Color = .secondary
}

/// A capability's row: its glyph on a faint disc (gold when it's on), the
/// name, a line of category and pills, two lines of description, and a
/// count at the trailing edge.
struct CapabilityRowLabel: View {
    let symbol: String
    var active = true
    let title: String
    var subtitle: String?
    var pills: [CapabilityPillModel] = []
    var detail: String?
    var meta: String?
    /// A status dot before the count: a connector's state.
    var metaDot: Color?
    var chevron = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .conduitFixedGlyph()
                .foregroundStyle(active ? Color.conduitAccent : Color.secondary)
                .frame(width: 30, height: 30)
                .background((active ? Color.conduitAccent : Color.secondary).opacity(0.13), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                if subtitle != nil || !pills.isEmpty {
                    HStack(spacing: 6) {
                        if let subtitle {
                            Text(verbatim: subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ForEach(pills, id: \.self) { pill in
                            CapabilityPill(text: pill.text, tint: pill.tint)
                        }
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let metaDot {
                Circle()
                    .fill(metaDot)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            if let meta {
                Text(verbatim: meta)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.conduitTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// A hairline between rows of a card, inset past the glyph.
struct CapabilityRowDivider: View {
    var body: some View {
        Divider().opacity(0.6).padding(.leading, 41)
    }
}

/// One row of a card with the hairline above it when it isn't the first:
/// one view per ForEach element, so the card's lazy stack places each row
/// as one piece.
struct CapabilityCardRow<Content: View>: View {
    let divided: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if divided { CapabilityRowDivider() }
            content
        }
    }
}

/// A named group over its card, the trailing accessory (a menu, a count)
/// on the name's line, and a footnote under it.
struct CapabilitySection<Content: View, Accessory: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .conduitAccent
    var footer: String?
    private let accessory: Accessory
    private let content: Content

    init(
        title: String,
        symbol: String,
        tint: Color = .conduitAccent,
        footer: String? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.footer = footer
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                SettingsSectionHeader(title: title, symbol: symbol, tint: tint)
                Spacer(minLength: 8)
                accessory
                    .padding(.trailing, 8)
            }
            // Lazy, so a tab of hundreds of skills or plugins builds and
            // re-renders only the rows on screen: an eager card of every row
            // redid them all on each AppState or store publish, which made
            // Skills and Plugins stutter while scrolling.
            LazyVStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard()
            if let footer {
                Text(verbatim: footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension CapabilitySection where Accessory == EmptyView {
    init(
        title: String,
        symbol: String,
        tint: Color = .conduitAccent,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, symbol: symbol, tint: tint, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

/// A tab's page: its sections down the backdrop, pull to refresh, the list
/// fading out under the bar.
struct CapabilityTabScroll<Content: View>: View {
    let refresh: () async -> Void
    private let content: Content

    init(refresh: @escaping () async -> Void, @ViewBuilder content: () -> Content) {
        self.refresh = refresh
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .modifier(V2SoftTopScrollEdge(isOn: true))
        .refreshable { await refresh() }
    }
}

/// A refresh that failed while the tab still shows what it read before.
struct CapabilityRefreshBanner: View {
    let message: String

    var body: some View {
        Text(verbatim: AppLocalization.string("Refresh failed: \(message)"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity)
    }
}

/// A tab with nothing to show: a symbol, a line and what to do.
struct CapabilityEmptyState: View {
    let title: String
    let symbol: String
    var message: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let message {
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button(AppLocalization.string("Try Again"), action: retry)
                    .buttonStyle(.bordered)
                    .tint(.conduitAccent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

/// A small action button at a row's trailing edge: Install, Update.
struct CapabilityRowButton: View {
    let title: String
    var busy = false
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 44)
            } else {
                Text(verbatim: title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.conduitAccent)
        .disabled(busy)
    }
}

/// Chips that wrap onto as many lines as they need: a toolset's tools.
struct CapabilityFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// A tab's filtered and sorted rows, kept while what they're made from stays
/// the same. A tab re-renders on every AppState or store publish, and
/// sorting hundreds of names with localized compares each time cost frames.
final class CapabilityListMemo<Input: Equatable, Output> {
    private var last: (input: Input, output: Output)?

    func value(for input: Input, _ compute: (Input) -> Output) -> Output {
        if let last, last.input == input { return last.output }
        let output = compute(input)
        last = (input, output)
        return output
    }
}

enum CapabilityFormat {
    /// `×1.2k`: how often a skill or tool was used.
    static func uses(_ count: Int) -> String {
        "×" + count.formatted(.number.notation(.compactName))
    }
}
