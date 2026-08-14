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
