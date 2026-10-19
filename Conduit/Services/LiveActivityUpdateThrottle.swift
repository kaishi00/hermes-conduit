import Foundation

/// How often a running turn's Live Activity is updated from its stream.
/// Each update wakes the widget extension to redraw the Lock Screen and
/// the Dynamic Island, and a turn that moves between tools, thinking and
/// writing can change its state several times a second. So an activity is
/// updated at most once every `interval`: a state that comes sooner waits,
/// and only the newest waiting state goes out once the interval is up.
/// A change the user acts on, a turn starting or stopping to wait for an
/// approval or an answer, goes out at once. (A finished turn ends its
/// activity instead, which is never held.) A held state that comes due
/// long after its time (Conduit was suspended meanwhile) is dropped: the
/// relay may have pushed a newer one. Pure, with the time passed in, so
/// it is tested without ActivityKit or waiting.
struct LiveActivityUpdateThrottle {
    typealias State = HermesTurnAttributes.ContentState

    static let interval: TimeInterval = 2
    /// A held state this long past its time is dropped.
    static let overdueAfter: TimeInterval = 2 * interval

    /// What to do with a new state.
    enum Decision: Equatable {
        /// Update the activity with it now.
        case now
        /// Hold it, and call `due(for:at:)` at this time: the newest
        /// state held by then goes out.
        case at(Date)
    }

    private var sent: [String: (state: State, at: Date)] = [:]
    private var held: [String: State] = [:]

    /// The activity was started (or taken over) showing `state`.
    mutating func started(_ id: String, showing state: State, at now: Date) {
        sent[id] = (state, now)
        held[id] = nil
    }

    /// A new state for activity `id`. On `.now` it counts as sent.
    mutating func offer(_ state: State, for id: String, at now: Date) -> Decision {
        guard let last = sent[id] else {
            sent[id] = (state, now)
            return .now
        }
        let next = last.at.addingTimeInterval(Self.interval)
        if now >= next || Self.isUrgent(from: last.state, to: state) {
            sent[id] = (state, now)
            held[id] = nil
            return .now
        }
        held[id] = state
        return .at(next)
    }

    /// The held state to send now, if any; it counts as sent. Nil, and
    /// dropped, once it is `overdueAfter` past its time.
    mutating func due(for id: String, at now: Date) -> State? {
        guard let state = held.removeValue(forKey: id) else { return nil }
        if let last = sent[id], now.timeIntervalSince(last.at) > Self.interval + Self.overdueAfter {
            return nil
        }
        sent[id] = (state, now)
        return state
    }

    /// Whether a state is held for activity `id`.
    func holds(_ id: String) -> Bool {
        held[id] != nil
    }

    /// The activity ended: nothing held for it goes out.
    mutating func forget(_ id: String) {
        sent[id] = nil
        held[id] = nil
    }

    /// Whether the Lock Screen would be wrong about the user's part: the
    /// turn now waits on them, or no longer does.
    static func isUrgent(from shown: State, to state: State) -> Bool {
        shown.turnPhase.waitsOnUser != state.turnPhase.waitsOnUser
            || state.turnPhase.isFinished
    }
}
