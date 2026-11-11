import AppIntents
import SwiftUI
import WidgetKit

/// Pulse on the Home Screen (issue 2190): the newest open cards, each with
/// Done, Do it and Not now working in place, read from the host by the
/// widget itself (PulseWidgetAccess). A tap on a card's words opens it on
/// the Pulse screen.
struct PulseWidget: Widget {
    let kind = ConduitWidgetKind.pulse

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PulseWidgetProvider()) { entry in
            PulseWidgetView(entry: entry)
        }
        .configurationDisplayName("Pulse")
        .description("See what Pulse brought up, and handle it without opening Conduit.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PulseWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: PulseWidgetSnapshot?
}

struct PulseWidgetProvider: TimelineProvider {
    /// How often WidgetKit is asked to reload it; every Pulse push does too.
    static let refresh: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> PulseWidgetEntry {
        PulseWidgetEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PulseWidgetEntry) -> Void) {
        completion(PulseWidgetEntry(date: Date(), snapshot: PulseWidgetStore.production?.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PulseWidgetEntry>) -> Void) {
        Task {
            let snapshot = await Self.read()
            let next = Date().addingTimeInterval(Self.refresh)
            completion(Timeline(entries: [PulseWidgetEntry(date: Date(), snapshot: snapshot)], policy: .after(next)))
        }
    }

    /// Pulse's feed, read with the pass Conduit keeps for the widget, kept
    /// as the last good read; that read when the host can't be reached, and
    /// nothing when Conduit hasn't given the widget a pass (no Pulse on the
    /// dashboard in use, or Conduit not opened since the widget was added).
    static func read(store: PulseWidgetStore? = PulseWidgetStore.production,
                     access: PulseWidgetAccess? = PulseWidgetKeychain.load()) async -> PulseWidgetSnapshot? {
        let kept = store?.read()
        guard let access else { return nil }
        let previous = kept?.dashboardID == access.dashboardID ? kept : nil
        let language = WidgetSnapshotStore.production?.read()?.appLanguage ?? "system"
        do {
            let feed = try await LocationHostClient.requestJSON(
                pass: access.pass, path: PulseWidgetFeed.feedPath(looks: access.serves(PulseWidgetAccess.looksCapability)),
                method: "GET", body: nil, timeout: 12)
            guard var snapshot = PulseWidgetFeed.snapshot(from: feed, access: access, appLanguage: language, heading: {
                WidgetLocalization.string(PulseWidgetFeed.headingKey(kind: $0, topic: $1), language: language)
            }) else { return previous }
            // An empty list says when Pulse looks next (Settings > Pulse's Next look).
            if snapshot.cards.isEmpty, snapshot.quietUntil == nil,
               let state = try? await LocationHostClient.requestJSON(pass: access.pass, path: PulseWidgetFeed.base,
                                                                     method: "GET", body: nil, timeout: 8),
               (state["daily_report"] as? Bool) == true,
               let next = (state["next_report_at"] as? NSNumber)?.doubleValue {
                snapshot = snapshot.with(nextLookAt: .some(Date(timeIntervalSince1970: next)))
            }
            snapshot = snapshot.merging(previous)
            try? store?.write(snapshot)
            return snapshot
        } catch LocationHostError.signInRequired {
            let note = WidgetLocalization.string("Open Conduit to refresh", language: language)
            return previous?.with(note: .some(note))
        } catch {
            return previous
        }
    }
}

private struct PulseWidgetView: View {
    let entry: PulseWidgetEntry

    @Environment(\.widgetFamily) private var family

    private var language: String { entry.snapshot?.appLanguage ?? "system" }

    private func string(_ key: String) -> String {
        WidgetLocalization.string(key, language: language)
    }

    /// The rows that fit: the top card on a small widget, two on a medium
    /// one, four on a large one.
    private var shownCount: Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 2
        default: 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 6) {
            header
            if let snapshot = entry.snapshot {
                if let note = snapshot.note {
                    Text(verbatim: note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                if snapshot.cards.isEmpty {
                    empty(snapshot)
                } else {
                    let shown = Array(snapshot.cards.prefix(shownCount))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, card in
                        if index > 0 { Divider() }
                        if family == .systemSmall {
                            smallCard(card, snapshot: snapshot)
                        } else {
                            row(card, snapshot: snapshot)
                        }
                    }
                    let more = snapshot.openCount - shown.count
                    if more > 0 {
                        Text(verbatim: String.localizedStringWithFormat(string("%lld more waiting"), more))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(verbatim: string("Open Conduit to refresh"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
        // Anywhere outside a card's words and buttons opens the Pulse screen;
        // a small widget, which takes no links, opens at its card.
        .widgetURL(entry.snapshot.map {
            PulseWidgetLink(dashboardID: $0.dashboardID, card: family == .systemSmall ? $0.cards.first?.id : nil).url
        })
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(verbatim: string("Pulse"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func empty(_ snapshot: PulseWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: string("Nothing open in Pulse"))
                .font(.subheadline.weight(.semibold))
            if snapshot.quietUntil != nil {
                Text(verbatim: string("Pulse is quiet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let next = snapshot.nextLookAt, next > entry.date {
                HStack(spacing: 4) {
                    Text(verbatim: string("Next look"))
                    Text(next, style: .time)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The words, which open the card on the Pulse screen.
    private func words(_ card: PulseWidgetCard, snapshot: PulseWidgetSnapshot, headlineLines: Int,
                       sentenceLines: Int) -> some View {
        Link(destination: PulseWidgetLink(dashboardID: snapshot.dashboardID, card: card.id).url) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.heading)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                Text(verbatim: card.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(headlineLines)
                if sentenceLines > 0, !card.sentence.isEmpty {
                    Text(verbatim: card.sentence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(sentenceLines)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .privacySensitive()
        }
        .accessibilityElement(children: .combine)
    }

    private func smallCard(_ card: PulseWidgetCard, snapshot: PulseWidgetSnapshot) -> some View {
        words(card, snapshot: snapshot, headlineLines: 4, sentenceLines: 0)
    }

    private func row(_ card: PulseWidgetCard, snapshot: PulseWidgetSnapshot) -> some View {
        let large = family == .systemLarge
        return HStack(alignment: .center, spacing: 8) {
            words(card, snapshot: snapshot, headlineLines: large ? 2 : 1, sentenceLines: large ? 2 : 1)
            buttons(card, snapshot: snapshot)
        }
        .invalidatableContent()
    }

    private func buttons(_ card: PulseWidgetCard, snapshot: PulseWidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            if card.sentAt != nil {
                Image(systemName: "paperplane.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(verbatim: string("Sent to Hermes.")))
            } else if card.offersDoIt {
                Button(intent: PulseWidgetDoItIntent(card: card.id, dashboardID: snapshot.dashboardID)) {
                    icon("arrow.right.circle.fill", label: string("Do it"), prominent: true)
                }
                .buttonStyle(.plain)
            }
            if card.offersLater {
                Button(intent: PulseWidgetLaterIntent(card: card.id, dashboardID: snapshot.dashboardID)) {
                    icon("clock", label: string("Not now"), prominent: false)
                }
                .buttonStyle(.plain)
            }
            if card.offersDone {
                Button(intent: PulseWidgetDoneIntent(card: card.id, dashboardID: snapshot.dashboardID)) {
                    icon("checkmark.circle", label: string("Done"), prominent: false)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(_ symbol: String, label: String, prominent: Bool) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(verbatim: label))
    }
}
