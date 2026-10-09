import Foundation

/// Pure-function stream event parser extracted from HermesClient so the
/// gateway-to-app boundary can be unit-tested without a live WebSocket.
enum StreamEventParser {
    static func parse(params: AnyCodable) -> StreamEvent? {
        guard let obj = params.objectValue else { return nil }
        let type = obj["type"]?.stringValue ?? ""
        let sessionId = obj["session_id"]?.stringValue ?? ""
        let payload = obj["payload"]?.objectValue

        // Per-type required-field guards below are intentional: some events
        // carry ids/fields their consumers require and are rejected here,
        // while others degrade to optional fields. Do not widen or narrow a
        // single guard without checking its consumers.
        switch type {
        case "message.start":
            return .messageStart(sessionId: sessionId)

        case "message.delta":
            let text = payload?["text"]?.stringValue ?? obj["text"]?.stringValue ?? ""
            if text.isEmpty { return nil }
            return .messageDelta(sessionId: sessionId, text: text)

        case "reasoning.delta", "message.reasoning", "message.reasoning.delta":
            let text: String
            if let reasoning = payload?["reasoning"]?.stringValue {
                text = reasoning
            } else if let reasoningContent = payload?["reasoning_content"]?.stringValue {
                text = reasoningContent
            } else if let payloadText = payload?["text"]?.stringValue {
                text = payloadText
            } else if let content = payload?["content"]?.stringValue {
                text = content
            } else if let reasoning = obj["reasoning"]?.stringValue {
                text = reasoning
            } else {
                text = obj["text"]?.stringValue ?? ""
            }
            if text.isEmpty { return nil }
            return .reasoningDelta(sessionId: sessionId, text: text)

        case "message.complete":
            let messageId = payload?["message_id"]?.stringValue
                ?? payload?["id"]?.stringValue
                ?? payload?["message"]?.objectValue?["id"]?.stringValue
                ?? obj["message_id"]?.stringValue
                ?? obj["id"]?.stringValue
            let content = payload?["content"]?.stringValue
                ?? payload?["text"]?.stringValue
                ?? payload?["rendered"]?.stringValue
            let reasoning = payload?["reasoning"]?.stringValue
            return .messageComplete(sessionId: sessionId, messageId: messageId, content: content, reasoning: reasoning)

        case "message.reaction":
            guard let rowId = HermesClient.exactIntValue(payload?["row_id"]), rowId > 0 else { return nil }
            return .messageReaction(
                sessionId: sessionId,
                rowId: rowId,
                reactions: MessageNormalizer.messageReactions(from: payload?["reactions"]),
                role: payload?["role"]?.stringValue ?? ""
            )

        case "error":
            return .messageError(sessionId: sessionId, message: payload?["message"]?.stringValue ?? AppLocalization.string("Hermes reported an error."))

        case "message.interrupted", "session.interrupted":
            return .messageInterrupted(sessionId: sessionId)

        case "session.busy":
            let busy = payload?["busy"]?.boolValue ?? false
            return .sessionBusy(sessionId: sessionId, busy: busy)

        case "session.info":
            return .sessionInfo(sessionId: sessionId, snapshot: SessionRuntimeSnapshot(object: payload ?? [:]))

        case "status.update":
            // A status edge without a session id cannot drive any
            // conversation-scoped state; reject it rather than letting an
            // empty key into compaction bookkeeping.
            guard !sessionId.isEmpty else { return nil }
            let kindRaw = payload?["kind"]?.stringValue ?? ""
            let kind: StatusUpdateKind
            switch kindRaw {
            case "compacting": kind = .compacting
            case "compacted": kind = .compacted
            default: kind = .other(kindRaw)
            }
            return .statusUpdate(sessionId: sessionId, kind: kind, text: payload?["text"]?.stringValue)

        case "session.title":
            let storedSessionId = payload?["session_id"]?.stringValue ?? ""
            let title = payload?["title"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !storedSessionId.isEmpty, !title.isEmpty else { return nil }
            return .sessionTitle(
                runtimeSessionId: sessionId,
                storedSessionId: storedSessionId,
                title: title
            )

        case "tool.start", "tool_call":
            let name = payload?["name"]?.stringValue ?? ""
            let toolID = ["tool_id", "tool_call_id", "call_id"]
                .compactMap { payload?[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let input = payload?["args_text"]?.descriptiveStringValue
                ?? payload?["context"]?.descriptiveStringValue
                ?? payload?["input"]?.descriptiveStringValue
                ?? payload?["arguments"]?.descriptiveStringValue
                ?? payload?["args"]?.descriptiveStringValue
            return .toolStart(sessionId: sessionId, toolName: name, toolInput: input, toolID: toolID)

        case "tool.complete", "tool_result":
            let name = payload?["name"]?.stringValue ?? ""
            let toolID = ["tool_id", "tool_call_id", "call_id"]
                .compactMap { payload?[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let output = payload?["output"]?.descriptiveStringValue ?? payload?["result"]?.descriptiveStringValue
            return .toolComplete(sessionId: sessionId, toolName: name, toolOutput: output, toolID: toolID)

        case "review.summary":
            guard let payload, let review = MessageNormalizer.reviewActivity(
                from: payload,
                eventSessionId: sessionId,
                allowUnprefixedSummary: true
            ) else { return nil }
            return .reviewSummary(sessionId: sessionId, activity: review)

        case "clarify", "clarify.request":
            guard let payload,
                  let clarify = MessageNormalizer.clarifyActivity(from: payload) else { return nil }
            return .clarify(sessionId: sessionId, activity: clarify)

        case "clarify.expire":
            let requestId = (payload?["request_id"]?.stringValue
                ?? payload?["requestId"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestId.isEmpty else { return nil }
            return .clarifyExpire(sessionId: sessionId, requestId: requestId, reason: nil)

        case "request.cancel":
            // The gateway withdrew a server→client request (timeout,
            // interrupt, shutdown). A clarify card is keyed by the server
            // request id, so it expires exactly like `clarify.expire`. An
            // approval card is keyed by its queue id, so HermesClient (which
            // holds the srq → queue id mapping) emits `.approvalWithdrawn`.
            // For a clarify, `resolved` means it was answered, never an
            // expiry. Masked input prompts expire the same way, and keep
            // `resolved` so a card another surface answered says so.
            let method = payload?["method"]?.stringValue ?? ""
            let requestId = (payload?["id"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestId.isEmpty else { return nil }
            // A missing reason is not a timeout: only the legacy
            // clarify.expire (reason nil) or an explicit "timeout" says so.
            let reason = payload?["reason"]?.stringValue ?? ""
            if method == "clarify" {
                guard reason != "resolved" else { return nil }
                return .clarifyExpire(sessionId: sessionId, requestId: requestId, reason: reason)
            }
            if InputPromptActivity.Kind(rawValue: method) != nil {
                return .inputPromptExpire(sessionId: sessionId, requestId: requestId, reason: reason)
            }
            return nil

        case "approval.request":
            guard let payload,
                  let approval = MessageNormalizer.approvalActivity(from: payload, sessionId: sessionId) else { return nil }
            return .approval(sessionId: sessionId, activity: approval)

        case "context.update", "session.context":
            let percent = payload?["context_percent"]?.doubleValue ?? 0
            let used = payload?["context_used"]?.intValue ?? 0
            let max = payload?["context_max"]?.intValue ?? 0
            return .contextUpdate(sessionId: sessionId, percent: percent, used: used, max: max)

        case "cwd.update", "workspace.update":
            let cwd = payload?["cwd"]?.stringValue ?? ""
            return .cwdUpdate(sessionId: sessionId, cwd: cwd)

        case "model.update":
            let model = payload?["model"]?.stringValue ?? ""
            let provider = payload?["provider"]?.stringValue ?? ""
            return .modelUpdate(sessionId: sessionId, model: model, provider: provider)

        case let eventType where eventType.hasPrefix("subagent."):
            guard let payload else { return nil }
            let activity = Self.delegateAgentActivity(from: payload, eventType: eventType, sessionId: sessionId)
            return .delegateAgent(sessionId: sessionId, activity: activity)

        default:
            return .unparsed(payload: obj.mapValues { $0.anyValue })
        }
    }

    private static func delegateAgentActivity(from payload: [String: AnyCodable], eventType: String, sessionId: String) -> DelegateAgentActivity {
        // Hermes names the agent `subagent_id`; every subagent.* event for one
        // agent carries it. Without it each progress event became its own
        // "Running" card (#492). Older emitters omit it: their goal and slot
        // in the batch still name one agent, within this session.
        func nonEmpty(_ key: String) -> String? {
            payload[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        let subagentID = nonEmpty("subagent_id")
        let goal = payload["goal"]?.stringValue ?? payload["task"]?.stringValue ?? ""
        let taskIndex = payload["task_index"]?.intValue ?? 0
        let delegationID = nonEmpty("delegation_id")
        // A delegation id and slot name the agent alone, so a frame that
        // omits the goal still lands on its card.
        let id = subagentID ?? nonEmpty("id") ?? nonEmpty("agent_id")
            ?? (delegationID.map { "\(sessionId)/\($0)#\(taskIndex)" } ?? "\(sessionId)/#\(taskIndex):\(goal)")
        let statusValue = payload["status"]?.stringValue ?? {
            if eventType.contains("fail") { return "failed" }
            if eventType.contains("interrupt") { return "interrupted" }
            if eventType.contains("complete") || eventType.contains("finish") { return "completed" }
            if eventType.contains("spawn") { return "queued" }
            return "running"
        }()
        let status: DelegateAgentActivity.Status
        switch statusValue.lowercased() {
        // Hermes' other terminal states.
        case "error", "timeout": status = .failed
        // An end event's status always means the agent ended.
        case let value: status = DelegateAgentActivity.Status(rawValue: value)
            ?? (eventType.contains("complete") || eventType.contains("finish") ? .completed : .running)
        }
        let text = payload["text"]?.stringValue ?? payload["message"]?.stringValue ?? payload["summary"]?.stringValue ?? ""
        let kind: DelegateAgentActivity.StreamLine.Kind = eventType.contains("tool") ? .tool : eventType.contains("thinking") ? .thinking : eventType.contains("progress") ? .progress : .summary
        let lines = text.isEmpty ? [] : [DelegateAgentActivity.StreamLine(kind: kind, text: text, isError: status == .failed)]
        return DelegateAgentActivity(
            id: id,
            // Empty when the event names no goal: the card says "Delegate agent".
            goal: goal,
            model: nonEmpty("model"),
            status: status,
            taskCount: payload["task_count"]?.intValue ?? 1,
            taskIndex: taskIndex,
            currentTool: nonEmpty("tool_name") ?? nonEmpty("tool") ?? nonEmpty("current_tool"),
            summary: nonEmpty("summary"),
            stream: lines,
            hasGatewayID: subagentID != nil
        )
    }
}
