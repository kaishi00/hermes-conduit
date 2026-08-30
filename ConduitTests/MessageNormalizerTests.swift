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
            NotificationSessionResolver.resumableSessionID(for: "runtime-123", in: [session]),
            "stored-123"
        )
    }

    func testNotificationResolverTrimsUnknownRuntimeID() {
        XCTAssertEqual(
            NotificationSessionResolver.resumableSessionID(for: "  runtime-123  ", in: []),
            "runtime-123"
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

    func testFailedNotificationRouteRetriesOnceThenClearsTarget() async {
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

        let initialAttempt = service.navigationAttempt
        XCTAssertTrue(service.handleFailedNotificationRoute(target))
        let retryDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while service.navigationAttempt == initialAttempt,
              ContinuousClock.now < retryDeadline {
            await Task.yield()
        }
        XCTAssertEqual(service.navigationAttempt, initialAttempt + 1)
        XCTAssertEqual(service.pendingTarget, target)

        XCTAssertFalse(service.handleFailedNotificationRoute(target))
        XCTAssertNil(service.pendingTarget)
        let terminalAttempt = service.navigationAttempt
        let terminalDeadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        while service.navigationAttempt == terminalAttempt,
              ContinuousClock.now < terminalDeadline {
            await Task.yield()
        }
        XCTAssertEqual(service.navigationAttempt, terminalAttempt)
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
        XCTAssertEqual(activity?.question, "Which environment should I use?")
        XCTAssertEqual(activity?.choices.map(\.label), ["Staging", "Production"])
        XCTAssertEqual(activity?.choices.map(\.value), ["Staging", "Production"])
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
        XCTAssertEqual(activity?.question, "Pick one")
        XCTAssertEqual(activity?.choices, [ClarifyChoice(label: "Use current branch", value: "current")])
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

    func testMalformedScalarDisplayContentDegradesToPhysicalCarrier() {
        // Only a textual projection is authoritative; a stray scalar is
        // malformed rather than an intentional empty projection.
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(341),
                "role": .string("user"),
                "content": .string("Genuine ask."),
                "display_content": .number(5)
            ])
        ])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "Genuine ask.")
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
}
