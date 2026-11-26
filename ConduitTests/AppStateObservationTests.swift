import Combine
import Observation
import XCTest
@testable import Conduit

/// AppState's own properties are observed one by one (issue 828): a view
/// redraws for what it reads, not for every AppState change. What AppState
/// still republishes (the stores on screen) and its explicit sends keep
/// reaching `objectWillChange`, and the few properties read as streams keep
/// what `@Published`'s publisher gave.
@MainActor
final class AppStateObservationTests: XCTestCase {

    private func makeAppState() -> AppState {
        let suiteName = "AppStateObservationTests." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return AppState(defaults: defaults, loadSavedConnection: false)
    }

    private func session(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id, alternateIds: [], title: id, model: "Hermes", updatedLabel: "now",
            profile: "default", source: .chat, isActive: false, isArchived: false, lineageRootId: nil
        )
    }

    private final class Flag {
        var isSet = false
    }

    /// Whether `change` changes what `read` reads.
    private func changes(_ read: () -> Void, by change: () -> Void) -> Bool {
        let changed = Flag()
        withObservationTracking { read() } onChange: { changed.isSet = true }
        change()
        return changed.isSet
    }

    func testAPropertyChangeReachesOnlyWhatReadsIt() {
        let appState = makeAppState()
        var published = 0
        let watch = appState.objectWillChange.sink { published += 1 }
        defer { watch.cancel() }

        XCTAssertFalse(
            changes({ _ = appState.errorMessage }, by: { appState.showSidebar.toggle() }),
            "another property changing leaves what reads errorMessage alone"
        )
        published = 0
        XCTAssertTrue(changes({ _ = appState.errorMessage }, by: { appState.errorMessage = "Offline" }))
        XCTAssertEqual(published, 0, "AppState's own properties no longer publish")
    }

    func testTheStoresOnScreenStillPublishAsAppState() {
        let appState = makeAppState()
        var published = 0
        let watch = appState.objectWillChange.sink { published += 1 }
        defer { watch.cancel() }

        appState.sessions = [session("a")]
        XCTAssertGreaterThan(published, 0, "the runtime on screen's changes publish as AppState's until it's observed on its own")
    }

    func testValuesStreamsGiveWhatPublishedGave() {
        let appState = makeAppState()
        appState.errorMessage = "first"
        var received: [String?] = []
        var storedWhenSent: [String?] = []
        let watch = appState.errorMessageValues.sink { value in
            received.append(value)
            storedWhenSent.append(appState.errorMessage)
        }
        defer { watch.cancel() }

        appState.errorMessage = "second"
        appState.errorMessage = nil

        XCTAssertEqual(received, ["first", "second", nil], "the value on subscribing, then each one set")
        XCTAssertEqual(storedWhenSent, ["first", "first", "second"], "each sent before it lands, as @Published sent it")
    }

    func testCachesAreNotObserved() {
        let appState = makeAppState()
        appState.sessions = [session("a")]
        XCTAssertFalse(
            changes({ _ = appState.listedSessionsCache }, by: { _ = appState.listedSessions }),
            "a body's read filling a cache redraws nothing else that read it"
        )
    }

    func testAWakeSettingReachesWhatReadsIt() {
        let appState = makeAppState()
        let enabled = appState.wakeListensOnCarPlay
        XCTAssertTrue(
            changes({ _ = appState.wakeListensOnCarPlay }, by: { appState.setWakeListensOnCarPlay(!enabled) }),
            "the store isn't observed, so its setters bump what reading it reads"
        )
    }

    func testAHeldListKeepsHoldingCatalogChanges() {
        let appState = makeAppState()
        appState.sessions = [session("a")]
        _ = appState.listedSessions
        XCTAssertFalse(
            changes({ _ = appState.listedSessions }, by: { appState.sessions = [session("a"), session("b")] }),
            "catalog changes reach the list through AppState's publish, which a held list holds"
        )
    }
}
