import CryptoKit
import Foundation
import os

/// A bot's screen (Hermes' Bot Screen): the headless desktop on the Hermes
/// host that the bot's `computer_use` and headed browser act on, one per
/// bot (profile), shared by every chat of the bot, its workstreams too.
/// Conduit watches it, takes over (a sign-in, 2FA, a CAPTCHA) and hands back,
/// through Hermes' `display.*` methods on the app's own socket and the
/// screen's RFB stream on `/api/display/ws`, which the viewer page draws
/// (Conduit/Resources/BotScreen/BotScreenViewer.html, noVNC).
///
/// Hermes runs it on Linux hosts only; elsewhere `display.status` says
/// `supported: false` and Conduit offers nothing (Eric 2026-11-05: no
/// option at all on a host that can't have it).
struct BotScreenLease: Equatable {
    /// "agent" (the bot has control) or "human" (a person took over).
    let holder: String
    /// The first 12 hex characters of sha256 of the holder's viewer id: a
    /// viewer recognises itself without the id ever leaving the gateway.
    let viewerHash: String?
    let epoch: Int

    init(_ object: [String: AnyCodable]?) {
        holder = object?["holder"]?.stringValue ?? "agent"
        viewerHash = object?["viewer_hash"]?.stringValue
        epoch = object?["epoch"]?.intValue ?? 0
    }

    var isHuman: Bool { holder == "human" }

    func isHeld(byViewerHash hash: String?) -> Bool {
        guard isHuman, let hash, let viewerHash else { return false }
        return viewerHash == hash
    }

    /// `viewer_hash` as Hermes writes it for a viewer id.
    static func hash(ofViewer id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).lowercased()
    }
}

struct BotScreenStatus: Equatable {
    struct ImageSwitch: Equatable {
        let current: String
        let target: String
    }

    let profile: String
    /// A host that can have a screen (Linux).
    let isSupported: Bool
    let isInstalled: Bool
    let missing: [String]
    let isRunning: Bool
    let geometry: String
    /// The command that installs the packages, as typed on the host.
    let installCommand: String?
    /// Why a start would be refused now (low memory); shown in place of Start.
    let blocker: String?
    let imageSwitch: ImageSwitch?
    private(set) var lease: BotScreenLease
    /// Hermes' key for the profile's home, which its events carry.
    let profileKey: String

    init?(_ object: [String: AnyCodable]) {
        guard let supported = object["supported"]?.boolValue else { return nil }
        profile = object["profile"]?.stringValue ?? ""
        isSupported = supported
        isInstalled = object["installed"]?.boolValue ?? false
        missing = object["missing"]?.arrayValue?.compactMap(\.stringValue) ?? []
        isRunning = object["running"]?.boolValue ?? false
        geometry = object["geometry"]?.stringValue ?? ""
        installCommand = (object["install_command"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 }
        blocker = (object["blocker"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 }
        if let image = object["image_switch"]?.objectValue, let target = image["target_image"]?.stringValue {
            imageSwitch = ImageSwitch(current: image["current_image"]?.stringValue ?? "", target: target)
        } else {
            imageSwitch = nil
        }
        lease = BotScreenLease(object["lease"]?.objectValue)
        profileKey = object["profile_key"]?.stringValue ?? ""
    }

    /// The screen's size, for the viewer's frame; 16:10 when unknown.
    var aspectRatio: CGFloat {
        let parts = geometry.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return 1.6 }
        return CGFloat(parts[0] / parts[1])
    }

    func replacingLease(_ lease: BotScreenLease) -> BotScreenStatus {
        var copy = self
        copy.lease = lease
        return copy
    }
}

/// Who drives a bot's screen as the plugin keeps it (screen_lock): the chat
/// holding it now, apart from the one that used it last (Eric 2026-11-05).
struct BotScreenUse: Equatable {
    struct Entry: Equatable {
        let sessionID: String
        /// "workstream", "bot_chat" or "chat".
        let kind: String
        let ref: String
        let title: String
        let label: String
        let at: Date?
    }

    let controlling: Entry?
    let last: Entry?
    let waitingRefs: [String]

