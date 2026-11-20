import Foundation

/// What the Plan limits widget reads with (issue 2796): the dashboard and
/// profile in use and a host pass for the dashboard, made as the Pulse
/// widget's. Conduit keeps it in the notifications App Group's Keychain
/// while a Plan limits widget is on the Home Screen, and removes it
/// otherwise, so the widget reads Hermes' numbers itself without Conduit
/// running.
struct UsageWidgetAccess: Codable, Equatable {
    let dashboardID: UUID
    /// The profile in use: each profile signs in to its own providers.
    let profile: String
    let pass: LocationHostPass
}

enum UsageWidgetKeychain {
    static let account = "usage-access.v1"

    static func load() -> UsageWidgetAccess? { WidgetAccessKeychain.load(account: account) }

    @discardableResult
    static func save(_ access: UsageWidgetAccess) -> Bool { WidgetAccessKeychain.save(access, account: account) }

    static func clear() { WidgetAccessKeychain.clear(account: account) }
}

/// One window of a plan's limit as the widget shows it: a 5-hour session,
/// a weekly cap.
struct UsageWidgetWindow: Codable, Equatable, Identifiable {
    let label: String
    /// 0 through 100.
    let usedPercent: Double
    let resetsAt: Date?
    var id: String { label }

    var fraction: Double { min(max(usedPercent / 100, 0), 1) }
}

/// One provider that reports a plan limit, as the widget shows it.
struct UsageWidgetProvider: Codable, Equatable, Identifiable {
    let slug: String
    let title: String
    /// A pool's account the windows are of, when it has a name.
    let account: String?
    let windows: [UsageWidgetWindow]
    /// The whole sign-in is rate limited (or every account of a pool is).
    let isLimited: Bool
    let limitedUntil: Date?
    var id: String { slug }
}

/// What the Plan limits widget shows: the plan limits Hermes reports for
/// the profile in use, as the widget last read them. Kept as its last good
/// read, for when the host can't be reached.
struct UsageWidgetSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1
    /// The most a medium widget shows.
    static let maximumProviders = 2

    let schemaVersion: Int
    let dashboardID: UUID
    let profile: String
    let appLanguage: String
    let providers: [UsageWidgetProvider]
    /// When the widget read them from Hermes.
    let readAt: Date
    /// The pass stopped working: Conduit must be opened to sign in again.
    let needsConduit: Bool

    init(dashboardID: UUID, profile: String, appLanguage: String, providers: [UsageWidgetProvider],
         readAt: Date, needsConduit: Bool = false) {
        schemaVersion = Self.currentSchemaVersion
        self.dashboardID = dashboardID
        self.profile = profile
        self.appLanguage = appLanguage
        self.providers = Array(providers.prefix(Self.maximumProviders))
        self.readAt = readAt
        self.needsConduit = needsConduit
    }

    func showing(_ access: UsageWidgetAccess) -> Bool {
        dashboardID == access.dashboardID && profile == access.profile
    }

    func with(needsConduit: Bool) -> UsageWidgetSnapshot {
        UsageWidgetSnapshot(dashboardID: dashboardID, profile: profile, appLanguage: appLanguage,
                            providers: providers, readAt: readAt, needsConduit: needsConduit)
    }
}

/// The widget's rows from Hermes' `/api/model/options`, the REST twin of
/// the `model.options` call Settings > Usage reads: the same quota, so the
/// widget and the page never disagree.
enum UsageWidgetFeed {
    static let path = "/api/model/options"

    static func path(profile: String) -> String {
        LocationHostClient.withProfile(path, profile: profile)
    }

    /// The providers worth a row: each one's own windows, or for a pool the
    /// account Hermes would use (the usable one with the most left), and
    /// whether the sign-in is limited outright. A provider reporting none
    /// of these is left out.
    static func providers(from quotas: [ProviderQuota]) -> [UsageWidgetProvider] {
        quotas.compactMap { quota -> UsageWidgetProvider? in
            var limitedUntil: Date?
            var isLimited = false
            if case .account(let resetsAt) = quota.limit {
                isLimited = true
                limitedUntil = resetsAt
            }
            var windows = quota.windows
            var account: String?
            if windows.isEmpty, !quota.accounts.isEmpty {
                let signedIn = quota.accounts.filter { $0.state != .unavailable }
                let allLimited = !signedIn.isEmpty && signedIn.allSatisfy { $0.state == .limited }
                let usable = quota.accounts.filter { ($0.state == .ready || $0.state == .unknown) && !$0.windows.isEmpty }
                // A limited account's windows only when the whole pool is
                // limited (its full window is why); never a signed-out
                // account's last numbers, which Settings > Usage doesn't
                // count either.
                let best = usable.max { mostLeft($0.windows) < mostLeft($1.windows) }
                    ?? (allLimited ? signedIn.first { !$0.windows.isEmpty } : nil)
                if let best {
                    windows = best.windows
                    account = best.label.isEmpty ? nil : best.label
                }
                if !isLimited, allLimited {
                    isLimited = true
                    limitedUntil = signedIn.compactMap(\.resetsAt).min()
                }
            }
            guard !windows.isEmpty || isLimited else { return nil }
            return UsageWidgetProvider(
                slug: quota.slug,
                title: quota.title,
                account: account,
                windows: windows.map { UsageWidgetWindow(label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) },
                isLimited: isLimited,
                limitedUntil: limitedUntil
            )
        }
    }

    /// When the widget reads again: in `refresh`, or a minute after a
    /// window resets or a limit lifts if one does sooner, so a reset window
    /// doesn't stay up as full.
    static func nextRead(after now: Date, snapshot: UsageWidgetSnapshot?, refresh: TimeInterval) -> Date {
        let regular = now.addingTimeInterval(refresh)
        let resets = (snapshot?.providers ?? []).flatMap { $0.windows.compactMap(\.resetsAt) + [$0.limitedUntil].compactMap { $0 } }
        guard let soonest = resets.filter({ $0 > now }).min() else { return regular }
        return min(regular, soonest.addingTimeInterval(60))
    }

    /// What's left of the fullest account-wide window (a model's when it has
    /// no other), as a provider row counts it.
    private static func mostLeft(_ windows: [QuotaWindow]) -> Double {
        let accountWide = windows.filter { !$0.modelScoped }
        let counted = accountWide.isEmpty ? windows : accountWide
        return 1 - (counted.map(\.fraction).max() ?? 1)
    }
}

/// The widget's last good read, in the launcher App Group. Only the widget
/// writes it; Conduit removes it with the access item.
struct UsageWidgetStore {
    static let filename = "usage-v1.json"
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    static var production: UsageWidgetStore? {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroup) else { return nil }
        return UsageWidgetStore(directory: directory)
    }

    private var url: URL { directory.appendingPathComponent(Self.filename) }

    func read() -> UsageWidgetSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(UsageWidgetSnapshot.self, from: data),
              snapshot.schemaVersion == UsageWidgetSnapshot.currentSchemaVersion else { return nil }
        return snapshot
    }

    func write(_ snapshot: UsageWidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Whether there was one to remove.
    @discardableResult
    func remove() -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        return (try? fileManager.removeItem(at: url)) != nil
    }
}
