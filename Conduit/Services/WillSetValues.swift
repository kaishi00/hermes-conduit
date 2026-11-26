import Combine

/// What `@Published`'s publisher gave, for a property of an `@Observable`
/// class, which has none (issue 828): the value on subscribing, then each
/// new value as it's set, before it lands. The property's `willSet` sends
/// it, so what reads the stream sees every value, in order, as before.
final class WillSetValues<Value> {
    private let sends = PassthroughSubject<Value, Never>()

    /// From the property's `willSet`.
    func send(_ newValue: Value) {
        sends.send(newValue)
    }

    /// The stream. `current` is read as each subscriber subscribes.
    func publisher(current: @escaping () -> Value) -> AnyPublisher<Value, Never> {
        let sends = sends
        return Deferred { sends.prepend(current()) }.eraseToAnyPublisher()
    }
}
