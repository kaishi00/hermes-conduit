#if DEBUG
import SwiftUI

/// Deterministic UI-test fixture for widget URL delivery. Every operation
/// returns transport data; AppState and WidgetLaunchCoordinator still perform
/// the route and adopt the resulting conversation identity.
@MainActor
enum WidgetLaunchUITestFixture {
    static let urlArgument = "-CONDUIT_UI_TEST_WIDGET_URL"
    static let deliveryArgument = "-CONDUIT_UI_TEST_WIDGET_DELIVERY"
    static let holdReadinessArgument = "-CONDUIT_UI_TEST_WIDGET_HOLD_READINESS"
    static let deliveryButtonID = "widgetUITestDeliverURL"
    static let workspaceOutcomeID = "widgetUITestWorkspace"
    static let conversationOutcomeID = "widgetUITestConversation"
    static let freshConversationOutcomeID = "widgetUITestFreshConversation"
    static let deferredTalkOutcomeID = "widgetUITestTalkDeferred"
    static let recoveryOutcomeID = "widgetUITestRecovery"
    static let diagnosticID = "widgetUITestDiagnostic"

    private static let dashboardID = UUID(uuidString: "8D516B21-6B3C-4F5A-A0D6-6F6E8B73A901")!
    fileprivate static let profile = "work"
    private static let sessionID = "widget-ui-test-session"
    private static let currentSessionID = "widget-ui-test-current-session"
    private static let resumeMessageID = "widget-ui-test-resume"
    private static let createdSessionID = "widget-ui-test-created-session"
    private static let dashboardURL = "https://conduit-ui-test.invalid"

    static func launchURL(arguments: [String]) -> URL? {
        guard ProcessInfo.processInfo.environment["CONDUIT_UITEST"] == "1",
              let index = arguments.firstIndex(of: urlArgument),
              arguments.indices.contains(index + 1) else { return nil }
        let raw = arguments[index + 1]
        guard let url = URL(string: raw), url.scheme?.lowercased() == "conduit",
              url.host?.lowercased() == "widget" else { return nil }
        return url
    }

