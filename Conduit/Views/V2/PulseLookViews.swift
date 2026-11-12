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
//  checklist, a value large with how it moved, who the user is waiting on
//  and for how long, what a watch found and where, and a card body as a chat draws a conduit_show card.
//  Plain words draw nothing more.
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
        case .number:
            return (.indigo, "number", .lead)
        case .waiting:
            return (.pink, "person.badge.clock", .lead)
        case .found:
            return (Self.foundTint, "binoculars.fill", .lead)
        case .drawn:
            return (.conduitAccent, "", .under)
        case .brief, .plain:
            return (.conduitAccent, "", .none)
        }
    }

    /// Mint, darker on a light screen, where the system's is too pale to read
    /// as large words.
    static let foundTint = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemMint : UIColor(red: 0, green: 0.52, blue: 0.47, alpha: 1)
    })

    /// A status card is tinted whole: its state is the news.
    static func washes(_ body: PulseLook.Body) -> Bool {
        if case .status = body { return true }
        return false
    }

    /// How a number moved from what it was: the good way, the other way,
    /// or, when which way is good wasn't said, only that it moved.
    enum Move: Equatable { case good, bad, unsaid }

    /// nil when there's no earlier value, or it's the same one.
    static func move(value: Double, was: Double?, better: PulseLook.Better?) -> Move? {
        guard let was, was != value else { return nil }
        guard let better else { return .unsaid }
        return (value > was) == (better == .up) ? .good : .bad
    }

    /// Whether a number is on the wrong side of its limit; never when
    /// which way is good wasn't said.
    static func pastLimit(value: Double, limit: Double?, better: PulseLook.Better?) -> Bool {
        guard let limit, let better else { return false }
        return better == .down ? value > limit : value < limit
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
            case let .number(label, value, unit, was, limit, better):
                number(label, value: value, unit: unit, was: was, limit: limit, better: better)
            case let .waiting(person, what, since):
                waiting(person, what: what, since: since)
            case let .found(asked, answer, place):
                found(asked, answer: answer, place: place)
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
            // One line that wraps, so a large text size keeps the job's name
            // whole rather than cutting it to fit the counts.
            Text(verbatim: [job, AppLocalization.string("Runs: \(results.count)"),
                            AppLocalization.string("Failed: \(failedCount)")]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
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

    /// The value leads the card, large, with how it moved from the earlier
    /// one: green when it went the good way, red when it went the other,
    /// grey when which way is good wasn't said. A limit it's past the wrong
    /// side of is red.
    private func number(_ label: String, value: Double, unit: String, was: Double?, limit: Double?,
                        better: PulseLook.Better?) -> some View {
        let move = PulseLookStyle.move(value: value, was: was, better: better)
        let moved: Color = move == .good ? .green : move == .bad ? .red : .secondary
        let past = PulseLookStyle.pastLimit(value: value, limit: limit, better: better)
        let amount = Text(verbatim: Self.amount(value, unit))
            .scaledFont(.title.weight(.bold))
            .foregroundStyle(tint)
        let change = was.flatMap { was in was == value ? nil : HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: value > was ? "arrow.up" : "arrow.down")
                .accessibilityHidden(true)
            Text(AppLocalization.string("from \(Self.amount(was, unit))"))
        }
        .scaledFont(.subheadline.weight(.semibold))
        .foregroundStyle(moved)
        // The arrow and its colour say which way and whether that's good
        // only to the eye: VoiceOver hears it in words.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.spokenChange(value: value, was: was, unit: unit, move: move ?? .unsaid))) }
        return VStack(alignment: .leading, spacing: 4) {
            // How it moved goes under the value when a large text size
            // leaves no room beside it, rather than both breaking.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    amount
                    change
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    amount.fixedSize(horizontal: false, vertical: true)
                    change.fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 0) {
                Text(verbatim: label)
                    .foregroundStyle(.secondary)
                if let limit {
                    Text(verbatim: " · ")
                        .foregroundStyle(.secondary)
                    Text(AppLocalization.string("Limit \(Self.amount(limit, unit))"))
                        .foregroundStyle(past ? Color.red : Color.secondary)
                        .accessibilityLabel(Text(verbatim: Self.spokenLimit(limit, unit: unit, past: past)))
                }
            }
            .scaledFont(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// How a number moved from what it was, in words: which way, and
    /// whether that's the good way when the card knows.
    static func spokenChange(value: Double, was: Double, unit: String, move: PulseLookStyle.Move) -> String {
        let from = amount(was, unit)
        switch (value > was, move) {
        case (true, .good): return AppLocalization.string("Up from \(from), better")
        case (true, .bad): return AppLocalization.string("Up from \(from), worse")
        case (true, .unsaid): return AppLocalization.string("Up from \(from)")
        case (false, .good): return AppLocalization.string("Down from \(from), better")
        case (false, .bad): return AppLocalization.string("Down from \(from), worse")
        case (false, .unsaid): return AppLocalization.string("Down from \(from)")
        }
    }

    /// A number's limit in words, saying so when the number is past it (the
    /// card shows that only by turning the limit red).
    static func spokenLimit(_ limit: Double, unit: String, past: Bool) -> String {
        past ? AppLocalization.string("Past the limit of \(amount(limit, unit))")
            : AppLocalization.string("Limit \(amount(limit, unit))")
    }

    /// A number in the app's language with its unit: a percent or a degree
    /// right after it, any other unit after a space.
    static func amount(_ value: Double, _ unit: String) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...2)).locale(AppLocalization.formattingLocale))
        guard !unit.isEmpty else { return number }
        return unit == "%" || unit.hasPrefix("°") ? number + unit : number + " " + unit
    }

    /// Who the user is waiting on leads the card, then what, then since
    /// when and how long that is.
    private func waiting(_ person: String, what: String, since: Date?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style.symbol)
                .scaledFont(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: person)
                    .scaledFont(.title3.weight(.bold))
                    .foregroundStyle(tint)
                Text(verbatim: what)
                    .scaledFont(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let since {
                    Text(AppLocalization.string("Since \(since.formatted(.dateTime.weekday(.abbreviated).day().month().locale(AppLocalization.formattingLocale))) · \(PulseLook.relativeDay(since))"))
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// What was found leads the card, then what the user asked for and
    /// where it turned up.
    private func found(_ asked: String, answer: String, place: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style.symbol)
                .scaledFont(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: answer)
                    .scaledFont(.title3.weight(.bold))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AppLocalization.string("You asked: \(asked) · \(place)"))
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
