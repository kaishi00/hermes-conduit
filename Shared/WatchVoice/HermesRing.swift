//
//  HermesRing.swift
//  Conduit and the Conduit Watch app
//
//  A call from Hermes that rings on the iPhone and the Apple Watch alike
//  (relay 0.10+, designs/hermes-calls-watch.md). iOS doesn't pass a calling
//  app's CallKit call to the Watch, so the relay sends the call to both,
//  each push with the same ring. The device that answers or declines
//  settles the ring at the relay, which tells the other to stop ringing:
//  the iPhone's ringing call cuts its link to the Watch, so the two can't
//  tell each other.
//

import Foundation

/// The ring a call push carries when the call rings on the Watch too.
struct HermesRing: Equatable {
    let id: String
    /// Settles the ring: only the call's two pushes hold it.
    let token: String
    /// Where to settle it, on the relay that sent the call.
    let url: URL

    /// The ring in a call push, outside any sealed envelope; nil when the
    /// call rings on this device alone.
    static func from(_ userInfo: [AnyHashable: Any]) -> HermesRing? {
        guard let ring = HermesRingPush.ring(in: userInfo),
              let id = ring["id"] as? String, HermesRingPush.isID(id),
              let token = ring["token"] as? String, HermesRingPush.isToken(token),
              let text = ring["url"] as? String, let url = URL(string: text),
              url.scheme == "https", url.path.hasSuffix("/v1/rings/\(id)/settled") else { return nil }
        return HermesRing(id: id, token: token, url: url)
    }
}

/// How a ring was settled.
enum HermesRingOutcome: String, Equatable {
    case answered
    case declined
}

/// The device that settled a ring.
enum HermesRingDevice: String, Equatable {
    case phone
    case watch
}

/// The relay's "stop ringing": the other device answered or declined.
struct HermesRingSettled: Equatable {
    let id: String
    let outcome: HermesRingOutcome
    let by: HermesRingDevice

    /// Nil for any other push, a call included.
    static func from(_ userInfo: [AnyHashable: Any]) -> HermesRingSettled? {
        guard let ring = HermesRingPush.ring(in: userInfo),
              let id = ring["id"] as? String, HermesRingPush.isID(id),
              let outcome = (ring["settled"] as? String).flatMap(HermesRingOutcome.init(rawValue:)),
              let by = (ring["by"] as? String).flatMap(HermesRingDevice.init(rawValue:)) else { return nil }
        return HermesRingSettled(id: id, outcome: outcome, by: by)
    }
}

enum HermesRingPush {
    /// The `ring` beside `sent_at`: in `conduit`, or in `body.conduit`.
    static func ring(in userInfo: [AnyHashable: Any]) -> [String: Any]? {
        let direct = (userInfo["conduit"] as? [String: Any])?["ring"] as? [String: Any]
        let nested = ((userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any])?["ring"] as? [String: Any]
        return direct ?? nested
    }

    /// The relay's `sent_at` (seconds since 1970), outside any sealed
    /// envelope.
    static func sentAt(_ userInfo: [AnyHashable: Any]) -> Date? {
        let direct = userInfo["conduit"] as? [String: Any]
        let nested = (userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any]
        guard let seconds = (direct?["sent_at"] as? NSNumber) ?? (nested?["sent_at"] as? NSNumber) else { return nil }
        return Date(timeIntervalSince1970: seconds.doubleValue)
    }

    /// The call's title when the push carries it in the clear; nil from a
    /// sealed push, which only the iPhone can open.
    static func title(_ userInfo: [AnyHashable: Any]) -> String? {
        let call = ((userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any])?["call"] as? [String: Any]
        let words = (call?["title"] as? String)?
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ") ?? ""
        return words.isEmpty ? nil : String(words.prefix(60))
    }

    static func isID(_ value: String) -> Bool { value.count == 22 && value.allSatisfy(isBase64URL) }
    static func isToken(_ value: String) -> Bool { value.count == 43 && value.allSatisfy(isBase64URL) }

    private static func isBase64URL(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
    }
}

/// What settling a ring came to.
enum HermesRingSettleResult: Equatable {
    /// This device settled it; the other stops ringing.
    case settled
    /// The other device got there first.
    case alreadySettled(HermesRingOutcome, by: HermesRingDevice)
    /// The relay forgot the ring (it expired, or the relay restarted) or
    /// couldn't be reached: the other device rings out.
    case failed
}

enum HermesRingSettler {
    static func request(_ ring: HermesRing, by device: HermesRingDevice, outcome: HermesRingOutcome) -> URLRequest {
        var request = URLRequest(url: ring.url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": ring.token,
            "by": device.rawValue,
            "outcome": outcome.rawValue,
        ])
        return request
    }

    static func result(status: Int, data: Data) -> HermesRingSettleResult {
        if (200..<300).contains(status) { return .settled }
        guard status == 409,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settled = body["settled"] as? [String: Any],
              let outcome = (settled["outcome"] as? String).flatMap(HermesRingOutcome.init(rawValue:)),
              let by = (settled["by"] as? String).flatMap(HermesRingDevice.init(rawValue:)) else { return .failed }
        return .alreadySettled(outcome, by: by)
    }

    static func settle(_ ring: HermesRing, by device: HermesRingDevice, outcome: HermesRingOutcome, session: URLSession = .shared) async -> HermesRingSettleResult {
        do {
            let (data, response) = try await session.data(for: request(ring, by: device, outcome: outcome))
            return result(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch {
            return .failed
        }
    }
}
