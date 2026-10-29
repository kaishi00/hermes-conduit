//
//  CrashReportOffer.swift
//  Conduit
//
//  After Conduit crashes or freezes, iOS hands it a MetricKit diagnostic on
//  the next launch (MetricKitReports keeps it). Conduit asks once, on a card
//  over the main screen, whether to send it to its developer; Send posts it
//  to Conduit's own relay (`POST /v1/crash-reports`, notifier
//  relay/src/crash-reports.mjs), whichever relay the user's notifications
//  use. Not now drops it from the offer; it stays in Diagnostics & logs.
//
//  A report is the diagnostic's crashes and hangs as iOS wrote them (call
//  stacks, exception and termination codes) with the version, build, iOS
//  version and device model. An Objective-C exception's message and its
//  arguments are left out: they can quote anything.
//

import Foundation
import os

private let crashReportLog = Logger(subsystem: "com.milim.relay", category: "crash-reports")

/// The report a stored MetricKit diagnostic payload sends.
enum CrashReportUpload {
    static let path = "v1/crash-reports"
    /// The relay takes 600,000 characters; a payload past this sends only
    /// its first crash and first hang.
    static let maxCharacters = 550_000
    /// An older diagnostic isn't offered: it's about a build long gone.
    static let maxAge: TimeInterval = 7 * 86_400
    /// The relay's field pattern: letters, digits, spaces and ()._,:+-.
    private static let fieldCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ()._,:+-"))

    enum Kind: String {
        case crash
        case hang
    }

    /// Whether a payload holds a crash or a hang worth asking about, and
    /// which: a crash wins.
    static func kind(ofPayloadJSON data: Data) -> Kind? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if !((root["crashDiagnostics"] as? [Any]) ?? []).isEmpty { return .crash }
        if !((root["hangDiagnostics"] as? [Any]) ?? []).isEmpty { return .hang }
        return nil
    }

    /// The body to post, or nil for a payload with no crash or hang.
    static func body(
        fromPayloadJSON data: Data,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
        build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
        os: String = ProcessInfo.processInfo.operatingSystemVersionString,
        device: String = CrashReportUpload.deviceModel
    ) -> [String: Any]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = kind(ofPayloadJSON: data) else { return nil }
        var crashes = ((root["crashDiagnostics"] as? [Any]) ?? []).map(withoutMessages)
        var hangs = ((root["hangDiagnostics"] as? [Any]) ?? []).map(withoutMessages)
        func diagnostic() -> [String: Any] {
            var object: [String: Any] = ["crashDiagnostics": crashes, "hangDiagnostics": hangs]
            object["timeStampBegin"] = root["timeStampBegin"]
            object["timeStampEnd"] = root["timeStampEnd"]
            return object
        }
        if let encoded = try? JSONSerialization.data(withJSONObject: diagnostic()), encoded.count > maxCharacters {
            crashes = Array(crashes.prefix(1))
            hangs = Array(hangs.prefix(1))
        }
        // The build that crashed, which may not be the one running now.
        let first = (crashes.first ?? hangs.first) as? [String: Any]
        let meta = first?["diagnosticMetaData"] as? [String: Any] ?? [:]
        return [
            "app_version": field(meta["appVersion"], fallback: appVersion),
            "build": field(meta["appBuildVersion"], fallback: build),
            "os": field(meta["osVersion"], fallback: os),
            "device": field(meta["deviceType"], fallback: device),
            "kind": kind.rawValue,
            "diagnostic": diagnostic(),
        ]
    }

    /// "iPhone17,2".
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// An exception's composed message and its arguments can quote anything
    /// the app held; its type, name and format string stay.
    private static func withoutMessages(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            var kept: [String: Any] = [:]
            for (key, child) in object where key != "composedMessage" && key != "arguments" {
                kept[key] = withoutMessages(child)
            }
            return kept
        case let list as [Any]:
            return list.map(withoutMessages)
        default:
            return value
        }
    }

    private static func field(_ value: Any?, fallback: String) -> String {
        func cleaned(_ text: String) -> String {
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: text.unicodeScalars.filter { fieldCharacters.contains($0) })
            return String(String(scalars).trimmingCharacters(in: .whitespaces).prefix(64))
        }
        let text = (value as? String).map(cleaned) ?? ""
        let backup = cleaned(fallback)
        return text.isEmpty ? (backup.isEmpty ? "unknown" : backup) : text
    }
}

