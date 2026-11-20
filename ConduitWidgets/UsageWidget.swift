import SwiftUI
import WidgetKit

/// Plan limits on the Home Screen (issue 2796): how much of each
/// subscription window Hermes reports is used (a 5-hour session, a weekly
/// cap), and when each resets. The widget reads Hermes itself with the pass
/// Conduit keeps for it (UsageWidgetAccess), the same numbers as
/// Settings > Usage.
struct UsageWidget: Widget {
    let kind = ConduitWidgetKind.usage

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageWidgetTimelineProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Plan limits")
        .description("See how much of your plan's limits you've used, and when they reset.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageWidgetSnapshot?
}

struct UsageWidgetTimelineProvider: TimelineProvider {
    /// How often WidgetKit is asked to reload it. Hermes refreshes its
    /// quota cache in the background whenever it's asked, so each read
    /// also brings the next one up to date.
    static let refresh: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        // Only while Conduit keeps the widget a pass for that dashboard and profile.
        let access = UsageWidgetKeychain.load()
        let kept = UsageWidgetStore.production?.read()
        completion(UsageWidgetEntry(date: Date(), snapshot: access.flatMap { kept?.showing($0) == true ? kept : nil }))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        Task {
            let snapshot = await Self.read()
            completion(Timeline(entries: [UsageWidgetEntry(date: Date(), snapshot: snapshot)],
                                policy: .after(Self.nextRead(after: Date(), snapshot: snapshot))))
        }
    }

    /// In half an hour, or just after a window resets if one does sooner,
    /// so a reset window doesn't stay up as full.
    static func nextRead(after now: Date, snapshot: UsageWidgetSnapshot?) -> Date {
        let regular = now.addingTimeInterval(refresh)
        let resets = (snapshot?.providers ?? []).flatMap { $0.windows.compactMap(\.resetsAt) + [$0.limitedUntil].compactMap { $0 } }
        guard let soonest = resets.filter({ $0 > now }).min() else { return regular }
        return min(regular, soonest.addingTimeInterval(60))
    }

    /// Hermes' plan limits for the profile in use, read with the pass
    /// Conduit keeps for the widget and kept as the last good read; that
    /// read when the host can't be reached, and nothing when Conduit hasn't
    /// given the widget a pass (not opened since the widget was added).
    static func read(store: UsageWidgetStore? = UsageWidgetStore.production,
                     access: UsageWidgetAccess? = UsageWidgetKeychain.load(),
                     currentAccess: () -> UsageWidgetAccess? = UsageWidgetKeychain.load) async -> UsageWidgetSnapshot? {
        guard let access else {
            // Conduit took the pass away: nothing of it stays on disk.
            store?.remove()
            return nil
        }
        let previous = store?.read().flatMap { $0.showing(access) ? $0 : nil }
        let language = WidgetSnapshotStore.production?.read()?.appLanguage ?? "system"
        let providers: [UsageWidgetProvider]
        do {
            let options = try await LocationHostClient.requestJSON(
                pass: access.pass, path: UsageWidgetFeed.path(profile: access.profile),
                method: "GET", body: nil, timeout: 20)
            providers = UsageWidgetFeed.providers(from: ProviderQuota.list(from: options))
        } catch LocationHostError.signInRequired {
            return previous?.with(needsConduit: true)
                ?? UsageWidgetSnapshot(dashboardID: access.dashboardID, profile: access.profile, appLanguage: language,
                                       providers: [], readAt: Date(), needsConduit: true)
        } catch LocationHostError.http(status: 404, detail: _) {
            // A Hermes without the route reports no plan limits to read.
            providers = []
        } catch {
            return previous
        }
        // Conduit took the pass away or moved to another dashboard or
        // profile meanwhile: this answer is no longer the widget's to show.
        guard currentAccess() == access else { return nil }
        let snapshot = UsageWidgetSnapshot(dashboardID: access.dashboardID, profile: access.profile,
                                           appLanguage: language, providers: providers, readAt: Date())
        try? store?.write(snapshot)
        return snapshot
    }
}

private struct UsageWidgetView: View {
    let entry: UsageWidgetEntry

    @Environment(\.widgetFamily) private var family

    private var language: String { entry.snapshot?.appLanguage ?? "system" }

    private func string(_ key: String) -> String {
        WidgetLocalization.string(key, language: language)
    }

    /// A share in the app language's digits and sign, as Settings > Usage writes it.
    private func percent(_ fraction: Double) -> String {
        let locale = language == "system" ? Locale.current : Locale(identifier: language)
        // A window barely touched reads 0.4%, not 0%.
        let digits = fraction > 0 && fraction < 0.1 ? 0...1 : 0...0
        return fraction.formatted(.percent.precision(.fractionLength(digits)).locale(locale))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let snapshot = entry.snapshot {
                if snapshot.needsConduit {
                    Text(verbatim: string(PulseWidgetNote.openConduit))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                if snapshot.providers.isEmpty {
                    if !snapshot.needsConduit {
                        Text(verbatim: string("No plan limits reported"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if family == .systemSmall {
                    providerColumn(snapshot.providers[0], windowCount: 2)
                } else if snapshot.providers.count == 1 {
                    wideProvider(snapshot.providers[0])
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(snapshot.providers.prefix(2)) { provider in
                            providerColumn(provider, windowCount: 2)
                        }
                    }
                }
            } else {
                Text(verbatim: string(PulseWidgetNote.openConduit))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(verbatim: string("Plan limits"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func providerTitle(_ provider: UsageWidgetProvider) -> some View {
        Text(verbatim: provider.account.map { "\(provider.title) · \($0)" } ?? provider.title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
    }

    @ViewBuilder
    private func limited(_ provider: UsageWidgetProvider) -> some View {
        if provider.isLimited {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(verbatim: string("Limited"))
                if let until = provider.limitedUntil, until > entry.date {
                    Text(until, style: .time)
                }
            }
            .font(.caption2)
            .foregroundStyle(.orange)
            .lineLimit(1)
        }
    }

    /// A provider's name, then its windows one under another.
    private func providerColumn(_ provider: UsageWidgetProvider, windowCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            providerTitle(provider)
            limited(provider)
            ForEach(provider.windows.prefix(windowCount)) { window in
                windowView(window)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One provider on a medium widget: its windows side by side.
    private func wideProvider(_ provider: UsageWidgetProvider) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            providerTitle(provider)
            limited(provider)
            HStack(alignment: .top, spacing: 14) {
                ForEach(provider.windows.prefix(3)) { window in
                    windowView(window)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func windowView(_ window: UsageWidgetWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(verbatim: window.label)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: String(format: string("%@ used"), percent(window.fraction)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.caption2)
            ProgressView(value: window.fraction)
                .tint(window.fraction >= 1 ? .red : (window.fraction >= 0.8 ? .orange : .accentColor))
            if let resetsAt = window.resetsAt, resetsAt > entry.date {
                HStack(spacing: 3) {
                    Text(verbatim: string("Resets in"))
                    Text(resetsAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
