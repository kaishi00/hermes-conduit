import Foundation

/// Keepalive pings on a Watch bridge socket, as `WatchBridgeCallModel`
/// counts them (and the iPhone's dashboard voice sockets, through
/// `VoiceSocketKeepalive`). A socket that died without closing (after a suspension)
/// never fails its receive, so only its pings tell: a ping still
/// unanswered when the next is due, or one that failed, is a miss.
struct WatchPingWatchdog {
    /// One miss can be a late pong after a suspension; two in a row is a
    /// dead socket.
    static let missLimit = 2

    private(set) var misses = 0
    private var outstanding = false

    /// A ping is due. True when the socket is dead; otherwise send one.
    mutating func pingDue() -> Bool {
        if outstanding {
            misses += 1
            if misses >= Self.missLimit { return true }
        }
        outstanding = true
        return false
    }

    /// A ping's answer. True when the socket is dead.
    mutating func answered(ok: Bool) -> Bool {
        outstanding = false
        guard !ok else {
            misses = 0
            return false
        }
        misses += 1
        return misses >= Self.missLimit
    }
}
