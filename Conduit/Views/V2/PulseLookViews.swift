//
//  PulseLookViews.swift
//  Conduit
//
//  A Pulse card's body, drawn from the pick it was made from (PulseLook,
//  plugin 0.150.0): the Pulse screen keeps one frame for every card (what
//  it's about and when, its words, its buttons) and draws what's inside by
//  its shape, each in its own colour and place so the type reads at a
//  glance (PulseLookStyle). A date as a coloured day down the card's edge,
//  something due as a countdown over a bar from when it was noticed, a
//  job's runs as blocks across the top, a promise in the words it was
//  made, a status as its state writ large on a tinted card, steps as a
//  checklist, and a card body as a chat draws a conduit_show card. Plain
//  words draw nothing more.
//

import SwiftUI

/// How a card's type shows at a glance (Eric, 2026-11-10: the cards still
/// looked alike): each shape has its own colour, a symbol, and a place on
/// the card for what defines it. A date stands as a coloured day down the
/// card's leading edge, a job's runs as a band across its top, and what's
/// due, a promise and a status lead the card above its words; steps list
/// under them.
struct PulseLookStyle {
    enum Place { case side, band, lead, under, none }

    let tint: Color
    let symbol: String
    let place: Place

    init(_ body: PulseLook.Body, now: Date = Date()) {
        let parts = Self.parts(body, now: now)
        tint = parts.0
        symbol = parts.1
        place = parts.2
    }

    private static func parts(_ body: PulseLook.Body, now: Date) -> (Color, String, Place) {
        switch body {
        case .date:
            return (.blue, "calendar", .side)
        case let .due(due, hasTime, _):
            let late = (hasTime ? due : PulseLook.endOfDay(due)) < now
            return (late ? .red : .orange, "hourglass", .lead)
        case let .runs(_, results):
            return (results.contains(false) ? .red : .green, "arrow.triangle.2.circlepath", .band)
        case .promise:
            return (.purple, "quote.opening", .lead)
        case let .status(_, state):
            switch state {
            case .ok: return (.green, "checkmark.circle.fill", .lead)
            case .warn: return (.orange, "exclamationmark.triangle.fill", .lead)
            case .fail: return (.red, "xmark.octagon.fill", .lead)
            }
        case .steps:
            return (.teal, "checklist", .under)
        case .drawn:
            return (.conduitAccent, "", .under)
        case .brief, .plain:
            return (.conduitAccent, "", .none)
        }
    }

    /// A status card is tinted whole: its state is the news.
    static func washes(_ body: PulseLook.Body) -> Bool {
        if case .status = body { return true }
        return false
    }
}

struct PulseLookBody: View {
    let look: PulseLook
    /// Drawn inside the Pulse frame, which stands a date's day down the
    /// card's edge; anywhere else (the morning brief's block) the date's
    /// line says the day itself.
    var framed = false

    private var style: PulseLookStyle { PulseLookStyle(look.body) }
    private var tint: Color { style.tint }

    var body: some View {
        Group {
            switch look.body {
            case let .date(day, what, whose):
                dateLine(day, what: what, whose: whose)
            case let .due(due, hasTime, noticed):
                dueCountdown(due, hasTime: hasTime, noticed: noticed)
            case let .runs(job, results):
                runBlocks(job, results: results)
            case let .promise(said, person, place, when):
                promise(said, details: [person, place, when])
            case let .status(label, state):
                status(label, state: state)
            case let .steps(names, at):
                checklist(names, at: at)
            case let .drawn(card):
                RichCardView(card: card)
            case .brief, .plain:
                EmptyView()
            }
        }
    }

    /// In the frame the day itself stands down the card's edge
    /// (PulseDateColumn): here, whose it is and how far off, after the day
    /// where there's no column.
    private func dateLine(_ day: Date, what: String, whose: String) -> some View {
        let title = [whose, what].filter { !$0.isEmpty }.joined(separator: " · ")
        let date = framed ? "" : day.formatted(.dateTime.weekday(.abbreviated).day().month().locale(AppLocalization.formattingLocale))
        return Text(verbatim: ([date, title, PulseLook.relativeDay(day)].filter { !$0.isEmpty }).joined(separator: " · "))
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func dueCountdown(_ due: Date, hasTime: Bool, noticed: Date?) -> some View {
        let now = Date()
        // A day with no time is due by that day's end: not late on the day.
        let by = hasTime ? due : PulseLook.endOfDay(due)
        let late = by < now
        // A bar needs a start: with no day it was noticed before the due
        // day (none, or the same day, as picks kept before 0.153.2 may say), only the day.
        let start = noticed.flatMap { by > $0 && !Calendar.current.isDate($0, inSameDayAs: due) ? $0 : nil }
        let progress: Double = {
            guard let start else { return late ? 1 : 0.5 }
            return min(1, max(0, now.timeIntervalSince(start) / by.timeIntervalSince(start)))
        }()
        let dueText = hasTime ? due.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute().locale(AppLocalization.formattingLocale))
            : due.formatted(.dateTime.weekday(.abbreviated).day().month().locale(AppLocalization.formattingLocale))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: style.symbol)
                    .scaledFont(.headline)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(verbatim: hasTime ? due.formatted(.relative(presentation: .named).locale(AppLocalization.formattingLocale)) : PulseLook.relativeDay(due))
                    .scaledFont(.title2.weight(.bold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text(verbatim: dueText)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if start != nil {
                ProgressView(value: progress)
                    .tint(tint)
                    .accessibilityHidden(true)
            }
        }
    }

