import XCTest

extension XCTestCase {
    /// A UserDefaults suite of this test's own, named `<name>.<UUID>` and
    /// removed when the test ends. Replaces the suite / guard / teardown
    /// block test files used to write out by hand.
    func makeScratchDefaults(_ name: String) -> UserDefaults {
        let suite = "\(name).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