    static func createAppStateIfEnabled() -> AppState? {
        let arguments = ProcessInfo.processInfo.arguments
        guard launchURL(arguments: arguments) != nil else { return nil }

        let suiteName = "WidgetLaunchUITestFixture"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(profile, forKey: "conduit.activeProfile")
        defaults.set([profile, "staging"], forKey: "conduit.knownProfiles.v1")

        let dashboard = SavedDashboard(
            id: dashboardID,
            label: "UI Test Workspace",
            normalizedURL: dashboardURL
        )
        let workspace = WidgetWorkspaceID(dashboardID: dashboardID, profile: profile)
        let requestedSession = SessionSummary(
            id: sessionID,
            storedSessionId: sessionID,
            alternateIds: [],
            title: "Widget UI Test Conversation",
            model: "Hermes",
            updatedLabel: "",
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
        let currentSession = SessionSummary(
            id: currentSessionID,
            storedSessionId: currentSessionID,
            alternateIds: [],
            title: "Current UI Test Conversation",
            model: "Hermes",
            updatedLabel: "",
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
        let holdReadiness = arguments.contains(holdReadinessArgument)
        let catalog = WidgetUITestCatalog(
            current: currentSession,
            requested: requestedSession,
            createdID: createdSessionID,
            holdsReadiness: holdReadiness
        )
        let resumeOperations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in try await catalog.rows() },
            openSessionWithProfile: { client, requestedID, _, requestedProfile in
                guard (requestedProfile ?? client.profile) == profile, requestedID == sessionID else {
                    throw WidgetUITestFixtureError.unexpectedResume
                }
                return SessionResumeResult(
                    sessionId: sessionID,
                    storedSessionId: sessionID,
                    messages: [ChatMessage(
                        id: resumeMessageID,
                        role: .assistant,
                        content: "Widget route resumed the requested conversation.",
                        timestamp: "1"
                    )],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            verifyTransportHealth: { _ in },
            probeActiveSessions: { _ in [] }
        )

        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: true,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboardID, dashboards: [dashboard]),
            clearSessionPresentationCache: {},
            sessionCatalogLoader: { _ in try await catalog.rows() },
            chatResumeLifecycleOperations: resumeOperations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        guard let connection = appState.connection else { return nil }
        appState.client = HermesClient(connection: connection, profile: profile)
        appState.profiles = [profile, "staging"]
        appState.sessions = [currentSession, requestedSession]
        appState.widgetSettledCatalogOwner = holdReadiness ? nil : workspace
        appState.widgetSessionCreatorOverride = { _, _ in
            await catalog.recordCreatedSession()
            return (createdSessionID, createdSessionID, profile)
        }
        appState.activeSessionId = currentSessionID
        return appState
    }

    fileprivate static func isEnabled(arguments: [String]) -> Bool {
        ProcessInfo.processInfo.environment["CONDUIT_UITEST"] == "1"
            && launchURL(arguments: arguments) != nil
    }

    private static func holdReadiness(arguments: [String]) -> Bool {
        arguments.contains(holdReadinessArgument)
    }

    private static func deliveryMode(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: deliveryArgument),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func modifier(appState: AppState) -> WidgetLaunchUITestFixtureModifier {
        WidgetLaunchUITestFixtureModifier(appState: appState)
    }

    fileprivate static func isRecoveryVisible(_ appState: AppState) -> Bool {
        appState.errorMessage == AppLocalization.string("WidgetLaunch.ConversationUnavailable")
    }

    fileprivate static func isRequestedWorkspaceSelected(_ appState: AppState) -> Bool {
        guard let url = launchURL(arguments: ProcessInfo.processInfo.arguments),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dashboard = components.queryItems?.first(where: { $0.name == "dashboard" })?.value,
              let requestedDashboardID = UUID(uuidString: dashboard),
              let profile = components.queryItems?.first(where: { $0.name == "profile" })?.value else {
            return false
        }
        return appState.activeDashboardID == requestedDashboardID && appState.activeProfile == profile
    }

    fileprivate static func isSuccessfulResume(_ appState: AppState) -> Bool {
        isRequestedWorkspaceSelected(appState)
            && appState.activeSessionId == sessionID
            && appState.messages.contains(where: { $0.id == resumeMessageID })
    }

    fileprivate static func isSuccessfulCreate(_ appState: AppState) -> Bool {
        isRequestedWorkspaceSelected(appState)
            && appState.activeSessionId == createdSessionID
            && appState.sessions.contains(where: { $0.id == createdSessionID && $0.profile == profile })
    }

    fileprivate static func isRetainedCurrentConversationAfterRecovery(_ appState: AppState) -> Bool {
        isRecoveryVisible(appState)
            && isRequestedWorkspaceSelected(appState)
            && appState.activeSessionId == currentSessionID
    }

    fileprivate static func shouldExposeWorkspace(_ appState: AppState) -> Bool {
        isSuccessfulResume(appState)
            || isSuccessfulCreate(appState)
            || isRetainedCurrentConversationAfterRecovery(appState)
    }

    fileprivate static func workspaceValue(_ appState: AppState) -> String {
        shouldExposeWorkspace(appState) ? appState.activeProfile : ""
    }

    fileprivate static func conversationValue(_ appState: AppState) -> String? {
        if isSuccessfulResume(appState) { return appState.activeSessionId }
        if isRetainedCurrentConversationAfterRecovery(appState) { return appState.activeSessionId }
        return nil
    }

    fileprivate static func shouldExposeFreshConversation(_ appState: AppState) -> Bool {
        isSuccessfulCreate(appState)
    }

    fileprivate static func deferredTalkValue(_ appState: AppState, arguments: [String]) -> String? {
        guard holdReadiness(arguments: arguments),
              launchURL(arguments: arguments)?.path == "/v1/talk",
              appState.widgetLaunchCoordinator.hasPendingRequest,
              !appState.showVoiceSheet,
              !appState.isVoiceCallInProgress else { return nil }
        return "waiting-for-foreground-readiness"
    }

    fileprivate static func diagnosticValue(_ appState: AppState, admitted: Bool) -> String {
        let requestedWorkspace = WidgetWorkspaceID(dashboardID: dashboardID, profile: profile)
        let owner = appState.widgetSettledCatalogOwner == requestedWorkspace
        let error = appState.errorMessage ?? "nil"
        return "admitted=\(admitted); pending=\(appState.widgetLaunchCoordinator.hasPendingRequest); owner=\(owner); foreground=\(appState.widgetForegroundReady); connected=\(appState.isConnected); error=\(error)"
    }

    fileprivate static func shouldShowWarmDelivery(arguments: [String]) -> Bool {
        isEnabled(arguments: arguments) && deliveryMode(arguments: arguments) == "warm"
    }

    fileprivate static func coldURL(arguments: [String]) -> URL? {
        guard isEnabled(arguments: arguments), deliveryMode(arguments: arguments) != "warm" else { return nil }
        return launchURL(arguments: arguments)
    }

    fileprivate static func accessValue(_ value: String, identifier: String) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(identifier)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
    }
}

