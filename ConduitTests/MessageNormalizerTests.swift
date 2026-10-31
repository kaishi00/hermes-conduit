import XCTest
@testable import Conduit

@MainActor
final class MessageNormalizerTests: XCTestCase {
    func testRuntimeSnapshotReadsLiveAssistantProjection() {
        let snapshot = SessionRuntimeSnapshot(
            object: [:],
            inflight: .object([
                "assistant": .string("Already streamed text")
            ])
        )

        XCTAssertTrue(snapshot.hasLiveProjection)
        XCTAssertEqual(snapshot.inflightAssistantText, "Already streamed text")
    }

    func testResumeDropsInflightTextAlreadyPresentInPersistedTranscript() {
        let history = [
            ChatMessage(
                id: "persisted-assistant",
                role: .assistant,
                content: "Let me find the transcript.",
                timestamp: "2026-07-29T06:21:00Z"
            )
        ]

        XCTAssertEqual(
            AppState.unpersistedInflightAssistantText(
                "Let me find the transcript.",
                after: history
            ),
            ""
        )
    }

    func testResumeKeepsOnlyUnpersistedInflightContinuation() {
        let history = [
            ChatMessage(
                id: "persisted-assistant",
                role: .assistant,
                content: "Let me find the transcript.",
                timestamp: "2026-07-29T06:21:00Z"
            )
        ]

        XCTAssertEqual(
            AppState.unpersistedInflightAssistantText(
                "Let me find the transcript. I found it.",
                after: history
            ),
            "I found it."
        )
    }

    func testResumeKeepsOnlyTheStepStillBeingWrittenWhenEarlierStepsAreSaved() {
        // Hermes' projection runs every step of the turn together; each
        // finished step is already a saved row next to its tool card.
        let history = [
            ChatMessage(id: "u", role: .user, content: "Check the logs and the config.", timestamp: "t"),
            ChatMessage(id: "a1", role: .assistant, content: "Reading the logs first.", timestamp: "t"),
            ChatMessage(id: "t1", role: .tool, content: "", timestamp: "t"),
            ChatMessage(id: "a2", role: .assistant, content: "The logs are clean. Now the config.", timestamp: "t"),
            ChatMessage(id: "t2", role: .tool, content: "", timestamp: "t")
        ]

        XCTAssertEqual(
            AppState.unpersistedInflightAssistantText(
                "Reading the logs first.The logs are clean. Now the config.The config sets",
                after: history
            ),
            "The config sets"
        )
    }

    func testResumeCountsStepsBeforeASteerAsTheRunningTurns() {
        // A steer lands mid-turn; the projection still holds the steps
        // written before it.
        let history = [
            ChatMessage(id: "u", role: .user, content: "Check the logs and the config.", timestamp: "t"),
            ChatMessage(id: "a1", role: .assistant, content: "Reading the logs first.", timestamp: "t"),
            ChatMessage(id: "s", role: .user, content: "Skip the config.", timestamp: "t", displayKind: ChatMessage.steerDisplayKind),
            ChatMessage(id: "a2", role: .assistant, content: "Ok.", timestamp: "t")
        ]

        XCTAssertEqual(
            AppState.unpersistedInflightAssistantText(
                "Reading the logs first.Ok.Summing up the logs",
                after: history
            ),
            "Summing up the logs"
        )
        XCTAssertEqual(
            AppState.unpersistedInflightAssistantText(
                "Reading the logs first.Then",
                after: Array(history.prefix(3))
            ),
            "Then"
        )
    }

    func testResumeMatchesSavedStepsWhateverTheirWhitespace() {
        let history = [
            ChatMessage(id: "u", role: .user, content: "Summarise it.", timestamp: "t"),
            ChatMessage(id: "a1", role: .assistant, content: "Step one:\n- read\n- note", timestamp: "t"),
            ChatMessage(id: "a2", role: .assistant, content: "Step two done.", timestamp: "t")
        ]

        XCTAssertEqual(
            AppState.unpersistedInflightAssistantText(
                "Step one:\n\n- read\n- note\n\nStep two  done.\n\nAnd the summary",
                after: history
            ),
            "And the summary"
        )
    }

    func testResumePassesOverAStepTheProjectionDoesNotShow() {
        let history = [
            ChatMessage(id: "u", role: .user, content: "Go.", timestamp: "t"),
            ChatMessage(id: "a1", role: .assistant, content: "Saved differently.", timestamp: "t"),
            ChatMessage(id: "a2", role: .assistant, content: "The second step checked every config file.", timestamp: "t")
        ]

        XCTAssertEqual(
            AppState.unpersistedInflightAssistantText(
                "First step as streamed. The second step checked every config file. Third",
                after: history
            ),
            "Third"
        )
    }

    func testResumeNeverCutsTheStepBeingWrittenAtAShortStepsWords() {
        // A short saved step the projection doesn't show at its place is
        // not looked for inside the step still being written.
        let history = [
            ChatMessage(id: "u", role: .user, content: "Go.", timestamp: "t"),
            ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "t")
        ]