    /// One block a run, oldest first, across the card's top band.
    private func runBlocks(_ job: String, results: [Bool]) -> some View {
        let failedCount = results.filter { !$0 }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(results.enumerated()), id: \.offset) { _, ok in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(ok ? Color.green : Color.red)
                        .frame(height: 22)
                        .frame(maxWidth: 36)
                }
                Spacer(minLength: 0)
            }
            .accessibilityHidden(true)
            HStack(spacing: 6) {
                if !job.isEmpty {
                    Text(verbatim: job)
                        .lineLimit(1)
                    Text(verbatim: "·")
                }
                Text(AppLocalization.string("Runs: \(results.count)"))
                Text(verbatim: "·")
                Text(AppLocalization.string("Failed: \(failedCount)"))
            }
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .accessibilityElement(children: .combine)
        }
    }

    /// The words as they were said lead the card.
    private func promise(_ said: String, details: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style.symbol)
                .scaledFont(.title2.weight(.bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: said)
                    .scaledFont(.title3.weight(.medium))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                let line = details.filter { !$0.isEmpty }.joined(separator: " · ")
                if !line.isEmpty {
                    Text(verbatim: line)
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func status(_ label: String, state: PulseLook.State) -> some View {
        let title: String = switch state {
        case .ok: AppLocalization.string("OK")
        case .warn: AppLocalization.string("Warning")
        case .fail: AppLocalization.string("Failing")
        }
        return HStack(spacing: 10) {
            Image(systemName: style.symbol)
                .scaledFont(.title.weight(.semibold))
                .foregroundStyle(style.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .scaledFont(.title3.weight(.bold))
                    .foregroundStyle(style.tint)
                Text(verbatim: label)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The steps as a list: done ones struck through, the one it's at in bold.
    private func checklist(_ names: [String], at: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 8) {
                    Image(systemName: index < at ? "checkmark.circle.fill" : index == at ? "circle.inset.filled" : "circle")
                        .foregroundStyle(index <= at ? tint : Color.secondary.opacity(0.5))
                    Text(verbatim: name)
                        .strikethrough(index < at)
                        .fontWeight(index == at ? .semibold : .regular)
                        .foregroundStyle(index == at ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .scaledFont(.subheadline)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AppLocalization.string(
            "Step \(String(at + 1)) of \(String(names.count)) · \(names[at])")))
    }
}

/// A date card's day, down its leading edge in the type's colour.
struct PulseDateColumn: View {
    let day: Date
    var tint: Color = .blue

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: day.formatted(.dateTime.weekday(.abbreviated).locale(AppLocalization.formattingLocale)).uppercased())
                .scaledFont(.caption.weight(.bold))
            Text(verbatim: day.formatted(.dateTime.day().locale(AppLocalization.formattingLocale)))
                .scaledFont(.largeTitle.weight(.bold))
            Text(verbatim: day.formatted(.dateTime.month(.abbreviated).locale(AppLocalization.formattingLocale)).uppercased())
                .scaledFont(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .frame(minWidth: 76, maxHeight: .infinity)
        .padding(.horizontal, 6)
        .background(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: day.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(AppLocalization.formattingLocale))))
    }
}

/// The morning brief in its parts (0.150.0): its summary, then what's on
/// today and what's still open, each counted, and how many held cards it
/// brought.
struct PulseBriefParts: View {
    let summary: String
    let today: [String]
    let open: [String]
    let heldCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !summary.isEmpty {
                Text(verbatim: summary)
                    .scaledFont(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !today.isEmpty {
                section(AppLocalization.string("Today (\(today.count))"), today)
            }
            if !open.isEmpty {
                section(AppLocalization.string("Still open (\(open.count))"), open)
            }
            if heldCount > 0 {
                Text(AppLocalization.string("Held for this morning: \(heldCount)"))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(Color.conduitAccent)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: line)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .scaledFont(.subheadline)
                .foregroundStyle(Color.primary.opacity(0.86))
            }
        }
    }
}
