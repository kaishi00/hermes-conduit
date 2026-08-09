import Foundation

struct ChatMessageScrollTarget: Identifiable, Equatable {
    let message: ChatMessage
    let semanticID: String

    /// SwiftUI keeps the existing source-row identity for rendering and
    /// controls. Only scroll targeting uses the source-independent ID.
    var id: String { message.id }
}

enum ChatMessageScrollTargets {
    static func make(for messages: [ChatMessage]) -> [ChatMessageScrollTarget] {
        var occurrences: [String: Int] = [:]
        return messages.map { message in
            let fingerprint = fingerprint(for: message)
            let occurrence = occurrences[fingerprint, default: 0]
            occurrences[fingerprint] = occurrence + 1
            return ChatMessageScrollTarget(
                message: message,
                semanticID: "chat-message-\(fingerprint)-\(occurrence)"
            )
        }
    }

    private static func fingerprint(for message: ChatMessage) -> String {
        var fingerprint = DeterministicChatFingerprint()
        fingerprint.append("chat-message-v1")
        fingerprint.append(message.role.rawValue)
        fingerprint.append(message.content)
        fingerprint.append(message.code)

        fingerprint.append(message.tool?.name)
        fingerprint.append(message.tool?.input)

        fingerprint.append(message.clarify?.question)
        fingerprint.append(message.clarify?.choices.count)
        message.clarify?.choices.forEach { choice in
            fingerprint.append(choice.label)
            fingerprint.append(choice.value)
        }

        fingerprint.append(message.approval?.command)
        fingerprint.append(message.approval?.description)
        fingerprint.append(message.approval?.choices?.count)
        message.approval?.choices?.forEach { fingerprint.append($0) }
        fingerprint.append(message.approval?.allowPermanent)
        fingerprint.append(message.approval?.smartDenied)

        fingerprint.append(message.review?.summary)
        fingerprint.append(message.review?.details?.count)
        message.review?.details?.forEach { fingerprint.append($0) }

        fingerprint.append(message.attachments?.count)
        message.attachments?.forEach { attachment in
            // Picker/cache IDs and local/gateway URIs change across transcript
            // projections. These presentation fields remain source-stable.
            fingerprint.append(attachment.kind.rawValue)
            fingerprint.append(attachment.name)
            fingerprint.append(attachment.mimeType)
        }

        return fingerprint.value
    }
}

struct ChatScrollSessionIdentity: Equatable {
    let canonicalSessionID: String?
    let equivalentSessionIDs: Set<String>
    let isReconciling: Bool
    let settledRevision: UInt64

    static let none = ChatScrollSessionIdentity(
        canonicalSessionID: nil,
        equivalentSessionIDs: [],
        isReconciling: false,
        settledRevision: 0
    )

    init(
        canonicalSessionID: String?,
        equivalentSessionIDs: Set<String>,
        isReconciling: Bool,
        settledRevision: UInt64
    ) {
        let canonical = Self.normalized(canonicalSessionID)
        var equivalents = Set(equivalentSessionIDs.compactMap(Self.normalized))
        if let canonical { equivalents.insert(canonical) }
        self.canonicalSessionID = canonical
        self.equivalentSessionIDs = equivalents
        self.isReconciling = isReconciling
        self.settledRevision = settledRevision
    }

    func contains(_ sessionID: String?) -> Bool {
        guard let sessionID = Self.normalized(sessionID) else { return false }
        return equivalentSessionIDs.contains(sessionID)
    }

    func areEquivalent(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = Self.normalized(lhs),
              let rhs = Self.normalized(rhs) else { return false }
        if lhs == rhs { return true }
        return equivalentSessionIDs.contains(lhs) && equivalentSessionIDs.contains(rhs)
    }

    private static func normalized(_ sessionID: String?) -> String? {
        guard let value = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

struct ChatScrollRestorationGate: Equatable {
    let observedSettledRevision: UInt64
    let requiresSettledRevisionAdvance: Bool

    init(
        observing identity: ChatScrollSessionIdentity,
        reconciliationExpected: Bool = false
    ) {
        observedSettledRevision = identity.settledRevision
        requiresSettledRevisionAdvance = identity.isReconciling || reconciliationExpected
    }

    func allowsNonLatestRestoration(using identity: ChatScrollSessionIdentity) -> Bool {
        guard !identity.isReconciling else { return false }
        return !requiresSettledRevisionAdvance
            || identity.settledRevision > observedSettledRevision
    }
}

struct ChatScrollSnapshot: Equatable {
    let anchorMessageID: String?
    let followsLatest: Bool

    static let latest = ChatScrollSnapshot(anchorMessageID: nil, followsLatest: true)
}

private struct DeterministicChatFingerprint {
    private var first: UInt64 = 14_695_981_039_346_656_037
    private var second: UInt64 = 7_809_847_782_465_536_322

    var value: String {
        paddedHex(first) + paddedHex(second)
    }

    mutating func append(_ value: String?) {
        guard let value else {
            append(byte: 0)
            return
        }
        append(byte: 1)
        append(length: value.utf8.count)
        value.utf8.forEach { append(byte: $0) }
    }

    mutating func append(_ value: Int?) {
        append(value.map(String.init))
    }

    mutating func append(_ value: Bool?) {
        append(value.map { $0 ? "true" : "false" })
    }

    private mutating func append(length: Int) {
        var length = UInt64(length)
        for _ in 0..<MemoryLayout<UInt64>.size {
            append(byte: UInt8(truncatingIfNeeded: length))
            length >>= 8
        }
    }

    private mutating func append(byte: UInt8) {
        first ^= UInt64(byte)
        first &*= 1_099_511_628_211
        second ^= UInt64(byte)
        second &*= 14_029_467_366_897_019_727
    }

    private func paddedHex(_ value: UInt64) -> String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

struct ChatScrollStateStore {
    private var snapshots: [String: ChatScrollSnapshot] = [:]

    mutating func save(_ snapshot: ChatScrollSnapshot, for sessionID: String) {
        let key = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        snapshots[key] = snapshot
    }

    func snapshot(for sessionID: String) -> ChatScrollSnapshot? {
        snapshots[sessionID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func restoration(
        for sessionID: String,
        availableMessageIDs: Set<String>
    ) -> ChatScrollSnapshot? {
        guard let snapshot = snapshot(for: sessionID) else { return nil }
        guard !snapshot.followsLatest else { return .latest }
        guard let anchor = snapshot.anchorMessageID,
              availableMessageIDs.contains(anchor) else {
            return .latest
        }
        return snapshot
    }
}
