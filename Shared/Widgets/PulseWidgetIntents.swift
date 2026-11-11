import AppIntents
import Foundation

/// A button on a card in the Pulse widget (issue 2190).
enum PulseWidgetAction: String, Codable {
    /// Marks the card done; its row leaves the list.
    case done
    /// Sends the card's Do it message to Hermes; the answer comes the usual
    /// way (Live Activity, push).
    case doIt = "do_it"
    /// Puts the card off until later today (tomorrow once it's late).
    case later
}

/// Done on a card in the Pulse widget: the widget tells the host itself,
/// with the pass Conduit keeps for it (PulseWidgetAccess).
struct PulseWidgetDoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Done"
    static let isDiscoverable = false

    @Parameter(title: "Card") var card: Int
    @Parameter(title: "Workspace") var dashboard: String

    init() {}

    init(card: Int, dashboardID: UUID) {
        self.card = card
        dashboard = dashboardID.uuidString
    }

    func perform() async throws -> some IntentResult {
        await PulseWidgetHostActions.run(.done, card: card, dashboard: dashboard)
        return .result()
    }
}

/// Not now on a card in the Pulse widget, the same way.
struct PulseWidgetLaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Not now"
    static let isDiscoverable = false

    @Parameter(title: "Card") var card: Int
    @Parameter(title: "Workspace") var dashboard: String

    init() {}

    init(card: Int, dashboardID: UUID) {
        self.card = card
        dashboard = dashboardID.uuidString
    }

    func perform() async throws -> some IntentResult {
        await PulseWidgetHostActions.run(.later, card: card, dashboard: dashboard)
        return .result()
    }
}

/// Do it on a card in the Pulse widget. Sending to a chat takes Conduit's
/// own connection, so this one runs in Conduit's process: iOS performs a
/// LiveActivityIntent in the app, starting it in the background when it
/// isn't running. `PulseWidgetRunner` is the app's (AppState+PulseWidget);
/// the widget's own is a stand-in that is never called.
struct PulseWidgetDoItIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Do it"
    static let isDiscoverable = false

    @Parameter(title: "Card") var card: Int
    @Parameter(title: "Workspace") var dashboard: String

    init() {}

    init(card: Int, dashboardID: UUID) {
        self.card = card
        dashboard = dashboardID.uuidString
    }

    func perform() async throws -> some IntentResult {
        await PulseWidgetRunner.run(.doIt, card: card, dashboard: dashboard)
        return .result()
    }
}

/// Done and Not now from the widget, against the host directly. The row
/// leaves the widget's list at once; WidgetKit then reloads the widget,
/// which reads the feed again. One that couldn't reach the host stays,
/// with why.
enum PulseWidgetHostActions {
    static func run(_ action: PulseWidgetAction, card: Int, dashboard: String,
                    access: PulseWidgetAccess? = PulseWidgetKeychain.load(),
                    store: PulseWidgetStore? = PulseWidgetStore.production) async {
        guard action != .doIt, let dashboardID = UUID(uuidString: dashboard) else { return }
        let kept = store?.read()
        let language = kept?.appLanguage ?? "system"
        guard let access, access.dashboardID == dashboardID else {
            note(WidgetLocalization.string("Open Conduit to refresh", language: language), kept: kept, store: store)
            return
        }
        let path: String
        var body: [String: Any] = ["card": card]
        switch action {
        case .done:
            path = PulseWidgetFeed.base + "/done"
            body["done"] = true
        case .later:
            path = PulseWidgetFeed.base + "/dismiss"
            body["dismissed"] = true
            // Later today; the plugin makes it tomorrow once today's gone.
            if access.serves(PulseWidgetAccess.restCapability) { body["until"] = "later_today" }
        case .doIt:
            return
        }
        do {
            _ = try await LocationHostClient.requestJSON(pass: access.pass, path: path, method: "POST", body: body)
            guard let kept, kept.dashboardID == dashboardID else { return }
            try? store?.write(kept.with(cards: kept.cards.filter { $0.id != card }, note: .some(nil)))
        } catch LocationHostError.signInRequired {
            note(WidgetLocalization.string("Open Conduit to refresh", language: language), kept: kept, store: store)
        } catch {
            note(WidgetLocalization.string("Conduit couldn't reach Hermes. Open Conduit and check the connection.",
                                           language: language), kept: kept, store: store)
        }
    }

    private static func note(_ text: String, kept: PulseWidgetSnapshot?, store: PulseWidgetStore?) {
        guard let kept else { return }
        try? store?.write(kept.with(note: .some(text), noteAt: Date()))
    }
}
