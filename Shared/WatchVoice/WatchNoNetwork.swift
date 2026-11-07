import Foundation

/// A Watch call whose sockets watchOS gives no network (#1346). Its live
/// socket is "low-level networking", which watchOS routes apart from the
/// Watch's ordinary internet: a Watch that browses fine through the
/// iPhone can still fail every socket with -1009 before it opens. A call
/// that never opened one ends after one quick retry and says so, instead
/// of rejoining and saying it lost Hermes. Once a socket has opened, a
/// drop is the call's to rejoin as before.
struct WatchNoNetwork {
    /// The first refusal can be the path coming up just after the audio
    /// session activated; the second in a row is the Watch's network.
    static let refusalLimit = 2

    private(set) var opened = false
    private(set) var refusals = 0

    /// A socket opened: the call has a network.
    mutating func socketOpened() {
        opened = true
        refusals = 0
    }

    /// A socket closed or failed, with its event's fields. True when the
    /// call should end, saying the Watch had no network.
    mutating func socketEnded(_ fields: [String: Any]) -> Bool {
        guard !opened, Self.isOffline(fields) else { return false }
        refusals += 1
        return refusals >= Self.refusalLimit
    }

    /// Whether a socket's error fields say the Watch had no network.
    static func isOffline(_ fields: [String: Any]) -> Bool {
        guard fields["domain"] as? String == NSURLErrorDomain, let code = fields["code"] as? Int else { return false }
        return offlineCodes.contains(code)
    }

    private static let offlineCodes: Set<Int> = [
        URLError.notConnectedToInternet.rawValue,
        URLError.dataNotAllowed.rawValue,
        URLError.internationalRoamingOff.rawValue,
    ]
}
