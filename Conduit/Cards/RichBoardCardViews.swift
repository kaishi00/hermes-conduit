//
//  RichBoardCardViews.swift
//  Conduit
//
//  How the board kinds look (a table to sort, a timeline, a checklist, a
//  list, progress and a callout), how a board lays out its cards (one under
//  another, small ones side by side on a wide window, or tabs), and its
//  follow-ups. Each card sits on the same surface as the other rich cards
//  and says where its information is from.
//

import SwiftUI

// MARK: - Layout

/// The cards of one board, laid out by Conduit: one under another, small
/// cards in pairs when the window is wide, or one at a time as tabs.
struct RichBoardLayout: View {
    let cards: [RichCard]
    var tabs = false

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selected = 0

    var body: some View {
        if tabs, cards.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                RichBoardTabs(titles: cards.enumerated().map { index, card in
                    card.title ?? String(index + 1)
                }, selected: $selected)
                // Keyed by the card, so a card's own state (a table's sort)
                // never carries over to another in its place.
                RichCardView(card: cards[min(selected, cards.count - 1)])
                    .id(cards[min(selected, cards.count - 1)])
            }
            // A live update with fewer cards leaves the last one picked.
            .onChange(of: cards.count) { _, count in
                if selected >= count { selected = max(count - 1, 0) }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Self.rows(cards, wide: sizeClass == .regular).enumerated()), id: \.offset) { _, row in
                    if row.count == 2 {
                        HStack(alignment: .top, spacing: 12) {
                            RichCardView(card: row[0]).id(row[0])
                            RichCardView(card: row[1]).id(row[1])
                        }
                    } else if let card = row.first {
                        RichCardView(card: card).id(card)
                    }
                }
            }
        }
    }

    /// Small cards pair up side by side on a wide window, two at a time in
    /// the order Hermes gave; every other card has a row of its own.
    static func rows(_ cards: [RichCard], wide: Bool) -> [[RichCard]] {
        guard wide else { return cards.map { [$0] } }
        var rows: [[RichCard]] = []
        var waiting: RichCard?
        for card in cards {
            if isSmall(card) {
                if let first = waiting {
                    rows.append([first, card])
                    waiting = nil
                } else {
                    waiting = card
                }
            } else {
                if let first = waiting {
                    rows.append([first])
                    waiting = nil
                }
                rows.append([card])
            }
        }
        if let first = waiting { rows.append([first]) }
        return rows
    }

    static func isSmall(_ card: RichCard) -> Bool {
        switch card.kind {
        case .callout, .status: return true
        case .stats: return card.stats.count <= 2
        case .progress: return card.progress.count <= 2
        default: return false
        }
    }
}

private struct RichBoardTabs: View {
    let titles: [String]
    @Binding var selected: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    Button {
                        selected = index
                    } label: {
                        Text(verbatim: title)
                            .scaledFont(.subheadline.weight(index == selected ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(index == selected ? Color.primary : Color.secondary)
                            .background(Capsule().fill(index == selected ? Color.conduitAccent.opacity(0.18)
                                                                         : Color.primary.opacity(0.06)))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(index == selected ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
    }
}

/// A board's follow-ups under it: tap sends one as the user's message,
/// long-press puts it in the composer, as Predictive's reply chips do, and
/// like them they step aside while the user writes a draft (a tap would
/// replace it) and ignore taps in their first moment on screen.
struct RichBoardFollowUps: View {
    let followUps: [String]
    /// Holds the composer's draft (Predictive's store sees every edit).
    @ObservedObject var composer: PredictiveStore
    let send: (String) -> Void
    let edit: (String) -> Void

    @State private var shownAt = Date.distantFuture

    var body: some View {
        if composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CapabilityFlowLayout(spacing: 8) {
                ForEach(Array(followUps.enumerated()), id: \.offset) { index, text in
                    PredictiveReplyChip(text: text, isFirst: index == 0,
                                        send: { if ready { send($0) } },
                                        edit: { if ready { Haptics.light(); edit($0) } })
                }
            }
            .onAppear { shownAt = Date() }
        }
    }

    private var ready: Bool { Date().timeIntervalSince(shownAt) >= Predictive.tapGuard }
}

/// A board Conduit can't draw every card of: the cards' own Markdown, on
/// the cards' surface, so the row never shows part of it or nothing.
struct RichBoardMarkdown: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownText(source: markdown)
            Text("This version of Conduit can't draw these cards, so they're shown as text.")
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .richCardSurface()
    }
}

// MARK: - Table

struct RichTableCard: View {
    let card: RichCard
    /// Rows shown before Show all.
    static let shownRows = 12

