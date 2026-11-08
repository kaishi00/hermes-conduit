import Foundation

// Date's <= and >= in this target, so no build calls Foundation's.
//
// The iOS and watchOS 27.2 SDKs mark Foundation's `Date.<=` and `Date.>=`
// `@backDeployed(before: 27.2)`: a build made with them calls Foundation's
// own copy on 27.2 and later and a copy bundled in the app before. Foundation
// in the early 27.2 betas (24B5084k, 24B5089g) doesn't have them yet, so a
// build from the 27.2 SDK jumped to a null pointer there, at launch, the first
// time it compared two dates (TestFlight builds 250 to 252: "Keeps crashing",
// 2026-11-05). These are found first in the target that declares them, so a
// comparison of two Dates calls them and the build imports neither symbol.
//
// Every shipped target compiles this file (project.yml). It's disfavored so a
// target that sees another's internals (`@testable import Conduit`) still
// compiles: there Foundation's wins, which is fine for a test bundle. CI checks
// that no shipped binary imports the two symbols (scripts/check-weak-imports.py).
extension Date {
    @_disfavoredOverload
    static func <= (lhs: Date, rhs: Date) -> Bool {
        !(rhs < lhs)
    }

    @_disfavoredOverload
    static func >= (lhs: Date, rhs: Date) -> Bool {
        !(lhs < rhs)
    }
}
