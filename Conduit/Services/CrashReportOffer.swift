//
//  CrashReportOffer.swift
//  Conduit
//
//  After Conduit crashes or freezes, iOS hands it a MetricKit diagnostic on
//  the next launch (MetricKitReports keeps it). Conduit asks once, on a card
//  over the main screen, whether to send it to its developer; Send posts it
//  to the developer's relay at push.milim.dev (`POST /v1/crash-reports`,
//  notifier relay/src/crash-reports.mjs), even when the user's notifications
//  use another relay. Not now drops it from the offer; it stays in
//  Diagnostics & logs.
//
//  A report is the diagnostic's crashes and hangs (call stacks, exception
//  and termination codes) with the version, build, iOS version and device
//  model, built from the keys named below only. An Objective-C exception's
//  message and its arguments are left out: they can quote anything. It
//  carries the newest stall trace saved in the diagnostic's span
//  (ChatTraceStore): what the chat did before the freeze, never its text.
//

import Foundation
import os

private let crashReportLog = Logger(subsystem: "com.milim.relay", category: "crash-reports")

/// The report a stored MetricKit diagnostic payload sends.
enum CrashReportUpload {
    static let path = "v1/crash-reports"
    /// The relay takes 600,000 characters; a payload past this many bytes
    /// sends only its first crash and first hang, and one still past it
    /// isn't offered.
    static let maxBytes = 550_000
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
        guard let root = (try? JSONSerialization.jsonObject(with: MetricKitReportStore.shallowed(data))) as? [String: Any] else { return nil }
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
        guard let root = (try? JSONSerialization.jsonObject(with: MetricKitReportStore.shallowed(data))) as? [String: Any],
              let kind = kind(ofPayloadJSON: data) else { return nil }
        var crashes = ((root["crashDiagnostics"] as? [Any]) ?? []).map(kept)
        var hangs = ((root["hangDiagnostics"] as? [Any]) ?? []).map(kept)
        func diagnostic() -> [String: Any] {
            var object: [String: Any] = ["crashDiagnostics": crashes, "hangDiagnostics": hangs]
            object["timeStampBegin"] = root["timeStampBegin"]
            object["timeStampEnd"] = root["timeStampEnd"]
            return object
        }
        func fits() -> Bool {
            ((try? JSONSerialization.data(withJSONObject: diagnostic()))?.count ?? .max) <= maxBytes
        }
        if !fits() {
            crashes = Array(crashes.prefix(1))
            hangs = Array(hangs.prefix(1))
            guard fits() else { return nil }
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

    /// A chat trace on its own (kind chat, relay 0.25+): the version and
    /// build that saved it, with this device's iOS version and model.
    static func body(
        chatTrace trace: ChatTraceStore.Trace,
        lines: [String],
        os: String = ProcessInfo.processInfo.operatingSystemVersionString,
        device: String = CrashReportUpload.deviceModel
    ) -> [String: Any] {
        [
            "app_version": field(trace.appVersion, fallback: "unknown"),
            "build": field(trace.build, fallback: "unknown"),
            "os": field(os, fallback: "unknown"),
            "device": field(device, fallback: "unknown"),
            "kind": "chat",
            "trace": ChatTraceUpload.object(trace, lines: lines),
        ]
    }

    /// When a stored diagnostic's span ended, from its file name
    /// (MetricKitReportStore: kind-begin-end-hash.json).
    static func end(ofFileName name: String) -> Date? {
        let parts = (name as NSString).deletingPathExtension.split(separator: "-")
        guard parts.count == 4, let seconds = TimeInterval(parts[2]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// When it began.
    static func begin(ofFileName name: String) -> Date? {
        let parts = (name as NSString).deletingPathExtension.split(separator: "-")
        guard parts.count == 4, let seconds = TimeInterval(parts[1]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    struct PostResponse {
        /// The HTTP status, or 0 when the post didn't get there.
        let status: Int
        /// The relay kept the post's chat trace (0.25+ says so; an older one
        /// takes a report and drops what it doesn't know).
        let keptTrace: Bool
    }

    /// Posts a report or trace to the relay's route.
    static func post(_ body: [String: Any], to relayURL: URL, session: URLSession) async -> PostResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return PostResponse(status: 0, keptTrace: false) }
        var request = URLRequest(url: relayURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (answer, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) {
                crashReportLog.error("The relay refused a crash report: HTTP \(status, privacy: .public)")
            }
            let object = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
            return PostResponse(status: status, keptTrace: object?["trace"] as? Bool == true)
        } catch {
            crashReportLog.error("Couldn't send a crash report: \(MetricKitReportStore.logged(error), privacy: .public)")
            return PostResponse(status: 0, keptTrace: false)
        }
    }

    /// "iPhone17,2".
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The keys a report keeps, level by level; anything else MetricKit
    /// writes, now or in a later iOS, stays on the phone. An exception's
    /// composed message, arguments and format string can quote anything the
    /// app held, so only its type and name go.
    private static let diagnosticKeys: Set<String> = ["version", "diagnosticMetaData", "callStackTree"]
    private static let metaKeys: Set<String> = [
        "appVersion", "appBuildVersion", "osVersion", "deviceType", "platformArchitecture",
        "bundleIdentifier", "isTestFlightApp", "lowPowerModeEnabled",
        "exceptionType", "exceptionCode", "signal", "terminationReason", "virtualMemoryRegionInfo",
        "hangDuration", "exceptionReason",
    ]
    private static let exceptionKeys: Set<String> = ["exceptionType", "exceptionName", "className"]
    private static let treeKeys: Set<String> = ["callStackPerThread", "callStacks"]
    private static let threadKeys: Set<String> = ["threadAttributed", "callStackRootFrames"]
    private static let frameKeys: Set<String> = [
        "binaryUUID", "binaryName", "offsetIntoBinaryTextSegment", "address", "sampleCount", "subFrames",
    ]

    private static func kept(_ diagnostic: Any) -> Any {
        pick(diagnostic, diagnosticKeys) { key, value in
            switch key {
            case "diagnosticMetaData": return keptMeta(value)
            case "callStackTree": return keptTree(value)
            default: return value
            }
        }
    }

    private static func keptMeta(_ meta: Any) -> Any {
        pick(meta, metaKeys) { key, value in
            if key == "exceptionReason" { return pick(value, exceptionKeys) { $1 } }
            return value
        }
    }

    private static func keptTree(_ tree: Any) -> Any {
        pick(tree, treeKeys) { key, value in
            guard key == "callStacks" else { return value }
            let threads: [Any] = (value as? [Any]) ?? []
            return threads.map { thread -> Any in
                pick(thread, threadKeys) { key, frames in
                    guard key == "callStackRootFrames" else { return frames }
                    let roots: [Any] = (frames as? [Any]) ?? []
                    return roots.map { keptFrame($0, level: 1) }
                }
            }
        }
    }

    /// A root frame is the one that was running and its subFrames lead out
    /// toward the thread's entry, so the crash site is in the levels kept.
    /// A stack that overflowed can nest thousands of frames: the first 240
    /// frame levels are kept, so the walk's depth stays bounded and the body,
    /// which nests a level-L frame 7 + 2L deep, stays under the 512 that
    /// JSONSerialization writes (the relay keeps 512 frame levels, notifier #469).
    static let maxFrameDepth = 240

    private static func keptFrame(_ frame: Any, level: Int) -> Any {
        pick(frame, frameKeys) { key, value in
            guard key == "subFrames" else { return value }
            guard level < maxFrameDepth else { return [Any]() }
            let children: [Any] = (value as? [Any]) ?? []
            return children.map { keptFrame($0, level: level + 1) }
        }
    }

    /// The keys of `object` named in `keys`, each through `child`.
    private static func pick(_ object: Any, _ keys: Set<String>, _ child: (String, Any) -> Any) -> [String: Any] {
        var picked: [String: Any] = [:]
        for (key, value) in (object as? [String: Any]) ?? [:] where keys.contains(key) {
            picked[key] = child(key, value)
        }
        return picked
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
/// clears it on the main thread, so each change holds a lock.
struct CrashReportQueue {
    static let key = "conduit.crashReports.pending"
    /// The build that found the relay taking no reports: that build offers
    /// none, and the next one asks about what's still queued.
    static let unsupportedKey = "conduit.crashReports.unsupportedBuild"
    static let storedKey = "conduit.crashReports.lookedAtStored"
    private static let lock = NSLock()
    var defaults: UserDefaults = .standard
    var build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

    var pending: [String] { defaults.stringArray(forKey: Self.key) ?? [] }
    var isUnsupported: Bool { defaults.string(forKey: Self.unsupportedKey) == build }

    func add(_ fileName: String) {
        change { names in
            guard !names.contains(fileName) else { return }
            names.append(fileName)
            // A run of crashes asks about the newest few.
            names = Array(names.suffix(5))
        }
    }

    func remove(_ fileNames: [String]) {
        change { names in names.removeAll { fileNames.contains($0) } }
    }

    func clear() { change { names in names = [] } }

    /// Whether the reports kept before the card existed were queued on this
    /// device.
    var lookedAtStoredReports: Bool { defaults.bool(forKey: Self.storedKey) }

    func markLookedAtStoredReports() { defaults.set(true, forKey: Self.storedKey) }

    /// Conduit's relay doesn't take reports: this build offers no more. What's
    /// queued stays for the next build, so a build out before the relay
    /// takes reports loses none, and one declined or sent isn't asked again.
    func stopOffering() {
        defaults.set(build, forKey: Self.unsupportedKey)
    }

    private func change(_ body: (inout [String]) -> Void) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var names = pending
        body(&names)
        defaults.set(names.isEmpty ? nil : names, forKey: Self.key)
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
    /// The reports the card is about.
    private var shown: [String] = []

    private let queue: CrashReportQueue
    private let directory: URL
    private let traces: ChatTraceStore
    private let relayURL: URL
    private let session: URLSession
    /// How long the thanks shows before the card goes.
    private let thanksFor: Duration

    init(
        queue: CrashReportQueue = CrashReportQueue(),
        directory: URL = MetricKitReportStore.defaultDirectory,
        traces: ChatTraceStore = ChatTraceStore(),
        relayURL: URL = PushNotificationService.upstreamRelayURL,
        session: URLSession = .shared,
        thanksFor: Duration = .seconds(3)
    ) {
        self.queue = queue
        self.directory = directory
        self.traces = traces
        self.relayURL = relayURL
        self.session = session
        self.thanksFor = thanksFor
    }

    /// Shows the card when reports wait and nothing else is on it.
    func refresh() async {
        guard state == .hidden || state == .sent else { return }
        let reports = await pendingReports()
        guard !reports.isEmpty, state == .hidden || state == .sent else { return }
        shown = reports.map(\.fileName)
        state = .asking(crashed: reports.contains { $0.kind == .crash })
    }

    /// Not now: the reports the card asked about aren't offered again; one
    /// that came in meanwhile is offered next.
    func dismiss() {
        if case .asking = state { queue.remove(shown) }
        if state == .failed { queue.remove(shown) }
        state = .hidden
        Task { await refresh() }
    }

    func send() async {
        // A second tap while sending sends nothing twice.
        guard state != .sending else { return }
        state = .sending
        // The reports the card asked about, not one that came in since.
        let reports = await pendingReports(named: shown)
        guard !reports.isEmpty else {
            state = .hidden
            return
        }
        var sent: [String] = []
        var failed = false
        for report in reports {
            var result = await post(report.body)
            if case .failed(let status) = result, report.trace != nil, status == 413 || status == 400 {
                // A relay before 0.25 takes no post this big, and one that
                // won't take a trace's line refuses the post: the report
                // goes without it, and the trace stays in Diagnostics & logs.
                var plain = report.body
                plain["trace"] = nil
                result = await post(plain)
            } else if case .sent(keptTrace: true) = result, let trace = report.trace {
                // At the relay now. One that dropped it keeps it here.
                let traces = traces
                await Task.detached(priority: .utility) { traces.remove(trace) }.value
            }
            switch result {
            case .sent:
                sent.append(report.fileName)
            case .unsupported:
                // This relay takes no reports: stop asking.
                queue.remove(sent)
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
            try? await Task.sleep(for: thanksFor)
            if state == .sent { state = .hidden }
            // One that came in while sending.
            await refresh()
        }
    }

    /// Read off the main thread, then only read on it.
    private struct Report: @unchecked Sendable {
        let fileName: String
        let kind: CrashReportUpload.Kind
        let body: [String: Any]
        /// The stall trace riding with it, by file name.
        let trace: String?
    }

    /// Pending reports (only those named, when given) whose files are kept
    /// and from the last week, read off the main thread (a diagnostic can
    /// run to megabytes), each with the newest stall trace saved in its
    /// span. One gone, too old, or not a report that can be sent leaves the
    /// queue; one that can't be read just now stays.
    private func pendingReports(named only: [String]? = nil) async -> [Report] {
        guard !queue.isUnsupported else { return [] }
        let names = queue.pending.filter { only?.contains($0) ?? true }
        let directory = directory
        let traces = traces
        let (reports, gone) = await Task.detached(priority: .utility) { () -> ([Report], [String]) in
            var gone: [String] = []
            let reports: [Report] = names.compactMap { name in
                let url = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path),
                      let end = CrashReportUpload.end(ofFileName: name),
                      Date().timeIntervalSince(end) < CrashReportUpload.maxAge else {
                    gone.append(name)
                    return nil
                }
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let kind = CrashReportUpload.kind(ofPayloadJSON: data),
                      var body = CrashReportUpload.body(fromPayloadJSON: data) else {
                    gone.append(name)
                    return nil
                }
                var traceName: String?
                if let begin = CrashReportUpload.begin(ofFileName: name),
                   let trace = traces.stall(between: begin, and: end),
                   let lines = traces.lines(of: trace) {
                    body["trace"] = ChatTraceUpload.object(trace, lines: lines)
                    traceName = trace.fileName
                }
                return Report(fileName: name, kind: kind, body: body, trace: traceName)
            }
            return (reports, gone)
        }.value
        if !gone.isEmpty { queue.remove(gone) }
        return reports
    }

    private enum PostResult { case sent(keptTrace: Bool), unsupported, failed(status: Int) }

    private func post(_ body: [String: Any]) async -> PostResult {
        let response = await CrashReportUpload.post(body, to: relayURL, session: session)
        switch response.status {
        case 200..<300: return .sent(keptTrace: response.keptTrace)
        case 404: return .unsupported
        default: return .failed(status: response.status)
        }
    }
}
