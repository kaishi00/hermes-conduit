import Foundation

struct ChatScrollAnchorMetadata: Codable, Equatable {
    let fingerprint: String
    let duplicateCount: Int
}

struct ChatMessageScrollTarget: Identifiable, Equatable {
    let message: ChatMessage
    let semanticID: String
    let restorationMetadata: ChatScrollAnchorMetadata

    /// SwiftUI keeps the existing source-row identity for rendering and
    /// controls. Only scroll targeting uses the source-independent ID.
    var id: String { message.id }
}

enum ChatMessageScrollTargetCacheUpdate: Equatable {
    case unchanged
    case renderingChanged
    case semanticsChanged
}

enum ChatMessageScrollUpdatePolicy {
    static func shouldReassertLatest(
        after update: ChatMessageScrollTargetCacheUpdate,
        followsLatest: Bool,
        hasPendingRestoration: Bool,
        hasNotificationHandoff: Bool
    ) -> Bool {
        update != .unchanged
            && followsLatest
            && !hasPendingRestoration
            && !hasNotificationHandoff
    }
}

struct ChatMessageScrollTargetCache: Equatable {
    private(set) var targets: [ChatMessageScrollTarget] = []
    private(set) var renderingRevision: UInt64 = 0
    private var fingerprints: [String] = []

    @discardableResult
    mutating func update(for messages: [ChatMessage]) -> ChatMessageScrollTargetCacheUpdate {
        let updatedFingerprints = ChatMessageScrollTargets.fingerprints(for: messages)
        if updatedFingerprints == fingerprints, targets.count == messages.count {
            guard targets.map(\.message) != messages else { return .unchanged }
            targets = zip(messages, targets).map { message, target in
                ChatMessageScrollTarget(
                    message: message,
                    semanticID: target.semanticID,
                    restorationMetadata: target.restorationMetadata
                )
            }
            renderingRevision &+= 1
            return .renderingChanged
        }

        fingerprints = updatedFingerprints
        targets = ChatMessageScrollTargets.make(
            for: messages,
            fingerprints: updatedFingerprints
        )
        renderingRevision &+= 1
        return .semanticsChanged
    }
}

struct ChatRenderedScrollScope: Hashable {
    let sessionKey: ChatScrollSessionKey
    let cacheRevision: UInt64
    let restorationGeneration: UInt64?
    let transcriptRevision: UInt64
    let viewportTransitionGeneration: UInt64
}

struct ChatRenderedScrollContent: Equatable {
    let scope: ChatRenderedScrollScope
}

/// A preference payload emitted only by targets SwiftUI has instantiated.
/// The cache deliberately cannot populate this value: lazy offscreen rows
/// become ready only when their own geometry participates in the layout pass.
struct ChatRenderedScrollTargets: Equatable {
    private(set) var rowsByScope: [ChatRenderedScrollScope: Set<String>] = [:]
    private(set) var bottomsByScope: [ChatRenderedScrollScope: Set<String>] = [:]

    static func row(
        semanticID: String,
        scope: ChatRenderedScrollScope
    ) -> ChatRenderedScrollTargets {
        ChatRenderedScrollTargets(rowsByScope: [scope: [semanticID]])
    }

    static func bottom(
        anchorID: String,
        scope: ChatRenderedScrollScope
    ) -> ChatRenderedScrollTargets {
        ChatRenderedScrollTargets(bottomsByScope: [scope: [anchorID]])
    }

    static func reduce(
        value: inout ChatRenderedScrollTargets,
        nextValue: ChatRenderedScrollTargets
    ) {
        for (scope, rows) in nextValue.rowsByScope {
            value.rowsByScope[scope, default: []].formUnion(rows)
        }
        for (scope, bottoms) in nextValue.bottomsByScope {
            value.bottomsByScope[scope, default: []].formUnion(bottoms)
        }
    }

    func contains(row semanticID: String, in scope: ChatRenderedScrollScope) -> Bool {
        rowsByScope[scope]?.contains(semanticID) == true
    }

    func contains(bottom anchorID: String, in scope: ChatRenderedScrollScope) -> Bool {
        bottomsByScope[scope]?.contains(anchorID) == true
    }
}

enum ChatResumeRenderRestorationAction: Equatable {
    case wait
    case scroll(ChatResumeViewportDestination)
    case complete
    case abandon
    case cancelled
}

/// A deterministic policy for the view-owned part of restoration. SwiftUI
/// supplies actual layout observations; the policy never treats a derived
/// message cache as proof that ScrollViewReader has installed its targets.
struct ChatResumeRenderRestorationState {
    let generation: UInt64
    let sessionKey: ChatScrollSessionKey
    private(set) var destination: ChatResumeViewportDestination
    private let maximumChecks: Int
    private let retryInterval: Int
    private var checkCount = 0
    private var lastScrollCheck: Int?
    private var isCancelled = false

