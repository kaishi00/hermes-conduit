import SwiftUI
import WebKit

/// A bot whose screen a sheet shows.
struct BotScreenTarget: Identifiable, Equatable {
    let profile: String
    let botName: String
    var id: String { profile }
}

/// A bot's screen (Bot Screen): watch it, take over for a sign-in or a
/// CAPTCHA, hand back. Also starts the screen and installs its packages on
/// the host, so nothing needs a terminal (Eric 2026-11-05).
struct BotScreenSheet: View {
    @EnvironmentObject private var appState: AppState
    let target: BotScreenTarget

    var body: some View {
        BotScreenContent(target: target, client: appState.client, work: appState.botWork)
            // A reconnect makes a new client: the screen is read again on it.
            .id(appState.client.map { ObjectIdentifier($0) })
            // The screen covers the open chat from wherever it opened (the
            // chat's menu, a Work panel card, Bots Home): what arrives
            // meanwhile hasn't been read, and closing it reads it (#1579).
            .onAppear { appState.botScreenSheetsOpen += 1 }
            .onDisappear {
                appState.botScreenSheetsOpen = max(0, appState.botScreenSheetsOpen - 1)
                if appState.botScreenSheetsOpen == 0 { appState.clearShownChatNotifications() }
            }
    }
}

private struct BotScreenContent: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: BotScreenModel
    @ObservedObject var work: BotWorkStore
    let target: BotScreenTarget
    @State private var typed = ""
    @State private var typesSecret = true
    @State private var sudoPassword = ""
    @State private var confirmsStop = false
    @FocusState private var typeFieldFocused: Bool

    init(target: BotScreenTarget, client: HermesClient?, work: BotWorkStore) {
        self.target = target
        self.work = work
        _model = StateObject(wrappedValue: BotScreenModel(profile: target.profile, client: client))
    }

    private var use: BotScreenUse? { work.snapshot(target.profile)?.screen }

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        content
                        if let error = model.errorText {
                            Text(error)
                                .scaledFont(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: AppLocalization.string("\(target.botName)'s Screen"), close: { dismiss() })
            }
        }
        // Made while Conduit is already in the background (a reconnect
        // rebuilt the sheet there): it starts away, so nothing attaches.
        .onAppear { if scenePhase == .background { model.backgrounded() } }
        .task { await model.load() }
        // Who drives the screen now, read again while the sheet is open.
        .refreshesBotWork(profile: target.profile)
        // Gone because a reconnect rebuilt it on a new client: the hold stays.
        .onDisappear { model.close(reconnecting: !model.uses(appState.client)) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.backgrounded() }
            // Read again: the screen may have started or stopped meanwhile.
            if phase == .active {
                model.foregrounded()
                Task { await model.load() }
            }
        }
        // A new or cancelled ask never takes the password typed for another.
        .onChange(of: model.sudoRequestID) { _, _ in sudoPassword = "" }
        .confirmationDialog(AppLocalization.string("Stop the screen?"), isPresented: $confirmsStop,
                            titleVisibility: .visible) {
            Button(AppLocalization.string("Stop Screen"), role: .destructive) {
                Task { await model.stop() }
            }
        } message: {
            Text(AppLocalization.string("The bot's open windows close. It starts again the next time it's needed."))
        }
    }

    @ViewBuilder private var content: some View {
        switch model.availability {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        case .unsupported:
            ContentUnavailableView(
                AppLocalization.string("No screen on this host"),
                systemImage: "display.trianglebadge.exclamationmark",
                description: Text(AppLocalization.string("A bot's screen needs Hermes on a Linux host and a recent Hermes."))
            )
        case .failed(let reason):
            ContentUnavailableView {
                Label(AppLocalization.string("Couldn't read the screen"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason)
            } actions: {
                Button(AppLocalization.string("Try Again")) { Task { await model.load() } }
            }
        case .available:
            if let status = model.status {
                available(status)
            }
        }
    }

    @ViewBuilder private func available(_ status: BotScreenStatus) -> some View {
        if model.isInstalling || !model.installLog.isEmpty {
            installProgress(status)
        } else if let image = status.imageSwitch {
            // A sandbox that needs the desktop image switches first; the
            // install comes after, inside it.
            imageSwitch(image)
        } else if !status.isInstalled {
            notInstalled(status)
        } else if !status.isRunning {
            stopped(status)
        } else {
            running(status)
        }
    }

    private func notInstalled(_ status: BotScreenStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AppLocalization.string("The screen isn't set up on this host yet"), systemImage: "display")
                .scaledFont(.headline)
            Text(AppLocalization.string("Installing adds a small desktop and its packages on the Hermes host (about 1 GB of disk). Hermes asks for the host's password if it needs one."))
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.install() }
            } label: {
                Label(AppLocalization.string("Install on Host"), systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || status.installCommand == nil)
            if let command = status.installCommand {
                commandBox(command)
            } else {
                Text(AppLocalization.string("This host has no package manager Hermes knows (apt, dnf or pacman)."))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func installProgress(_ status: BotScreenStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if model.isInstalling { ProgressView() }
                Text(model.isInstalling ? AppLocalization.string("Installing on the host…")
                     : AppLocalization.string("Install finished"))
                    .scaledFont(.headline)
            }
            if model.sudoRequestID != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalization.string("The host's sudo password"))
                        .scaledFont(.subheadline.weight(.semibold))
                    Text(AppLocalization.string("It goes to the Hermes host only, for this install, and isn't kept."))
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        SecureField(AppLocalization.string("Password"), text: $sudoPassword)
                            .textContentType(.password)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(sendPassword)
                        Button(AppLocalization.string("Send"), action: sendPassword)
                            .buttonStyle(.borderedProminent)
                            .disabled(sudoPassword.isEmpty)
                    }
                    Button(AppLocalization.string("Cancel Install"), role: .cancel) {
                        sudoPassword = ""
                        Task { await model.answerSudo("") }
                    }
                    .scaledFont(.footnote)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.installLog.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .scaledFont(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 220)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: model.installLog.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            if !model.isInstalling {
                Button(AppLocalization.string("Continue")) {
                    Task { await model.continueAfterInstall() }
                }
                .buttonStyle(.borderedProminent)
                if !status.isInstalled, let command = status.installCommand {
                    commandBox(command)
                }
            }
        }
    }

    private func sendPassword() {
        let password = sudoPassword
        sudoPassword = ""
        guard !password.isEmpty else { return }
        Task { await model.answerSudo(password) }
    }

    private func commandBox(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string("Or run this on the host:"))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Text(command)
                    .scaledFont(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = command
                    Haptics.light()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel(AppLocalization.string("Copy Command"))
            }
            .padding(10)
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func imageSwitch(_ image: BotScreenStatus.ImageSwitch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AppLocalization.string("The bot's sandbox needs the desktop image"), systemImage: "shippingbox")
                .scaledFont(.headline)
            Text(AppLocalization.string("Its sandbox runs \(image.current). The screen needs \(image.target). Switching keeps its files; packages installed inside it come back on use."))
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(AppLocalization.string("Switch Image")) { Task { await model.switchImage(approve: true) } }
                    .buttonStyle(.borderedProminent)
                Button(AppLocalization.string("Keep Current Image")) { Task { await model.switchImage(approve: false) } }
                    .buttonStyle(.bordered)
            }
            .disabled(model.isBusy)
        }
    }

    private func stopped(_ status: BotScreenStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AppLocalization.string("The screen is off"), systemImage: "display")
                .scaledFont(.headline)
            Text(AppLocalization.string("It starts when you start it here, and stops after a while nobody uses it."))
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
            if let blocker = status.blocker {
                Text(blocker)
                    .scaledFont(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    Task { await model.start() }
                } label: {
                    Label(AppLocalization.string("Start Screen"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
            useLine
        }
    }

    private func running(_ status: BotScreenStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            controlChip(status)
            BotScreenWebView(model: model)
                .aspectRatio(status.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(model.iHold ? Color.red : Color.clear, lineWidth: 3)
                }
                .overlay {
                    streamOverlay
                }
                .accessibilityLabel(AppLocalization.string("\(target.botName)'s Screen"))
            useLine
            controls(status)
            if model.iHold { typeBar }
        }
    }

    @ViewBuilder private var streamOverlay: some View {
        switch model.stream {
        case .connecting, .idle:
            ProgressView().tint(.white)
        case .lost(let reason):
            VStack(spacing: 8) {
                Text(reason)
                    .scaledFont(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button(AppLocalization.string("Reconnect")) { Task { await model.attach() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        case .live:
            EmptyView()
        }
    }

    private func controlChip(_ status: BotScreenStatus) -> some View {
        let text: String
        let color: Color
        if model.iHold {
            text = AppLocalization.string("You're in control")
            color = .red
        } else if status.lease.isHuman {
            text = AppLocalization.string("Someone else is in control")
            color = .orange
        } else {
            text = AppLocalization.string("\(target.botName) is in control")
            color = .green
        }
        return Label(text, systemImage: "circle.fill")
            .labelStyle(BotScreenChipStyle(color: color))
            .scaledFont(.subheadline.weight(.semibold))
    }

    /// Which of the bot's chats drives the screen now, apart from the one
    /// that used it last (the plugin's hold; Eric 2026-11-05).
    @ViewBuilder private var useLine: some View {
        if let controlling = use?.controlling {
            Text(AppLocalization.string("\(BotScreenUse.name(of: controlling)) is using the screen"))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        } else if let last = use?.last, let at = last.at {
            Text(AppLocalization.string("Nobody is using it now. Last used by \(BotScreenUse.name(of: last)), \(at.formatted(.relative(presentation: .named)))."))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func controls(_ status: BotScreenStatus) -> some View {
        HStack(spacing: 10) {
            if model.iHold {
                Button {
                    Haptics.light()
                    Task { await model.handBack() }
                } label: {
                    Label(AppLocalization.string("Hand Back"), systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Haptics.light()
                    Task { await model.takeOver() }
                } label: {
                    Label(AppLocalization.string("Take Over"), systemImage: "hand.raised")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.stream != .live)
            }
            Menu {
                if model.someoneElseHolds {
                    Button(AppLocalization.string("Hand Back for Them")) { Task { await model.handBack(force: true) } }
                }
                Button(AppLocalization.string("Stop Screen"), role: .destructive) { confirmsStop = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
            }
            .accessibilityLabel(AppLocalization.string("More"))
        }
        .disabled(model.isBusy)
    }

    /// Typing on the screen: a field (hidden like a password by default, as
    /// what's typed during a takeover usually is) and the keys a form needs.
    private var typeBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Group {
                    if typesSecret {
                        SecureField(AppLocalization.string("Type on the screen"), text: $typed)
                    } else {
                        TextField(AppLocalization.string("Type on the screen"), text: $typed)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($typeFieldFocused)
                .onSubmit(sendTyped)
                Button {
                    typesSecret.toggle()
                } label: {
                    Image(systemName: typesSecret ? "eye" : "eye.slash")
                }
                .accessibilityLabel(typesSecret ? AppLocalization.string("Show Typing")
                                    : AppLocalization.string("Hide Typing"))
                Button(AppLocalization.string("Send"), action: sendTyped)
                    .buttonStyle(.bordered)
                    .disabled(typed.isEmpty)
            }
            HStack(spacing: 8) {
                keyButton(.enter, AppLocalization.string("Return"))
                keyButton(.tab, AppLocalization.string("Tab"))
                keyButton(.backspace, AppLocalization.string("Delete"))
                keyButton(.escape, AppLocalization.string("Esc"))
            }
            Text(AppLocalization.string("Tap the screen to click. What you type in this bar lands as you typed it, whatever your keyboard's layout."))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func keyButton(_ key: BotScreenKey, _ title: String) -> some View {
        Button(title) { model.press(key) }
            .buttonStyle(.bordered)
            .scaledFont(.footnote)
    }

    private func sendTyped() {
        let text = typed
        typed = ""
        guard !text.isEmpty else { return }
        model.type(text)
    }
}

private struct BotScreenChipStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .foregroundStyle(color)
                .imageScale(.small)
            configuration.title
        }
    }
}

/// The page that draws the screen: noVNC in a web view, fed by the model.
struct BotScreenWebView: UIViewRepresentable {
    @ObservedObject var model: BotScreenModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakScriptHandler(context.coordinator), name: "screen")
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        context.coordinator.webView = view
        if let url = Bundle.main.url(forResource: "BotScreenViewer", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "screen")
        coordinator.model?.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, BotScreenPage {
        weak var model: BotScreenModel?
        weak var webView: WKWebView?
        private var ready = false

        init(model: BotScreenModel) {
            self.model = model
        }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? [String: Any] ?? [:]
            MainActor.assumeIsolated { self.received(body) }
        }

        private func received(_ body: [String: Any]) {
            // The stream a message is about, as startStream tagged it.
            let tag = (body["stream"] as? NSNumber)?.intValue
            switch body["type"] as? String {
            case "ready":
                ready = true
                model?.page = self
                if let model, model.status?.isRunning == true, model.stream == .idle {
                    Task { await model.attach() }
                }
            case "send":
                if let text = body["data"] as? String, let data = Data(base64Encoded: text) {
                    model?.pageSent(data, tag: tag)
                }
            case "connected":
                model?.pageConnected(tag: tag)
            case "close":
                model?.pageClosedStream(tag: tag)
            case "failed":
                model?.pageFailed(body["reason"] as? String ?? "", tag: tag)
            default:
                break
            }
        }

        private func call(_ script: String) {
            guard ready else { return }
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        func startStream(viewOnly: Bool, tag: Int) {
            call("conduitScreen.start({viewOnly: \(viewOnly), stream: \(tag)})")
        }
        func streamOpened() { call("conduitScreen.opened()") }
        func streamData(_ data: Data) { call("conduitScreen.data('\(data.base64EncodedString())')") }
        func streamClosed(code: Int) { call("conduitScreen.closed(\(code), '')") }
        func stopStream() { call("conduitScreen.stop()") }
        func setViewOnly(_ viewOnly: Bool) { call("conduitScreen.setViewOnly(\(viewOnly))") }
        func sendKeysyms(_ keysyms: [Int]) {
            call("conduitScreen.keysyms([\(keysyms.map(String.init).joined(separator: ","))])")
        }
    }
}

/// The content controller keeps its handler strongly; this keeps the
/// coordinator from living as long as the web view's process.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// "Screen" wherever a bot's screen opens from: shown only once the bot's
/// host said it can have one (Eric 2026-11-05).
struct BotScreenButton: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @ObservedObject var support: BotScreenSupport
    let profile: String
    let open: () -> Void
    var title: String? = nil
    /// A round icon, as the Bot Overview's header buttons are.
    var iconOnly = false

    var body: some View {
        Group {
            if support.isSupported(profile) {
                if iconOnly {
                    Button(action: open) {
                        Image(systemName: "display")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title ?? AppLocalization.string("Open Screen"))
                } else {
                    Button(action: open) {
                        Label(title ?? AppLocalization.string("Open Screen"), systemImage: "display")
                    }
                }
            }
        }
        .task(id: "\(profile)\u{1F}\(appState.isConnected)") {
            if appState.isConnected { support.check(profile, client: appState.client) }
        }
    }
}
