//
//  PulseLookViews.swift
//  Conduit
//
//  A Pulse card's body, drawn from the pick it was made from (PulseLook,
//  plugin 0.149.0): the Pulse screen keeps one frame for every card (what
//  it's about and when, its words, its buttons) and draws what's inside by
//  its shape. A date as a calendar tile, something due as the days left on
//  a bar from when it was noticed, a job's runs as dots, a promise in the
//  words it was made, a status as a pill, steps as a stepper, and a card
//  body as a chat draws a conduit_show card. Plain words draw nothing more.
//

import SwiftUI

struct PulseLookBody: View {
    let look: PulseLook
    var dimmed = false

    var body: some View {
        Group {
            switch look.body {
            case let .date(day, what, whose):
                dateTile(day, what: what, whose: whose)
            case let .due(due, hasTime, noticed):
                dueBar(due, hasTime: hasTime, noticed: noticed)
            case let .runs(job, results):
                runDots(job, results: results)
            case let .promise(said, person, place, when):
                promise(said, details: [person, place, when])
            case let .status(label, state):
                status(label, state: state)
            case let .steps(names, at):
                stepper(names, at: at)
            case let .drawn(card):
                RichCardView(card: card)
            case .brief, .plain:
                EmptyView()
            }
        }
        .opacity(dimmed ? 0.7 : 1)
    }

    private func dateTile(_ day: Date, what: String, whose: String) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(verbatim: day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .scaledFont(.caption2.weight(.semibold))
                    .foregroundStyle(Color.conduitAccent)
                Text(verbatim: day.formatted(.dateTime.day()))
                    .scaledFont(.title2.weight(.semibold))
                Text(verbatim: day.formatted(.dateTime.month(.abbreviated)))
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 52)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: day.formatted(date: .complete, time: .omitted)))
            VStack(alignment: .leading, spacing: 2) {
                let title = [whose, what].filter { !$0.isEmpty }.joined(separator: " · ")
                if !title.isEmpty {
                    Text(verbatim: title)
                        .scaledFont(.subheadline.weight(.medium))
                }
                Text(verbatim: day.formatted(.relative(presentation: .named)))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func dueBar(_ due: Date, hasTime: Bool, noticed: Date?) -> some View {
        let now = Date()
        let late = due < now
        let progress: Double = {
            guard let noticed, due > noticed else { return late ? 1 : 0.5 }
            return min(1, max(0, now.timeIntervalSince(noticed) / due.timeIntervalSince(noticed)))
        }()
        let dueText = hasTime ? due.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute())
            : due.formatted(.dateTime.weekday(.abbreviated).day().month())
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: due.formatted(.relative(presentation: .named)))
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(late ? Color.red : progress > 0.75 ? Color.orange : Color.primary)
            ProgressView(value: progress)
                .tint(late ? .red : progress > 0.75 ? .orange : .conduitAccent)
                .accessibilityHidden(true)
            HStack {
                if let noticed {
                    Text(verbatim: noticed.formatted(.dateTime.day().month()))
                }
                Spacer(minLength: 0)
                Text(verbatim: dueText)
            }
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func runDots(_ job: String, results: [Bool]) -> some View {
        let failedCount = results.filter { !$0 }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(results.enumerated()), id: \.offset) { _, ok in
                    Circle()
                        .fill(ok ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                }
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
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func promise(_ said: String, details: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(Color.conduitAccent.opacity(0.6))
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "“\(said)”")
                    .italic()
                    .scaledFont(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                let line = details.filter { !$0.isEmpty }.joined(separator: " · ")
                if !line.isEmpty {
                    Text(verbatim: line)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func status(_ label: String, state: PulseLook.State) -> some View {
        let tint: Color = state == .ok ? .green : state == .warn ? .orange : .red
        let title: String = switch state {
        case .ok: AppLocalization.string("OK")
        case .warn: AppLocalization.string("Warning")
        case .fail: AppLocalization.string("Failing")
        }
        return HStack(spacing: 8) {
            Text(verbatim: label)
                .scaledFont(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(verbatim: title)
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.15)))
        }
        .accessibilityElement(children: .combine)
    }

    private func stepper(_ names: [String], at: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, _ in
                    Circle()
                        .fill(index <= at ? Color.conduitAccent : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)
                    if index < names.count - 1 {
                        Rectangle()
                            .fill(index < at ? Color.conduitAccent : Color.secondary.opacity(0.3))
                            .frame(height: 2)
                    }
                }
            }
            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    Text(verbatim: name)
                        .scaledFont(.caption2.weight(index == at ? .semibold : .regular))
                        .foregroundStyle(index == at ? Color.primary : Color.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity,
                               alignment: index == 0 ? .leading : index == names.count - 1 ? .trailing : .center)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AppLocalization.string(
            "Step \(String(at + 1)) of \(String(names.count)) · \(names[at])")))
    }
}

/// The morning brief in its parts (0.149.0): its summary, then what's on
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