    init(
        generation: UInt64,
        sessionKey: ChatScrollSessionKey,
        destination: ChatResumeViewportDestination,
        maximumChecks: Int = 80,
        retryInterval: Int = 4
    ) {
        self.generation = generation
        self.sessionKey = sessionKey
        self.destination = destination
        self.maximumChecks = max(maximumChecks, 1)
        self.retryInterval = max(retryInterval, 1)
    }

    mutating func updateDestination(_ destination: ChatResumeViewportDestination) {
        guard self.destination != destination else { return }
        self.destination = destination
        lastScrollCheck = nil
    }

    mutating func cancel() {
        isCancelled = true
    }

    mutating func nextAction(
        renderedContent: ChatRenderedScrollContent?,
        installedTargets: ChatRenderedScrollTargets,
        cacheRevision: UInt64,
        transcriptRevision: UInt64,
        topVisibleID: String?,
        isNearBottom: Bool
    ) -> ChatResumeRenderRestorationAction {
        guard !isCancelled else { return .cancelled }
        checkCount += 1

        guard let renderedContent,
              renderedContent.scope.restorationGeneration == generation,
              renderedContent.scope.sessionKey == sessionKey,
              renderedContent.scope.cacheRevision == cacheRevision,
              renderedContent.scope.transcriptRevision == transcriptRevision else {
            return checkCount > maximumChecks ? .abandon : .wait
        }

        if lastScrollCheck != nil,
           targetIsInstalled(in: installedTargets, scope: renderedContent.scope),
           destinationIsConfirmed(
            topVisibleID: topVisibleID,
            isNearBottom: isNearBottom
        ) {
            return .complete
        }

        guard checkCount <= maximumChecks else { return .abandon }

        if lastScrollCheck.map({ checkCount - $0 >= retryInterval }) ?? true {
            lastScrollCheck = checkCount
            return .scroll(destination)
        }

        return .wait
    }

    private func targetIsInstalled(
        in installedTargets: ChatRenderedScrollTargets,
        scope: ChatRenderedScrollScope
    ) -> Bool {
        switch destination {
        case .latest:
            return installedTargets.contains(
                bottom: bottomAnchorID(for: scope.sessionKey),
                in: scope
            )
        case .anchor(let anchor):
            return installedTargets.contains(row: anchor, in: scope)
        }
    }

    private func bottomAnchorID(for sessionKey: ChatScrollSessionKey) -> String {
        "chat-latest-\(sessionKey.profile)-\(sessionKey.sessionID)"
    }

    private func destinationIsConfirmed(
        topVisibleID: String?,
        isNearBottom: Bool
    ) -> Bool {
        switch destination {
        case .latest:
            return isNearBottom
        case .anchor(let anchor):
            return topVisibleID == anchor
        }
    }
}

enum ChatMessageScrollTargets {
    static func make(for messages: [ChatMessage]) -> [ChatMessageScrollTarget] {
        make(for: messages, fingerprints: fingerprints(for: messages))
    }

    fileprivate static func fingerprints(for messages: [ChatMessage]) -> [String] {
        messages.map(fingerprint)
    }