    init?(_ object: [String: Any]?) {
        guard let object else { return nil }
        controlling = Self.entry(object["controlling"])
        last = Self.entry(object["last"])
        waitingRefs = (object["waiting"] as? [[String: Any]] ?? []).compactMap {
            let ref = $0["ref"] as? String ?? ""
            return ref.isEmpty ? nil : ref
        }
    }

    private static func entry(_ value: Any?) -> Entry? {
        guard let row = value as? [String: Any], let id = row["session_id"] as? String, !id.isEmpty else { return nil }
        let at = ((row["at"] ?? row["since"]) as? NSNumber)?.doubleValue
        return Entry(sessionID: id, kind: row["kind"] as? String ?? "chat", ref: row["ref"] as? String ?? "",
                     title: row["title"] as? String ?? "", label: row["label"] as? String ?? "",
                     at: at.map { Date(timeIntervalSince1970: $0) })
    }

    /// How a chat holding the screen is named here: its ref, the Bot Chat,
    /// or its title.
    static func name(of entry: Entry) -> String {
        switch entry.kind {
        case "workstream" where !entry.ref.isEmpty: return entry.ref
        case "bot_chat": return AppLocalization.string("the Bot Chat")
        default: return entry.title.isEmpty ? AppLocalization.string("another chat") : entry.title
        }
    }
}

/// The keys the screen's type bar sends besides text, as X keysyms.
enum BotScreenKey: String, CaseIterable, Identifiable {
    case enter, tab, backspace, escape

    var id: String { rawValue }

    var keysym: Int {
        switch self {
        case .enter: return 0xFF0D
        case .tab: return 0xFF09
        case .backspace: return 0xFF08
        case .escape: return 0xFF1B
        }
    }

    /// The keysym for one character typed on the screen: Latin-1 as itself,
    /// the rest as Unicode keysyms (0x01000000 + code point), a line break
    /// as Return.
    static func keysym(for scalar: Unicode.Scalar) -> Int {
        if scalar == "\n" || scalar == "\r" { return BotScreenKey.enter.keysym }
        if scalar == "\t" { return BotScreenKey.tab.keysym }
        let value = Int(scalar.value)
        if (0x20...0x7E).contains(value) || (0xA0...0xFF).contains(value) { return value }
        return 0x0100_0000 + value
    }
}

/// One bot's screen as a view shows it: status, the live stream, the lease
/// and the install. The page draws; this owns the socket.
@MainActor
final class BotScreenModel: ObservableObject {
    enum Stream: Equatable {
        case idle, connecting, live
        case lost(String)
    }

    enum Availability: Equatable {
        case loading
        /// The host can't have a screen, or its Hermes has no `display.*`.
        case unsupported
        case available
        case failed(String)
    }

    let profile: String
    @Published private(set) var availability: Availability = .loading
    @Published private(set) var status: BotScreenStatus?
    @Published private(set) var stream: Stream = .idle
    @Published private(set) var isBusy = false
    @Published var errorText: String?
    @Published private(set) var installLog: [String] = []
    @Published private(set) var isInstalling = false
    /// The open sudo request of an install of this screen, started here or elsewhere.
    @Published private(set) var sudoRequestID: String?
    @Published private(set) var viewerHash: String?

    /// The page's end of the stream (BotScreenWebView).
    weak var page: BotScreenPage?

