//
//  ConnectionSetupComponents.swift
//  Conduit
//
//  The Connection Setup assistant's V2 pieces: the step header, cards of
//  choice rows, checklists, fields and notes. Drawn like the V2 sign-in
//  screens (settings cards over the still backdrop, gold glyphs, the gold
//  capsule to move on) so the assistant reads as part of the same app.
//

import SwiftUI

/// A step's header: its glyph in a gold well, the "Step N of 2" label and
/// progress bar for the numbered questions, then the title and its
/// explanation.
struct ConnectionSetupHeader: View {
    let symbol: String
    var progress: String? = nil
    /// 1-based position in the numbered questions, for the progress bar.
    var progressStep: Int? = nil
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .scaledFont(.title3.weight(.semibold))
                    .conduitFixedGlyph()
                    .foregroundStyle(Color.conduitAccent)
                    .frame(width: 48, height: 48)
                    .background(Color.conduitAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.conduitAccent.opacity(0.3), lineWidth: 0.5)
                    }
                    .accessibilityHidden(true)
                if let progress {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: progress)
                            .scaledFont(.footnote.weight(.semibold))
                            .foregroundStyle(Color.conduitAccent)
                            .accessibilityIdentifier("setup.step-label")
                        if let progressStep {
                            ConnectionSetupProgressBar(step: progressStep, count: ConnectionSetupFlow.progressStepCount)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title)
                    .scaledFont(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(verbatim: detail)
                        .scaledFont(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One short gold segment per numbered question: the done ones filled.
private struct ConnectionSetupProgressBar: View {
    let step: Int
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...count, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Color.conduitAccent : Color.primary.opacity(0.14))
                    .frame(width: 22, height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A card of rows with hairlines between them, as in V2 Settings.
struct ConnectionSetupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard()
    }
}

/// A card holding free content (a checklist, a test's stages) with the
/// card's inner padding.
struct ConnectionSetupPanel<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard()
    }
}

/// A choice row in a card: an optional gold glyph, the name over a short
/// detail, a badge, and a trailing checkmark or chevron. The whole row is
/// the target.
struct ConnectionSetupChoiceRow: View {
    enum Accessory {
        case chevron
        case checkmark(selected: Bool)
        case disclosure(expanded: Bool)
    }

    var icon: String? = nil
    let title: String
    var detail: String? = nil
    var badge: String? = nil
    var accessory: Accessory = .chevron
    var showsDivider = false
    let identifier: String
    let action: () -> Void

    /// A disclosure row says whether its content is open.
    private var disclosureState: String {
        guard case .disclosure(let expanded) = accessory else { return "" }
        return expanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed")
    }

    private var isSelected: Bool {
        if case .checkmark(selected: true) = accessory { return true }
        return false
    }

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 14) {
                if let icon {
                    Image(systemName: icon)
                        .scaledFont(.body.weight(.medium))
                        .conduitFixedGlyph()
                        .foregroundStyle(Color.conduitAccent)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .scaledFont(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let badge {
                        Text(verbatim: badge)
                            .scaledFont(.caption.weight(.semibold))
                            .foregroundStyle(Color.conduitAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.conduitAccent.opacity(0.15), in: Capsule())
                            .padding(.vertical, 1)
                    }
                    if let detail {
                        Text(verbatim: detail)
                            .scaledFont(.subheadline)
                            .foregroundStyle(Color.primary.opacity(0.58))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(isSelected ? Color.conduitAccent.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if showsDivider {
                V2RowDivider(leadingInset: icon == nil ? 16 : 56)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(disclosureState)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var trailing: some View {
        switch accessory {
        case .chevron:
            Image(systemName: "chevron.right")
                .scaledFont(.footnote.weight(.semibold))
                .foregroundStyle(.conduitTertiary)
                .accessibilityHidden(true)
        case .checkmark(let selected):
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .scaledFont(.title3)
                .conduitFixedGlyph()
                .foregroundStyle(selected ? Color.conduitAccent : Color.primary.opacity(0.25))
                .accessibilityHidden(true)
        case .disclosure(let expanded):
            Image(systemName: "chevron.down")
                .scaledFont(.footnote.weight(.semibold))
                .foregroundStyle(.conduitTertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .accessibilityHidden(true)
        }
    }
}

/// One line of a checklist: a gold dot, number, or check before the text.
struct ConnectionSetupListItem: View {
    enum Marker {
        case bullet
        case number(Int)
        case check
    }

    let marker: Marker
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            markerView
                .frame(width: 22, alignment: .center)
            Text(verbatim: text)
                .scaledFont(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var markerView: some View {
        switch marker {
        case .bullet:
            Circle()
                .fill(Color.conduitAccent)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0.height + 2 }
                .accessibilityHidden(true)
        case .number(let number):
            Text(verbatim: "\(number)")
                .scaledFont(.caption.weight(.bold))
                .monospacedDigit()
                .conduitFixedGlyph()
                .foregroundStyle(Color.conduitAccent)
                .frame(width: 22, height: 22)
                .background(Color.conduitAccent.opacity(0.15), in: Circle())
        case .check:
            Image(systemName: "checkmark.circle")
                .scaledFont(.subheadline)
                .conduitFixedGlyph()
                .foregroundStyle(Color.conduitAccent)
                .accessibilityHidden(true)
        }
    }
}

/// A quiet footnote with a leading glyph: what Conduit will or won't do.
struct ConnectionSetupNote: View {
    var symbol = "info.circle"
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labelled field: the name in small secondary type over the field's
/// well, as on the sign-in screens.
struct ConnectionSetupField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .scaledFont(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityHidden(true)
            content
        }
    }
}

/// The address being set up, as a card with the server glyph.
struct ConnectionSetupAddressCard: View {
    let title: String
    let address: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .scaledFont(.body.weight(.medium))
                .conduitFixedGlyph()
                .foregroundStyle(Color.conduitAccent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: address)
                    .scaledFont(.callout.weight(.medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup.address-preview")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard()
    }
}

/// An outcome banner: green for ready, gold for a step still to take, red
/// for a failure, with the outcome's text beside its glyph.
enum ConnectionSetupBannerTone {
    case success
    case pending
    case failure

    var color: Color {
        switch self {
        case .success: return .green
        case .pending: return .conduitAccent
        case .failure: return .red
        }
    }

    var symbol: String {
        switch self {
        case .success: return "checkmark.seal.fill"
        case .pending: return "arrow.right.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }
}

struct ConnectionSetupBanner<Content: View>: View {
    let tone: ConnectionSetupBannerTone
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone.symbol)
                .scaledFont(.body)
                .foregroundStyle(tone.color)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tone.color.opacity(0.2), lineWidth: 0.5)
        }
    }
}