    @State private var sort: (column: Int, ascending: Bool)?
    @State private var showsAll = false

    var body: some View {
        if let table = card.table {
            RichInfoCardFrame(title: card.title, source: card.source) {
                let rows = sort.map { table.sorted(by: $0.column, ascending: $0.ascending) } ?? table.rows
                let shown = showsAll ? rows : Array(rows.prefix(Self.shownRows))
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            ForEach(Array(table.columns.enumerated()), id: \.offset) { column, name in
                                header(name, column: column, numeric: table.isNumeric(column))
                            }
                        }
                        Divider()
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                                    Text(verbatim: cell)
                                        .scaledFont(.subheadline)
                                        .monospacedDigit()
                                        .foregroundStyle(cell == RichCardSchema.blankCell ? Color.secondary : Color.primary)
                                        .frame(maxWidth: 220, alignment: table.isNumeric(column) ? .trailing : .leading)
                                        .gridColumnAlignment(table.isNumeric(column) ? .trailing : .leading)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                if rows.count > Self.shownRows {
                    Button(showsAll ? AppLocalization.string("Show fewer") : AppLocalization.string("Show all")) {
                        showsAll.toggle()
                    }
                    .scaledFont(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.conduitAccent)
                    .frame(minHeight: 44)
                }
            }
        }
    }

    private func header(_ name: String, column: Int, numeric: Bool) -> some View {
        Button {
            if let current = sort, current.column == column {
                sort = (column, !current.ascending)
            } else {
                // Numbers start biggest first, text from A.
                sort = (column, !numeric)
            }
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: name)
                if let sort, sort.column == column {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .scaledFont(.caption2.weight(.bold))
                        .accessibilityHidden(true)
                }
            }
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Sorts the table by this column"))
        .accessibilityValue(sort?.column == column
                            ? Text(sort?.ascending == true ? AppLocalization.string("Sorted ascending")
                                                           : AppLocalization.string("Sorted descending"))
                            : Text(verbatim: ""))
    }
}

// MARK: - Timeline

struct RichTimelineCard: View {
    let card: RichCard

    @Environment(\.openURL) private var openURL

    var body: some View {
        RichInfoCardFrame(title: card.title, source: card.source) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(card.timeline.enumerated()), id: \.offset) { _, day in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: day.label)
                                .scaledFont(.subheadline.weight(.bold))
                                .foregroundStyle(Color.conduitAccent)
                            if let title = day.title {
                                Text(verbatim: title)
                                    .scaledFont(.subheadline.weight(.semibold))
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        ForEach(Array(day.stops.enumerated()), id: \.offset) { index, stop in
                            stopRow(stop, last: index == day.stops.count - 1)
                        }
                    }
                }
            }
        }
    }

    private func stopRow(_ stop: RichTimelineDay.Stop, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.conduitAccent)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                if !last {
                    Rectangle()
                        .fill(Color.conduitAccent.opacity(0.3))
                        .frame(width: 2)
                }
            }
            .frame(width: 8)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let time = stop.time {
                        Text(verbatim: time)
                            .scaledFont(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: stop.text)
                        .scaledFont(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let place = stop.place, let url = Self.mapsURL(place) {
                    Button {
                        openURL(url)
                    } label: {
                        Label {
                            Text(verbatim: place)
                        } icon: {
                            Image(systemName: "mappin.and.ellipse")
                        }
                        .scaledFont(.caption)
                        .foregroundStyle(Color.conduitAccent)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the map"))
                }
                if let note = stop.note {
                    Text(verbatim: note)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, last ? 0 : 6)
        }
    }

    /// An Apple Maps search for a stop's place.
    static func mapsURL(_ place: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: place)]
        return components?.url
    }
}

// MARK: - Checklist

struct RichChecklistCard: View {
    let card: RichCard

    @Environment(\.richChecklistContext) private var context
    @Environment(\.richChecklistInChat) private var inChat
    @ObservedObject private var memory = RichChecklistMemory.shared

    var body: some View {
        let key = RichChecklistMemory.listKey(for: card)
        let scope = context?.scope ?? RichChecklistMemory.localScope
        // A chat's ticks are on the host; the call screen's never stand in.
        let ticked = inChat && context == nil ? [] : memory.ticked(scope: scope, key: key)
        RichInfoCardFrame(title: card.title, source: card.source) {
            VStack(alignment: .leading, spacing: 12) {
                let done = card.checklist.filter { ticked.contains($0.text.lowercased()) }.count
                Text(AppLocalization.string("\(String(done)) of \(String(card.checklist.count)) done"))
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(Self.groups(card.checklist).enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 4) {
                        if let name = group.name {
                            Text(verbatim: name)
                                .scaledFont(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                            row(item, done: ticked.contains(item.text.lowercased()), key: key, scope: scope)
                        }
                    }
                }
            }
        }
        .task(id: TaskKey(scope: scope, key: key)) {
            await memory.refresh(context: context, key: key)
        }
    }