    private weak var client: HermesClient?
    private var viewerID: String?
    private var pendingSudo: (id: String, profileKey: String)?
    /// Counts the installs that ended, so a late answer to one can't say it's still going.
    private var installsEnded = 0
    private var socket: (any HermesWebSocket)?
    private var transport: (any HermesWebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var attachGeneration = 0
    /// Bumped when the sheet closes or the app goes to the background: a
    /// takeover answered after that is handed straight back.
    private var leaveGeneration = 0
    private var rapidEvictions = 0
    private var dialedAt = Date.distantPast
    private let logger = Logger(subsystem: "com.milim.relay", category: "BotScreen")

    static let controlTakenCode = 4000
    static let maxRapidEvictions = 3
    static let maxLogLines = 400

    /// The viewer id each bot's screen was last watched with, kept past the
    /// sheet: a reconnect starts the sheet over, and the user's own hold is
    /// still theirs on the new connection.
    private static var viewerIDs: [String: String] = [:]

    init(profile: String, client: HermesClient?) {
        self.profile = profile
        self.client = client
        viewerID = Self.viewerIDs[profile]
        viewerHash = viewerID.map(BotScreenLease.hash(ofViewer:))
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .hermesDisplayEvent, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?["type"] as? String ?? ""
            let payload = note.userInfo?["payload"] as? [String: AnyCodable] ?? [:]
            let sender = note.object as AnyObject?
            MainActor.assumeIsolated { self?.receive(type: type, payload: payload, from: sender) }
        })
        observers.append(center.addObserver(forName: .hermesDisplaySudo, object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["request_id"] as? String ?? ""
            let key = note.userInfo?["profile_key"] as? String ?? ""
            let sender = note.object as AnyObject?
            MainActor.assumeIsolated { self?.receiveSudo(id: id, profileKey: key, from: sender) }
        })
        observers.append(center.addObserver(forName: .hermesDisplaySudoCancelled, object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["request_id"] as? String ?? ""
            MainActor.assumeIsolated {
                if self?.sudoRequestID == id { self?.sudoRequestID = nil }
                if self?.pendingSudo?.id == id { self?.pendingSudo = nil }
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        transport?.invalidate()
    }

    /// The person holds the screen from this view.
    var iHold: Bool { status?.lease.isHeld(byViewerHash: viewerHash) ?? false }

    /// Someone else (another device or window) took over.
    var someoneElseHolds: Bool { (status?.lease.isHuman ?? false) && !iHold }

    // MARK: Reads and actions

    func load() async {
        guard let client else {
            availability = .failed(AppLocalization.string("Not connected to Hermes."))
            return
        }
        do {
            let answer = try await client.display("display.status", profile: profile)
            guard let next = BotScreenStatus(answer) else {
                availability = .unsupported
                return
            }
            apply(next)
            availability = next.isSupported ? .available : .unsupported
            if next.isRunning, stream == .idle { await attach() }
        } catch let error as RpcError where error.code == HermesClient.methodNotFoundCode {
            availability = .unsupported
        } catch {
            availability = .failed(error.localizedDescription)
        }
    }

    func start() async {
        await perform { client in
            let answer = try await client.display("display.start", profile: self.profile, timeout: 60)
            if let next = BotScreenStatus(answer) { self.apply(next) }
            if self.status?.isRunning == true { await self.attach() }
        }
    }

    func stop() async {
        await perform { client in
            self.detach()
            let answer = try await client.display("display.stop", profile: self.profile)
            if let next = BotScreenStatus(answer) { self.apply(next) }
        }
    }

    func install() async {
        guard let client else {
            errorText = AppLocalization.string("Not connected to Hermes.")
            return
        }
        installLog = []
        errorText = nil
        isBusy = true
        defer { isBusy = false }
        let ended = installsEnded
        do {
            // A long install may answer late; its log and its end come as events.
            let answer = try await client.display("display.install", profile: profile, timeout: 900)
            // It may have finished before its own answer came back: what its
            // end said stands.
            if installsEnded == ended { isInstalling = answer["started"]?.boolValue ?? false }
        } catch {
            guard installsEnded == ended, !isInstalling else { return }
            errorText = error.localizedDescription
            logger.notice("Bot Screen install failed: \(LogRedaction.message(error), privacy: .public)")
        }
    }

    /// Leaves an ended install's log for the screen's own view.
    func continueAfterInstall() async {
        installLog = []
        errorText = nil
        await load()
    }

    func answerSudo(_ password: String) async {
        guard let id = sudoRequestID, let client else { return }
        sudoRequestID = nil
        do {
            try await client.respondToDisplaySudo(requestId: id, password: password)
        } catch {
            // Asked again: the field comes back for another try, unless a
            // newer ask or the install's end came in meanwhile.
            // Never one Hermes cancelled meanwhile.
            if sudoRequestID == nil, isInstalling, client.pendingDisplaySudo[id] != nil { sudoRequestID = id }
            errorText = error.localizedDescription
        }
    }

    func switchImage(approve: Bool) async {
        await perform { client in
            let answer = try await client.display("display.switchSandboxImage", profile: self.profile,
                                                  params: ["approve": approve])
            if let next = BotScreenStatus(answer) { self.apply(next) }
        }
    }

    /// Take over: the person's keyboard and pointer drive the screen; the
    /// bot's screen tools are refused until they hand back.
    func takeOver() async {
        guard let viewerID else { return }
        let leave = leaveGeneration
        await perform { client in
            let answer = try await client.display("display.lease.acquire", profile: self.profile,
                                                  params: ["viewer_id": viewerID, "reason": "Conduit"])
            guard leave == self.leaveGeneration else {
                // Nobody watches any more: the bot isn't kept off its screen.
                _ = try? await client.display("display.lease.release", profile: self.profile,
                                              params: ["viewer_id": viewerID])
                return
            }
            self.applyLease(BotScreenLease(answer["lease"]?.objectValue))
        }
    }

    /// Hand back: the bot has control again.
    func handBack(force: Bool = false) async {
        await perform { client in
            var params: [String: Any] = [:]
            if let viewerID = self.viewerID, !force { params["viewer_id"] = viewerID }
            if force { params["force"] = true }
            let answer = try await client.display("display.lease.release", profile: self.profile, params: params)
            self.applyLease(BotScreenLease(answer["lease"]?.objectValue))
        }
    }

    /// The view is going: the person's hold goes with it (as closing the
    /// pane does on Hermes Desktop), then the stream.
    func close() {
        leaveGeneration += 1
        if iHold, let client, let viewerID {
            let profile = profile
            Task { _ = try? await client.display("display.lease.release", profile: profile,
                                                 params: ["viewer_id": viewerID]) }
        }
        detach()
    }

    func type(_ text: String) {
        guard iHold else { return }
        // A pasted CRLF is one Return; sent in the page's batches, so long
        // text all goes.
        let keysyms = text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.map(BotScreenKey.keysym(for:))
        for start in stride(from: 0, to: keysyms.count, by: Self.keysymBatch) {
            page?.sendKeysyms(Array(keysyms[start..<min(start + Self.keysymBatch, keysyms.count)]))
        }
    }

    /// The most the page sends in one call.
    static let keysymBatch = 4096

    func press(_ key: BotScreenKey) {
        guard iHold else { return }
        page?.sendKeysyms([key.keysym])
    }

    private func perform(_ work: @escaping (HermesClient) async throws -> Void) async {
        guard let client else {
            errorText = AppLocalization.string("Not connected to Hermes.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await work(client)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
            logger.notice("Bot Screen action failed: \(LogRedaction.message(error), privacy: .public)")
        }
    }

    private func apply(_ next: BotScreenStatus) {
        let wasRunning = status?.isRunning ?? false
        status = keepingNewerLease(next)
        if let pending = pendingSudo {
            pendingSudo = nil
            if pending.profileKey == next.profileKey {
                isInstalling = true
                sudoRequestID = pending.id
            }
        }
        // An ask that came before this view opened (the sheet closed and
        // reopened, or an install started elsewhere) is still answerable.
        if sudoRequestID == nil, !next.profileKey.isEmpty,
           let open = client?.pendingDisplaySudo.first(where: { $0.value == next.profileKey }) {
            isInstalling = true
            sudoRequestID = open.key
        }
        page?.setViewOnly(!iHold)
        if wasRunning, !next.isRunning { detach() }
    }

    /// A status read before another device's takeover or hand back landed
    /// keeps the newer lease (one without a lease reads as epoch 0).
    private func keepingNewerLease(_ next: BotScreenStatus) -> BotScreenStatus {
        // Across a stop or start the lease starts over: taken as it comes.
        guard let previous = status, previous.isRunning, next.isRunning,
              next.lease.epoch < previous.lease.epoch else { return next }
        let current = previous.lease
        return next.replacingLease(current)
    }

    private func applyLease(_ lease: BotScreenLease) {
        // A late answer never undoes a newer change another device made.
        guard let status, lease.epoch >= status.lease.epoch else { return }
        self.status = status.replacingLease(lease)
        page?.setViewOnly(!iHold)
    }

    // MARK: Events

    private func receive(type: String, payload: [String: AnyCodable], from sender: AnyObject?) {
        guard sender === client else { return }
        let key = payload["profile_key"]?.stringValue ?? ""
        guard let status, !key.isEmpty, key == status.profileKey else { return }
        switch type {
        case "display.lease":
            applyLease(BotScreenLease(payload["lease"]?.objectValue))
        case "display.status":
            if let next = BotScreenStatus(payload) {
                apply(next)
                if next.isRunning, stream == .idle { Task { await attach() } }
            }
        case "display.install.log":
            guard let line = payload["line"]?.stringValue else { return }
            isInstalling = true
            installLog.append(line)
            if installLog.count > Self.maxLogLines { installLog.removeFirst(installLog.count - Self.maxLogLines) }
        case "display.install.done":
            installsEnded += 1
            isInstalling = false
            sudoRequestID = nil
            let code = payload["code"]?.intValue ?? 1
            if let next = payload["status"]?.objectValue.flatMap(BotScreenStatus.init) { apply(next) }
            if code == 0 {
                // Installed: the screen's own view takes over from the log.
                installLog = []
            } else {
                errorText = code == -2
                    ? AppLocalization.string("This host has no sudo. Run the install command on the host yourself.")
                    : AppLocalization.string("The install didn't finish. Its log is below.")
            }
        default:
            break
        }
    }

    private func receiveSudo(id: String, profileKey: String, from sender: AnyObject?) {
        // Any install of this bot's screen, one started elsewhere too: the
        // host waits on its password either way.
        guard sender === client, !id.isEmpty else { return }
        guard let status else {
            // Before the first status read: kept until it says whose it is.
            pendingSudo = (id, profileKey)
            return
        }
        guard profileKey == status.profileKey else { return }
        isInstalling = true
        sudoRequestID = id
    }

    // MARK: The stream

    /// Watches the screen: a ticket from `display.observe`, then the RFB
    /// stream on the app's own connection, handed to the page.
    func attach() async {
        guard let client, status?.isRunning == true, page != nil else { return }
        detach()
        attachGeneration += 1
        let generation = attachGeneration
        stream = .connecting
        do {
            // The id this view minted before keeps its hold across a reconnect.
            let observed = try await client.display("display.observe", profile: profile,
                                                    params: viewerID.map { ["viewer_id": $0] } ?? [:])
            guard generation == attachGeneration else { return }
            guard let ticket = observed["ticket"]?.stringValue, let id = observed["viewer_id"]?.stringValue else {
                throw HermesError.invalidResponse
            }
            viewerID = id
            Self.viewerIDs[profile] = id
            viewerHash = BotScreenLease.hash(ofViewer: id)
            if let next = BotScreenStatus(observed) {
                status = keepingNewerLease(next)
                page?.setViewOnly(!iHold)
            }
            let request = try await client.displayStreamRequest(path: observed["path"]?.stringValue ?? "/api/display/ws",
                                                                ticket: ticket)
            guard generation == attachGeneration else { return }
            page?.startStream(viewOnly: !iHold)
            dialedAt = Date()
            let transport = URLSessionWebSocketTransport()
            self.transport = transport
            let socket = transport.makeSocket(
                request: request,
                onOpen: { [weak self] socket in
                    Task { @MainActor in self?.opened(socket, generation: generation) }
                },
                onCloseBeforeOpen: { [weak self] socket in
                    Task { @MainActor in self?.ended(socket, generation: generation) }
                }
            )
            self.socket = socket
            socket.resume()
        } catch {
            guard generation == attachGeneration else { return }
            stream = .lost(error.localizedDescription)
        }
    }

    func detach() {
        attachGeneration += 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        transport?.invalidate()
        transport = nil
        page?.stopStream()
        stream = .idle
    }

    /// Bytes the page sends (input, when this view holds the screen).
    func pageSent(_ data: Data) {
        socket?.send(.data(data)) { _ in }
    }

    func pageConnected() {
        stream = .live
        // rapidEvictions isn't reset here: an attach that's evicted at once
        // still completes its handshake first. A close after ten quiet
        // seconds starts the count over.
    }

    /// The page closed its end: only a live stream's, since a detach's own
    /// stop reports a close after the next stream may have started dialling.
    func pageClosedStream() {
        guard stream == .live else { return }
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    /// The page's RFB handshake failed (the server refused it).
    func pageFailed(_ reason: String) {
        guard stream == .connecting || stream == .live else { return }
        detach()
        stream = .lost(reason.isEmpty ? AppLocalization.string("The screen's stream was lost.") : reason)
    }

    /// The app went to the background: a takeover is handed back, so the
    /// bot isn't kept off its screen while nobody watches, and the stream
    /// closes until it's watched again.
    func backgrounded() {
        leaveGeneration += 1
        if iHold { Task { await handBack(force: false) } }
        detach()
    }

    private func opened(_ socket: any HermesWebSocket, generation: Int) {
        guard generation == attachGeneration, self.socket === socket else { return }
        page?.streamOpened()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self, !Task.isCancelled, generation == self.attachGeneration,
                          self.socket === socket else { return }
                    switch message {
                    case .data(let data): self.page?.streamData(data)
                    case .string(let text): self.page?.streamData(Data(text.utf8))
                    @unknown default: break
                    }
                } catch {
                    await MainActor.run { self?.ended(socket, generation: generation) }
                    return
                }
            }
        }
    }

    private func ended(_ socket: any HermesWebSocket, generation: Int) {
        guard generation == attachGeneration, self.socket === socket else { return }
        let code = socket.closeCode.rawValue
        page?.streamClosed(code: code)
        self.socket = nil
        transport?.invalidate()
        transport = nil
        if code == Self.controlTakenCode {
            // Someone took over from another device: watch again, on a fresh
            // ticket, a few times at most if every attach is evicted at once.
            rapidEvictions = Date().timeIntervalSince(dialedAt) < 10 ? rapidEvictions + 1 : 1
            if rapidEvictions <= Self.maxRapidEvictions {
                stream = .idle
                Task { await attach() }
                return
            }
            stream = .lost(AppLocalization.string("Someone else took control of the screen."))
            return
        }
        stream = code == URLSessionWebSocketTask.CloseCode.normalClosure.rawValue
            ? .idle : .lost(AppLocalization.string("The screen's stream was lost."))
        Task { await load() }
    }
}

/// The page that draws a screen (BotScreenWebView), as the model drives it.
@MainActor
protocol BotScreenPage: AnyObject {
    func startStream(viewOnly: Bool)
    func streamOpened()
    func streamData(_ data: Data)
    func streamClosed(code: Int)
    func stopStream()
    func setViewOnly(_ viewOnly: Bool)
    func sendKeysyms(_ keysyms: [Int])
}

/// Which bots' hosts can have a screen, as last read: a bot's Screen entries
/// show only once its host said it can (Eric 2026-11-05).
@MainActor
final class BotScreenSupport: ObservableObject {
    @Published private(set) var supported: [String: Bool] = [:]
    private var reading: Set<String> = []
    private var generation = 0
    private weak var readFrom: HermesClient?