        XCTAssertEqual(
            AppState.unpersistedInflightAssistantText(
                "Working on it. Done. Now the rest",
                after: history
            ),
            "Working on it. Done. Now the rest"
        )
    }

    func testResumeNeverCutsWithAnEarlierTurnsReplyAtTheStart() {
        let history = [
            ChatMessage(id: "u1", role: .user, content: "Look into it.", timestamp: "t"),
            ChatMessage(id: "a1", role: .assistant, content: "Checking the logs.", timestamp: "t"),
            ChatMessage(id: "u2", role: .user, content: "Again please.", timestamp: "t")
        ]

        XCTAssertEqual(
            AppState.unpersistedInflightAssistantText(
                "Checking the logs. They look different now.",
                after: history
            ),
            "Checking the logs. They look different now."
        )
    }

    func testResumeNeverCutsTheRunningTurnWithAnEarlierTurnsReply() {
        let history = [
            ChatMessage(id: "u1", role: .user, content: "Look into it.", timestamp: "t"),
            ChatMessage(id: "a1", role: .assistant, content: "Checking the logs.", timestamp: "t"),
            ChatMessage(id: "u2", role: .user, content: "Again please.", timestamp: "t")
        ]

        XCTAssertEqual(
            AppState.unpersistedInflightAssistantText(
                "Once more from the top. Checking the logs.",
                after: history
            ),
            "Once more from the top. Checking the logs."
        )
    }

    func testGatewayPlatformsAreNamedByTheirHermesSource() {
        let expected: [(String, SessionSource)] = [
            ("slack", .slack), ("whatsapp", .whatsapp), ("whatsapp_cloud", .whatsapp),
            ("signal", .signal), ("bluebubbles", .imessage), ("photon", .imessage),
            ("matrix", .matrix), ("mattermost", .mattermost), ("teams", .teams),
            ("google_chat", .googleChat), ("email", .email), ("sms", .sms), ("irc", .irc),
            ("line", .line), ("simplex", .simplex), ("weixin", .wechat), ("wecom", .wecom),
            ("wecom_callback", .wecom), ("feishu", .feishu), ("dingtalk", .dingtalk),
            ("qqbot", .qq), ("yuanbao", .yuanbao), ("buzz", .buzz), ("raft", .raft),
            ("ntfy", .ntfy), ("a2a", .a2a), ("msgraph_webhook", .webhook),
            ("api_server", .api), ("Slack", .slack)
        ]
        for (source, category) in expected {
            XCTAssertEqual(MessageNormalizer.classifySource(["source": .string(source)]), category, source)
        }
        // The app's own sessions stay chats, and a plugin platform Conduit
        // doesn't know yet is Other rather than a guess.
        XCTAssertEqual(MessageNormalizer.classifySource(["source": .string("desktop")]), .chat)
        XCTAssertEqual(MessageNormalizer.classifySource(["source": .string("relay")]), .other)
        XCTAssertEqual(MessageNormalizer.classifySource(["source": .string("voice")]), .other)
        // Every platform has a place in the filter order.
        XCTAssertTrue(SessionSource.gatewayPlatforms.allSatisfy(AppState.defaultSessionFilterOrder.contains))
        XCTAssertEqual(Set(AppState.defaultSessionFilterOrder), Set(SessionSource.allCases))
    }

    func testSessionNormalizationLeavesSessionsThatArentChatsOut() {
        let sessions = MessageNormalizer.normalizeSessions(
            .object([
                "sessions": .array([
                    .object(["id": .string("worker"), "source": .string("kanban")]),
                    .object(["id": .string("integration"), "source": .string("tool")]),
                    .object(["id": .string("one-shot"), "source": .string("ONESHOT")]),
                    .object(["id": .string("chat"), "source": .string("desktop")])
                ])
            ]),
            profile: "default"
        )

        // Hermes won't reopen a Kanban worker as a chat (4132), and its own
        // pickers hide tool integrations and one-shot runs.
        XCTAssertEqual(sessions.map(\.id), ["chat"])
    }

    func testSessionNormalizationLeavesKanbanWorkersStoredBeforeTheTagOut() {
        let sessions = MessageNormalizer.normalizeSessions(
            .object([
                "sessions": .array([
                    // A worker Hermes stored as `cli`, titled later or not.
                    .object(["id": .string("titled"), "source": .string("cli"),
                             "title": .string("SeaBag 1.7.9 Release"), "preview": .string("work kanban task t_04fbcc18")]),
                    .object(["id": .string("untitled"), "source": .string("local"),
                             "preview": .string("Work kanban task t_9a1b2c3d ")]),
                    // A person's message that only starts the same way stays,
                    // and so does a chat from elsewhere that reads the same.
                    .object(["id": .string("chat"), "source": .string("cli"),
                             "preview": .string("work kanban task t_1 again, it failed")]),
                    .object(["id": .string("telegram"), "source": .string("telegram"),
                             "preview": .string("work kanban task t_2")])
                ])
            ]),
            profile: "default"
        )

        XCTAssertEqual(sessions.map(\.id), ["chat", "telegram"])
    }

    func testSessionNormalizationPreservesExplicitProfileOwnership() {
        let sessions = MessageNormalizer.normalizeSessions(
            .object([
                "sessions": .array([
                    .object([
                        "id": .string("secondary-session"),
                        "profile": .string("secondary")
                    ])
                ])
            ]),
            profile: "default"
        )

        XCTAssertEqual(sessions.first?.profile, "secondary")
    }

    func testSessionNormalizationRecognizesAlternateProfileKeys() {
        let sessions = MessageNormalizer.normalizeSessions(
            .object([
                "sessions": .array([
                    .object([
                        "id": .string("profile-name-session"),
                        "profile_name": .string("work")
                    ]),
                    .object([
                        "id": .string("profile-id-session"),
                        "profile_id": .string("personal")
                    ])
                ])
            ]),
            profile: "default"
        )

        XCTAssertEqual(sessions.compactMap(\.profile), ["work", "personal"])
    }

    func testSessionNormalizationKeepsStoredIDSeparateFromRuntimeID() {
        let sessions = MessageNormalizer.normalizeSessions(
            .object([
                "sessions": .array([
                    .object([
                        "session_id": .string("runtime-123"),
                        "id": .string("stored-123"),
                        "profile": .string("default")
                    ])
                ])
            ]),
            profile: "default"
        )

        XCTAssertEqual(sessions.first?.storedSessionId, "stored-123")
        XCTAssertTrue(sessions.first?.alternateIds.contains("stored-123") == true)
    }

    func testSessionNormalizationDoesNotTreatLoneIDAsVerifiedStoredID() {
        let sessions = MessageNormalizer.normalizeSessions(
            .object([
                "sessions": .array([
                    .object(["id": .string("ambiguous-123")])
                ])
            ]),
            profile: "default"
        )

        XCTAssertNil(sessions.first?.storedSessionId)
    }

    func testNotificationRuntimeIDResolvesToStoredSessionID() {
        let session = SessionSummary(
            id: "runtime-123",
            storedSessionId: "stored-123",
            alternateIds: ["stored-123"],
            title: "A session",
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false
        )

        XCTAssertEqual(
            NotificationSessionResolver.route(
                target: ConduitNotificationTarget(profile: nil, sessionId: "runtime-123", type: nil),
                catalog: [session],
                identityIndex: ConversationIdentityIndex(),
                profile: "default"
            ),
            NotificationSessionResolver.Route(
                resumeTargetID: "stored-123",
                durableSessionID: "stored-123",
                basis: .catalogAlias
            )
        )
    }

    func testNotificationResolverTrimsUnknownRuntimeID() {
        XCTAssertEqual(
            NotificationSessionResolver.route(
                target: ConduitNotificationTarget(profile: nil, sessionId: "  runtime-123  ", type: nil),
                catalog: [],
                identityIndex: ConversationIdentityIndex(),
                profile: "default"
            ),
            NotificationSessionResolver.Route(
                resumeTargetID: "runtime-123",
                durableSessionID: nil,
                basis: .legacyRuntime
            ),
            "An unknown runtime id flows through as itself — never reinterpreted as a durable id"
        )
    }

    func testFailedNotificationRouteClearsPendingTarget() {
        let service = PushNotificationService.shared
        defer {
            if let pendingTarget = service.pendingTarget {
                service.clearPendingTarget(pendingTarget)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-123",
                "type": "response_ready"
            ] as [String: Any]
        ])

        guard let target = service.pendingTarget else {
            return XCTFail("Expected the notification target to be pending")
        }

        service.clearPendingTarget(target)

        XCTAssertNil(service.pendingTarget)
    }

    func testNotificationPayloadCarriesApprovalDecision() {
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-1",
                "profile": "default",
                "type": "approval.needed",
                "decision": [
                    "kind": "approval",
                    "session_key": "runtime-1",
                    "description": "Run a dangerous shell command",
                    "choices": ["once", "deny"],
                ] as [String: Any],
            ] as [String: Any],
        ])

        guard case let .approval(sessionKey, description, choices) = service.pendingTarget?.decision else {
            return XCTFail("Expected an approval decision carried on the notification target")
        }
        XCTAssertEqual(sessionKey, "runtime-1")
        XCTAssertEqual(description, "Run a dangerous shell command")
        XCTAssertEqual(choices, ["once", "deny"])
    }

    func testNotificationPayloadDecisionAbsentForNonDecisionEvents() {
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "session-1",
                "type": "response.ready",
            ] as [String: Any],
        ])
        XCTAssertNil(service.pendingTarget?.decision, "Non-decision notifications must not carry a decision")
    }

    func testNotificationPayloadDecisionRejectedWithoutSessionKey() {
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        // An approval with no answerable session key is not useful; drop it.
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "session-1",
                "type": "approval.needed",
                "decision": ["kind": "approval", "description": "something"] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertNil(service.pendingTarget?.decision)
    }

    func testNotificationPayloadDecisionRejectedWithoutDisplayText() {
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "session-1",
                "type": "approval.needed",
                "decision": [
                    "kind": "approval",
                    "session_key": "session-1",
                    "description": "   ",
                    "choices": ["once", "deny"],
                ] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertNil(service.pendingTarget?.decision, "An approval with no display text must degrade to a routing target")
    }

    func testNotificationPayloadDecisionRejectedWithoutUsableChoices() {
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        // Absent choices.
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "session-1",
                "type": "approval.needed",
                "decision": ["kind": "approval", "session_key": "session-1", "description": "d"] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertNil(service.pendingTarget?.decision, "Absent choices must degrade to a routing target")

        // All-empty/invalid choices.
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "session-1",
                "type": "approval.needed",
                "decision": [
                    "kind": "approval",
                    "session_key": "session-1",
                    "description": "d",
                    "choices": ["  ", ""],
                ] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertNil(service.pendingTarget?.decision, "Choices with no usable entries must degrade to a routing target")
    }

    func testNotificationPreferencesRoundTripDecisionCardsKey() throws {
        var preferences = ConduitNotificationPreferences()
        XCTAssertTrue(preferences.decisionCards, "Decision cards default on, independent of show previews")
        XCTAssertFalse(preferences.showPreviews)

        preferences.decisionCards = false
        let data = try JSONEncoder().encode(preferences)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["decision_cards"] as? Bool, false, "The relay expects the snake_case decision_cards key")

        let decoded = try JSONDecoder().decode(ConduitNotificationPreferences.self, from: data)
        XCTAssertFalse(decoded.decisionCards)
    }

    func testNotificationDetailMapsToTheRelayFlags() throws {
        var preferences = ConduitNotificationPreferences()
        XCTAssertEqual(preferences.detail, .generic, "Notifications stay generic by default")

        preferences.detail = .chatNames
        XCTAssertFalse(preferences.showPreviews)
        XCTAssertTrue(preferences.showChatNames)
        let data = try JSONEncoder().encode(preferences)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["show_chat_names"] as? Bool, true, "The relay expects the snake_case show_chat_names key")
        XCTAssertEqual(try JSONDecoder().decode(ConduitNotificationPreferences.self, from: data).detail, .chatNames)

        preferences.detail = .previews
        XCTAssertTrue(preferences.showPreviews)
        XCTAssertTrue(preferences.showChatNames, "Full previews names the chat too")
        preferences.detail = .generic
        XCTAssertFalse(preferences.showPreviews || preferences.showChatNames)

        let legacy = try JSONDecoder().decode(ConduitNotificationPreferences.self, from: Data(#"{"show_previews": true}"#.utf8))
        XCTAssertEqual(legacy.detail, .previews, "Show previews on before #1415 is Full previews")
    }

    func testNotificationPreferencesRoundTripAttentionSoundKey() throws {
        var preferences = ConduitNotificationPreferences()
        XCTAssertTrue(preferences.attentionSound, "Approval and input sounds default on")

        preferences.attentionSound = false
        let data = try JSONEncoder().encode(preferences)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["attention_sound"] as? Bool, false, "The relay expects the snake_case attention_sound key")

        let decoded = try JSONDecoder().decode(ConduitNotificationPreferences.self, from: data)
        XCTAssertFalse(decoded.attentionSound)
    }

    func testNotificationPreferencesDecodeLegacyRegistrationWithoutDecisionCardsKey() throws {
        // A registration persisted by a build that predated decision_cards.
        // Decoding must fall back to the default rather than throwing — a
        // throw would make the `try?` in the service init drop the whole
        // stored registration and silently disable push on upgrade.
        let legacyJSON = """
        {
          "enabled": true,
          "approval_needed": false,
          "input_needed": true,
          "response_ready": true,
          "turn_failed": true,
          "background_task_finished": true,
          "completion_sound": true,
          "show_previews": true
        }
        """
        let decoded = try JSONDecoder().decode(
            ConduitNotificationPreferences.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertFalse(decoded.approvalNeeded, "Persisted values must survive")
        XCTAssertTrue(decoded.showPreviews, "Persisted values must survive")
        XCTAssertTrue(decoded.decisionCards, "Absent decision_cards must fall back to the default-on value")
        XCTAssertTrue(decoded.attentionSound, "Absent attention_sound must fall back to the default-on value")
    }

    func testRelayMetaDecodingAndCapabilityChecks() throws {
        let json = """
        {
          "version": "0.2.0",
          "capabilities": ["decisions", "decision-cards", "meta"],
          "gateways": [
            {
              "id": "gw-1",
              "name": "Mac Studio Hermes",
              "plugin_version": "0.2.0",
              "plugin_capabilities": ["approval-decisions", "clarify-loop", "version-reporting"]
            },
            {
              "id": "gw-2",
              "name": "Old laptop",
              "plugin_version": null,
              "plugin_capabilities": [],
              "last_event_at": "2026-08-15T01:00:00Z"
            },
            {
              "id": "gw-3",
              "name": "Fresh pair",
              "plugin_version": null,
              "plugin_capabilities": [],
              "last_event_at": null
            }
          ]
        }
        """
        let meta = try JSONDecoder().decode(RelayMetaInfo.self, from: Data(json.utf8))

        XCTAssertTrue(meta.supportsDecisionCards)
        XCTAssertEqual(meta.gateways.count, 3)

        let current = meta.gateways[0]
        XCTAssertTrue(current.supportsApprovalCards)
        XCTAssertTrue(current.supportsClarifyCards)

        // Events sent but never a plugin version = pre-0.2 notifier: prompt
        // the update instead of showing "waiting for the first notification".
        let legacy = meta.gateways[1]
        XCTAssertNil(legacy.pluginVersion)
        XCTAssertNotNil(legacy.lastEventAt)
        XCTAssertTrue(legacy.hasSentEventsButNeverReported)

        // A gateway that has sent nothing keeps the waiting state — it is not
        // evidence of an old plugin, so no contradictory update prompt.
        let neverSent = meta.gateways[2]
        XCTAssertNil(neverSent.pluginVersion)
        XCTAssertNil(neverSent.lastEventAt)
        XCTAssertFalse(neverSent.hasSentEventsButNeverReported)
    }

    func testRelayMetaOutlastsAFailedFetch() throws {
        let json = #"{"version": "0.40.0", "capabilities": ["meta", "location-push"], "gateways": []}"#
        let known = try JSONDecoder().decode(RelayMetaInfo.self, from: Data(json.utf8))
        XCTAssertTrue(known.supportsLocationPush)
        let newer = try JSONDecoder().decode(RelayMetaInfo.self, from: Data(#"{"version": "0.41.0", "capabilities": ["meta"], "gateways": []}"#.utf8))
        // What the relay says replaces what it said.
        XCTAssertEqual(PushNotificationService.relayMetaAfterFetch(previous: known, status: 200, fetched: newer), newer)
        // A relay without the route predates version reporting.
        XCTAssertNil(PushNotificationService.relayMetaAfterFetch(previous: known, status: 404, fetched: nil))
        // Offline, a relay error or an unreadable answer: the last answer
        // stands, so the next registration update keeps the location-push
        // token instead of sending locationToken: .clear.
        for status in [nil, 500, 502, 503, 401] as [Int?] {
            XCTAssertEqual(PushNotificationService.relayMetaAfterFetch(previous: known, status: status, fetched: nil), known, "\(String(describing: status))")
        }
        XCTAssertEqual(PushNotificationService.relayMetaAfterFetch(previous: known, status: 200, fetched: nil), known)
        // Never fetched: still unknown.
        XCTAssertNil(PushNotificationService.relayMetaAfterFetch(previous: nil, status: nil, fetched: nil))
    }

    func testRelayMetaDecodingDropsMalformedGatewayRowsLossily() throws {
        // One incompatible gateway record must not hide the whole section.
        let json = """
        {
          "version": "0.2.0",
          "capabilities": ["decisions"],
          "gateways": [
            { "id": "gw-bad" },
            { "id": "gw-good", "name": "Main", "plugin_version": "0.2.0", "plugin_capabilities": ["clarify-loop"] }
          ]
        }
        """
        let meta = try JSONDecoder().decode(RelayMetaInfo.self, from: Data(json.utf8))
        XCTAssertEqual(meta.gateways.map(\.id), ["gw-good"])
        XCTAssertTrue(meta.supportsDecisionCards)
    }

    func testNotificationPairingsShowOnlyTheActiveDashboards() throws {
        let main = UUID()
        let review = UUID()
        let removed = UUID()
        let json = """
        {
          "version": "0.2.0",
          "capabilities": ["decisions"],
          "gateways": [
            { "id": "gw-main", "name": "Mac Hermes", "plugin_version": "0.4.0",
              "plugin_capabilities": ["approval-decisions", "clarify-loop"], "dashboard_id": "\(main.uuidString.lowercased())" },
            { "id": "gw-review", "name": "Mac Hermes", "plugin_version": "0.3.0",
              "plugin_capabilities": ["approval-decisions", "clarify-loop"], "dashboard_id": "\(review.uuidString)" },
            { "id": "gw-removed", "name": "Old", "plugin_version": "0.4.0",
              "plugin_capabilities": [], "dashboard_id": "\(removed.uuidString)" },
            { "id": "gw-malformed", "name": "Bad", "plugin_version": null,
              "plugin_capabilities": [], "dashboard_id": "not-a-uuid" },
            { "id": "gw-legacy", "name": "Legacy", "plugin_version": "0.2.0",
              "plugin_capabilities": [], "dashboard_id": null }
          ]
        }
        """
        let meta = try JSONDecoder().decode(RelayMetaInfo.self, from: Data(json.utf8))

        // On the review dashboard, the main dashboard's up-to-date pairing
        // never stands in for the review dashboard's own.
        let onReview = NotificationDashboardPairings(
            gateways: meta.gateways, activeDashboardID: review, savedDashboardIDs: [main, review]
        )
        XCTAssertEqual(onReview.thisDashboard.map(\.id), ["gw-review"])
        XCTAssertEqual(onReview.thisDashboard.first?.pluginVersion, "0.3.0")
        // A pre-dashboard pairing can't be attributed while two are saved.
        XCTAssertEqual(onReview.unscoped.map(\.id), ["gw-legacy"])
        XCTAssertEqual(onReview.otherDashboardsCount, 1)
        // A removed dashboard's pairing, or a malformed binding, is not
        // "another dashboard": there is nothing to switch to.
        XCTAssertEqual(onReview.unrecognizedCount, 2)

        let onMain = NotificationDashboardPairings(
            gateways: meta.gateways, activeDashboardID: main, savedDashboardIDs: [main, review]
        )
        XCTAssertEqual(onMain.thisDashboard.map(\.id), ["gw-main"])
    }

    func testNotificationPairingsWithOneDashboardKeepLegacyPairings() {
        let only = UUID()
        let gateway = { (id: String, dashboardID: String?) in
            RelayMetaInfo.Gateway(
                id: id, name: id, pluginVersion: nil, pluginCapabilities: [], lastEventAt: nil, dashboardID: dashboardID
            )
        }
        let pairings = NotificationDashboardPairings(
            gateways: [gateway("legacy", nil), gateway("blank", "  "), gateway("scoped", only.uuidString)],
            activeDashboardID: only,
            savedDashboardIDs: [only]
        )
        // Same rule as push routing: with one dashboard saved, an unscoped
        // pairing's pushes route to it, so it is this dashboard's.
        XCTAssertEqual(pairings.thisDashboard.map(\.id), ["legacy", "blank", "scoped"])
        XCTAssertTrue(pairings.unscoped.isEmpty)
        XCTAssertEqual(pairings.otherDashboardsCount, 0)

        // With the selected dashboard removed, nothing is judged: push
        // routing would send the legacy pairing to the one saved dashboard,
        // but listing it would present it as the selected dashboard's.
        let noneActive = NotificationDashboardPairings(
            gateways: [gateway("legacy", nil), gateway("scoped", only.uuidString)],
            activeDashboardID: nil,
            savedDashboardIDs: [only]
        )
        XCTAssertEqual(noneActive, NotificationDashboardPairings(gateways: [], activeDashboardID: nil, savedDashboardIDs: []))
        XCTAssertTrue(noneActive.thisDashboard.isEmpty)
        XCTAssertEqual(noneActive.otherDashboardsCount, 0)

        // With every dashboard removed, the same: nothing is listed or counted.
        let noneSaved = NotificationDashboardPairings(
            gateways: [gateway("scoped", only.uuidString)], activeDashboardID: nil, savedDashboardIDs: []
        )
        XCTAssertEqual(noneSaved.unrecognizedCount, 0)
        XCTAssertTrue(noneSaved.unscoped.isEmpty)
    }

    func testExpiredPromptErrorClassification() {
        // The gateway's one-shot prompt timeout: JSON-RPC 4009.
        XCTAssertTrue(AppState.isExpiredPromptError(RpcError(code: 4009, message: "no pending approval request")))
        // Code-less variants still classify via the message, case-insensitively.
        XCTAssertTrue(AppState.isExpiredPromptError(RpcError(code: nil, message: "No Pending clarify request")))
        // Genuine failures must not be misread as expiry.
        XCTAssertFalse(AppState.isExpiredPromptError(RpcError(code: 4004, message: "session not found")))
        XCTAssertFalse(AppState.isExpiredPromptError(HermesError.timeout("approval.respond")))
        XCTAssertFalse(AppState.isExpiredPromptError(HermesError.notConnected))
    }

    func testNotificationPayloadCarriesClarifyDecision() {
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-1",
                "profile": "default",
                "type": "input.needed",
                "decision": [
                    "kind": "clarify",
                    "request_id": "conduit-push-abc123",
                    "question": "Which color?",
                    "choices": ["Red", "Blue"],
                ] as [String: Any],
            ] as [String: Any],
        ])

        guard case let .clarify(requestId, question, choices) = service.pendingTarget?.decision else {
            return XCTFail("Expected a clarify decision carried on the notification target")
        }
        XCTAssertEqual(requestId, "conduit-push-abc123")
        XCTAssertEqual(question, "Which color?")
        XCTAssertEqual(choices, ["Red", "Blue"])
    }

    func testNotificationPayloadCarriesBatchClarifyDecision() {
        // Current notifier: the pushed decision preserves the FULL question
        // set — qids, choices, and multi_select — with no reduction to the
        // first question.
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-1",
                "profile": "default",
                "type": "input.needed",
                "decision": [
                    "kind": "clarify",
                    "request_id": "conduit-push-batch1",
                    "questions": [
                        ["qid": "environment", "question": "Which environment?", "choices": ["staging", "prod"], "multi_select": false],
                        ["qid": "tests", "question": "Which tests?", "choices": ["unit", "ui"], "multi_select": true],
                        ["qid": "notes", "question": "Any additional notes?", "choices": []]
                    ] as [[String: Any]],
                ] as [String: Any],
            ] as [String: Any],
        ])

        guard case let .clarifyBatch(requestId, questions) = service.pendingTarget?.decision else {
            return XCTFail("Expected a batch clarify decision carried on the notification target")
        }
        XCTAssertEqual(requestId, "conduit-push-batch1")
        XCTAssertEqual(questions.map(\.id), ["environment", "tests", "notes"], "qids are preserved as identity")
        XCTAssertEqual(questions.map(\.question), ["Which environment?", "Which tests?", "Any additional notes?"])
        XCTAssertEqual(questions[0].choices.map(\.value), ["staging", "prod"])
        XCTAssertTrue(questions[1].multiSelect, "multi_select must survive the push payload")
        XCTAssertFalse(questions[0].multiSelect)
        XCTAssertTrue(questions[2].choices.isEmpty, "Free-text questions survive the push payload")
        XCTAssertFalse(questions[0].isSyntheticID, "Pushed batch qids are gateway identities, not synthetic")
    }

    func testNotificationPayloadBatchClarifyFallsBackToScalarWhenQuestionsUnusable() {
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-1",
                "profile": "default",
                "type": "input.needed",
                "decision": [
                    "kind": "clarify",
                    "request_id": "conduit-push-batch2",
                    "questions": [["question": "No qid"]] as [[String: Any]],
                    "question": "Scalar fallback",
                    "choices": ["a"]
                ] as [String: Any],
            ] as [String: Any],
        ])
        guard case let .clarify(requestId, question, choices) = service.pendingTarget?.decision else {
            return XCTFail("Expected the legacy scalar decode when no batch question survives")
        }
        XCTAssertEqual(requestId, "conduit-push-batch2")
        XCTAssertEqual(question, "Scalar fallback")
        XCTAssertEqual(choices, ["a"])
    }

    // MARK: - APNs payload layout selection (notifier 0.3+ single-copy shape)

    /// Wraps a Conduit payload in the raw APNs notification layout.
    private func receiveAPNsPayload(_ service: PushNotificationService, payload: [String: Any]) {
        service.receiveNotificationPayload(payload)
    }

    func testNotificationPayloadNestedRichConduitParsesBatchDecision() {
        // Notifier 0.3+ optimized layout: top-level conduit is a routing
        // stub, body.conduit carries the structured decision. The nested
        // copy must win — a `direct ?? nested` choice would silently drop
        // the answerable card.
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        receiveAPNsPayload(service, payload: [
            "aps": ["alert": ["title": "Input needed", "body": "Which environment?"]],
            "body": [
                "conduit": [
                    "type": "input.needed",
                    "session_id": "runtime-1",
                    "profile": "default",
                    "decision": [
                        "kind": "clarify",
                        "request_id": "conduit-push-opt1",
                        "question": "Which environment?",
                        "questions": [
                            ["qid": "q0", "question": "Which environment?", "choices": ["staging", "prod"], "multi_select": false],
                            ["qid": "q1", "question": "Which tests?", "choices": ["unit", "ui"], "multi_select": true],
                        ] as [[String: Any]],
                    ] as [String: Any],
                ] as [String: Any],
            ],
            "conduit": [
                "type": "input.needed",
                "session_id": "runtime-1",
                "profile": "default",
            ] as [String: Any],
        ])

        guard case let .clarifyBatch(requestId, questions) = service.pendingTarget?.decision else {
            return XCTFail("The nested rich decision must be selected over the routing-only stub")
        }
        XCTAssertEqual(requestId, "conduit-push-opt1")
        XCTAssertEqual(questions.map(\.id), ["q0", "q1"], "the full batch survives the payload selection")
    }

    func testNotificationPayloadNestedOnlyConduitStillParses() {
        // Current-generation layout without a top-level copy at all.
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        service.receiveNotificationPayload([
            "body": [
                "conduit": [
                    "session_id": "runtime-1",
                    "type": "input.needed",
                    "decision": [
                        "kind": "clarify",
                        "request_id": "conduit-push-nested1",
                        "question": "Which color?",
                        "choices": ["Red", "Blue"],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ])
        guard case let .clarify(requestId, question, choices) = service.pendingTarget?.decision else {
            return XCTFail("Expected the nested-only decision to parse")
        }
        XCTAssertEqual(requestId, "conduit-push-nested1")
        XCTAssertEqual(question, "Which color?")
        XCTAssertEqual(choices, ["Red", "Blue"])
    }

    func testNotificationPayloadLegacyTopLevelConduitStillParses() {
        // Legacy layout: only the top-level conduit copy exists.
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-1",
                "profile": "default",
                "type": "input.needed",
                "decision": [
                    "kind": "clarify",
                    "request_id": "conduit-push-legacy1",
                    "question": "Legacy?",
                    "choices": ["a"],
                ] as [String: Any],
            ] as [String: Any],
        ])
        guard case let .clarify(requestId, question, _) = service.pendingTarget?.decision else {
            return XCTFail("Expected the legacy top-level decision to parse")
        }
        XCTAssertEqual(requestId, "conduit-push-legacy1")
        XCTAssertEqual(question, "Legacy?")
    }

    func testNotificationPayloadWithoutDecisionNavigatesWithoutInventingACard() {
        // Plain fallback banner (decision stripped or disabled): routing must
        // still work, and no ClarifyActivity may be invented.
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        service.receiveNotificationPayload([
            "body": [
                "conduit": [
                    "type": "input.needed",
                    "session_id": "runtime-1",
                    "profile": "default",
                ] as [String: Any],
            ] as [String: Any],
            "conduit": [
                "type": "input.needed",
                "session_id": "runtime-1",
                "profile": "default",
            ] as [String: Any],
        ])
        let target = service.pendingTarget
        XCTAssertNotNil(target, "The plain notification still routes to the session")
        XCTAssertEqual(target?.sessionId, "runtime-1")
        XCTAssertNil(target?.decision, "A plain fallback banner must never invent an answerable card")
    }

    func testNotificationPayloadClarifyDecisionRejectedWithoutRequestId() {
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        // Without the plugin-minted id the card is not answerable; degrade.
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "session-1",
                "type": "input.needed",
                "decision": ["kind": "clarify", "question": "Which color?"] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertNil(service.pendingTarget?.decision)

        // A non-prefixed id would be routed to the gateway's clarify.respond,
        // which can never resolve a plugin-minted decision; reject it too.
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "session-1",
                "type": "input.needed",
                "decision": ["kind": "clarify", "request_id": "gateway-rid-1", "question": "Which color?"] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertNil(service.pendingTarget?.decision)

        // The bare prefix with no unique suffix is equally unanswerable.
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "session-1",
                "type": "input.needed",
                "decision": ["kind": "clarify", "request_id": "conduit-push-", "question": "Which color?"] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertNil(service.pendingTarget?.decision)
    }

    /// Waits for the scheduled retry to bump `navigationAttempt`. A cap, not
    /// a timing: the loop exits as soon as the retry lands. A busy simulator
    /// can stall the main actor for seconds inside one yield, and a 1s cap
    /// then expired before the retry got its turn.
    private func waitForNotificationRetry(
        _ service: PushNotificationService,
        after attempt: Int,
        cap: Duration = .seconds(10)
    ) async {
        let deadline = ContinuousClock.now.advanced(by: cap)
        while service.navigationAttempt == attempt,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    /// #789: a cold launch on a slow network can fail the open several times
    /// while the session catalog is still loading. The tap stays pending and
    /// is retried for as long as the retry window lasts, however many reads
    /// fail inside it.
    func testFailedNotificationRouteKeepsRetryingInsideTheWindow() async {
        let service = PushNotificationService(retryDelay: .zero)
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-123",
                "type": "response_ready"
            ] as [String: Any]
        ])
        guard let target = service.pendingTarget else {
            return XCTFail("Expected the notification target to be pending")
        }

        for failure in 1...4 {
            let attempt = service.navigationAttempt
            XCTAssertTrue(
                service.handleFailedNotificationRoute(target),
                "Failure \(failure) inside the window dropped the tap"
            )
            await waitForNotificationRetry(service, after: attempt)
            XCTAssertEqual(service.navigationAttempt, attempt + 1)
            XCTAssertEqual(service.pendingTarget, target)
        }
    }

    /// The window, counted from the tap, is a cap: once it has run out, the
    /// next failure clears the tap and schedules nothing more.
    func testFailedNotificationRouteClearsTargetOnceTheWindowRunsOut() async {
        var now = ContinuousClock.now
        let service = PushNotificationService(
            retryDelay: .zero,
            routeRetryWindow: .seconds(30),
            now: { now }
        )
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-123",
                "type": "response_ready"
            ] as [String: Any]
        ])
        guard let target = service.pendingTarget else {
            return XCTFail("Expected the notification target to be pending")
        }

        let initialAttempt = service.navigationAttempt
        XCTAssertTrue(service.handleFailedNotificationRoute(target))
        await waitForNotificationRetry(service, after: initialAttempt)
        XCTAssertEqual(service.navigationAttempt, initialAttempt + 1)

        now = now.advanced(by: .seconds(29))
        let lateAttempt = service.navigationAttempt
        XCTAssertTrue(service.handleFailedNotificationRoute(target))
        await waitForNotificationRetry(service, after: lateAttempt)
        XCTAssertEqual(service.pendingTarget, target)

        now = now.advanced(by: .seconds(2))
        XCTAssertFalse(service.handleFailedNotificationRoute(target))
        XCTAssertNil(service.pendingTarget)
        let terminalAttempt = service.navigationAttempt
        await waitForNotificationRetry(service, after: terminalAttempt, cap: .milliseconds(100))
        XCTAssertEqual(service.navigationAttempt, terminalAttempt)
    }

    /// An open that starts while a retry is still waiting stands the retry
    /// down: firing later would cancel the open in flight.
    func testStartingAnOpenCancelsTheWaitingRetry() async {
        let service = PushNotificationService(retryDelay: .milliseconds(50))
        service.receiveNotificationPayload([
            "conduit": ["session_id": "runtime-123", "type": "response_ready"] as [String: Any]
        ])
        guard let target = service.pendingTarget else {
            return XCTFail("Expected the notification target to be pending")
        }
        XCTAssertTrue(service.handleFailedNotificationRoute(target))
        let attempt = service.navigationAttempt
        service.beginNotificationRoute(target)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.navigationAttempt, attempt)
        XCTAssertEqual(service.pendingTarget, target)
    }

    /// A new tap gets a window of its own, so an earlier tap's failures don't
    /// shorten it.
    func testNewNotificationTapStartsAFreshRetryWindow() async {
        var now = ContinuousClock.now
        let service = PushNotificationService(
            retryDelay: .zero,
            routeRetryWindow: .seconds(30),
            now: { now }
        )
        service.receiveNotificationPayload([
            "conduit": ["session_id": "runtime-1", "type": "response_ready"] as [String: Any]
        ])
        guard let first = service.pendingTarget else {
            return XCTFail("Expected the first target to be pending")
        }
        XCTAssertTrue(service.handleFailedNotificationRoute(first))

        now = now.advanced(by: .seconds(25))
        service.receiveNotificationPayload([
            "conduit": ["session_id": "runtime-2", "type": "response_ready"] as [String: Any]
        ])
        guard let second = service.pendingTarget, second != first else {
            return XCTFail("Expected the second target to replace the first")
        }
        XCTAssertTrue(service.handleFailedNotificationRoute(second))
        now = now.advanced(by: .seconds(10))
        XCTAssertTrue(service.handleFailedNotificationRoute(second))
        XCTAssertEqual(service.pendingTarget, second)
    }

    private func makeWindowedService(
        now: @escaping () -> ContinuousClock.Instant
    ) -> (PushNotificationService, ConduitNotificationTarget?) {
        let service = PushNotificationService(
            retryDelay: .zero,
            routeRetryWindow: .seconds(30),
            now: now
        )
        service.receiveNotificationPayload([
            "conduit": ["session_id": "runtime-123", "type": "response_ready"] as [String: Any]
        ])
        return (service, service.pendingTarget)
    }

    /// #789: a launch that took longer than the window to connect still
    /// makes the tap's first open.
    func testFirstOpenRunsEvenAfterTheWindow() {
        var now = ContinuousClock.now
        let (service, pending) = makeWindowedService(now: { now })
        guard let target = pending else { return XCTFail("Expected a pending target") }
        now = now.advanced(by: .seconds(45))
        XCTAssertTrue(service.beginNotificationRoute(target))
        XCTAssertEqual(service.pendingTarget, target)
    }

    /// An open that a lost connection cut short is not reopened by a
    /// reconnect after the window: the tap is too old to open now.
    func testReconnectAfterTheWindowDoesNotReopenAnOldTap() {
        var now = ContinuousClock.now
        let (service, pending) = makeWindowedService(now: { now })
        guard let target = pending else { return XCTFail("Expected a pending target") }
        XCTAssertTrue(service.beginNotificationRoute(target))
        now = now.advanced(by: .seconds(31))
        XCTAssertFalse(service.beginNotificationRoute(target))
        XCTAssertNil(service.pendingTarget)
    }

    /// A reconnect inside the window still opens the tap.
    func testReconnectInsideTheWindowReopensTheTap() {
        var now = ContinuousClock.now
        let (service, pending) = makeWindowedService(now: { now })
        guard let target = pending else { return XCTFail("Expected a pending target") }
        XCTAssertTrue(service.beginNotificationRoute(target))
        now = now.advanced(by: .seconds(20))
        XCTAssertTrue(service.beginNotificationRoute(target))
        XCTAssertEqual(service.pendingTarget, target)
    }

    /// The retry the window's end scheduled fires at the deadline, and runs.
    func testRetryScheduledForTheWindowsEndStillRuns() async {
        var now = ContinuousClock.now
        let (service, pending) = makeWindowedService(now: { now })
        guard let target = pending else { return XCTFail("Expected a pending target") }
        XCTAssertTrue(service.beginNotificationRoute(target))
        now = now.advanced(by: .seconds(29))
        let attempt = service.navigationAttempt
        XCTAssertTrue(service.handleFailedNotificationRoute(target))
        await waitForNotificationRetry(service, after: attempt)
        XCTAssertEqual(service.navigationAttempt, attempt + 1)
        now = now.advanced(by: .seconds(1))
        XCTAssertTrue(service.beginNotificationRoute(target))
        XCTAssertEqual(service.pendingTarget, target)
    }

    /// A scheduled retry whose run was held back (the app was suspended
    /// when it came due) doesn't open the tap long after the window.
    func testScheduledRetryStartedLateAfterTheWindowDoesNotOpen() async {
        var now = ContinuousClock.now
        let (service, pending) = makeWindowedService(now: { now })
        guard let target = pending else { return XCTFail("Expected a pending target") }
        XCTAssertTrue(service.beginNotificationRoute(target))
        now = now.advanced(by: .seconds(29))
        let attempt = service.navigationAttempt
        XCTAssertTrue(service.handleFailedNotificationRoute(target))
        await waitForNotificationRetry(service, after: attempt)
        XCTAssertEqual(service.navigationAttempt, attempt + 1)
        now = now.advanced(by: .seconds(60))
        XCTAssertFalse(service.beginNotificationRoute(target))
        XCTAssertNil(service.pendingTarget)
    }

    /// A retry whose sleep ran out while the app was suspended wakes late:
    /// it is measured from when it came due, so past the window it doesn't open.
    func testScheduledRetryThatWokeLateAfterTheWindowDoesNotOpen() async {
        var now = ContinuousClock.now
        let (service, pending) = makeWindowedService(now: { now })
        guard let target = pending else { return XCTFail("Expected a pending target") }
        XCTAssertTrue(service.beginNotificationRoute(target))
        now = now.advanced(by: .seconds(29))
        let attempt = service.navigationAttempt
        XCTAssertTrue(service.handleFailedNotificationRoute(target))
        now = now.advanced(by: .seconds(60))
        await waitForNotificationRetry(service, after: attempt)
        XCTAssertEqual(service.navigationAttempt, attempt + 1)
        XCTAssertFalse(service.beginNotificationRoute(target))
        XCTAssertNil(service.pendingTarget)
    }

    /// A retry that came due while the app was offline is not what the late
    /// reconnect runs: past the window, that reconnect drops the tap.
    func testRetryDueWhileOfflineDoesNotOpenAfterTheWindow() async {
        var now = ContinuousClock.now
        let (service, pending) = makeWindowedService(now: { now })
        guard let target = pending else { return XCTFail("Expected a pending target") }
        XCTAssertTrue(service.beginNotificationRoute(target))
        now = now.advanced(by: .seconds(10))
        let attempt = service.navigationAttempt
        XCTAssertTrue(service.handleFailedNotificationRoute(target))
        await waitForNotificationRetry(service, after: attempt)
        XCTAssertEqual(service.navigationAttempt, attempt + 1)
        service.notificationRouteAwaitsConnection(target)
        now = now.advanced(by: .seconds(60))
        XCTAssertFalse(service.beginNotificationRoute(target))
        XCTAssertNil(service.pendingTarget)
    }

    /// A tap whose open stopped for a call waits however long the call
    /// lasts, with no retry meanwhile, and once it has ended opens with a
    /// window of its own.
    func testTapWaitingForACallOpensWithAFreshWindowOnceItEnds() async {
        var now = ContinuousClock.now
        let (service, pending) = makeWindowedService(now: { now })
        guard let target = pending else { return XCTFail("Expected a pending target") }
        XCTAssertTrue(service.beginNotificationRoute(target))
        XCTAssertTrue(service.handleFailedNotificationRoute(target))
        let attempt = service.navigationAttempt
        service.notificationRouteAwaitsCall(target)
        XCTAssertTrue(service.pendingRouteAwaitsCall)
        XCTAssertEqual(service.navigationAttempt, attempt + 1, "the route runs again, to wait there")
        await waitForNotificationRetry(service, after: attempt + 1, cap: .milliseconds(100))
        XCTAssertEqual(service.navigationAttempt, attempt + 1, "the retry that was due stood down")

        now = now.advanced(by: .seconds(600))
        XCTAssertTrue(service.beginNotificationRoute(target), "a ten-minute call still opens it")
        XCTAssertFalse(service.pendingRouteAwaitsCall)
        XCTAssertEqual(service.pendingTarget, target)
        now = now.advanced(by: .seconds(20))
        XCTAssertTrue(service.handleFailedNotificationRoute(target), "inside the new window")
        now = now.advanced(by: .seconds(11))
        XCTAssertFalse(service.beginNotificationRoute(target), "past the new window")
        XCTAssertNil(service.pendingTarget)
    }

    /// Quiet for today's retry waiting for a call replaces a tap that waits
    /// too, never one opening (a call's own included); a tap that starts
    /// waiting replaces the retry, and so does a newer tap. Whichever
    /// started waiting last owns the call's end, so only one takes the
    /// screen when it comes.
    func testQuietRetryWaitingForACallAndTapsReplaceEachOther() {
        let (service, pending) = makeWindowedService(now: { ContinuousClock.now })
        guard let opening = pending else { return XCTFail("Expected a pending target") }
        let quiet = PulseQuietTarget(dashboardID: UUID().uuidString, gatewayID: "gw-2")
        service.pulseQuietAwaitsCall(quiet)
        XCTAssertEqual(service.pendingTarget, opening, "a tap opening stays")
        XCTAssertEqual(service.pendingPulseQuiet, quiet)

        let waiting = service.pulseQuietAttempt
        service.notificationRouteAwaitsCall(opening)
        XCTAssertNil(service.pendingPulseQuiet, "the tap's open came back waiting: it replaces the retry")
        XCTAssertGreaterThan(service.pulseQuietAttempt, waiting, "and ends the wait it left running")

        service.pulseQuietAwaitsCall(quiet)
        XCTAssertNil(service.pendingTarget, "the newer retry replaces a tap that waits")

        service.receiveNotificationPayload([
            "conduit": ["session_id": "runtime-456", "type": "response_ready"] as [String: Any]
        ])
        XCTAssertNotNil(service.pendingTarget)
        XCTAssertNil(service.pendingPulseQuiet, "a newer tap replaces the retry")
    }

    /// A newer tap replaces one waiting for a call, and routes as any tap.
    func testNewTapReplacesOneWaitingForACall() {
        let (service, pending) = makeWindowedService(now: { ContinuousClock.now })
        guard let first = pending else { return XCTFail("Expected a pending target") }
        XCTAssertTrue(service.beginNotificationRoute(first))
        service.notificationRouteAwaitsCall(first)
        service.receiveNotificationPayload([
            "conduit": ["session_id": "runtime-456", "type": "response_ready"] as [String: Any]
        ])
        XCTAssertNotNil(service.pendingTarget)
        XCTAssertNotEqual(service.pendingTarget, first)
        XCTAssertFalse(service.pendingRouteAwaitsCall)
    }

    /// The route opens a tap waiting for a call only once two checks in a
    /// row find no call and Conduit on screen: a call changing hands isn't
    /// the call's end. Cancelled, it opens nothing.
    func testWaitForTheCallToEndNeedsTwoReadyChecksInARow() async {
        var readiness = [false, true, false, true, true]
        var checks = 0
        var sleeps = 0
        let ended = await PushNotificationService.waitForCallToEnd(
            interval: .seconds(1),
            isReady: {
                checks += 1
                return readiness.removeFirst()
            },
            sleep: { _ in sleeps += 1 }
        )
        XCTAssertTrue(ended)
        XCTAssertEqual(checks, 5, "a lone ready check between two calls didn't open it")
        XCTAssertEqual(sleeps, 4)
        let cancelled = await PushNotificationService.waitForCallToEnd(
            interval: .seconds(1),
            isReady: { true },
            sleep: { _ in throw CancellationError() }
        )
        XCTAssertFalse(cancelled)
    }

    /// A tap waiting for a call outlives a relaunch: closing Conduit ends a
    /// call on the phone and its notification is gone, so it waits again at
    /// the next launch, its decision card included. Opening it, or a newer
    /// tap, lets it go, and one kept past its lifetime is dropped.
    func testTapWaitingForACallWaitsAgainAfterARelaunch() {
        let kept = makeScratchDefaults("WaitingTap")
        var date = Date()
        let first = PushNotificationService(retryDelay: .zero, keptTaps: kept, date: { date })
        first.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-1",
                "profile": "work",
                "dashboard_id": UUID().uuidString,
                "type": "approval.needed",
                "decision": [
                    "kind": "approval",
                    "session_key": "runtime-1",
                    "description": "Run a dangerous shell command",
                    "choices": ["once", "deny"],
                ] as [String: Any],
            ] as [String: Any],
        ])
        guard let target = first.pendingTarget, target.decision != nil else {
            return XCTFail("Expected a pending target with its decision")
        }
        XCTAssertTrue(first.beginNotificationRoute(target))
        XCTAssertNil(kept.data(forKey: PushNotificationService.waitingTapKey), "only a tap waiting for a call is kept")
        first.notificationRouteAwaitsCall(target)

        date = date.addingTimeInterval(3600)
        let relaunched = PushNotificationService(retryDelay: .zero, keptTaps: kept, date: { date })
        XCTAssertEqual(relaunched.pendingTarget, target, "the same tap, decision and all")
        XCTAssertTrue(relaunched.pendingRouteAwaitsCall)
        XCTAssertTrue(relaunched.beginNotificationRoute(target), "it opens once there's no call")
        XCTAssertNil(kept.data(forKey: PushNotificationService.waitingTapKey), "opening lets it go")

        relaunched.notificationRouteAwaitsCall(target)
        relaunched.receiveNotificationPayload([
            "conduit": ["session_id": "runtime-2", "type": "response.ready"] as [String: Any]
        ])
        XCTAssertNil(kept.data(forKey: PushNotificationService.waitingTapKey), "a newer tap replaces it")
        guard let newer = relaunched.pendingTarget else { return XCTFail("Expected the newer tap") }
        XCTAssertTrue(relaunched.beginNotificationRoute(newer))
        relaunched.notificationRouteAwaitsCall(newer)
        date = date.addingTimeInterval(PushNotificationService.waitingTapLifetime)
        let late = PushNotificationService(retryDelay: .zero, keptTaps: kept, date: { date })
        XCTAssertNil(late.pendingTarget, "too old to switch workspace for")
        XCTAssertNil(kept.data(forKey: PushNotificationService.waitingTapKey))
    }

    /// Quiet for today's retry waiting for a call waits again after a
    /// relaunch, as a tap does, but only on the day it was pressed: it was
    /// Quiet for that day, so a call or a relaunch past midnight drops it.
    func testQuietRetryWaitingForACallWaitsAgainAfterARelaunchThatDay() {
        let kept = makeScratchDefaults("WaitingPulseQuiet")
        guard let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()),
              let lateEvening = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: noon) else {
            return XCTFail("Expected today's noon and late evening")
        }
        var date = noon
        let first = PushNotificationService(retryDelay: .zero, keptTaps: kept, date: { date })
        let quiet = PulseQuietTarget(dashboardID: UUID().uuidString, gatewayID: "gw-2")
        first.pulseQuietAwaitsCall(quiet)

        date = noon.addingTimeInterval(3600)
        let relaunched = PushNotificationService(retryDelay: .zero, keptTaps: kept, date: { date })
        XCTAssertEqual(relaunched.pendingPulseQuiet, quiet)
        XCTAssertEqual(relaunched.pulseQuietAttempt, 1, "its wait starts again")
        XCTAssertTrue(relaunched.takePendingPulseQuiet(quiet), "it goes through that day")
        XCTAssertNil(kept.data(forKey: PushNotificationService.waitingPulseQuietKey), "going through lets it go")

        relaunched.pulseQuietAwaitsCall(quiet)
        let waiting = relaunched.pulseQuietAttempt
        relaunched.receiveNotificationPayload([
            "conduit": ["session_id": "runtime-2", "type": "response.ready"] as [String: Any]
        ])
        XCTAssertNil(relaunched.pendingPulseQuiet)
        XCTAssertNil(kept.data(forKey: PushNotificationService.waitingPulseQuietKey), "a newer tap replaces it")
        XCTAssertGreaterThan(relaunched.pulseQuietAttempt, waiting, "and ends the wait it left running")

        relaunched.pulseQuietAwaitsCall(quiet)
        date = date.addingTimeInterval(PushNotificationService.waitingTapLifetime)
        XCTAssertNil(PushNotificationService(retryDelay: .zero, keptTaps: kept, date: { date }).pendingPulseQuiet,
                     "too old, as a tap would be")
        XCTAssertNil(kept.data(forKey: PushNotificationService.waitingPulseQuietKey))

        date = lateEvening
        relaunched.pulseQuietAwaitsCall(quiet)
        date = lateEvening.addingTimeInterval(3600)
        XCTAssertNil(PushNotificationService(retryDelay: .zero, keptTaps: kept, date: { date }).pendingPulseQuiet,
                     "pressed yesterday: the day it was for has ended")
        XCTAssertNil(kept.data(forKey: PushNotificationService.waitingPulseQuietKey))
        XCTAssertFalse(relaunched.takePendingPulseQuiet(quiet), "nor does a call past midnight carry it over")
        XCTAssertNil(relaunched.pendingPulseQuiet)
    }

    /// Closed between keeping a tap that starts waiting and dropping the
    /// retry it replaces, Conduit finds both kept: only the tap, the newer,
    /// waits again, so the two don't both take the screen when the call ends.
    func testARelaunchKeepsOnlyTheNewerOfAWaitingTapAndRetry() {
        let kept = makeScratchDefaults("WaitingTapAndPulseQuiet")
        let date = Date()
        let first = PushNotificationService(retryDelay: .zero, keptTaps: kept, date: { date })
        first.pulseQuietAwaitsCall(PulseQuietTarget(dashboardID: UUID().uuidString, gatewayID: "gw-2"))
        let keptQuiet = kept.data(forKey: PushNotificationService.waitingPulseQuietKey)
        XCTAssertNotNil(keptQuiet)
        first.receiveNotificationPayload([
            "conduit": ["session_id": "runtime-1", "type": "response.ready"] as [String: Any]
        ])
        guard let tap = first.pendingTarget else { return XCTFail("Expected the newer tap") }
        XCTAssertTrue(first.beginNotificationRoute(tap))
        first.notificationRouteAwaitsCall(tap)
        kept.set(keptQuiet, forKey: PushNotificationService.waitingPulseQuietKey)

        let relaunched = PushNotificationService(retryDelay: .zero, keptTaps: kept, date: { date })
        XCTAssertEqual(relaunched.pendingTarget, tap)
        XCTAssertNil(relaunched.pendingPulseQuiet, "the older retry stays dropped")
        XCTAssertNil(kept.data(forKey: PushNotificationService.waitingPulseQuietKey))
    }

    func testSessionNormalizationDoesNotInventOwnershipWithoutFallback() {
        let sessions = MessageNormalizer.normalizeSessions(
            .object([
                "sessions": .array([
                    .object(["id": .string("unowned-session")])
                ])
            ]),
            profile: nil
        )

        XCTAssertNil(sessions.first?.profile)
    }

    func testSessionNormalizationPreservesMessageCount() {
        let sessions = MessageNormalizer.normalizeSessions(
            .object([
                "sessions": .array([
                    .object([
                        "id": .string("empty-shadow"),
                        "profile": .string("default"),
                        "message_count": .number(0)
                    ]),
                    .object([
                        "id": .string("real-session"),
                        "profile": .string("secondary"),
                        "messageCount": .string("4")
                    ])
                ])
            ]),
            profile: nil
        )

        XCTAssertEqual(sessions.compactMap(\.messageCount), [0, 4])
    }

    func testRuntimeSnapshotReadsSessionYoloOverrideSeparatelyFromProfileDefault() {
        let snapshot = SessionRuntimeSnapshot(object: [
            "yolo": .bool(false),
            "approvals_mode": .string("off")
        ])

        XCTAssertEqual(snapshot.yolo, false)
        XCTAssertEqual(snapshot.approvalsMode, "off")
    }

    func testProjectTreeNormalizationUsesServerOwnedPreviews() {
        let projects = MessageNormalizer.normalizeProjects(
            .object([
                "projects": .array([
                    .object([
                        "id": .string("__no_project__"),
                        "label": .string("Home"),
                        "path": .string("/workspace"),
                        "is_no_project": .bool(true),
                        "session_count": .number(2),
                        "preview_sessions": .array([
                            .object([
                                "id": .string("detached"),
                                "title": .string("Plan the trip")
                            ])
                        ])
                    ])
                ])
            ]),
            profile: "default"
        )

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].id, "__no_project__")
        XCTAssertTrue(projects[0].isHome)
        XCTAssertEqual(projects[0].primaryPath, "/workspace")
        XCTAssertEqual(projects[0].sessionCount, 2)
        XCTAssertEqual(projects[0].previewSessions.map(\.title), ["Plan the trip"])
    }

    func testProjectTreeMarksAutoDiscoveredReposAsNotEditable() {
        let projects = MessageNormalizer.normalizeProjects(
            .object([
                "projects": .array([
                    .object(["id": .string("p1"), "label": .string("Skunkworks"), "isAuto": .bool(false)]),
                    .object(["id": .string("auto:repo"), "label": .string("repo"), "isAuto": .bool(true)])
                ])
            ]),
            profile: "default"
        )

        XCTAssertEqual(projects.map(\.isAuto), [false, true])
    }

    func testOnlyCreatedProjectIDsAreEditableWhenTheFlagIsMissing() {
        // Created projects are `p_<hex>`; without the flag, any other id
        // counts as auto so editability fails closed.
        let projects = MessageNormalizer.normalizeProjects(
            .object([
                "projects": .array([
                    .object(["id": .string("p_1a2b3c4d"), "label": .string("Skunkworks")]),
                    .object(["id": .string("/srv/repos/conduit"), "label": .string("conduit")]),
                    .object(["id": .string("auto:repo"), "label": .string("repo")]),
                    .object(["id": .string("__no_project__"), "label": .string("Home"), "is_no_project": .bool(true)])
                ])
            ]),
            profile: "default"
        )

        XCTAssertEqual(projects.map(\.isAuto), [false, true, true, false], "Home is not an auto repo")
    }

    func testProjectWithoutPrimaryPathAnchorsAtFirstRepoRoot() {
        // `projects.tree` emits `path: null` for an explicit project whose
        // primary_path was never set, but still seeds its folders as repos.
        let projects = MessageNormalizer.normalizeProjects(
            .object([
                "projects": .array([
                    .object([
                        "id": .string("p_multi"),
                        "label": .string("Multi"),
                        "path": .null,
                        "isNoProject": .bool(false),
                        "sessionCount": .number(0),
                        "repos": .array([
                            .object(["id": .string("r0"), "label": .string("none"), "path": .null]),
                            .object(["id": .string("rn"), "label": .string("bad"), "path": .number(7)]),
                            .object(["id": .string("r1"), "label": .string("app"), "path": .string("/work/app")])
                        ]),
                        "previewSessions": .array([])
                    ]),
                    .object([
                        "id": .string("__no_project__"),
                        "label": .string("Home"),
                        "path": .null,
                        "isNoProject": .bool(true),
                        "repos": .array([
                            .object(["id": .string("__no_project__"), "path": .string("/should/not/use")])
                        ])
                    ])
                ])
            ]),
            profile: "default"
        )

        XCTAssertEqual(projects.map(\.id), ["p_multi", "__no_project__"])
        XCTAssertEqual(projects[0].primaryPath, "/work/app")
        XCTAssertNil(projects[1].primaryPath)
    }

    func testProjectPrimaryPathWinsOverRepoRoots() {
        let project = MessageNormalizer.normalizeProject(
            .object([
                "id": .string("p_app"),
                "label": .string("App"),
                "path": .string("/work/primary"),
                "repos": .array([
                    .object(["path": .string("/work/other")])
                ])
            ]),
            profile: "default"
        )

        XCTAssertEqual(project?.primaryPath, "/work/primary")
    }

    func testProjectSessionNormalizationKeepsWorkspaceLanes() {
        let detail = MessageNormalizer.normalizeProjectSessions(
            .object([
                "project": .object([
                    "id": .string("p_app"),
                    "label": .string("App"),
                    "repos": .array([
                        .object([
                            "label": .string("Conduit"),
                            "groups": .array([
                                .object([
                                    "id": .string("main"),
                                    "label": .string("main"),
                                    "sessions": .array([
                                        .object(["id": .string("s1"), "title": .string("Fix sidebar")])
                                    ])
                                ])
                            ])
                        ])
                    ])
                ])
            ]),
            profile: "default"
        )

        XCTAssertEqual(detail?.title, "App")
        XCTAssertEqual(detail?.lanes.map(\.title), ["main"])
        XCTAssertEqual(detail?.lanes.first?.sessions.map(\.title), ["Fix sidebar"])
    }

    func testProjectSessionLaneKeepsItsFolderPath() {
        let detail = MessageNormalizer.normalizeProjectSessions(
            .object([
                "project": .object([
                    "id": .string("p_app"),
                    "label": .string("App"),
                    "repos": .array([
                        .object([
                            "label": .string("Conduit"),
                            "groups": .array([
                                .object([
                                    "id": .string("voice"),
                                    "label": .string("voice-v2"),
                                    "path": .string("/work/app/.worktrees/voice-v2"),
                                    "sessions": .array([
                                        .object(["id": .string("s1"), "title": .string("Barge-in")])
                                    ])
                                ]),
                                .object([
                                    "id": .string("bare"),
                                    "path": .string("/work/app"),
                                    "sessions": .array([
                                        .object(["id": .string("s2"), "title": .string("Release")])
                                    ])
                                ])
                            ])
                        ])
                    ])
                ])
            ]),
            profile: "default"
        )

        XCTAssertEqual(detail?.lanes.map(\.title), ["voice-v2", "/work/app"])
        // A lane labeled by its path doesn't repeat it.
        XCTAssertEqual(detail?.lanes.map(\.path), ["/work/app/.worktrees/voice-v2", nil])
    }

    func testGeneratedSessionTitleIsNormalizedForDisplay() {
        XCTAssertEqual(
            AppState.normalizedGeneratedSessionTitle("Title: \"Plan a Garden\"\nAn explanation we should not show"),
            "Plan a Garden"
        )
        XCTAssertEqual(
            AppState.normalizedGeneratedSessionTitle("<think>I should be concise.</think>\nTitle: \"Plan a Garden\""),
            "Plan a Garden"
        )
        XCTAssertNil(AppState.normalizedGeneratedSessionTitle("   \n  "))
    }

    func testPersistedToolCallKeepsNameAndOutputWithoutRepeatingMetadataOnFinalReply() {
        let messages = MessageNormalizer.normalizeMessages([
            message(
                id: 1,
                role: "assistant",
                content: "",
                toolCalls: .array([
                    .object([
                        "id": .string("call-1"),
                        "function": .object([
                            "name": .string("execute_code"),
                            "arguments": .string("{\"code\":\"print(1)\"}")
                        ])
                    ])
                ])
            ),
            .object([
                "id": .number(2),
                "role": .string("tool"),
                "tool_call_id": .string("call-1"),
                "tool_name": .string("execute_code"),
                "content": .string("1")
            ]),
            // This mirrors an incidental object-shaped metadata field. It is
            // not a persisted assistant tool-call array and must not create a
            // duplicate card after the final reply.
            message(
                id: 3,
                role: "assistant",
                content: "Finished.",
                toolCalls: .object(["previous": .string("call-1")])
            )
        ])

        let tools = messages.filter { $0.role == .tool }
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].tool?.name, "execute_code")
        XCTAssertEqual(tools[0].tool?.output, "1")
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.content, "Finished.")
    }

    func testToolResultWithAnIDMismatchDoesNotAttachToAnotherCallByName() {
        let messages = MessageNormalizer.normalizeMessages([
            message(
                id: 1,
                role: "assistant",
                content: "",
                toolCalls: .array([
                    .object([
                        "id": .string("call-1"),
                        "function": .object([
                            "name": .string("write_file"),
                            "arguments": .string("{\"path\":\"note.txt\"}")
                        ])
                    ])
                ])
            ),
            .object([
                "id": .number(2),
                "role": .string("tool"),
                "tool_call_id": .string("different-call"),
                "tool_name": .string("write_file"),
                "content": .string("saved")
            ])
        ])

        let tools = messages.filter { $0.role == .tool }
        XCTAssertEqual(tools.count, 2)
        XCTAssertNil(tools[0].tool?.output)
        XCTAssertEqual(tools[1].tool?.name, "write_file")
        XCTAssertEqual(tools[1].tool?.output, "saved")
    }

    func testCompactResumeToolContextRemainsAnInputPreview() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "role": .string("tool"),
                "name": .string("read_file"),
                "context": .string("README.md")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].tool?.name, "read_file")
        XCTAssertEqual(messages[0].tool?.input, "README.md")
        XCTAssertNil(messages[0].tool?.output)
    }

    func testEmptyExternalMetadataDoesNotCreatePhantomAssistantHeader() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(1),
                "role": .string("user"),
                "content": .string("Hello from Discord")
            ]),
            // Some external histories append an envelope without a role or
            // visible content. It must not turn into an empty assistant row.
            .object([
                "id": .number(2),
                "source": .string("discord"),
                "metadata": .object(["channel_id": .string("123")])
            ]),
            .object([
                "id": .number(3),
                "role": .string("assistant"),
                "content": .string("Hi there.")
            ])
        ])

        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.content), ["Hello from Discord", "Hi there."])
    }

    func testDesktopImageReferenceBecomesAResumableAttachment() {
        let original = "@image:/root/.hermes/images/upload_20260729_211837_1.jpeg"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(41),
                "role": .string("user"),
                "content": .string(original)
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "")
        XCTAssertEqual(messages[0].rawContent, original)
        XCTAssertEqual(messages[0].attachments?.count, 1)
        XCTAssertEqual(messages[0].attachments?.first?.name, "upload_20260729_211837_1.jpeg")
        XCTAssertEqual(messages[0].attachments?.first?.uri, "/root/.hermes/images/upload_20260729_211837_1.jpeg")
        XCTAssertEqual(messages[0].attachments?.first?.mimeType, "image/jpeg")
        XCTAssertEqual(messages[0].attachments?.first?.kind, .image)
    }

    func testDesktopImageReferenceIsRemovedWithoutLosingCaption() {
        let original = """
        Here is the screenshot.

        @image:/root/.hermes/images/screenshot.png
        """
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .string("desktop-user-message"),
                "role": .string("user"),
                "content": .string(original)
            ])
        ])

        XCTAssertEqual(messages[0].content, "Here is the screenshot.")
        XCTAssertEqual(messages[0].rawContent, original)
        XCTAssertEqual(messages[0].attachments?.first?.name, "screenshot.png")
        XCTAssertEqual(messages[0].attachments?.first?.mimeType, "image/png")
    }

    func testStagedFileReferenceBecomesADocumentAttachment() {
        let original = """
        @file:/root/.hermes/attachments/report.pdf

        Summarise this.

        --- Attached Context ---

        📎 @file:/root/.hermes/attachments/report.pdf (application/pdf, 1.2 MB) — binary file, not inlined as text. \
        It is available on disk at `/root/.hermes/attachments/report.pdf`. Use your tools to work with it.
        """
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(61),
                "role": .string("user"),
                "content": .string(original)
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "Summarise this.")
        XCTAssertEqual(messages[0].rawContent, original)
        XCTAssertEqual(messages[0].attachments?.count, 1)
        XCTAssertEqual(messages[0].attachments?.first?.name, "report.pdf")
        XCTAssertEqual(messages[0].attachments?.first?.uri, "/root/.hermes/attachments/report.pdf")
        XCTAssertEqual(messages[0].attachments?.first?.mimeType, "application/pdf")
        XCTAssertEqual(messages[0].attachments?.first?.kind, .document)
    }

    func testQuotedFileReferenceKeepsTheWholeName() {
        let original = """
        @file:`/root/.hermes/attachments/Q3 Report.pdf`
        @file:/root/.hermes/attachments/notes.txt

        --- Attached Context ---

        📎 @file:`/root/.hermes/attachments/Q3 Report.pdf` (application/pdf, 80 KB) — binary file.
        """
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(62),
                "role": .string("user"),
                "content": .string(original)
            ])
        ])

        XCTAssertEqual(messages[0].content, "")
        XCTAssertEqual(messages[0].attachments?.map(\.name), ["Q3 Report.pdf", "notes.txt"])
        XCTAssertEqual(messages[0].attachments?.map(\.uri), [
            "/root/.hermes/attachments/Q3 Report.pdf",
            "/root/.hermes/attachments/notes.txt"
        ])
    }

    func testFilesAndImagesFromOneTurnBothBecomeAttachments() {
        let original = """
        @file:/root/.hermes/attachments/notes.txt

        Look at both

        --- Attached Context ---

        📌 @file:/root/.hermes/attachments/notes.txt (3 tokens)
        hello
        @image:/root/.hermes/images/upload_20261006_1.png
        """
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(63),
                "role": .string("user"),
                "content": .string(original)
            ])
        ])

        XCTAssertEqual(messages[0].content, "Look at both")
        XCTAssertEqual(messages[0].attachments?.map(\.name), ["notes.txt", "upload_20261006_1.png"])
        XCTAssertEqual(messages[0].attachments?.map(\.kind), [Attachment.Kind.document, .image])
    }

    func testFileReferenceTypedInTheTextStaysInTheText() {
        let original = """
        Compare @file:src/main.py with the spec

        --- Context Warnings ---
        - @file:src/main.py: file not found
        """
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(64),
                "role": .string("user"),
                "content": .string(original)
            ])
        ])

        XCTAssertEqual(messages[0].content, "Compare @file:src/main.py with the spec")
        XCTAssertEqual(messages[0].rawContent, original)
        XCTAssertNil(messages[0].attachments)
    }

    func testContextHeadingTypedWithoutAReferenceStays() {
        let original = """
        Hermes printed this:

        --- Attached Context ---

        and then stopped.
        """
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(65),
                "role": .string("user"),
                "content": .string(original)
            ])
        ])

        XCTAssertEqual(messages[0].content, original)
        XCTAssertNil(messages[0].attachments)
    }

    func testFileAttachReplyWithoutAFileReferenceUsesThePath() {
        XCTAssertEqual(
            HermesClient.fileAttachmentReference(from: .object([
                "ref_path": .string("/root/.hermes/attachments/report.pdf"),
                "ref_text": .string("report.pdf")
            ])),
            "@file:/root/.hermes/attachments/report.pdf",
            "A ref_text that isn't an @file: reference gives way to the staged path"
        )
        XCTAssertEqual(
            HermesClient.fileAttachmentReference(from: .object([
                "path": .string("/root/.hermes/attachments/report.pdf")
            ])),
            "@file:/root/.hermes/attachments/report.pdf"
        )
    }

    func testContextFooterBelowAnyHermesReferenceIsDropped() {
        for typed in [
            "Summarise @url:https://example.com/post",
            "Review @diff please",
            "Read @file:\"notes/Q3 plan.md\""
        ] {
            let original = "\(typed)\n\n--- Attached Context ---\n\n🌐 expanded content"
            let messages = MessageNormalizer.normalizeMessages([
                .object([
                    "id": .number(66),
                    "role": .string("user"),
                    "content": .string(original)
                ])
            ])
            XCTAssertEqual(messages[0].content, typed, typed)
        }
    }

    func testFileAttachReplyGivesThePromptReference() {
        XCTAssertEqual(
            HermesClient.fileAttachmentReference(from: .object([
                "attached": .bool(true),
                "path": .string("/root/.hermes/attachments/Q3 Report.pdf"),
                "ref_text": .string("@file:`/root/.hermes/attachments/Q3 Report.pdf`")
            ])),
            "@file:`/root/.hermes/attachments/Q3 Report.pdf`"
        )
        XCTAssertEqual(
            HermesClient.fileAttachmentReference(from: .object([
                "attached": .bool(true),
                "path": .string("/root/.hermes/attachments/Q3 Report.pdf")
            ])),
            "@file:`/root/.hermes/attachments/Q3 Report.pdf`",
            "A reply without ref_text still names the staged file"
        )
        XCTAssertNil(HermesClient.fileAttachmentReference(from: .object(["attached": .bool(true)])))
        XCTAssertEqual(HermesClient.formatReferenceValue("/tmp/a.pdf"), "/tmp/a.pdf")
        XCTAssertEqual(HermesClient.formatReferenceValue("/tmp/it's `odd`.pdf"), "\"/tmp/it's `odd`.pdf\"")
    }

    func testModelRuntimeNoticeBecomesACompactSystemActivity() {
        let original = """
        [System: The active model for this chat has changed to glm-5.2 via provider zai. From this point forward, use this runtime metadata when answering questions about what model/provider is active.]
        """
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(52),
                "role": .string("user"),
                "content": .string(original)
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "[Model has been changed to zai/glm-5.2]")
        XCTAssertEqual(messages[0].rawContent, original)
    }

    func testOrdinaryModelDiscussionRemainsAUserMessage() {
        let content = "The active model for this chat has changed, right?"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(53),
                "role": .string("user"),
                "content": .string(content)
            ])
        ])

        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, content)
        XCTAssertNil(messages[0].rawContent)
    }

    func testClarifyActivityAcceptsNativeStringChoices() {
        let activity = MessageNormalizer.clarifyActivity(from: [
            "request_id": .string("clarify-1"),
            "question": .string("Which environment should I use?"),
            "choices": .array([.string("Staging"), .string("Production")])
        ])

        XCTAssertEqual(activity?.requestId, "clarify-1")
        XCTAssertEqual(activity?.questions.count, 1)
        XCTAssertEqual(activity?.questions[0].question, "Which environment should I use?")
        XCTAssertEqual(activity?.questions[0].choices.map(\.label), ["Staging", "Production"])
        XCTAssertEqual(activity?.questions[0].choices.map(\.value), ["Staging", "Production"])
    }

    func testClarifyActivityKeepsLegacyStructuredChoices() {
        let activity = MessageNormalizer.clarifyActivity(from: [
            "requestId": .string("clarify-2"),
            "prompt": .string("Pick one"),
            "options": .array([
                .object(["label": .string("Use current branch"), "value": .string("current")])
            ])
        ])

        XCTAssertEqual(activity?.requestId, "clarify-2")
        XCTAssertEqual(activity?.questions[0].question, "Pick one")
        XCTAssertEqual(activity?.questions[0].choices, [ClarifyChoice(label: "Use current branch", value: "current")])
    }

    func testClarifyActivityNormalizesLegacyScalarIntoOneQuestionBatch() {
        // The legacy scalar payload must normalize into the SAME batch model
        // the current questions[] protocol produces — one internal shape, no
        // parallel scalar implementation.
        let activity = MessageNormalizer.clarifyActivity(from: [
            "request_id": .string("clarify-3"),
            "question": .string("Solo"),
            "choices": .array([.string("a")])
        ])
        XCTAssertEqual(activity?.questions.count, 1)
        XCTAssertEqual(activity?.displayQuestion, "Solo")
        XCTAssertEqual(activity?.correlationQuestion, "Solo")
        XCTAssertEqual(activity?.status, .pending)
    }

    func testClarifyActivityParsesCurrentBatchQuestionsProtocol() {
        let activity = MessageNormalizer.clarifyActivity(from: [
            "request_id": .string("req-1"),
            "questions": .array([
                .object([
                    "qid": .string("environment"),
                    "question": .string("Which environment?"),
                    "choices": .array([.string("staging"), .string("prod")]),
                    "multi_select": .bool(false)
                ]),
                .object([
                    "qid": .string("tests"),
                    "question": .string("Which tests should run?"),
                    "choices": .array([.string("unit"), .string("integration"), .string("ui")]),
                    "multi_select": .bool(true)
                ]),
                .object([
                    "qid": .string("notes"),
                    "question": .string("Any additional notes?"),
                    "choices": .array([])
                ])
            ])
        ])

        XCTAssertEqual(activity?.questions.map(\.id), ["environment", "tests", "notes"])
        XCTAssertEqual(activity?.displayQuestion, "Which environment?\nWhich tests should run?\nAny additional notes?")
        XCTAssertEqual(activity?.correlationQuestion, "Which environment?", "Supersede correlation uses the first question, matching the notifier's reduction")
        XCTAssertEqual(activity?.questions[1].multiSelect, true)
        XCTAssertEqual(activity?.questions[2].choices.isEmpty, true)
    }

    func testPendingClarifyActivityRestoresAnswersKeyedByQID() {
        let activity = MessageNormalizer.pendingClarifyActivity(from: [
            "request_id": .string("req-batch"),
            "questions": .array([
                .object([
                    "qid": .string("environment"),
                    "question": .string("Which environment?"),
                    "choices": .array([.string("staging"), .string("prod")]),
                    "multi_select": .bool(false)
                ]),
                .object([
                    "qid": .string("notes"),
                    "question": .string("Notes?"),
                    "choices": .array([])
                ])
            ]),
            "answers": .object(["environment": .string("staging")])
        ])

        XCTAssertEqual(activity?.requestId, "req-batch")
        XCTAssertEqual(activity?.questions[0].status, .answered, "Answers locked before the detach restore locked")
        XCTAssertEqual(activity?.questions[0].answer, "staging")
        XCTAssertEqual(activity?.questions[1].status, .pending)
    }

    func testPendingClarifyActivityRestoresAFieldLeftBlankAsSkipped() {
        // Hermes keeps a form's blank field locked with null (or an empty
        // answer): it restores skipped, never reopened.
        let activity = MessageNormalizer.pendingClarifyActivity(from: [
            "request_id": .string("req-form"),
            "questions": .array([
                .object(["qid": .string("from"), "question": .string("Leaving from?"), "choices": .array([])]),
                .object(["qid": .string("budget"), "question": .string("Budget?"), "choices": .array([])]),
                .object(["qid": .string("who"), "question": .string("Who's going?"), "choices": .array([])])
            ]),
            "answers": .object(["from": .null, "budget": .string("")])
        ])

        XCTAssertEqual(activity?.questions[0].status, .answered)
        XCTAssertEqual(activity?.questions[0].isSkipped, true)
        XCTAssertEqual(activity?.questions[1].isSkipped, true)
        XCTAssertEqual(activity?.questions[2].status, .pending, "A qid Hermes didn't list is still open")
    }

    func testPendingClarifyActivityWithoutAnswersLeavesEverythingAnswerable() {
        let activity = MessageNormalizer.pendingClarifyActivity(from: [
            "request_id": .string("req-batch"),
            "questions": .array([
                .object(["qid": .string("a"), "question": .string("Q?"), "choices": .array([.string("x")])])
            ])
        ])
        XCTAssertEqual(activity?.questions[0].status, .pending)
    }

    func testPendingClarifyActivityAcceptsArrayValuedAnswers() {
        // A gateway may echo a locked multi-select answer as a real JSON
        // array rather than the array string the app sends; restore it either
        // way so a locked question never reopens.
        let activity = MessageNormalizer.pendingClarifyActivity(from: [
            "request_id": .string("req-batch"),
            "questions": .array([
                .object([
                    "qid": .string("tests"),
                    "question": .string("Which tests?"),
                    "choices": .array([.string("unit"), .string("ui")]),
                    "multi_select": .bool(true)
                ])
            ]),
            "answers": .object(["tests": .array([.string("unit"), .string("ui")])])
        ])

        XCTAssertEqual(activity?.questions[0].status, .answered)
        XCTAssertEqual(activity?.questions[0].resolvedAnswer, "unit, ui")
    }

    func testPendingClarifyActivityRejectsPayloadWithoutQuestions() {
        XCTAssertNil(MessageNormalizer.pendingClarifyActivity(from: [
            "request_id": .string("req-1")
        ]))
    }

    func testNotificationPayloadBatchClarifyDeduplicatesIdentities() {
        // Duplicate qids and duplicate choice values collapse (first wins) —
        // they would render as duplicate Identifiable rows and answer
        // ambiguously per question.
        let service = PushNotificationService(retryDelay: .zero)
        defer {
            if let target = service.pendingTarget {
                service.clearPendingTarget(target)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-1",
                "profile": "default",
                "type": "input.needed",
                "decision": [
                    "kind": "clarify",
                    "request_id": "conduit-push-dedupe",
                    "questions": [
                        ["qid": "q0", "question": "Which environment?", "choices": ["staging", "staging", "prod"], "multi_select": false],
                        ["qid": "q0", "question": "Duplicate qid dropped", "choices": ["x"], "multi_select": false],
                        ["qid": "q1", "question": "Which tests?", "choices": ["unit", "ui"], "multi_select": true],
                    ] as [[String: Any]],
                ] as [String: Any],
            ] as [String: Any],
        ])

        guard case let .clarifyBatch(requestId, questions) = service.pendingTarget?.decision else {
            return XCTFail("Expected a batch clarify decision carried on the notification target")
        }
        XCTAssertEqual(requestId, "conduit-push-dedupe")
        XCTAssertEqual(questions.map(\.id), ["q0", "q1"], "duplicate qids collapse to the first occurrence")
        XCTAssertEqual(questions[0].choices.map(\.value), ["staging", "prod"], "duplicate choice values collapse")
        XCTAssertEqual(questions[0].question, "Which environment?", "the surviving qid keeps the FIRST entry's text")
    }

    func testRelayTransportPolicyRequiresHTTPSExceptLoopback() {
        func url(_ string: String) -> URL { URL(string: string)! }
        // HTTPS is always allowed.
        XCTAssertTrue(RelayTransportPolicy.allowsCredentialTransport(url("https://push.milim.dev/v1/meta")))
        // The pairing credential is a bearer secret: arbitrary cleartext
        // relays are refused.
        XCTAssertFalse(RelayTransportPolicy.allowsCredentialTransport(url("http://push.milim.dev/v1/meta")))
        XCTAssertFalse(RelayTransportPolicy.allowsCredentialTransport(url("http://192.168.1.10:8080/v1/meta")))
        XCTAssertFalse(RelayTransportPolicy.allowsCredentialTransport(url("ftp://push.milim.dev")))
        // Bounded development exception: a loopback relay never exposes the
        // credential off the machine.
        XCTAssertTrue(RelayTransportPolicy.allowsCredentialTransport(url("http://localhost:8080/v1/meta")))
        XCTAssertTrue(RelayTransportPolicy.allowsCredentialTransport(url("http://127.0.0.1:9000/v1/decisions/x/respond")))
        XCTAssertTrue(RelayTransportPolicy.allowsCredentialTransport(url("http://[::1]:8080/v1/meta")))
    }

    func testConfiguredRelayURLFallsBackToDefaultWhenBlank() {
        let fallback = PushNotificationService.defaultRelayURL
        XCTAssertEqual(fallback.absoluteString, "https://push.milim.dev")
        XCTAssertEqual(PushNotificationService.configuredRelayURL(from: nil), fallback)
        XCTAssertEqual(PushNotificationService.configuredRelayURL(from: ""), fallback)
        XCTAssertEqual(PushNotificationService.configuredRelayURL(from: "  \n"), fallback)
        XCTAssertEqual(PushNotificationService.configuredRelayURL(from: "https:"), fallback, "a value with no host is never used as the relay")
        XCTAssertEqual(
            PushNotificationService.configuredRelayURL(from: " https://relay.example.com "),
            URL(string: "https://relay.example.com")!
        )
    }

    func testCredentialRequestsGoToIssuingRelayNotConfiguredOne() {
        let configured = URL(string: "https://relay-b.example.com")!
        XCTAssertEqual(
            PushNotificationService.requestRelayURL(issuer: "https://relay-a.example.com", configured: configured),
            URL(string: "https://relay-a.example.com")!,
            "a registration's credential never follows an edited Settings value"
        )
        XCTAssertEqual(
            PushNotificationService.requestRelayURL(issuer: nil, configured: configured),
            configured,
            "with no registration the configured relay applies"
        )
        XCTAssertNil(
            PushNotificationService.requestRelayURL(issuer: "", configured: configured),
            "an issuer that doesn't parse sends the credential nowhere, never to the configured relay"
        )
        XCTAssertNil(
            PushNotificationService.requestRelayURL(issuer: "https:", configured: configured),
            "an issuer that parses but names no host is just as unusable"
        )
        XCTAssertFalse(
            PushNotificationService.isSameRelay("https:", configured),
            "an unusable issuer never matches, so Settings offers a move that recovers"
        )
        XCTAssertFalse(
            RelayTransportPolicy.allowsCredentialTransport(PushNotificationService.unusableRelayURL),
            "the stand-in for an unusable issuer must be refused before any request is sent"
        )
    }

    func testSameRelayIgnoresCosmeticDifferences() {
        func same(_ issuer: String, _ configured: String) -> Bool {
            PushNotificationService.isSameRelay(issuer, URL(string: configured)!)
        }
        XCTAssertTrue(same("https://relay.example.com", "https://relay.example.com/"))
        XCTAssertTrue(same("https://relay.example.com", "HTTPS://Relay.Example.com"))
        XCTAssertTrue(same("https://relay.example.com", "https://relay.example.com:443"))
        XCTAssertTrue(same("https://relay.example.com/push", "https://relay.example.com/push/"))
        XCTAssertFalse(same("https://relay.example.com", "https://other.example.com"))
        XCTAssertFalse(same("https://relay.example.com", "http://relay.example.com"))
        XCTAssertFalse(same("https://relay.example.com", "https://relay.example.com:8443"))
        XCTAssertFalse(same("https://relay.example.com", "https://relay.example.com/push"))
        XCTAssertFalse(PushNotificationService.isSameRelay(nil, URL(string: "https://relay.example.com")!))
    }

    func testRelayInputValidationRejectsValuesThatWouldFallBackSilently() {
        XCTAssertTrue(PushNotificationService.isValidRelayInput(""), "blank means the default relay")
        XCTAssertTrue(PushNotificationService.isValidRelayInput("  "))
        XCTAssertTrue(PushNotificationService.isValidRelayInput("https://relay.example.com"))
        XCTAssertTrue(PushNotificationService.isValidRelayInput(" http://localhost:8080 "), "loopback HTTP is the development exception")
        XCTAssertFalse(PushNotificationService.isValidRelayInput("http://relay.example.com"), "cleartext relays would be refused after saving")
        XCTAssertFalse(PushNotificationService.isValidRelayInput("my relay.com"))
        XCTAssertFalse(PushNotificationService.isValidRelayInput("relay.example.com"), "a bare host has no scheme")
        XCTAssertFalse(PushNotificationService.isValidRelayInput("ftp://relay.example.com"))
        XCTAssertFalse(PushNotificationService.isValidRelayInput("https://"))
    }

    func testApprovalActivityNormalizesGatewayChoices() {
        let activity = MessageNormalizer.approvalActivity(
            from: [
                "command": .string("rm -rf /tmp/cache"),
                "description": .string("Remove a temporary cache"),
                "choices": .array([.string("once"), .string("session"), .string("once"), .string("deny")]),
                "allow_permanent": .bool(false),
                "smart_denied": .bool(true)
            ],
            sessionId: "runtime-approval-1"
        )

        XCTAssertEqual(activity?.sessionId, "runtime-approval-1")
        XCTAssertEqual(activity?.command, "rm -rf /tmp/cache")
        XCTAssertEqual(activity?.description, "Remove a temporary cache")
        XCTAssertEqual(activity?.choices, ["once", "session", "deny"])
        XCTAssertFalse(activity?.allowPermanent ?? true)
        XCTAssertTrue(activity?.smartDenied ?? false)
        XCTAssertEqual(activity?.status, .pending)
    }

    func testApprovalActivityKeepsFallbackDescriptionForSparseGatewayEvent() {
        let activity = MessageNormalizer.approvalActivity(
            from: [:],
            sessionId: "runtime-approval-2"
        )

        XCTAssertEqual(activity?.description, "Approval required")
        XCTAssertEqual(activity?.choices, nil)
        XCTAssertTrue(activity?.allowPermanent ?? false)
    }

    func testRuntimeSystemNoticeDoesNotRenderAsAUserMessage() {
        let original = "[System: The previous response was cut off by a network error mid-stream. Continue exactly where you left off.]"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(61),
                "role": .string("user"),
                "content": .string(original)
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "The previous response was cut off by a network error mid-stream. Continue exactly where you left off.")
        XCTAssertEqual(messages[0].rawContent, original)
    }

    // MARK: - Persisted context-compaction summaries

    func testPersistedCompactionSummaryFlaggedByMetadataIsOmitted() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(81),
                "role": .string("user"),
                "_compressed_summary": .bool(true),
                "content": .string("[CONTEXT COMPACTION 12:04 — 48% of window used]")
            ]),
            // The flag may survive only inside the record's metadata object
            // after a persistence round-trip.
            .object([
                "id": .number(82),
                "role": .string("user"),
                "metadata": .object(["_compressed_summary": .bool(true)]),
                "content": .string("Summary of the session so far without the top-level flag")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testPersistedCompactionSummaryRecognizedByCurrentPrefixWithoutMetadata() {
        // Large on purpose: the prefix detector must decide from a bounded
        // head without copying a summary-sized payload.
        let largeSummary = "[CONTEXT COMPACTION 12:04 — 48% of window used]\n"
            + String(repeating: "The user asked about the deploy pipeline and a config bug was fixed. ", count: 20_000)
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(83),
                "role": .string("user"),
                "content": .string(largeSummary)
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testPersistedLegacyContextSummaryPrefixIsOmitted() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(84),
                "role": .string("user"),
                "content": .string("[CONTEXT SUMMARY]: Earlier the user asked about the deploy pipeline.")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testPersistedCompactionSummaryIsOmittedRegardlessOfRole() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(85),
                "role": .string("assistant"),
                "_compressed_summary": .bool(true),
                "content": .string("Summary of everything the assistant did so far in this session.")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testMergedPriorContextRecordKeepsOnlyGenuineUserContent() {
        let genuine = "This is the user's real message."
        let merged = "[PRIOR CONTEXT — for reference only; not a new message]\n\n"
            + genuine
            + "\n\n[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\n\n"
            + "[CONTEXT COMPACTION 12:04]\n"
            + String(repeating: "Summary of the prior turns. ", count: 1_000)
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(86),
                "role": .string("user"),
                "content": .string(merged)
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, genuine)
        XCTAssertFalse(messages[0].content.contains("PRIOR CONTEXT"))
        XCTAssertFalse(messages[0].content.contains("COMPACTION"))
    }

    func testMergedCompactionRecordWithoutGenuineContentIsOmitted() {
        let merged = "[PRIOR CONTEXT — for reference only; not a new message]\n\n"
            + "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\n\n"
            + "[CONTEXT SUMMARY]: Everything before this point.\n"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(87),
                "role": .string("user"),
                "content": .string(merged)
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testMergedRecordWhosePrefixIsItselfASummaryIsOmitted() {
        // Double compaction: the row above the delimiter is an older summary,
        // not a genuine prompt. Splitting at the delimiter alone would keep
        // the older summary as a visible bubble.
        let merged = "[CONTEXT COMPACTION 12:04]\n"
            + String(repeating: "Prior summary of the session. ", count: 2_000)
            + "\n\n[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\n\n"
            + "[CONTEXT COMPACTION 12:05]\n"
            + String(repeating: "Newer summary of the session. ", count: 2_000)
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(91),
                "role": .string("user"),
                "content": .string(merged)
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testMergedRecordKeepsGenuineContentEvenWhenFlagged() {
        // The flag marks the row as carrying a summary, not as lacking a
        // genuine prompt; the merged split still owns it.
        let genuine = "Rebuild the release after the config change."
        let merged = "[PRIOR CONTEXT — for reference only; not a new message]\n\n"
            + genuine
            + "\n\n[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\n\n"
            + "[CONTEXT COMPACTION 12:04]\nSummary follows."
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(92),
                "role": .string("user"),
                "_compressed_summary": .bool(true),
                "content": .string(merged)
            ])
        ])

        XCTAssertEqual(messages.map(\.content), [genuine])
    }

    func testBareDelimiterRecordWithEmptyPrefixIsOmitted() {
        let merged = "\n\n[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\n\n"
            + "[CONTEXT SUMMARY]: Everything before this point.\n"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(93),
                "role": .string("user"),
                "content": .string(merged)
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testDelimiterRecordWithoutWrapperKeepsGenuineContent() {
        // The wrapper header is optional; the delimiter alone marks the merge.
        let genuine = "Please rerun the migration tests."
        let merged = genuine
            + "\n\n[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\n\n"
            + "[CONTEXT COMPACTION 12:04]\nSummary follows."
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(95),
                "role": .string("user"),
                "content": .string(merged)
            ])
        ])

        XCTAssertEqual(messages.map(\.content), [genuine])
    }

    func testQuotedWrapperInsideGenuineContentIsPreserved() {
        // The wrapper is only stripped as a leading header; a copy the user
        // quoted mid-message belongs to their message.
        let genuine = "The transcript marker looks like this:\n"
            + "[PRIOR CONTEXT — for reference only; not a new message]\n"
            + "and then my question follows."
        let merged = genuine
            + "\n\n[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\n\n"
            + "[CONTEXT COMPACTION 12:04]\nSummary follows."
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(96),
                "role": .string("user"),
                "content": .string(merged)
            ])
        ])

        XCTAssertEqual(messages.map(\.content), [genuine])
    }

    func testToolResultContainingCompactionDelimiterIsNotTruncated() {
        // Compaction artifacts ride conversational roles; a tool output that
        // merely prints the delimiter text must keep its full content.
        let output = "grep results:\n[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\nmatched 3 lines"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(94),
                "role": .string("tool"),
                "tool_call_id": .string("call-9"),
                "tool_name": .string("run_grep"),
                "content": .string(output)
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .tool)
        XCTAssertEqual(messages[0].tool?.output, output)
    }

    func testOrdinaryCompactionDiscussionIsNotHidden() {
        let content = "Can you explain how context compaction works?"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(88),
                "role": .string("user"),
                "content": .string(content)
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, content)
    }

    func testLargePersistedCompactionSummaryNeverReachesChatMessages() {
        // A multi-megabyte summary must be dropped during normalization, not
        // handed to the Markdown/UI rendering pipeline as a user bubble.
        let hugeSummary = "[CONTEXT COMPACTION 12:04]\n"
            + String(repeating: "The session covered implementation details and open questions. ", count: 30_000)
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(89),
                "role": .string("user"),
                "_compressed_summary": .bool(true),
                "content": .string(hugeSummary)
            ]),
            .object([
                "id": .number(90),
                "role": .string("assistant"),
                "content": .string("Still here after the summary was dropped.")
            ])
        ])

        XCTAssertEqual(messages.map(\.role), [.assistant])
        XCTAssertEqual(messages.first?.content, "Still here after the summary was dropped.")
    }

    func testLargeStandalonePrefixSummaryIsDroppedByPrefixAlone() {
        // No flag and no merged delimiter anywhere: classification must rest
        // on the prefix alone, without the full-payload delimiter search.
        let hugeSummary = "[CONTEXT COMPACTION 12:04 — 48% of window used]\n"
            + String(repeating: "Turn summary with no merged marker in the body. ", count: 100_000)
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(97),
                "role": .string("user"),
                "content": .string(hugeSummary)
            ]),
            .object([
                "id": .number(98),
                "role": .string("assistant"),
                "content": .string("Neighbor row survives.")
            ])
        ])

        XCTAssertEqual(messages.map(\.content), ["Neighbor row survives."])
    }

    func testCompactionPrefixHelperClassifiesFromABoundedHead() {
        // Multi-megabyte payloads must be classifiable from their head
        // without trimming or copying the whole string.
        let hugeTail = String(repeating: "Summary detail line. ", count: 250_000)

        XCTAssertTrue(MessageNormalizer.hasCompactionSummaryPrefix(
            "[CONTEXT COMPACTION 12:04]\n" + hugeTail + "\n  \n"
        ))
        XCTAssertTrue(MessageNormalizer.hasCompactionSummaryPrefix(
            "\n\t  [context summary]: legacy opening\n" + hugeTail
        ))
        XCTAssertTrue(MessageNormalizer.hasCompactionSummaryPrefix(
            "[Recent Summary (d0, node 342)]\n" + hugeTail
        ))
        // The Recent Summary anchor includes the opening parenthesis, so a
        // different bracketed notice with the same words stays visible.
        XCTAssertFalse(MessageNormalizer.hasCompactionSummaryPrefix(
            "[Recent Summary quoted without the node anchor]?\n" + hugeTail
        ))
        XCTAssertFalse(MessageNormalizer.hasCompactionSummaryPrefix(
            "Can you explain how context compaction works?\n" + hugeTail
        ))
        XCTAssertFalse(MessageNormalizer.hasCompactionSummaryPrefix("   \n\t"))
        XCTAssertFalse(MessageNormalizer.hasCompactionSummaryPrefix(""))
    }

    // MARK: - Hermes "Recent Summary" headers (third compaction generation)

    func testPersistedRecentSummaryHeaderIsOmittedForUserRecord() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(101),
                "role": .string("user"),
                "content": .string("[Recent Summary (d0, node 342)]\nEarlier the user asked about the deploy pipeline.")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testPersistedRecentSummaryHeaderIsOmittedRegardlessOfRole() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(102),
                "role": .string("assistant"),
                "content": .string("[Recent Summary (d0, node 342)]\nSummary of the assistant's prior turns.")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testRecentSummaryHeaderWithLeadingWhitespaceIsOmitted() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(103),
                "role": .string("user"),
                "content": .string("   \n\t[Recent Summary (d0, node 342)]\nSummary follows.")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testRecentSummaryHeaderAcceptsArbitraryDepthAndNodeNumbers() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(104),
                "role": .string("user"),
                "content": .string("[Recent Summary (d1, node 17)]\nSummary A.")
            ]),
            .object([
                "id": .number(105),
                "role": .string("assistant"),
                "content": .string("[Recent Summary (d12, node 9001)]\nSummary B.")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testRecentSummaryHeaderIsCaseInsensitive() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(106),
                "role": .string("user"),
                "content": .string("[recent summary (d0, node 342)]\nSummary follows.")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testOrdinaryRecentSummaryDiscussionIsNotHidden() {
        let content = "Can you explain what [Recent Summary (d0, node 342)] means?"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(107),
                "role": .string("user"),
                "content": .string(content)
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, content)
    }

    func testRecentSummaryMentionLaterInMessageIsNotHidden() {
        // Detection stays start-anchored: a header quoted later inside a
        // normal message belongs to the user's own text.
        let content = "My transcript shows a header like\n"
            + "[Recent Summary (d0, node 342)]\n"
            + "mid-session — what produces it?"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(108),
                "role": .string("user"),
                "content": .string(content)
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, content)
    }

    func testLargeRecentSummaryNeverReachesChatMessages() {
        // A multi-megabyte Recent Summary must be dropped by the bounded
        // prefix check alone — no flag, no merged delimiter in the body —
        // so it never reaches the Markdown/UI rendering pipeline.
        let hugeSummary = "[Recent Summary (d2, node 1188)]\n"
            + String(repeating: "The session covered implementation details and open questions. ", count: 30_000)
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(109),
                "role": .string("user"),
                "content": .string(hugeSummary)
            ]),
            .object([
                "id": .number(110),
                "role": .string("assistant"),
                "content": .string("Still here after the recent summary was dropped.")
            ])
        ])

        XCTAssertEqual(messages.map(\.role), [.assistant])
        XCTAssertEqual(messages.first?.content, "Still here after the recent summary was dropped.")
    }

    func testMergedRecentSummaryBehindWrapperNeverReachesChatMessages() {
        // Second compaction: a merged row whose retained prefix is itself a
        // generation-3 summary must be dropped after the delimiter split,
        // not kept as a visible bubble above the newest summary.
        let merged = "[PRIOR CONTEXT — for reference only; not a new message]\n"
            + "[Recent Summary (d0, node 342)]\n"
            + "Earlier turns, compacted.\n"
            + "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\n"
            + "Newest compacted turns."
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(111),
                "role": .string("user"),
                "content": .string(merged)
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testInterruptedIdenticalCorrectionDoesNotCreateASecondUserBubble() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(71),
                "role": .string("user"),
                "content": .string("Don't set it up now")
            ]),
            .object([
                "id": .number(72),
                "role": .string("assistant"),
                "content": .string("[This response was interrupted by a user correction.]")
            ]),
            .object([
                "id": .number(73),
                "role": .string("user"),
                "content": .string("Don't set it up now")
            ])
        ])

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.role), [.user, .system])
        XCTAssertEqual(messages.last?.content, "Response interrupted by a user correction.")
    }

    // MARK: - Hermes display projection (display_kind / display_content)

    /// Hermes persists some model-facing rows as `role=user` for provider
    /// history semantics while `display_kind`/`display_content` tell clients
    /// how they must actually be presented. Conduit must honor that contract
    /// at the normalization boundary instead of mapping the physical role
    /// straight onto a human user bubble.

    func testSteerRowStaysUserRowWithMarkerRemoved() {
        // Hermes persists a mid-turn steer as its own user row, wrapped in
        // the out-of-band marker the model trusts (issue #337).
        let marker = "\n\n[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]\nUse the staging database instead\n[/OUT-OF-BAND USER MESSAGE]"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(310),
                "role": .string("user"),
                "content": .string(marker),
                "display_kind": .string("steer")
            ])
        ])

        let row = messages.first
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(row?.role, .user)
        XCTAssertEqual(row?.content, "Use the staging database instead")
        XCTAssertEqual(row?.isSteer, true)
    }

    func testVisibleUserTextMovesImageTokensOut() {
        XCTAssertEqual(
            MessageNormalizer.visibleUserText("Here is the screenshot.\n@image:/root/x.png")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "Here is the screenshot."
        )
        XCTAssertEqual(MessageNormalizer.visibleUserText("No images"), "No images")
    }

    func testSteerTextWithoutMarkerIsKept() {
        XCTAssertEqual(MessageNormalizer.steerText(fromMarker: "  plain steer \n"), "plain steer")
    }

    func testOrdinaryUserRowIsNotSteer() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(311),
                "role": .string("user"),
                "content": .string("Hello")
            ])
        ])

        XCTAssertEqual(messages.first?.isSteer, false)
    }

    func testHiddenUserRowIsDroppedEntirely() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(301),
                "role": .string("user"),
                "content": .string("INTERNAL MODEL SCAFFOLD"),
                "display_kind": .string("hidden")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testHiddenAssistantRowIsDroppedEntirely() {
        // Hiding is a property of the row, not of its physical role.
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(302),
                "role": .string("assistant"),
                "content": .string("Interrupted-turn checkpoint payload"),
                "display_kind": .string("hidden")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testHiddenRowWithDisplayContentIsStillDropped() {
        // Explicit hiding wins over any projection: upstream only co-locates
        // these when the row must not be shown at all.
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(303),
                "role": .string("user"),
                "content": .string("internal carrier"),
                "display_content": .string("Supposedly visible"),
                "display_kind": .string("hidden")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testHiddenRowIsDroppedBeforeLargeBodyIsProcessed() {
        // The hidden verdict must come from the metadata alone — a
        // multi-megabyte model-facing body is never scanned or copied.
        let hugeBody = "[CONTEXT COMPACTION 12:04]\n"
            + String(repeating: "Compacted scaffold body. ", count: 30_000)
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(304),
                "role": .string("user"),
                "content": .string(hugeBody),
                "display_kind": .string("hidden")
            ]),
            .object([
                "id": .number(305),
                "role": .string("assistant"),
                "content": .string("Neighbor row survives.")
            ])
        ])

        XCTAssertEqual(messages.map(\.content), ["Neighbor row survives."])
    }

    func testDisplayContentOverridesPhysicalCarrier() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(306),
                "role": .string("user"),
                "content": .string("internal summary scaffold\n\nREAL ASK"),
                "display_content": .string("REAL ASK")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "REAL ASK")
        XCTAssertFalse(messages[0].content.contains("scaffold"))
    }

    func testDisplayContentWinsOverCompactionCarrierWithoutDroppingTheRow() {
        // Ordering: the physical content contains a legacy compaction
        // delimiter, but the explicit projection is authoritative — the row
        // must present the projected prompt, not be discarded wholesale.
        let carrier = "Pull the logs before triage.\n\n"
            + "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\n\n"
            + "[CONTEXT COMPACTION 12:04]\n"
            + String(repeating: "Summary body. ", count: 2_000)
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(307),
                "role": .string("user"),
                "content": .string(carrier),
                "display_content": .string("Pull the logs before triage.")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "Pull the logs before triage.")
    }

    func testDisplayContentWinsOverCompressedSummaryFlag() {
        // The REST projection keeps `_compressed_summary` metadata on a
        // recovered carrier row; the flag must not discard the projected ask.
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(308),
                "role": .string("user"),
                "content": .string("Summary of prior turns."),
                "metadata": .object(["_compressed_summary": .bool(true)]),
                "display_content": .string("The actual recovered ask.")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "The actual recovered ask.")
    }

    func testDisplayContentWinsEvenWhenProjectedTextStartsWithACompactionHeader() {
        // The compatibility filters never re-judge projected text: only rows
        // lacking display metadata are subject to the summary-prefix guard.
        let projected = "[CONTEXT COMPACTION 12:04]\nServer-declared visible text."
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(330),
                "role": .string("user"),
                "content": .string("physical carrier"),
                "display_content": .string(projected)
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, projected)
    }

    func testExplicitEmptyDisplayContentNeverFallsBackToPhysicalContent() {
        // Field presence — not a non-empty value — makes the projection
        // authoritative. The genuinely empty row follows the existing
        // empty-message rules, but the physical carrier must never reappear.
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(309),
                "role": .string("user"),
                "content": .string("DO NOT SHOW ME"),
                "display_content": .string("")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "")
        XCTAssertFalse(
            messages.contains { $0.content.contains("DO NOT SHOW ME") },
            "The physical content must never resurface behind an empty projection"
        )
    }

    func testAutoContinueKindProjectsToSystemTimelineNotice() {
        let scaffold = "[System note: Your previous turn was interrupted mid-run. Resuming from the last checkpoint.]"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(310),
                "role": .string("user"),
                "content": .string(scaffold),
                "display_kind": .string("auto_continue")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].displayKind, "auto_continue")
        XCTAssertEqual(messages[0].content, "Resumed interrupted turn")
        XCTAssertFalse(messages[0].content.contains("System note"))
    }

    func testModelSwitchKindKeepsExistingModelChangePresentation() {
        // The persisted marker rides as role=user; display_kind makes the
        // timeline outcome explicit while the existing model-change card
        // detection (driven by rawContent in ChatView) keeps working.
        let marker = "[System: The active model for this chat has changed to GLM-5.3-Flash via provider zai. From this point forward, use this runtime metadata when answering questions about what model/provider is active.]"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(311),
                "role": .string("user"),
                "content": .string(marker),
                "display_kind": .string("model_switch")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].displayKind, "model_switch")
        XCTAssertEqual(messages[0].content, "[Model has been changed to zai/GLM-5.3-Flash]")
        XCTAssertNotNil(
            MessageNormalizer.modelChangeActivity(fromText: messages[0].rawContent ?? messages[0].content),
            "ChatView's model-change card detection must still fire for the projected row"
        )
    }

    func testModelSwitchKindWithUnrecognizedTextFallsBackToCannedNotice() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(312),
                "role": .string("user"),
                "content": .string("model runtime pivot"),
                "display_kind": .string("model_switch")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "Model changed")
    }

    func testModelSwitchKindPrefersExplicitDisplayContentOverMarkerCard() {
        // When Hermes explicitly projects display content onto a model_switch
        // row, that copy is authoritative even over the marker-derived card.
        let marker = "[System: The active model for this chat has changed to GLM-5.3-Flash via provider zai. From this point forward, use this runtime metadata when answering questions about what model/provider is active.]"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(331),
                "role": .string("user"),
                "content": .string(marker),
                "display_content": .string("Switched to GLM-5.3-Flash via zai."),
                "display_kind": .string("model_switch")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "Switched to GLM-5.3-Flash via zai.")
    }

    func testKnownKindOnAssistantRowStillProjectsToTimeline() {
        // Upstream only ever tags user rows, but the projection is a property
        // of the row: a known synthetic kind never stays a human turn.
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(332),
                "role": .string("assistant"),
                "content": .string("[System note: Your previous turn was interrupted mid-run.]"),
                "display_kind": .string("auto_continue")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "Resumed interrupted turn")
    }

    func testDisplayKindMatchingToleratesSurroundingWhitespaceOnly() {
        // Whitespace around the canonical value is trimmed; case is matched
        // exactly like Hermes Desktop, so casing drift stays conservative.
        let trimmed = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(333),
                "role": .string("user"),
                "content": .string("scaffold"),
                "display_kind": .string("  hidden  ")
            ])
        ])
        let wrongCase = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(334),
                "role": .string("assistant"),
                "content": .string("Visible assistant text"),
                "display_kind": .string("Hidden")
            ])
        ])

        XCTAssertTrue(trimmed.isEmpty)
        XCTAssertEqual(wrongCase.count, 1)
        XCTAssertEqual(wrongCase[0].role, .assistant)
    }

    func testPersonalitySwitchKindProjectsToTimelineNoticeWithoutPersonaScaffold() {
        let marker = "[System: The user has changed the assistant's personality. From this point forward, adopt the following persona and respond accordingly: You are a terse pirate first mate.]"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(313),
                "role": .string("user"),
                "content": .string(marker),
                "display_kind": .string("personality_switch")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].displayKind, "personality_switch")
        XCTAssertEqual(messages[0].content, "Personality changed")
        XCTAssertFalse(messages[0].content.contains("pirate"))
    }

    func testAsyncDelegationCompleteUsesObjectMetadataTaskCount() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(314),
                "role": .string("user"),
                "content": .string("Background delegation report scaffold"),
                "display_kind": .string("async_delegation_complete"),
                "display_metadata": .object(["task_count": .number(2)])
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "2 background agents finished")
        XCTAssertFalse(messages[0].content.contains("scaffold"))
    }

    func testAsyncDelegationCompleteUsesSingularForOneTask() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(315),
                "role": .string("user"),
                "content": .string("Background delegation report scaffold"),
                "display_kind": .string("async_delegation_complete"),
                "display_metadata": .object(["task_count": .number(1)])
            ])
        ])

        XCTAssertEqual(messages[0].content, "1 background agent finished")
    }

    func testAsyncDelegationCompleteParsesJSONStringMetadata() {
        // Older backends serve display_metadata as unparsed JSON text.
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(316),
                "role": .string("user"),
                "content": .string("Background delegation report scaffold"),
                "display_kind": .string("async_delegation_complete"),
                "display_metadata": .string("{\"task_count\": 3, \"failed_count\": 0}")
            ])
        ])

        XCTAssertEqual(messages[0].content, "3 background agents finished")
    }

    func testAsyncDelegationCompleteMalformedMetadataDegradesToGenericNotice() {
        let variants: [AnyCodable] = [
            .string("{definitely not json"),
            .array([.number(1), .number(2)]),
            .object(["task_count": .string("two")]),
            .object(["task_count": .number(0)]),
            .object(["task_count": .number(-1)]),
            .object(["task_count": .number(2.5)]),
            .null
        ]
        for (index, metadata) in variants.enumerated() {
            let messages = MessageNormalizer.normalizeMessages([
                .object([
                    "id": .number(Double(320 + index)),
                    "role": .string("user"),
                    "content": .string("Background delegation report scaffold"),
                    "display_kind": .string("async_delegation_complete"),
                    "display_metadata": metadata
                ])
            ])

            XCTAssertEqual(messages.count, 1, "variant \(index) must still produce its notice")
            XCTAssertEqual(messages[0].role, .system, "variant \(index) must not stay a user bubble")
            XCTAssertEqual(
                messages[0].content,
                "Background agent work finished",
                "variant \(index) must degrade to the generic label"
            )
        }
    }

    func testAsyncDelegationCompleteKeepsLocalizedCountOverStampedDisplayText() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(330),
                "role": .string("user"),
                "content": .string("[ASYNC DELEGATION COMPLETE scaffold]"),
                "display_kind": .string("async_delegation_complete"),
                "display_metadata": .object([
                    "task_count": .number(1),
                    "display_text": .string("Subagent Task Completed: Tidy the notes")
                ])
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "1 background agent finished")
    }

    func testAsyncDelegationCompleteUsesDisplayTextWithoutCount() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(333),
                "role": .string("user"),
                "content": .string("[ASYNC DELEGATION COMPLETE scaffold]"),
                "display_kind": .string("async_delegation_complete"),
                "display_metadata": .object([
                    "display_text": .string("Subagent Task Completed: Tidy the notes")
                ])
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "Subagent Task Completed: Tidy the notes")
    }

    /// Hermes (2026-09-13) types background-process completion turns as
    /// `process_complete` and stamps a compact title; the model-facing output
    /// wall must never render as a user bubble.
    func testProcessCompleteRendersItsStampedTitleAsSystemNotice() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(331),
                "role": .string("user"),
                "content": .string("[IMPORTANT: Background process proc_1 completed normally (exit code 0). Command: make. Output: scaffold]"),
                "display_kind": .string("process_complete"),
                "display_metadata": .object([
                    "display_text": .string("Background Process Finished: make")
                ])
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].displayKind, "process_complete")
        XCTAssertEqual(messages[0].content, "Background Process Finished: make")
        XCTAssertFalse(messages[0].content.contains("scaffold"))
    }

    func testProcessCompleteWithoutTitleFallsBackToGenericNotice() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(332),
                "role": .string("user"),
                "content": .string("[IMPORTANT: Background process proc_2 completed. Output: scaffold]"),
                "display_kind": .string("process_complete"),
                "display_metadata": .object(["display_text": .string("   ")])
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "Background process finished")
    }

    /// The unprefixed review fallback belongs to the `review.summary` stream
    /// event only: a persisted system row is never reclassified as a review.
    func testPersistedSystemRowIsNotAReviewCard() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(334),
                "role": .string("system"),
                "content": .string("Workspace switched to /srv/app")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertNil(messages[0].review)
    }

    func testInternalNotificationKindNeverRendersAsHumanUser() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(324),
                "role": .string("user"),
                "content": .string("Background watch fired: nightly build finished."),
                "display_kind": .string("internal_notification")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].displayKind, "internal_notification")
        XCTAssertEqual(messages[0].content, "Background watch fired: nightly build finished.")
    }

    func testInternalNotificationKindStripsSystemWrapper() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(325),
                "role": .string("user"),
                "content": .string("[System: Resume wake-up notice for the scheduled task.]"),
                "display_kind": .string("internal_notification")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "Resume wake-up notice for the scheduled task.")
    }

    func testUnknownDisplayKindPreservesTheRowConservatively() {
        // A future kind must neither crash normalization nor delete or
        // reinterpret an otherwise ordinary visible row.
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(326),
                "role": .string("assistant"),
                "content": .string("Visible assistant text"),
                "display_kind": .string("future_kind")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .assistant)
        XCTAssertEqual(messages[0].content, "Visible assistant text")
        XCTAssertNil(messages[0].displayKind)
    }

    func testUnknownDisplayKindStillHonorsDisplayContent() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(327),
                "role": .string("user"),
                "content": .string("physical carrier"),
                "display_content": .string("Projected ask"),
                "display_kind": .string("future_kind")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "Projected ask")
    }

    func testToolRowsKeepLegacyHandlingAgainstDisplayFields() {
        // A tool row carrying display-shaped fields must not be rewritten:
        // upstream only ever projects conversational rows, so the tool card
        // keeps its own output exactly.
        let output = "grep results:\n[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\nmatched 3 lines"
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(328),
                "role": .string("tool"),
                "tool_call_id": .string("call-301"),
                "tool_name": .string("run_grep"),
                "content": .string(output),
                "display_content": .string("Tampered projection"),
                "display_kind": .string("model_switch")
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .tool)
        XCTAssertEqual(messages[0].tool?.output, output)
        XCTAssertEqual(messages[0].tool?.name, "run_grep")
        XCTAssertNil(messages[0].displayKind)
    }

    func testHiddenToolRowIsStillDropped() {
        // Hiding is explicit presentation semantics for the row and applies
        // regardless of physical role — the same rule the gateway's resume
        // projection applies to every role.
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(329),
                "role": .string("tool"),
                "tool_call_id": .string("call-302"),
                "tool_name": .string("read_file"),
                "content": .string("internal checkpoint payload"),
                "display_kind": .string("hidden")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testKindRowWithoutProjectionYieldsToLegacyCompactionFilter() {
        // Precedence pin: a synthetic row lacking display_content still goes
        // through the legacy filters, so a pure summary carrier is dropped
        // whole instead of being replaced by the canned notice.
        let carrier = "[CONTEXT COMPACTION 12:04]\n"
            + String(repeating: "Summary body. ", count: 2_000)
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(340),
                "role": .string("user"),
                "content": .string(carrier),
                "display_kind": .string("auto_continue")
            ])
        ])

        XCTAssertTrue(messages.isEmpty)
    }

    func testMalformedScalarDisplayContentNeverFallsBackToPhysicalCarrier() {
        // Field presence is the authority boundary: a stray scalar is an
        // explicit (odd) projection resolving to empty text, never a reason
        // to reveal the physical carrier.
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(341),
                "role": .string("user"),
                "content": .string("DO NOT SHOW PHYSICAL"),
                "display_content": .number(42)
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "")
        XCTAssertFalse(
            messages.contains { $0.content.contains("DO NOT SHOW PHYSICAL") },
            "The physical content must never resurface behind a malformed projection"
        )
    }

    func testExplicitNullDisplayContentNeverFallsBackToPhysicalContent() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(342),
                "role": .string("user"),
                "content": .string("DO NOT SHOW PHYSICAL"),
                "display_content": .null
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "")
        XCTAssertFalse(
            messages.contains { $0.content.contains("DO NOT SHOW PHYSICAL") },
            "An explicit null projection must not expose the physical content"
        )
    }

    func testExplicitEmptyProjectionOnTimelineKindRemainsAuthoritative() {
        // For synthetic kinds an empty projection must not be trimmed back
        // into absence: that would substitute canned labels or fall through
        // to the physical synthetic payload.
        let rows: [(Double, String, String)] = [
            (343, "internal_notification", "DO NOT SHOW PHYSICAL"),
            (344, "auto_continue", "AUTO CONTINUE INTERNAL SCAFFOLD"),
            (346, "model_switch", "DO NOT SHOW PHYSICAL"),
            (347, "personality_switch", "DO NOT SHOW PHYSICAL"),
            (348, "async_delegation_complete", "DO NOT SHOW PHYSICAL")
        ]
        for (id, kind, carrier) in rows {
            let messages = MessageNormalizer.normalizeMessages([
                .object([
                    "id": .number(id),
                    "role": .string("user"),
                    "content": .string(carrier),
                    "display_kind": .string(kind),
                    "display_content": .string("")
                ])
            ])

            XCTAssertEqual(messages.count, 1, kind)
            XCTAssertEqual(messages[0].role, .system, kind)
            XCTAssertEqual(messages[0].content, "", kind)
            XCTAssertFalse(
                messages.contains { $0.content.contains(carrier) },
                "\(kind): the physical payload must never resurface"
            )
        }
    }

    func testHugeTaskCountDegradesToGenericNoticeWithoutTrapping() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(345),
                "role": .string("user"),
                "content": .string("Background delegation report scaffold"),
                "display_kind": .string("async_delegation_complete"),
                "display_metadata": .object(["task_count": .number(1e100)])
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "Background agent work finished")
    }

    private func message(
        id: Double,
        role: String,
        content: String,
        toolCalls: AnyCodable
    ) -> AnyCodable {
        .object([
            "id": .number(id),
            "role": .string(role),
            "content": .string(content),
            "tool_calls": toolCalls
        ])
    }

    // MARK: - Approval text shows every scalar

    func testApprovalTextShowsRightToLeftOverride() {
        XCTAssertEqual(
            ApprovalDisplayText.revealingHidden("cat notes\u{202E}txt.hs | sh"),
            "cat notes<U+202E>txt.hs | sh"
        )
    }

    func testApprovalTextShowsZeroWidthAndTagCharacters() {
        XCTAssertEqual(
            ApprovalDisplayText.revealingHidden("ls\u{200B}\u{E0072}\u{E006D}"),
            "ls<U+200B><U+E0072><U+E006D>"
        )
    }

    func testApprovalTextShowsControlCharactersButKeepsLayout() {
        XCTAssertEqual(
            ApprovalDisplayText.revealingHidden("echo a\tb\nprintf x\r\nclear\u{1B}[2J\rok"),
            "echo a\tb\nprintf x\r\nclear<U+001B>[2J<U+000D>ok"
        )
    }

    func testApprovalTextShowsCombiningMarksPastTheCap() {
        XCTAssertEqual(
            ApprovalDisplayText.revealingHidden("a\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}b"),
            "a\u{0301}\u{0302}\u{0303}<U+0304><U+0305>b"
        )
    }

    func testApprovalTextKeepsOrdinaryTextAndEmojiSequences() {
        let text = "D\u{E9}ployer l\u{2019}app ? \u{1F469}\u{200D}\u{1F4BB} \u{2764}\u{FE0F}\u{200D}\u{1F525} \u{2014} rm -rf ./build"
        XCTAssertEqual(ApprovalDisplayText.revealingHidden(text), text)
    }

    func testApprovalTextShowsLoneJoiner() {
        XCTAssertEqual(ApprovalDisplayText.revealingHidden("rm\u{200D}-rf"), "rm<U+200D>-rf")
    }
}