    private struct TaskKey: Hashable {
        let scope: String
        let key: String
    }

    private func row(_ item: RichChecklistItem, done: Bool, key: String, scope: String) -> some View {
        Button {
            Haptics.light()
            memory.toggle(item.text, card: card, key: key, context: context)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .scaledFont(.title3)
                    .foregroundStyle(done ? Color.conduitAccent : Color.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: item.text)
                    .scaledFont(.subheadline)
                    .strikethrough(done)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(inChat && context == nil)
        .accessibilityValue(done ? Text("Done") : Text(verbatim: ""))
    }

    /// Items under their group headings, in the order Hermes gave: a group
    /// that comes back later continues where it first appeared.
    static func groups(_ items: [RichChecklistItem]) -> [(name: String?, items: [RichChecklistItem])] {
        var order: [String?] = []
        var grouped: [String: [RichChecklistItem]] = [:]
        for item in items {
            let name = item.group ?? ""
            if grouped[name] == nil { order.append(item.group) }
            grouped[name, default: []].append(item)
        }
        return order.map { ($0, grouped[$0 ?? ""] ?? []) }
    }
}

// MARK: - List

struct RichListCard: View {
    let card: RichCard

    @Environment(\.openURL) private var openURL

    var body: some View {
        RichInfoCardFrame(title: card.title, source: card.source) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(card.list.enumerated()), id: \.offset) { index, item in
                    if let url = item.url {
                        Button {
                            openURL(url)
                        } label: {
                            row(item, number: index + 1, opens: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Opens the page"))
                    } else {
                        row(item, number: index + 1, opens: false)
                    }
                }
            }
        }
    }

    private func row(_ item: RichListItem, number: Int, opens: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if card.ranked {
                Text(verbatim: "\(number)")
                    .scaledFont(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.conduitAccent)
                    .frame(minWidth: 22, alignment: .trailing)
            }
            if let photo = item.photo {
                AsyncImage(url: photo.url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.primary.opacity(0.06)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(Text("Source: \(photo.source)"))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(opens ? Color.conduitAccent : Color.primary)
                if let detail = item.detail {
                    Text(verbatim: detail)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value = item.value {
                Text(verbatim: value)
                    .scaledFont(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Progress

struct RichProgressCard: View {
    let card: RichCard

    var body: some View {
        RichInfoCardFrame(title: card.title, source: card.source) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(card.progress.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: item.label)
                                .scaledFont(.subheadline.weight(.semibold))
                            Spacer(minLength: 8)
                            Text(verbatim: Self.amount(item))
                                .scaledFont(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: item.fraction)
                            .tint(item.fraction >= 1 ? Color.green : Color.conduitAccent)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Text(verbatim: "\(Int((item.fraction * 100).rounded()))%"))
                }
            }
        }
    }

    /// "1,250 of 5,000 USD", in the user's number format.
    static func amount(_ item: RichProgress) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
            .locale(AppLocalization.formattingLocale)
        let unit = item.unit.map { " \($0)" } ?? ""
        return AppLocalization.string("\(item.value.formatted(format)) of \(item.goal.formatted(format))") + unit
    }
}

// MARK: - Callout

struct RichCalloutCard: View {
    let card: RichCard

    var body: some View {
        if let callout = card.callout {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbol(callout.tone))
                    .scaledFont(.title3)
                    .foregroundStyle(Self.tint(callout.tone))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: card.title ?? Self.name(callout.tone))
                        .scaledFont(.subheadline.weight(.semibold))
                    Text(verbatim: callout.text)
                        .scaledFont(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let source = card.source {
                        RichInfoSourceLine(source: source)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Self.tint(callout.tone).opacity(0.1))
            .richCardSurface()
            .accessibilityElement(children: .combine)
        }
    }

    static func symbol(_ tone: RichCallout.Tone) -> String {
        switch tone {
        case .tip: return "lightbulb"
        case .note: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        }
    }

    static func tint(_ tone: RichCallout.Tone) -> Color {
        switch tone {
        case .tip: return Color.green
        case .note: return Color.conduitAccent
        case .warning: return Color.orange
        }
    }

    static func name(_ tone: RichCallout.Tone) -> String {
        switch tone {
        case .tip: return AppLocalization.string("Tip")
        case .note: return AppLocalization.string("Note")
        case .warning: return AppLocalization.string("Warning")
        }
    }
}