@MainActor
struct WidgetLaunchUITestFixtureModifier: ViewModifier {
    @ObservedObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var coldDeliveryStarted = false
    @State private var pendingWidgetRequest = false
    @State private var admissionResult: Bool?

    private var arguments: [String] { ProcessInfo.processInfo.arguments }

    func body(content: Content) -> some View {
        if WidgetLaunchUITestFixture.isEnabled(arguments: arguments) {
            content
                .overlay(alignment: .topLeading) {
                    if WidgetLaunchUITestFixture.shouldShowWarmDelivery(arguments: arguments),
                       let url = WidgetLaunchUITestFixture.launchURL(arguments: arguments) {
                        Button {
                            admissionResult = appState.routeWidgetLaunchURL(url)
                        } label: {
                            Text(verbatim: "Deliver widget URL")
                        }
                        .accessibilityIdentifier(WidgetLaunchUITestFixture.deliveryButtonID)
                    }
                    outcomeElements
                }
                .task {
                    guard !coldDeliveryStarted,
                          let url = WidgetLaunchUITestFixture.coldURL(arguments: arguments) else { return }
                    coldDeliveryStarted = true
                    admissionResult = appState.routeWidgetLaunchURL(url)
                }
                .task {
                    while !Task.isCancelled {
                        pendingWidgetRequest = appState.widgetLaunchCoordinator.hasPendingRequest
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // RootView owns the real lifecycle transition. This fixture
                    // only samples coordinator state and never synthesizes it.
                    if phase == .active {
                        pendingWidgetRequest = appState.widgetLaunchCoordinator.hasPendingRequest
                    }
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var outcomeElements: some View {
        VStack(alignment: .leading, spacing: 0) {
            if WidgetLaunchUITestFixture.shouldExposeWorkspace(appState) {
                WidgetLaunchUITestFixture.accessValue(
                    WidgetLaunchUITestFixture.workspaceValue(appState),
                    identifier: WidgetLaunchUITestFixture.workspaceOutcomeID
                )
            }
            if let conversationID = WidgetLaunchUITestFixture.conversationValue(appState) {
                WidgetLaunchUITestFixture.accessValue(
                    conversationID,
                    identifier: WidgetLaunchUITestFixture.conversationOutcomeID
                )
            }
            if WidgetLaunchUITestFixture.shouldExposeFreshConversation(appState) {
                WidgetLaunchUITestFixture.accessValue(
                    appState.activeSessionId ?? "",
                    identifier: WidgetLaunchUITestFixture.freshConversationOutcomeID
                )
            }
            if let deferredValue = WidgetLaunchUITestFixture.deferredTalkValue(appState, arguments: arguments),
               pendingWidgetRequest {
                WidgetLaunchUITestFixture.accessValue(
                    deferredValue,
                    identifier: WidgetLaunchUITestFixture.deferredTalkOutcomeID
                )
            }
            if WidgetLaunchUITestFixture.isRecoveryVisible(appState) {
                WidgetLaunchUITestFixture.accessValue(
                    "conversation-unavailable",
                    identifier: WidgetLaunchUITestFixture.recoveryOutcomeID
                )
            }
            if let admissionResult {
                WidgetLaunchUITestFixture.accessValue(
                    WidgetLaunchUITestFixture.diagnosticValue(appState, admitted: admissionResult),
                    identifier: WidgetLaunchUITestFixture.diagnosticID
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHidden(false)
    }
}

@MainActor
private final class WidgetUITestCatalog {
    private let current: SessionSummary
    private let requested: SessionSummary
    private let createdID: String
    private let holdsReadiness: Bool
    private var created = false

    init(current: SessionSummary, requested: SessionSummary, createdID: String, holdsReadiness: Bool) {
        self.current = current
        self.requested = requested
        self.createdID = createdID
        self.holdsReadiness = holdsReadiness
    }

    func recordCreatedSession() async { created = true }

    func rows() async throws -> [SessionSummary] {
        if holdsReadiness {
            // Hold the actual catalog operation so neither the initial
            // foreground refresh nor a view-triggered refresh can publish a
            // settled catalog owner before the Talk assertion observes the
            // coordinator's pending request.
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
            }
            throw CancellationError()
        }
        guard created else { return [current, requested] }
        let createdSession = SessionSummary(
            id: createdID,
            storedSessionId: createdID,
            alternateIds: [],
            title: "New conversation",
            model: "Hermes",
            updatedLabel: "",
            profile: WidgetLaunchUITestFixture.profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
        return [current, requested, createdSession]
    }
}

private enum WidgetUITestFixtureError: Error {
    case unexpectedResume
}
#endif