/// The report files waiting to be offered, by file name in the MetricKit
/// store. MetricKitReports adds to it from its queue; the offer reads and
/// clears it on the main thread. UserDefaults is safe from both.
struct CrashReportQueue {
    static let key = "conduit.crashReports.pending"
    /// Set when Conduit's relay doesn't take reports: nothing more is offered.
    static let unsupportedKey = "conduit.crashReports.unsupported"
    var defaults: UserDefaults = .standard

    var pending: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func add(_ fileName: String) {
        guard !defaults.bool(forKey: Self.unsupportedKey) else { return }
        var names = pending
        guard !names.contains(fileName) else { return }
        names.append(fileName)
        // A run of crashes asks about the newest few.
        defaults.set(Array(names.suffix(5)), forKey: Self.key)
    }

    func remove(_ fileNames: [String]) {
        let left = pending.filter { !fileNames.contains($0) }
        defaults.set(left.isEmpty ? nil : left, forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }

    /// Conduit's relay doesn't take reports: drop these, offer no more.
    func stopOffering() {
        defaults.set(true, forKey: Self.unsupportedKey)
        clear()
    }
}

/// The card's state over the main screen.
@MainActor
final class CrashReportOffer: ObservableObject {
    static let shared = CrashReportOffer()

    enum State: Equatable {
        case hidden
        /// Asking about these reports; `crashed` says whether one is a crash.
        case asking(crashed: Bool)
        case sending
        case sent
        case failed
    }

    @Published private(set) var state: State = .hidden

    private let queue: CrashReportQueue
    private let directory: URL
    private let relayURL: URL
    private let session: URLSession

    init(
        queue: CrashReportQueue = CrashReportQueue(),
        directory: URL = MetricKitReportStore.defaultDirectory,
        relayURL: URL = PushNotificationService.upstreamRelayURL,
        session: URLSession = .shared
    ) {
        self.queue = queue
        self.directory = directory
        self.relayURL = relayURL
        self.session = session
    }

    /// Shows the card when reports wait and nothing else is on it.
    func refresh() {
        guard state == .hidden || state == .sent else { return }
        let reports = pendingReports()
        guard !reports.isEmpty else { return }
        state = .asking(crashed: reports.contains { $0.kind == .crash })
    }

    /// Not now: these reports aren't offered again.
    func dismiss() {
        if case .asking = state { queue.clear() }
        if state == .failed { queue.clear() }
        state = .hidden
    }

    func send() async {
        let reports = pendingReports()
        guard !reports.isEmpty else {
            state = .hidden
            return
        }
        state = .sending
        var sent: [String] = []
        var failed = false
        for report in reports {
            switch await post(report.body) {
            case .sent:
                sent.append(report.fileName)
            case .unsupported:
                // This relay takes no reports: stop asking.
                queue.stopOffering()
                state = .hidden
                return
            case .failed:
                failed = true
            }
        }
        queue.remove(sent)
        state = failed ? .failed : .sent
        if !failed {
            try? await Task.sleep(for: .seconds(3))
            if state == .sent { state = .hidden }
        }
    }

    private struct Report {
        let fileName: String
        let kind: CrashReportUpload.Kind
        let body: [String: Any]
    }

    /// Pending reports whose files are still kept; one gone or unreadable
    /// leaves the queue.
    private func pendingReports() -> [Report] {
        var gone: [String] = []
        let reports: [Report] = queue.pending.compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let kind = CrashReportUpload.kind(ofPayloadJSON: data),
                  let body = CrashReportUpload.body(fromPayloadJSON: data) else {
                gone.append(name)
                return nil
            }
            return Report(fileName: name, kind: kind, body: body)
        }
        if !gone.isEmpty { queue.remove(gone) }
        return reports
    }

    private enum PostResult { case sent, unsupported, failed }

    private func post(_ body: [String: Any]) async -> PostResult {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .failed }
        var request = URLRequest(url: relayURL.appendingPathComponent(CrashReportUpload.path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: return .sent
            case 404: return .unsupported
            default:
                crashReportLog.error("The relay refused a crash report: HTTP \(status, privacy: .public)")
                return .failed
            }
        } catch {
            crashReportLog.error("Couldn't send a crash report: \(MetricKitReportStore.logged(error), privacy: .public)")
            return .failed
        }
    }
}
