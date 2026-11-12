//
//  AppStateSupportTypes.swift
//  Conduit
//
//  Small value types AppState's chats, rooms and profiles pass around:
//  profile ownership, the group chat seams tests replace, a session's
//  persisted transcript, the composer's submission context and the
//  conversation's agent identity. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

/// What the client can prove about a profile that a decision wants to make the
/// dashboard workspace. `unverifiable` is not "ordinary by default": the caller
/// decides, and the push-routing path fails closed on it.
enum ProfileOwnershipVerdict: Equatable {
    /// Positively a bot's own profile (roster, or a known Bot Chat's scope).
    case botOwned
    /// Verified not to be a bot: the roster loaded and does not name it.
    case ordinary
    /// No usable evidence either way.
    case unverifiable
}

/// Group Chat RPC seams, same contract as `ChatResumeLifecycleOperations`:
/// production runs the client's `groups.*` calls; tests substitute canned
/// outcomes so a harness never reaches the network. A nil closure falls
/// through to the production call.
struct GroupChatLifecycleOperations {
    var capabilities: (@MainActor (HermesClient) async throws -> GroupCapabilities)?
    var list: (@MainActor (HermesClient) async throws -> ([GroupRoom], Int?))?
    var state: (@MainActor (HermesClient, String) async throws -> (GroupRoom, GroupDriverStatus?))?
    var log: (@MainActor (HermesClient, String, Int, Int?) async throws -> GroupLogPage)?
    var send: (@MainActor (HermesClient, String, String, String, String) async throws -> GroupSendResult)?
    /// A send's Hermes attachments, seen before `send` runs.
    var sendAttachments: (@MainActor ([GroupRoomAttachment]) -> Void)?
    /// Room, upload id, kind, name, mime, base64.
    var uploadAttachment: (@MainActor (HermesClient, String, String, String, String, String, String) async throws -> GroupRoomAttachment)?
    /// Room, event id, attachment id, size; answers a data URL.
    var downloadAttachment: (@MainActor (HermesClient, String, String, String, Int) async throws -> String)?
    var create: (@MainActor (HermesClient, String, String, [[String: Any]]) async throws -> GroupRoom)?
    var stop: (@MainActor (HermesClient, String) async throws -> Int)?
    var approve: (@MainActor (HermesClient, String, GroupPendingApproval, String) async throws -> Bool)?
    var disband: (@MainActor (HermesClient, String) async throws -> Void)?
    /// The plugin's rooms routes (the drafts and the Links), in place of
    /// the dashboard bridge.
    var roomRoute: RoomLinksClient.Request?
    /// Room, event id, settings, whether routing goes along.
    var context: (@MainActor (HermesClient, String, String, GroupRoomContext, Bool) async throws -> GroupRoomContext)?
    /// Room, discussion event id.
    var continueDiscussion: (@MainActor (HermesClient, String, String) async throws -> Void)?

    static let live = GroupChatLifecycleOperations()
}

/// Raw result of fetching a session's persisted history — the dashboard
/// messages endpoint's JSON payload exactly as returned, still to be parsed
/// by AppState's production normalizer path.
enum PersistedTranscriptFetchOutcome {
    case payload([String: Any])
    /// No usable history source: no dashboard bridge, or the gateway predates
    /// the messages endpoint. The caller falls back to the resume RPC that
    /// carries the transcript itself.
    case unavailable
    /// An unrelated history failure (network, authentication, unexpected
    /// payload). It must surface to the caller instead of silently degrading
    /// the resume into a fallback.
    case failed(Error)
}

/// Parsed readiness of the persisted transcript for a resume reconciliation.
enum PersistedTranscriptOutcome {
    case hydrated(PersistedSessionTranscript)
    case unavailable
    case failed(Error)
}

struct PersistedSessionTranscript {
    let resolvedSessionId: String?
    let messages: [ChatMessage]
    /// Pagination echo of the response this transcript was parsed from.
    /// Nil (or an echo without the `order=latest` tail contract) means the
    /// backend served a one-shot full transcript.
    var page: PersistedTranscriptPagination.PageInfo?
    /// Row ids positively extracted from raw rows carrying a durable
    /// `id` / `message_id` key, populated only when this transcript came from
    /// a validated `order=latest` page. Empty for legacy one-shot reads,
    /// whose row identity is positional and untrustworthy.
    var durableRowIDs: Set<String> = []
}

struct ComposerSubmissionContext: Equatable {
    let profile: String
    let sessionID: String?
    /// The conversation's durable identity at capture time. A legitimate
    /// runtime rebind (runtime-old → runtime-new of the SAME conversation)
    /// keeps this value stable, so an otherwise-owned submission survives the
    /// rebind; a navigation handoff to another conversation and back still
    /// fails the viewport-generation fence.
    let durableSessionID: String?
    let clientIdentity: ObjectIdentifier?
    let clientEpoch: UUID
    let viewportTransitionGeneration: UInt64
}

/// The agent identity the open conversation presents: the owning bot inside
/// a Bot Chat — its pinned label (captured at the open, else the roster's),
/// picture, Desktop color — else the active workspace profile's name and
/// photo. A value type the transcript's equatable rows can gate on; the
/// bot's picture compares by INSTANCE (the avatar cache hands out the same
/// object until a refresh replaces it).
struct ConversationAgentIdentity: Equatable {
    /// The face a Bot Chat's agent wears, rendered by `BotAvatarView` — the
    /// one definition of the roster's look, so the transcript can never
    /// drift from the Bots tab.
    struct BotFace: Equatable {
        /// The bot's PROFILE name — the color's fallback hue seeds from it.
        let name: String
        /// The Desktop appearance color string, trimmed (`hsl(...)`, hex, a
        /// named color); nil, empty, or unparseable seeds the name's own hue.
        let colorString: String?
        /// The bot's cached picture. Compares by INSTANCE, like the avatar
        /// cache that stores it.
        let image: UIImage?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name
                && lhs.colorString == rhs.colorString
                && lhs.image === rhs.image
        }
    }

    /// The user-facing name: the bot's pinned label, or the workspace
    /// profile's display name.
    let name: String
    /// The workspace profile's photo; always nil inside a Bot Chat.
    let photoURL: URL?
    /// The owning bot's face; nil for ordinary conversations, which render
    /// ProfileAvatarView's photo-or-gold-monogram.
    let botFace: BotFace?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name
            && lhs.photoURL == rhs.photoURL
            && lhs.botFace == rhs.botFace
    }

    /// The identity ordinary (workspace) conversations present.
    static func workspace(name: String, photoURL: URL?) -> ConversationAgentIdentity {
        ConversationAgentIdentity(name: name, photoURL: photoURL, botFace: nil)
    }
}
