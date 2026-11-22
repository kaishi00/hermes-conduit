import XCTest
@testable import Conduit

/// ConduitTests' principal class (`INFOPLIST_KEY_NSPrincipalClass` in
/// project.yml): XCTest makes one when it loads the bundle, before the first
/// test, and it watches every test from then on.
///
/// The App Language lives in `UserDefaults.standard`, which outlives a test,
/// its class and the xcodebuild invocation: the Nightly's unit batches run
/// one after another on the same simulator. A test that pins a language and
/// never restores it (a crash or timeout before its `defer`, or a test with
/// no restore at all) left every later test reading another language: on
/// 2026-11-22 a whole batch read Spanish ("Paso 1 de 2", "Listo"). So each
/// run and each test starts on System Default, and the log names whatever
/// left a language behind.
@objc(ConduitTestBundleObserver)
final class ConduitTestBundleObserver: NSObject, XCTestObservation {
    /// The observer XCTest made, for the test that checks it is registered.
    private(set) static weak var current: ConduitTestBundleObserver?

    /// The test XCTest last told this observer about, so a test can check
    /// the callbacks really arrive and not just that the observer exists.
    private(set) var lastStartedTest: String?

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
        Self.current = self
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        if let left = UserDefaults.standard.string(forKey: AppLanguageStore.defaultsKey) {
            print("ConduitTests: an earlier run left the App Language at \"\(left)\"; starting on System Default")
        }
        // The host app launched before this bundle loaded, so its store may
        // have read a leftover selection; the root's locale follows it.
        Self.resetAppLanguage()
        print("ConduitTests: device languages \(Locale.preferredLanguages.prefix(3)), "
            + "System Default resolves to \(Bundle.main.preferredLocalizations.first ?? "none")")
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        lastStartedTest = testCase.name
        Self.resetAppLanguage()
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        // Every test starts with the key cleared, so a value here is this
        // test's own: a restore-style defer puts back the nil it found.
        if let left = UserDefaults.standard.string(forKey: AppLanguageStore.defaultsKey) {
            print("ConduitTests: \(testCase.name) left the App Language at \"\(left)\"; resetting it")
        }
        Self.resetAppLanguage()
    }

    /// Clears the persisted selection and the shared store, which caches
    /// it: a test (or the Settings picker it drives) may pin through the
    /// store, and views and the root's locale follow the store.
    private static func resetAppLanguage() {
        let reset = {
            MainActor.assumeIsolated { AppLanguageStore.shared.select(.system) }
            // select writes "system"; System Default is the missing key.
            UserDefaults.standard.removeObject(forKey: AppLanguageStore.defaultsKey)
        }
        if Thread.isMainThread { reset() } else { DispatchQueue.main.sync(execute: reset) }
    }
}

extension AppLanguageTests {
    /// A pinned language never reaches the next test: the bundle's observer
    /// is registered and clears the selection before each test starts.
    func testEachTestStartsOnSystemDefaultWhateverTheLastOneLeft() throws {
        let observer = try XCTUnwrap(ConduitTestBundleObserver.current,
                                     "ConduitTests' NSPrincipalClass must be ConduitTestBundleObserver")
        XCTAssertEqual(observer.lastStartedTest, name, "XCTest must deliver testCaseWillStart to the observer")
        let pinned = try XCTUnwrap(AppLanguage.selectable.first { $0 != .system && $0 != .source })
        UserDefaults.standard.set(pinned.rawValue, forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(AppLanguage.current, pinned)

        observer.testCaseWillStart(self)

        XCTAssertNil(UserDefaults.standard.string(forKey: AppLanguageStore.defaultsKey))
        XCTAssertEqual(AppLanguage.current, .system)
    }

    /// A language pinned through the shared store (as the Settings picker
    /// does), or left before the bundle loaded, is reset in both places.
    func testABundleStartClearsTheStoreAndTheKey() throws {
        let observer = try XCTUnwrap(ConduitTestBundleObserver.current)
        let pinned = try XCTUnwrap(AppLanguage.selectable.first { $0 != .system && $0 != .source })
        AppLanguageStore.shared.select(pinned)
        XCTAssertEqual(AppLanguage.current, pinned)

        observer.testBundleWillStart(Bundle.main)

        XCTAssertNil(UserDefaults.standard.string(forKey: AppLanguageStore.defaultsKey))
        XCTAssertEqual(AppLanguageStore.shared.selection, .system)

        AppLanguageStore.shared.select(pinned)
        observer.testCaseWillStart(self)
        XCTAssertNil(UserDefaults.standard.string(forKey: AppLanguageStore.defaultsKey))
        XCTAssertEqual(AppLanguageStore.shared.selection, .system)
    }
}