    func isSupported(_ profile: String) -> Bool { supported[profile] == true }

    /// Reads it once per profile and connection; a read that failed is
    /// tried again a few times.
    func check(_ profile: String, client: HermesClient?, attempt: Int = 0) {
        guard let client else { return }
        // Another server (a new client): what was read stood for the old one.
        if readFrom !== client {
            reset()
            readFrom = client
        }
        guard supported[profile] == nil, !reading.contains(profile) else { return }
        reading.insert(profile)
        let generation = self.generation
        Task { @MainActor in
            defer { if generation == self.generation { reading.remove(profile) } }
            do {
                let answer = try await client.display("display.status", profile: profile)
                guard generation == self.generation else { return }
                // An answer it can't read is not a no: read again next time.
                if let status = BotScreenStatus(answer) { supported[profile] = status.isSupported }
            } catch let error as RpcError where error.code == HermesClient.methodNotFoundCode {
                guard generation == self.generation else { return }
                supported[profile] = false
            } catch {
                // Not known: read again shortly, while still on this server.
                guard generation == self.generation, attempt < 3 else { return }
                Task { @MainActor [weak self, weak client] in
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, let client, generation == self.generation else { return }
                    self.check(profile, client: client, attempt: attempt + 1)
                }
            }
        }
    }

    func reset() {
        // A probe still under way answers for the old server: dropped.
        generation += 1
        reading = []
        supported = [:]
    }
}