    fileprivate static func make(
        for messages: [ChatMessage],
        fingerprints: [String]
    ) -> [ChatMessageScrollTarget] {
        let duplicateCounts = fingerprints.reduce(into: [String: Int]()) { counts, fingerprint in
            counts[fingerprint, default: 0] += 1
        }
        var occurrences: [String: Int] = [:]
        return zip(messages, fingerprints).map { message, fingerprint in
            let occurrence = occurrences[fingerprint, default: 0]
            occurrences[fingerprint] = occurrence + 1
            return ChatMessageScrollTarget(
                message: message,
                semanticID: "chat-message-\(fingerprint)-\(occurrence)",
                restorationMetadata: ChatScrollAnchorMetadata(
                    fingerprint: fingerprint,
                    duplicateCount: duplicateCounts[fingerprint, default: 0]
                )
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

private enum ChatScrollIdentityNormalization {
    static func profile(_ profile: String?) -> String? {
        guard let value = profile?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.lowercased()
    }

    static func sessionID(_ sessionID: String?) -> String? {
        guard let value = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

struct ChatScrollSessionKey: Codable, Hashable {
    let profile: String
    let sessionID: String

    init(profile: String, sessionID: String) {
        self.profile = ChatScrollIdentityNormalization.profile(profile) ?? ""
        self.sessionID = ChatScrollIdentityNormalization.sessionID(sessionID) ?? ""
    }

    var isValid: Bool {
        !profile.isEmpty && !sessionID.isEmpty
    }
}

enum ChatSessionPersistenceIdentity {
    static func canonicalID(
        for sessionID: String?,
        identity: ChatScrollSessionIdentity,
        catalog: [SessionSummary]
    ) -> String? {
        guard let sessionID,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if let catalogSession = catalog.first(where: {
            $0.id == sessionID || $0.alternateIds.contains(sessionID)
        }) {
            return catalogSession.id
        }

        if identity.contains(sessionID) {
            return identity.canonicalSessionID ?? sessionID
        }
        return sessionID
    }
}

struct ChatScrollSessionCatalogIdentity: Equatable {
    let profile: String
    let canonicalSessionID: String
    let alternateSessionIDs: Set<String>

    init(
        profile: String,
        canonicalSessionID: String,
        alternateSessionIDs: Set<String>
    ) {
        self.profile = ChatScrollIdentityNormalization.profile(profile) ?? ""
        self.canonicalSessionID = ChatScrollIdentityNormalization.sessionID(canonicalSessionID) ?? ""
        self.alternateSessionIDs = Set(
            alternateSessionIDs.compactMap(ChatScrollIdentityNormalization.sessionID)
        )
    }

    fileprivate var identifiers: Set<String> {
        guard !canonicalSessionID.isEmpty else { return [] }
        var result = alternateSessionIDs
        result.insert(canonicalSessionID)
        return result
    }

    fileprivate var isValid: Bool {
        !canonicalSessionID.isEmpty
    }
}

struct ChatScrollSessionIdentity: Equatable {
    let profile: String?
    let canonicalSessionID: String?
    let equivalentSessionIDs: Set<String>
    let isReconciling: Bool
    let settledRevision: UInt64

    static let none = ChatScrollSessionIdentity(
        profile: nil,
        canonicalSessionID: nil,
        equivalentSessionIDs: [],
        isReconciling: false,
        settledRevision: 0
    )

    init(
        profile: String?,
        canonicalSessionID: String?,
        equivalentSessionIDs: Set<String>,
        isReconciling: Bool,
        settledRevision: UInt64
    ) {
        let normalizedProfile = ChatScrollIdentityNormalization.profile(profile)
        let canonical = ChatScrollIdentityNormalization.sessionID(canonicalSessionID)
        var equivalents = Set(
            equivalentSessionIDs.compactMap(ChatScrollIdentityNormalization.sessionID)
        )
        if let canonical { equivalents.insert(canonical) }
        self.profile = normalizedProfile
        self.canonicalSessionID = canonical
        self.equivalentSessionIDs = equivalents
        self.isReconciling = isReconciling
        self.settledRevision = settledRevision
    }

    var canonicalSessionKey: ChatScrollSessionKey? {
        key(for: canonicalSessionID)
    }

    func key(for sessionID: String?) -> ChatScrollSessionKey? {
        guard let profile,
              let sessionID = ChatScrollIdentityNormalization.sessionID(sessionID) else {
            return nil
        }
        let key = ChatScrollSessionKey(profile: profile, sessionID: sessionID)
        return key.isValid ? key : nil
    }

    func contains(_ sessionID: String?) -> Bool {
        guard let sessionID = ChatScrollIdentityNormalization.sessionID(sessionID) else {
            return false
        }
        return equivalentSessionIDs.contains(sessionID)
    }

    func contains(_ key: ChatScrollSessionKey?) -> Bool {
        guard let key, key.isValid, key.profile == profile else { return false }
        return equivalentSessionIDs.contains(key.sessionID)
    }

    func areEquivalent(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = ChatScrollIdentityNormalization.sessionID(lhs),
              let rhs = ChatScrollIdentityNormalization.sessionID(rhs) else {
            return false
        }
        if lhs == rhs { return true }
        return equivalentSessionIDs.contains(lhs) && equivalentSessionIDs.contains(rhs)
    }

    func areEquivalent(_ lhs: ChatScrollSessionKey?, _ rhs: ChatScrollSessionKey?) -> Bool {
        guard let lhs, let rhs,
              lhs.isValid, rhs.isValid,
              lhs.profile == profile,
              rhs.profile == profile else {
            return false
        }
        if lhs == rhs { return true }
        return equivalentSessionIDs.contains(lhs.sessionID)
            && equivalentSessionIDs.contains(rhs.sessionID)
    }
}

enum ChatScrollSessionIdentityResolver {
    static func resolve(
        profile: String,
        activeSessionID: String?,
        catalog: [ChatScrollSessionCatalogIdentity],
        requestedSessionID: String? = nil,
        resolvedSessionID: String? = nil,
        previousIdentity current: ChatScrollSessionIdentity,
        isReconciling: Bool,
        advanceSettledRevision: Bool = false
    ) -> ChatScrollSessionIdentity {
        let normalizedProfile = ChatScrollIdentityNormalization.profile(profile)
        let previous = current.profile == normalizedProfile
            ? current
            : ChatScrollSessionIdentity(
                profile: normalizedProfile,
                canonicalSessionID: nil,
                equivalentSessionIDs: [],
                isReconciling: current.isReconciling,
                settledRevision: current.settledRevision
            )
        let profileCatalog = catalog.filter {
            $0.isValid && ($0.profile.isEmpty || $0.profile == normalizedProfile)
        }
        func matchingSession(for ids: Set<String>) -> ChatScrollSessionCatalogIdentity? {
            guard !ids.isEmpty else { return nil }
            return profileCatalog.first { !$0.identifiers.isDisjoint(with: ids) }
        }

        let activeID = ChatScrollIdentityNormalization.sessionID(activeSessionID)
        let reconciliationIDs = Set(
            [requestedSessionID, resolvedSessionID]
                .compactMap(ChatScrollIdentityNormalization.sessionID)
        )
        let reconciliationSession = matchingSession(for: reconciliationIDs)
        let reconciliationCatalogIDs = reconciliationSession?.identifiers ?? []
        let reconciliationContinuesPrevious = reconciliationIDs.isEmpty
            || reconciliationIDs.contains(where: previous.contains)
            || !reconciliationCatalogIDs.isDisjoint(with: previous.equivalentSessionIDs)
            || activeID.map(reconciliationCatalogIDs.contains) == true

        var candidates = reconciliationIDs
        if reconciliationIDs.isEmpty || reconciliationContinuesPrevious,
           let activeID {
            candidates.insert(activeID)
        }
        let matchedSession = reconciliationSession ?? matchingSession(for: candidates)
        let continuesPreviousIdentity = candidates.contains(where: previous.contains)

        let canonicalSessionID: String?
        if let matchedSession {
            canonicalSessionID = matchedSession.canonicalSessionID
        } else if continuesPreviousIdentity {
            canonicalSessionID = previous.canonicalSessionID
        } else if !reconciliationIDs.isEmpty {
            canonicalSessionID = ChatScrollIdentityNormalization.sessionID(requestedSessionID)
                ?? ChatScrollIdentityNormalization.sessionID(resolvedSessionID)
                ?? activeID
        } else {
            canonicalSessionID = activeID
        }

        var equivalentSessionIDs = candidates
        if let matchedSession {
            equivalentSessionIDs.formUnion(matchedSession.identifiers)
        }
        if continuesPreviousIdentity {
            equivalentSessionIDs.formUnion(previous.equivalentSessionIDs)
        }

        return ChatScrollSessionIdentity(
            profile: normalizedProfile,
            canonicalSessionID: canonicalSessionID,
            equivalentSessionIDs: equivalentSessionIDs,
            isReconciling: isReconciling,
            settledRevision: advanceSettledRevision
                ? current.settledRevision &+ 1
                : current.settledRevision
        )
    }
}

struct ChatScrollTargetAvailability: Equatable {
    private let messageIDs: Set<String>
    private let metadataByMessageID: [String: ChatScrollAnchorMetadata]
    private let semanticIDBySourceMessageID: [String: String]

    init(targets: [ChatMessageScrollTarget]) {
        messageIDs = Set(targets.map(\.semanticID))
        metadataByMessageID = Dictionary(
            targets.map { ($0.semanticID, $0.restorationMetadata) },
            uniquingKeysWith: { existing, _ in existing }
        )
        semanticIDBySourceMessageID = Dictionary(
            targets.map { ($0.id, $0.semanticID) },
            uniquingKeysWith: { existing, _ in existing }
        )
    }

    func contains(_ messageID: String) -> Bool {
        messageIDs.contains(messageID)
    }

    func metadata(for messageID: String) -> ChatScrollAnchorMetadata? {
        metadataByMessageID[messageID]
    }

    func semanticID(forSourceMessageID sourceMessageID: String) -> String? {
        semanticIDBySourceMessageID[sourceMessageID]
    }
}

struct ChatScrollSnapshot: Codable, Equatable {
    let anchorMessageID: String?
    let followsLatest: Bool
    let anchorMetadata: ChatScrollAnchorMetadata?
    let anchorSourceMessageID: String?

    init(
        anchorMessageID: String?,
        followsLatest: Bool,
        anchorMetadata: ChatScrollAnchorMetadata? = nil,
        anchorSourceMessageID: String? = nil
    ) {
        self.anchorMessageID = anchorMessageID
        self.followsLatest = followsLatest
        self.anchorMetadata = anchorMetadata
        self.anchorSourceMessageID = anchorSourceMessageID
    }

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
