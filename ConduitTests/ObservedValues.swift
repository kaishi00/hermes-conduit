import Foundation
import Observation

/// What a Combine sink on a @Published property recorded, for an
/// @Observable model: the value `read` returns after each change to the
/// state it reads.
///
/// withObservationTracking calls back before a write lands and only once,
/// so each callback re-registers and records the value the previous write
/// left; finish() records the last one.
@MainActor
final class ObservedValues<Value> {
    private var values: [Value] = []
    private var changed = false
    private var finished = false
    private let read: @MainActor () -> Value

    init(_ read: @escaping @MainActor () -> Value) {
        self.read = read
        observe()
    }

    /// The value after each change seen so far; stops recording.
    func finish() -> [Value] {
        if !finished {
            finished = true
            if changed { values.append(read()) }
        }
        return values
    }

    private func observe() {
        withObservationTracking {
            _ = read()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                if self.changed { self.values.append(self.read()) }
                self.changed = true
                self.observe()
            }
        }
    }
}
