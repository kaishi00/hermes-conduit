//
//  AppState+SlashCommands.swift
//  Conduit
//
//  Slash commands: the catalog, running a command on the phone or the
//  gateway, edit and resend, rewinding turns, and reloading MCP servers
//  and skills. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Slash Commands

    /// Keep the common Hermes commands discoverable even when an older gateway
    /// returns only skill entries from `commands.catalog`. Commands Conduit
    /// does not own locally still run through slash.exec / command.dispatch.
    /// Internal so localization tests can pin the protocol-value invariants
    /// (raw name/aliases, localized display copy) across every App Language.
    static var builtInSlashCommands: [SlashCommand] { [
        SlashCommand(name: "new", aliases: ["reset", "clear"], description: AppLocalization.string("Start a new conversation"), category: AppLocalization.string("Session")),
        SlashCommand(name: "branch", aliases: ["fork"], description: AppLocalization.string("Branch this conversation into a new chat"), category: AppLocalization.string("Session")),
        SlashCommand(name: "model", description: AppLocalization.string("Open the model and run settings"), category: AppLocalization.string("Session")),
        SlashCommand(name: "yolo", description: AppLocalization.string("Toggle automatic tool approval"), category: AppLocalization.string("Session")),
        SlashCommand(name: "help", aliases: ["commands"], description: AppLocalization.string("Show available slash commands"), category: AppLocalization.string("Session")),
        SlashCommand(name: "approvals", description: AppLocalization.string("Show or set approval mode"), category: "Hermes"),
        SlashCommand(name: "background", aliases: ["bg"], description: AppLocalization.string("Run a prompt in the background"), category: "Hermes"),
        SlashCommand(name: "btw", description: AppLocalization.string("Ask a side question about this chat"), category: "Hermes"),
        SlashCommand(name: "compress", aliases: ["compact"], description: AppLocalization.string("Compress this conversation context"), category: "Hermes"),
        SlashCommand(name: "debug", description: AppLocalization.string("Create a debug report"), category: "Hermes"),
        SlashCommand(name: "goal", description: AppLocalization.string("Manage this session's standing goal"), category: "Hermes"),
        SlashCommand(name: "personality", description: AppLocalization.string("Switch the session personality"), category: "Hermes"),
        SlashCommand(name: "reload-mcp", aliases: ["reload_mcp"], description: AppLocalization.string("Reload MCP servers from config"), category: "Hermes"),
        SlashCommand(name: "reload-skills", aliases: ["reload_skills"], description: AppLocalization.string("Rescan installed skills"), category: "Hermes"),
        SlashCommand(name: "queue", aliases: ["q"], description: AppLocalization.string("Queue a prompt for the next turn"), category: "Hermes"),
        SlashCommand(name: "retry", description: AppLocalization.string("Retry the last user message"), category: "Hermes"),
        SlashCommand(name: "rollback", description: AppLocalization.string("List or restore file checkpoints"), category: "Hermes"),
        SlashCommand(name: "status", description: AppLocalization.string("Show current session status"), category: "Hermes"),
        SlashCommand(name: "steer", aliases: ["s"], description: AppLocalization.string("Steer the current run"), category: "Hermes"),
        SlashCommand(name: "stop", description: AppLocalization.string("Stop the reply and background processes"), category: "Hermes"),
        SlashCommand(name: "undo", description: AppLocalization.string("Remove the last user and assistant exchange"), category: "Hermes"),
        SlashCommand(name: "usage", description: AppLocalization.string("Show this session's token usage"), category: "Hermes"),
        SlashCommand(name: "version", description: AppLocalization.string("Show the Hermes Agent version"), category: "Hermes")
    ]
    }

    /// Hermes commands its `slash.exec` refuses for a chat like Conduit's
    /// (`unsupported_command`) that Conduit has no route of its own for:
    /// the `refused` rows of Hermes' gateway command parity table
    /// (website/docs/developer-guide/gateway-command-parity.md), minus the
    /// ones `executeSlashCommand` handles. Names and aliases. They stay out
    /// of the suggestions; typed anyway, they go to Hermes, whose refusal
    /// says what to use instead. The weekly parity check
    /// (scripts/check-hermes-slash-parity.py) flags when Hermes' table and
    /// this list drift apart.
    static let slashCommandsWithoutConduitRoute: Set<String> = [
        "agents", "tasks", "battery", "browser", "config", "copy", "discard",
        "export", "focus", "handoff", "hatch", "generate-pet", "history",
        "image", "import", "indicator", "journey", "learning", "memory-graph",
        "palette", "paste", "pause", "pet", "platform", "plugins", "prompt",
        "compose", "quit", "exit", "redraw", "reload", "restart", "resume", "rewind",
        "save", "sessions", "sethome", "set-home", "skin",
        "snapshot", "snap", "start", "statusbar", "sb", "subscription",
        "upgrade", "timestamps", "ts", "tools", "topic", "update",
        "wake", "worktree"
    ]

    /// Commands Conduit runs itself without Hermes' subcommands: Conduit's
    /// `/queue` only adds a message (Queue, #842); listing or editing
    /// Hermes' queue (`/queue list`, …) runs in Hermes' own clients only.
    private static let slashCommandsWithoutHermesSubcommands: Set<String> = ["queue"]

    static func normalizedSlashCatalog(_ payload: AnyCodable) -> [SlashCommand] {
        let object = payload.objectValue ?? [:]
        var commands: [String: SlashCommand] = [:]

        func add(_ command: SlashCommand) {
            guard !command.name.isEmpty, commands[command.name] == nil,
                  !slashCommandsWithoutConduitRoute.contains(command.name) else { return }
            commands[command.name] = command
        }

        if let categories = object["categories"]?.arrayValue {
            for category in categories {
                guard let categoryObject = category.objectValue else { continue }
                let categoryName = categoryObject["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                for pair in categoryObject["pairs"]?.arrayValue ?? [] {
                    if let command = slashCommand(from: pair, category: categoryName) {
                        add(command)
                    }
                }
            }
        }

        for pair in object["pairs"]?.arrayValue ?? [] {
            if let command = slashCommand(from: pair, category: AppLocalization.string("Skills & extensions")) {
                add(command)
            }
        }

        if let canon = object["canon"]?.objectValue {
            for (rawAlias, rawCanonical) in canon {
                let alias = normalizedSlashName(rawAlias)
                let canonical = normalizedSlashName(rawCanonical.stringValue ?? "")
                guard !alias.isEmpty, alias != canonical, var command = commands[canonical] else { continue }
                if !command.aliases.contains(alias) {
                    command.aliases.append(alias)
                    command.aliases.sort()
                    commands[canonical] = command
                }
            }
        }

        for builtin in builtInSlashCommands {
            if commands[builtin.name] == nil {
                commands[builtin.name] = builtin
            }
        }

        return commands.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `commands.catalog`'s `sub` ("/fast" → ["normal", "fast", …]) by bare
    /// command name. Where a command's `commands` entry narrows its words
    /// for a client (`desktop_subcommands`, e.g. `/skills` without the
    /// interactive hub), the narrower list wins.
    static func slashSubcommandMap(_ payload: AnyCodable) -> [String: [String]] {
        let object = payload.objectValue ?? [:]
        let meta = object["commands"]?.objectValue ?? [:]
        var map: [String: [String]] = [:]
        for (rawName, value) in object["sub"]?.objectValue ?? [:] {
            let name = normalizedSlashName(rawName)
            guard !name.isEmpty,
                  !slashCommandsWithoutConduitRoute.contains(name),
                  !slashCommandsWithoutHermesSubcommands.contains(name) else { continue }
            let narrowed = meta["/" + name]?.objectValue?["desktop_subcommands"]?.arrayValue
            let words = (narrowed ?? value.arrayValue ?? [])
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.contains(" ") }
            if !words.isEmpty { map[name] = words }
        }
        return map.merging(conduitSlashSubcommands) { hermes, _ in hermes }
    }

    /// Argument words for commands Conduit runs itself, which Hermes'
    /// catalog lists none for: `/reload-mcp now` reloads without asking.
    static let conduitSlashSubcommands: [String: [String]] = ["reload-mcp": ["now", "always"]]

    private static func slashCommand(from value: AnyCodable, category: String?) -> SlashCommand? {
        if let pair = value.arrayValue, let rawName = pair.first?.stringValue {
            let name = normalizedSlashName(rawName)
            guard !name.isEmpty else { return nil }
            let description = pair.dropFirst().first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SlashCommand(name: name, description: description?.isEmpty == false ? description! : AppLocalization.string("Hermes command"), category: category)
        }
        guard let object = value.objectValue else { return nil }
        let name = normalizedSlashName(object["name"]?.stringValue ?? object["command"]?.stringValue ?? "")
        guard !name.isEmpty else { return nil }
        return SlashCommand(
            name: name,
            aliases: (object["aliases"]?.arrayValue ?? [])
                .compactMap { $0.stringValue }
                .map { normalizedSlashName($0) }
                .filter { !$0.isEmpty },
            description: object["description"]?.stringValue ?? object["desc"]?.stringValue ?? AppLocalization.string("Hermes command"),
            category: category,
            argsHint: object["args_hint"]?.stringValue ?? object["argsHint"]?.stringValue
        )
    }

    private static func normalizedSlashName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
            .lowercased()
    }

    static func parseSlashCommand(_ text: String) -> (name: String, argument: String, cleaned: String)? {
        let trimmed = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        guard trimmed.hasPrefix("/") else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        return (normalizedSlashName(String(first)), parts.count > 1 ? String(parts[1]) : "", cleaned)
    }

    func loadSlashCommands() async {
        guard let client else { return }
        let profile = activeProfile
        let sessionID = activeSessionId
        do {
            let result = try await client.commandsCatalog(sessionId: sessionID)
            guard profile == activeProfile, self.client === client else { return }
            lastSlashCatalogPayload = result
            slashCommands = Self.normalizedSlashCatalog(result)
            slashSubcommands = Self.slashSubcommandMap(result)
        } catch {
            // Non-fatal — keep whatever we have
        }
    }

    /// Re-resolves the slash command list after an in-app App Language
    /// change. Built-in descriptions/categories localize per call; the
    /// server catalog is a stored protocol payload (descriptions are server
    /// data and stay raw), so only the merge is re-run — no refetch.
    func appLanguageDidChange() {
        if let payload = lastSlashCatalogPayload {
            slashCommands = Self.normalizedSlashCatalog(payload)
        } else {
            slashCommands = Self.builtInSlashCommands
            slashSubcommands = Self.conduitSlashSubcommands
        }
    }

    func executeSlashCommand(
        _ text: String,
        context: ComposerSubmissionContext? = nil
    ) async {
        let submissionContext = context ?? composerSubmissionContext()
        guard isCurrentComposerSubmission(submissionContext) else { return }
        guard let client,
              let sessionId = activeSessionId,
              let command = Self.parseSlashCommand(text) else { return }

        // Client-side special cases
        switch command.name {
        case "new", "reset", "clear":
            guard !isProfileSwitching, isConnected, !isConnecting else {
                if isProfileSwitching || isConnecting {
                    errorMessage = AppLocalization.string("Wait for the workspace switch to finish before starting a conversation.")
                }
                return
            }
            // The canonical-forever-chat guard for ordinary composer input:
            // attachment-free slash commands arrive HERE, never through
            // sendMessage's reroute, so a bot's canonical chat compacts
            // instead of forking into a scratch session.
            if isCanonicalForeverChatReset(text) {
                cancelChatResumeRestoration()
                appendSlashOutput(
                    AppLocalization.string(
                        "Bot chats never reset, so this one is compacted instead: Hermes carries on from a summary with fresh context, and keeps its memory and skills. For a separate chat, start one in Chats."
                    ),
                    context: submissionContext
                )
                await compressActiveSession(
                    focusTopic: "",
                    legacyCommand: "compact",
                    client: client,
                    sessionID: sessionId,
                    context: submissionContext
                )
                return
            }
            cancelChatResumeRestoration()
            await createNewSession()
            return
        case "branch", "fork":
            guard !isBusy else {
                errorMessage = AppLocalization.string("Stop the active response before branching this conversation.")
                return
            }
            guard !isBranchingChat, !isProfileSwitching else { return }
            guard let assistantMessage = messages.last(where: { $0.role == .assistant }) else {
                errorMessage = AppLocalization.string("There is no assistant response to branch from yet.")
                return
            }
            guard let messageIndex = messages.firstIndex(where: { $0.id == assistantMessage.id }),
                  messages[...messageIndex].contains(where: { message in
                      guard message.role == .user || message.role == .assistant else {
                          return false
                      }
                      let content = (message.role == .user ? message.rawContent : nil)
                          ?? message.content
                      return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                errorMessage = AppLocalization.string("There is no message history to branch from.")
                return
            }
            cancelChatResumeRestoration()
            await branchFromAssistantMessage(assistantMessage.id)
            return
        case "model":
            if command.argument.isEmpty {
                cancelChatResumeRestoration()
                showModelPicker = true
                return
            }
        case "yolo":
            if command.argument.isEmpty {
                cancelChatResumeRestoration()
                await toggleYolo(context: submissionContext)
                return
            }
        case "help":
            cancelChatResumeRestoration()
            appendSlashOutput(Self.formatSlashHelp(), context: submissionContext)
            return
        case "background", "bg", "btw":
            // Hermes' side-agent RPCs (Desktop and TUI parity). Through
            // slash.exec the slash worker prints the answer after the call
            // has returned, so it never reaches the chat. Without text, or
            // on a gateway without the RPCs, the slash path below answers.
            guard !command.argument.isEmpty else { break }
            let kind: SideAgentKind = command.name == "btw" ? .btw : .background
            cancelChatResumeRestoration()
            do {
                if let startSideAgent = chatResumeLifecycleOperations.startSideAgent {
                    _ = try await startSideAgent(client, kind, sessionId, command.argument)
                } else {
                    _ = try await client.startSideAgent(kind, sessionId: sessionId, text: command.argument)
                }
                appendSlashOutput(
                    kind == .btw
                        ? AppLocalization.string("Answering from a snapshot of this chat. The answer will appear here.")
                        : AppLocalization.string("Started in the background. The answer will appear here."),
                    context: submissionContext
                )
                return
            } catch where HermesClient.isMissingRPCMethod(error) {
                break
            } catch {
                guard isCurrentComposerSubmission(submissionContext) else { return }
                appendSlashOutput(
                    AppLocalization.string("⚠️ Command failed: \(UserFacingError.message(for: error))"),
                    context: submissionContext
                )
                return
            }
        case "steer", "s", "queue", "q":
            _ = await submitSteerOrQueueSlash(name: command.name, argument: command.argument, context: submissionContext)
            return
        case "undo", "retry":
            // Hermes' own clients run these as a revision-fenced rewind
            // (`session.mutate`); slash.exec refuses them. A Hermes without
            // the rewind gets the command through slash.exec, as before.
            cancelChatResumeRestoration()
            guard await rewindLastTurns(
                retry: command.name == "retry",
                argument: command.argument,
                client: client,
                sessionID: sessionId,
                context: submissionContext
            ) else { break }
            return
        case "rollback":
            // Hermes' file checkpoints, which slash.exec refuses: its own
            // clients run `rollback.list|diff|restore` (Desktop's /rollback).
            // A Hermes without them gets the command through slash.exec,
            // whose refusal says so.
            cancelChatResumeRestoration()
            guard await runRollback(argument: command.argument, client: client, sessionID: sessionId, context: submissionContext) else { break }
            return
        case "stop":
            // Desktop's /stop: the running reply, then this chat's
            // background processes (`process.stop`, what Hermes' own /stop
            // means).
            cancelChatResumeRestoration()
            await stopReplyAndBackgroundProcesses(client: client, sessionID: sessionId, context: submissionContext)
            return
        case "reload-mcp", "reload_mcp":
            // Hermes' own clients run these through their own verbs;
            // slash.exec refuses both. A Hermes without the verb gets the
            // command through slash.exec, whose refusal says what to use.
            cancelChatResumeRestoration()
            guard await reloadMCPServers(
                argument: command.argument,
                client: client,
                sessionID: sessionId,
                context: submissionContext
            ) else { break }
            return
        case "reload-skills", "reload_skills":
            cancelChatResumeRestoration()
            guard await reloadSkills(client: client, sessionID: sessionId, context: submissionContext) else { break }
            return
        case "compress", "compact":
            // Dedicated `session.compress` RPC (upstream Desktop parity). Must
            // not ride the generic slash path: compression legitimately
            // outlives the request timeout, and the gateway rejects it while
            // a turn runs (4009), so unlike `branch` there is no busy guard —
            // the gateway's own answer is the accurate one.
            guard !isBranchingChat, !isProfileSwitching else { return }
            cancelChatResumeRestoration()
            await compressActiveSession(
                focusTopic: command.argument,
                legacyCommand: command.cleaned,
                client: client,
                sessionID: sessionId,
                context: submissionContext
            )
            return
        default:
            break
        }

        // Server-side execution
        cancelChatResumeRestoration()
        do {
            let result = try await executeGatewaySlash(
                client: client,
                sessionID: sessionId,
                command: command.cleaned,
                context: submissionContext
            )
            guard isCurrentComposerSubmission(submissionContext) else { return }
            await handleSlashResult(
                result,
                depth: 0,
                aliasArgument: command.argument,
                client: client,
                sessionID: sessionId,
                context: submissionContext
            )
        } catch {
            guard isCurrentComposerSubmission(submissionContext) else { return }
            appendSlashOutput(Self.slashFailureNote(command: command.name, error: error), context: submissionContext)
        }
    }

    /// Hermes' `/queue` management words. Conduit can only add to the
    /// queue (`/queue add <message>` queues the message), so these say so.
    private static let hermesQueueManagementWords: Set<String> = ["list", "edit", "rm", "move", "clear"]

    /// What a failed slash command shows. Hermes' `unsupported_command` is
    /// a refusal by design, not a failure: it says so in words, with the
    /// alternative Hermes names (`data.detail`) when it has one.
    static func slashFailureNote(command: String, error: Error) -> String {
        if let rejection = error as? RpcError, rejection.reason == "unsupported_command" || rejection.message == "unsupported_command" {
            let refusal = AppLocalization.string("Hermes doesn't run /\(command) for Conduit chats.")
            guard let detail = rejection.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else {
                return refusal
            }
            return "\(refusal)\n\(detail)"
        }
        return AppLocalization.string("⚠️ Command failed: \(UserFacingError.message(for: error))")
    }

    /// A sent message's Edit and resend (issue 1420): takes it back, with
    /// everything after it, and puts its words back in the composer ahead
    /// of whatever is typed there, its "Replying to" chip too.
    /// `confirmedLaterTurns`: the user agreed to lose the messages after it;
    /// without that, Hermes' history having any (another device's) stops it.
    func editAndResend(_ message: ChatMessage, confirmedLaterTurns: Bool) async {
        let context = composerSubmissionContext()
        guard message.role == .user, isCurrentComposerSubmission(context),
              let client, let sessionID = activeSessionId else { return }
        cancelChatResumeRestoration()
        guard await rewindLastTurns(
            retry: false,
            argument: "",
            editing: message,
            editingConfirmsLaterTurns: confirmedLaterTurns,
            client: client,
            sessionID: sessionID,
            context: context
        ) else {
            appendSlashOutput(
                AppLocalization.string("This Hermes can't take a message back. Update Hermes to edit and resend."),
                context: context
            )
            return
        }
    }

    /// The turn in `snapshot` that `message` shows: by its row id when the
    /// transcript has it, else by its words, counting the same words sent
    /// later so a repeated message finds its own turn. Nil when the
    /// snapshot doesn't hold it.
    static func rewindTurn(
        for message: ChatMessage,
        in transcript: [ChatMessage],
        snapshot: SessionRewindSnapshot
    ) -> SessionRewindSnapshot.Turn? {
        if let rowID = message.rowId {
            return snapshot.turns.first { $0.rowID == rowID }
        }
        func words(_ text: String?) -> String? {
            text?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let index = transcript.firstIndex(where: { $0.id == message.id }),
              let sent = words(message.rawContent ?? message.content), !sent.isEmpty else { return nil }
        let sentLater = transcript[(index + 1)...].filter {
            $0.role == .user && words($0.rawContent ?? $0.content) == sent
        }.count
        let matching = snapshot.turns.filter { words($0.text) == sent }
        guard matching.count > sentLater else { return nil }
        return matching[matching.count - 1 - sentLater]
    }

    /// `/undo [N]` takes back the last N user turns and everything after
    /// them, and puts the oldest one back in the composer; `/retry` takes
    /// back the last one and sends it again; `editing` takes back that
    /// message and everything after it (Edit and resend). Hermes' `_rewind`
    /// (hermes_cli/gateway_chat_commands.py): the target comes from the
    /// same `session.resume` snapshot whose fences the rewind presents.
    /// False when this Hermes has no `session.mutate`.
    private func rewindLastTurns(
        retry: Bool,
        argument: String,
        editing: ChatMessage? = nil,
        editingConfirmsLaterTurns: Bool = false,
        client: HermesClient,
        sessionID: String,
        context: ComposerSubmissionContext
    ) async -> Bool {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnCount: Int
        if retry || editing != nil || trimmed.isEmpty {
            turnCount = 1
        } else if let count = Int(trimmed), count > 0 {
            turnCount = count
        } else {
            appendSlashOutput(
                AppLocalization.string("Usage: /undo [N]. Takes back your last N messages and Hermes' replies, and puts the oldest back in the composer."),
                context: context
            )
            return true
        }
        guard !isBusy else {
            appendSlashOutput(AppLocalization.string("Wait for the reply to finish, or /stop it, then try again."), context: context)
            return true
        }
        let nothingToRewind = retry
            ? AppLocalization.string("There's no message to retry.")
            : editing != nil
            ? AppLocalization.string("Couldn't find that message in the chat's history. Open the chat again, then try once more.")
            : AppLocalization.string("There's no message to undo.")
        let receipt: SessionRewindReceipt
        let target: SessionRewindSnapshot.Turn
        // Edit and resend on an earlier message takes later turns back too.
        var takesLaterTurns = false
        // Where the words taken back go: the chat this ran in, even if
        // another opens while the rewind runs.
        let editDraftKey = durableComposerDraftKeyOnScreen
        let editDashboardID = activeDashboardID
        let editAuthorName = conversationAgentIdentity.name
        // A bot chat's transcript lives in the bot profile's store; any
        // other chat's in the workspace's, which needs no profile.
        let profile = botScopeProfile(forSessionIDs: [sessionID], workspaceProfile: activeProfile)
        do {
            let snapshot: SessionRewindSnapshot
            if let rewindSnapshot = chatResumeLifecycleOperations.rewindSnapshot {
                snapshot = try await rewindSnapshot(client, sessionID)
            } else {
                snapshot = try await client.rewindSnapshot(sessionId: sessionID, profile: profile)
            }
            guard isCurrentComposerSubmission(context) else { return true }
            if let editing {
                guard let turn = Self.rewindTurn(for: editing, in: messages, snapshot: snapshot) else {
                    appendSlashOutput(
                        AppLocalization.string("Couldn't find that message in the chat's history. Open the chat again, then try once more."),
                        context: context
                    )
                    return true
                }
                target = turn
                takesLaterTurns = turn != snapshot.turns.last
                // Messages after it that the user wasn't asked about (sent
                // from another device since): nothing is taken back. The
                // chat loads them, so the next Edit and resend asks.
                if takesLaterTurns, !editingConfirmsLaterTurns {
                    let reopened = await openSessionOutcome(context.durableSessionID ?? sessionID)
                    guard reopened != .superseded else { return true }
                    let current = composerSubmissionContext()
                    guard composerSessionIDsAreEquivalent(context.sessionID, current.sessionID)
                        || composerSessionIDsAreEquivalent(context.durableSessionID, current.sessionID) else { return true }
                    appendSlashOutput(
                        AppLocalization.string("This chat has newer messages. Try Edit and resend again to see what it takes back."),
                        context: current
                    )
                    return true
                }
            } else {
                guard snapshot.turns.count >= turnCount else {
                    appendSlashOutput(nothingToRewind, context: context)
                    return true
                }
                target = snapshot.turns[snapshot.turns.count - turnCount]
            }
            // Refused before anything is taken back, as Hermes does.
            if retry, target.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                appendSlashOutput(AppLocalization.string("/retry can only send a text message again."), context: context)
                return true
            }
            if let rewindSession = chatResumeLifecycleOperations.rewindSession {
                receipt = try await rewindSession(client, sessionID, target.rowID, snapshot)
            } else {
                receipt = try await client.rewindSession(
                    sessionId: sessionID,
                    targetMessageID: target.rowID,
                    snapshot: snapshot,
                    profile: profile
                )
            }
        } catch where HermesClient.isMissingRPCMethod(error) {
            return false
        } catch {
            appendSlashOutput(
                editing != nil
                    ? Self.editFailureNote(error: error)
                    : Self.rewindFailureNote(command: retry ? "retry" : "undo", error: error),
                context: context
            )
            return true
        }
        guard receipt.rewoundCount > 0 else {
            appendSlashOutput(nothingToRewind, context: context)
            return true
        }
        let text = receipt.text ?? target.text ?? ""
        // /undo never touches files: Hermes names the files the undone
        // turns changed and the /rollback that restores them. Read now,
        // before the chat opens again, so no wait comes between that and
        // the words going back.
        let filesLine = retry || editing != nil
            ? nil
            : await undoRollbackHint(client: client, sessionID: sessionID, target: target, profile: profile)
        // Taken back on Hermes: Edit and resend's words go back now, into
        // their own chat's draft, whatever happens to the reopen below.
        if editing != nil, !text.isEmpty {
            putRewoundTextBack(text, key: editDraftKey, dashboardID: editDashboardID, authorName: editAuthorName)
        }
        // A chat left while the rewind ran keeps an /undo's or /retry's
        // words in its draft, as Edit and resend's.
        func keepWordsInTheirChat() -> Bool {
            if editing == nil, !text.isEmpty {
                putRewoundTextBack(text, key: editDraftKey, dashboardID: editDashboardID, authorName: editAuthorName)
            }
            return true
        }
        // Hermes' files line goes under whichever note the /undo ends with.
        func withFilesLine(_ note: String) -> String {
            filesLine.map { "\(note)\n\n\($0)" } ?? note
        }
        // Open the chat again so it shows the shortened transcript.
        guard isCurrentOrAliasedComposerSubmission(context) else { return keepWordsInTheirChat() }
        let reopened = await openSessionOutcome(context.durableSessionID ?? sessionID)
        guard reopened != .superseded else { return keepWordsInTheirChat() }
        let current = composerSubmissionContext()
        // Our own open moved the viewport on, so `context` is stale by
        // construction; the rewound chat must still be the one on screen.
        guard composerSessionIDsAreEquivalent(context.sessionID, current.sessionID)
            || composerSessionIDsAreEquivalent(context.durableSessionID, current.sessionID) else { return keepWordsInTheirChat() }
        if reopened == .failed {
            // Taken back, but the chat on screen still shows it: say so,
            // and keep the words (a /retry's too) in the composer.
            appendSlashOutput(
                withFilesLine(text.isEmpty
                    ? AppLocalization.string("Took the message back, but the chat couldn't reload. Open it again to see the change.")
                    : AppLocalization.string("Took the message back, but the chat couldn't reload. Open it again to see the change. The message is in the composer.")),
                context: current
            )
            if !text.isEmpty, editing == nil { prefillComposer(text) }
            return true
        }
        if editing != nil {
            appendSlashOutput(
                text.isEmpty
                    ? AppLocalization.string("Took back your message.")
                    : takesLaterTurns
                    ? AppLocalization.string("Took back your message and everything after it. It's in the composer to edit.")
                    : AppLocalization.string("Took back your message. It's in the composer to edit."),
                context: current
            )
            return true
        }
        if retry, !composerIsEnabled {
            // Taken back, but nothing can be sent right now: keep the words.
            appendSlashOutput(
                AppLocalization.string("Took back your last message. It's in the composer to edit."),
                context: current
            )
            prefillComposer(text)
            return true
        }
        if retry {
            _ = await performComposerSubmission(
                text: text,
                attachments: [],
                submissionContext: current,
                onBusy: nil,
                busyMode: busyInputMode,
                runsSlashCommands: false
            )
            return true
        }
        guard !text.isEmpty else {
            // A turn that held more than text has nothing to put back.
            appendSlashOutput(
                withFilesLine(turnCount == 1
                    ? AppLocalization.string("Took back your last message.")
                    : AppLocalization.string("Messages taken back: \(turnCount)")),
                context: current
            )
            return true
        }
        appendSlashOutput(
            withFilesLine(turnCount == 1
                ? AppLocalization.string("Took back your last message. It's in the composer to edit.")
                : AppLocalization.string("The oldest is in the composer to edit. Messages taken back: \(turnCount)")),
            context: current
        )
        prefillComposer(text)
        return true
    }

    /// `/undo`'s line about files: with checkpoints on and one taken while
    /// the undone turns ran, Hermes names the files they changed and the
    /// `/rollback` that restores them (`rollback.list`'s `undo_hint`, in
    /// Hermes' language). Advisory: nil when Hermes has none, or is older.
    private func undoRollbackHint(
        client: HermesClient,
        sessionID: String,
        target: SessionRewindSnapshot.Turn,
        profile: String?
    ) async -> String? {
        guard let since = target.timestamp else { return nil }
        let params: [String: Any] = ["undo_since": since, "undo_message_id": target.rowID]
        let result: AnyCodable
        do {
            if let rollback = chatResumeLifecycleOperations.rollback {
                result = try await rollback(client, .list, sessionID, params)
            } else {
                result = try await client.rollback(.list, sessionId: sessionID, params: params, profile: profile)
            }
        } catch {
            return nil
        }
        let text = result.objectValue?["undo_hint"]?.objectValue?["text"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// `/rollback` (Hermes Desktop's): lists the chat's file checkpoints,
    /// shows one's diff, or restores the working folder (or one file) to
    /// one. A whole restore can take back the turns since, so the chat
    /// opens again to show them gone. False when this Hermes has no
    /// checkpoint verbs, so slash.exec answers.
    private func runRollback(
        argument: String,
        client: HermesClient,
        sessionID: String,
        context: ComposerSubmissionContext
    ) async -> Bool {
        guard let request = RollbackRequest(argument: argument) else {
            appendSlashOutput(Self.rollbackUsage, context: context)
            return true
        }
        if request.method == .restore, request.filePath == nil, isBusy {
            appendSlashOutput(AppLocalization.string("Wait for the reply to finish, or /stop it, then try again."), context: context)
            return true
        }
        let profile = botScopeProfile(forSessionIDs: [sessionID], workspaceProfile: activeProfile)
        let result: AnyCodable
        do {
            if let rollback = chatResumeLifecycleOperations.rollback {
                result = try await rollback(client, request.method, sessionID, request.params)
            } else {
                result = try await client.rollback(request.method, sessionId: sessionID, params: request.params, profile: profile)
            }
        } catch where HermesClient.isMissingRPCMethod(error) {
            return false
        } catch {
            if isCurrentComposerSubmission(context) {
                appendSlashOutput(Self.slashFailureNote(command: "rollback", error: error), context: context)
            }
            return true
        }
        guard isCurrentComposerSubmission(context) else { return true }
        let object = result.objectValue ?? [:]
        switch request.method {
        case .list:
            appendSlashOutput(Self.checkpointList(object), context: context)
        case .diff:
            let parts = [object["stat"]?.stringValue, object["diff"]?.stringValue]
                .compactMap { $0?.trimmingCharacters(in: .newlines) }
                .filter { !$0.isEmpty }
            appendSlashOutput(
                parts.isEmpty
                    ? AppLocalization.string("No changes since that checkpoint.")
                    : Self.diffBlock(parts.joined(separator: "\n")),
                context: context
            )
        case .restore:
            let note = Self.restoreNote(object)
            // A whole restore that took turns back: open the chat again so
            // they leave the screen. The note goes under the reloaded
            // transcript, which would otherwise replace it.
            let removed = HermesClient.exactIntValue(object["history_removed"]) ?? 0
            guard object["success"]?.boolValue == true, request.filePath == nil, removed > 0 else {
                appendSlashOutput(note, context: context)
                return true
            }
            let reopened = await openSessionOutcome(context.durableSessionID ?? sessionID)
            guard reopened != .superseded else { return true }
            // Our own open moved the viewport on, so `context` is stale
            // by construction; the restored chat must still be on screen.
            let current = composerSubmissionContext()
            guard composerSessionIDsAreEquivalent(context.sessionID, current.sessionID)
                || composerSessionIDsAreEquivalent(context.durableSessionID, current.sessionID) else { return true }
            appendSlashOutput(
                reopened == .failed
                    ? note + "\n\n" + AppLocalization.string("Open the chat again to see the messages the restore took back.")
                    : note,
                context: current
            )
        }
        return true
    }

    /// A checkpoint's diff as a fenced block, so it draws as code.
    static func diffBlock(_ diff: String) -> String {
        ["```diff", diff, "```"].joined(separator: "\n")
    }

    static var rollbackUsage: String {
        AppLocalization.string("Usage: /rollback [list], /rollback diff <n>, or /rollback <n> [file] [--all]. Restores the files Hermes changed to a checkpoint.")
    }

    /// `rollback.list`'s checkpoints, newest first, numbered as /rollback
    /// takes them.
    static func checkpointList(_ object: [String: AnyCodable]) -> String {
        if object["enabled"]?.boolValue == false {
            return AppLocalization.string("File checkpoints are off for this chat. Turn them on with checkpoints.enabled in Hermes' config.yaml.")
        }
        let rows = object["checkpoints"]?.arrayValue?.compactMap(\.objectValue) ?? []
        guard !rows.isEmpty else {
            return AppLocalization.string("No checkpoints yet for this chat's folder.")
        }
        let lines = rows.enumerated().map { index, row -> String in
            let hash = String((row["hash"]?.stringValue ?? "").prefix(8))
            let parts = [hash, row["timestamp"]?.stringValue ?? "", row["message"]?.stringValue ?? ""]
                .filter { !$0.isEmpty }
            return "\(index + 1). " + parts.joined(separator: "  ")
        }
        return ([AppLocalization.string("Checkpoints, newest first:")] + lines + [
            "",
            AppLocalization.string("Restore with /rollback <n> [file] (add --all to also overwrite your own edits). See the changes with /rollback diff <n>.")
        ]).joined(separator: "\n")
    }

    /// What a restore did: the checkpoint, Hermes' own note (files it left
    /// alone), and how many messages it took back.
    static func restoreNote(_ object: [String: AnyCodable]) -> String {
        guard object["success"]?.boolValue == true else {
            let error = object["error"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return error.isEmpty
                ? AppLocalization.string("The restore didn't go through.")
                : AppLocalization.string("The restore didn't go through: \(error)")
        }
        let hash = String((object["restored_to"]?.stringValue ?? "").prefix(8))
        var lines = [hash.isEmpty
            ? AppLocalization.string("Restored the checkpoint.")
            : AppLocalization.string("Restored checkpoint \(hash).")]
        if let reason = object["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            lines.append(reason)
        }
        if let removedCount = HermesClient.exactIntValue(object["history_removed"]), removedCount > 0 {
            lines.append(AppLocalization.string("Messages taken back from this chat: \(removedCount)"))
        }
        return lines.joined(separator: "\n")
    }

    /// Words taken back in `key`'s draft, ahead of whatever is typed
    /// there, a quoted reply as its "Replying to" chip. The composer puts
    /// them in its field when that chat is on screen, else into the chat's
    /// stored draft, as for a send that didn't go.
    func putRewoundTextBack(_ text: String, key: ComposerDraftKey, dashboardID: UUID?, authorName: String) {
        let reply = ReplyQuoteEnvelope.parse(text)
        let replyReference = reply.map {
            ComposerReplyReference(authorName: authorName, text: $0.quote)
        }
        guard let dashboardID else {
            // Restore requests and stored drafts belong to a saved
            // dashboard. A chat is only open on one; without it (tests,
            // a first connection still being saved) the words go in as
            // the draft, the quote as its chip.
            prefillComposer(reply?.message ?? text)
            if let replyReference, canQuoteIntoComposer() {
                composerQuoteRequest = ComposerQuoteRequest(content: .reply(replyReference))
            }
            return
        }
        composerRestoreRequests.append(ComposerRestoreRequest(
            dashboardID: dashboardID,
            key: key,
            draft: ComposerDraft(text: reply?.message ?? text, attachments: [], replyReference: replyReference),
            focuses: true,
            pending: nil
        ))
    }

    /// Edit and resend's refusals: Hermes' words for a rewind, without
    /// naming a slash command the user didn't type.
    static func editFailureNote(error: Error) -> String {
        if let refusal = error as? RpcError, (refusal.reason ?? refusal.message) == "unsupported_command" {
            return AppLocalization.string("This Hermes can't take a message back. Update Hermes to edit and resend.")
        }
        return rewindFailureNote(command: "undo", error: error)
    }

    /// Hermes' rewind refusals in words: a running reply, or a message
    /// compression summarized.
    static func rewindFailureNote(command: String, error: Error) -> String {
        if let refusal = error as? RpcError {
            let reason = refusal.reason ?? refusal.message
            if reason == "session_busy" {
                return AppLocalization.string("Wait for the reply to finish, or /stop it, then try again.")
            }
            if reason == "invalid_params", refusal.detail?.hasPrefix("compacted:") == true {
                return AppLocalization.string("That message was summarized when the chat was compressed, so it can't be taken back.")
            }
        }
        return slashFailureNote(command: command, error: error)
    }

    static let composerRoutedSlashNames: Set<String> = ["steer", "s", "queue", "q"]

    /// Hermes' slash.exec refuses /steer and /queue for a chat like this one;
    /// they are the composer's own Steer and Queue, for this message. Returns
    /// whether the composer may clear its draft: a failed send keeps it.
    func submitSteerOrQueueSlash(
        name: String,
        argument rawArgument: String,
        context submissionContext: ComposerSubmissionContext
    ) async -> Bool {
        cancelChatResumeRestoration()
        let isSteer = name == "steer" || name == "s"
        let argument = rawArgument.trimmingCharacters(in: .whitespacesAndNewlines)
        let queueUsage = AppLocalization.string("Usage: /queue <message>. Sends the message as the next turn once the running reply finishes.")
        guard !argument.isEmpty else {
            appendSlashOutput(
                isSteer
                    ? AppLocalization.string("Usage: /steer <message>. Sends the message into the running reply without stopping it.")
                    : queueUsage,
                context: submissionContext
            )
            return true
        }
        var message = argument
        if !isSteer, let word = argument.split(separator: " ").first.map({ $0.lowercased() }) {
            if word == "add" {
                message = argument.dropFirst(word.count).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if word == argument.lowercased(), Self.hermesQueueManagementWords.contains(word) {
                // `/queue list` alone is Hermes' queue management;
                // `/queue list the files` is a message to queue.
                appendSlashOutput(
                    AppLocalization.string("Conduit can only add to the queue. Use /queue <message> to queue one."),
                    context: submissionContext
                )
                return true
            }
        }
        guard !message.isEmpty else {
            appendSlashOutput(queueUsage, context: submissionContext)
            return true
        }
        // The message goes as typed: `/steer /compact` steers with that text
        // rather than running it as a command.
        return await performComposerSubmission(
            text: message,
            attachments: [],
            submissionContext: submissionContext,
            onBusy: nil,
            busyMode: isSteer ? .steer : .queue,
            runsSlashCommands: false
        )
    }

    private func stopReplyAndBackgroundProcesses(
        client: HermesClient,
        sessionID: String,
        context: ComposerSubmissionContext
    ) async {
        var lines: [String] = []
        // A failed interrupt has already said so; it isn't "nothing running".
        var replyMayStillRun = false
        var sessionID = sessionID
        var context = context
        if isBusy {
            if await cancelCurrent() {
                lines.append(AppLocalization.string("Stopped the reply."))
            } else {
                replyMayStillRun = true
            }
            // Cancelling can re-key a reaped runtime; stop the current one.
            guard let currentContext = currentComposerSubmissionContextIfOwnedAndAliased(context) else { return }
            context = currentContext
            sessionID = currentContext.sessionID ?? sessionID
        }
        do {
            let stoppedCount: Int
            if let stopProcesses = chatResumeLifecycleOperations.stopProcesses {
                stoppedCount = try await stopProcesses(client, sessionID)
            } else {
                stoppedCount = try await client.stopProcesses(sessionId: sessionID)
            }
            if stoppedCount > 0 {
                lines.append(AppLocalization.string("Background processes stopped: \(stoppedCount)"))
            } else if lines.isEmpty, !replyMayStillRun {
                lines.append(AppLocalization.string("Nothing was running."))
            }
        } catch where HermesClient.isMissingRPCMethod(error) {
            if lines.isEmpty, !replyMayStillRun { lines.append(AppLocalization.string("Nothing was running.")) }
        } catch {
            lines.append(AppLocalization.string("⚠️ Command failed: \(UserFacingError.message(for: error))"))
        }
        guard !lines.isEmpty else { return }
        appendSlashOutput(lines.joined(separator: "\n"), context: context)
    }

    /// The words after `/reload-mcp` that go ahead without asking first,
    /// as in Hermes' own clients. `always` also stops Hermes asking again
    /// where Hermes keeps that setting (`hermes dashboard`).
    static let mcpReloadConfirmWords: Set<String> = ["now", "yes", "once", "approve", "always"]

    /// `/reload-mcp` through `reload.mcp`. Bare, Hermes may ask first: its
    /// words say so, plus how to go ahead when they don't. False when this
    /// Hermes has no `reload.mcp`, so slash.exec answers instead.
    private func reloadMCPServers(
        argument: String,
        client: HermesClient,
        sessionID: String,
        context: ComposerSubmissionContext
    ) async -> Bool {
        let word = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let confirm = Self.mcpReloadConfirmWords.contains(word)
        let always = word == "always"
        let note: String
        do {
            let outcome: MCPReloadOutcome
            if let reloadMCP = chatResumeLifecycleOperations.reloadMCP {
                outcome = try await reloadMCP(client, sessionID, confirm, always)
            } else {
                outcome = try await client.reloadMCP(sessionId: sessionID, confirm: confirm, always: always)
            }
            note = Self.mcpReloadNote(outcome)
        } catch where HermesClient.isMissingRPCMethod(error) {
            return false
        } catch {
            note = Self.mcpReloadFailureNote(error)
        }
        guard isCurrentComposerSubmission(context) else { return true }
        appendSlashOutput(note, context: context)
        return true
    }

    static func mcpReloadNote(_ outcome: MCPReloadOutcome) -> String {
        guard outcome.needsConfirmation else {
            return outcome.message ?? AppLocalization.string("MCP servers reloaded.")
        }
        let goAhead = AppLocalization.string("Send /reload-mcp now to reload.")
        guard let message = outcome.message else { return goAhead }
        // Hermes' dashboard already says which words go ahead.
        return message.contains("/reload-mcp now") ? message : message + "\n" + goAhead
    }

    /// A reload in which nothing took effect because servers didn't connect
    /// (`mcp_servers_unavailable`, "did not connect: a, b") names them.
    static func mcpReloadFailureNote(_ error: Error) -> String {
        if let refusal = error as? RpcError,
           refusal.reason == "mcp_servers_unavailable" || refusal.message == "mcp_servers_unavailable" {
            let detail = refusal.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let names = detail.replacingOccurrences(of: "^did not connect:\\s*", with: "", options: .regularExpression)
            if !names.isEmpty {
                return AppLocalization.string("Nothing reloaded: these MCP servers didn't connect: \(names)")
            }
        }
        return slashFailureNote(command: "reload-mcp", error: error)
    }

    /// `/reload-skills` through `skills.reload`, then the suggestions read
    /// Hermes' catalog again so new skill commands show. False when this
    /// Hermes has no `skills.reload`, so slash.exec answers instead.
    private func reloadSkills(
        client: HermesClient,
        sessionID: String,
        context: ComposerSubmissionContext
    ) async -> Bool {
        let note: String
        var reloaded = false
        do {
            let output: String
            if let reloadSkills = chatResumeLifecycleOperations.reloadSkills {
                output = try await reloadSkills(client, sessionID)
            } else {
                output = try await client.reloadSkills(sessionId: sessionID)
            }
            reloaded = true
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            note = trimmed.isEmpty ? AppLocalization.string("Skills reloaded.") : trimmed
        } catch where HermesClient.isMissingRPCMethod(error) {
            return false
        } catch {
            note = Self.slashFailureNote(command: "reload-skills", error: error)
        }
        if isCurrentComposerSubmission(context) {
            appendSlashOutput(note, context: context)
        }
        if reloaded { await loadChatResumeSlashCommands() }
        return true
    }

    func executeGatewaySlash(
        client: HermesClient,
        sessionID: String,
        command: String,
        context: ComposerSubmissionContext? = nil
    ) async throws -> AnyCodable {
        do {
            if let executeSlash = chatResumeLifecycleOperations.executeSlash {
                return try await executeSlash(client, sessionID, command)
            }
            return try await client.executeSlash(sessionId: sessionID, command: command)
        } catch {
            if let context {
                guard isCurrentComposerSubmission(context) else { throw error }
            }
            // Only a gateway answer (`RpcError`) means slash.exec declined to
            // run the command. A timeout or dropped connection may mean it IS
            // running, and re-sending it through command.dispatch could run a
            // skill or plugin twice.
            guard let rejection = error as? RpcError else { throw error }
            // `command` arrives already stripped of its leading slash (the
            // `cleaned` form, or an alias target), so re-slash it before
            // parsing: `parseSlashCommand` only accepts `/`-prefixed text,
            // and a nil parse here rethrew slash.exec's own error instead of
            // falling back — skill commands answer slash.exec with "skill
            // command: use command.dispatch for /<name>" (#244).
            guard let parsed = Self.parseSlashCommand("/" + command) else { throw error }
            // A command Hermes refuses for Conduit chats is no skill or
            // plugin either: its refusal is the answer.
            if Self.slashCommandsWithoutConduitRoute.contains(parsed.name) { throw error }
            do {
                if let dispatchCommand = chatResumeLifecycleOperations.dispatchCommand {
                    return try await dispatchCommand(
                        client,
                        sessionID,
                        parsed.name,
                        parsed.argument
                    )
                }
                return try await client.dispatchCommand(sessionId: sessionID, name: parsed.name, arg: parsed.argument)
            } catch {
                // When slash.exec pointed at command.dispatch, dispatch's own
                // failure is the real one. Otherwise slash.exec's rejection
                // (session busy, not found, …) is the meaningful error, not
                // dispatch's generic "not a quick/plugin/skill command".
                if rejection.message.contains("command.dispatch") { throw error }
                throw rejection
            }
        }
    }

    func handleSlashResult(
        _ result: AnyCodable,
        depth: Int,
        aliasArgument: String,
        client: HermesClient,
        sessionID: String,
        context: ComposerSubmissionContext
    ) async {
        guard isCurrentComposerSubmission(context) else { return }
        guard depth < 4 else {
            appendSlashOutput(AppLocalization.string("⚠️ Too many command aliases."), context: context)
            return
        }

        let obj = result.objectValue ?? [:]
        let type = obj["type"]?.stringValue ?? ""
        let output = obj["output"]?.stringValue ?? obj["message"]?.stringValue ?? obj["notice"]?.stringValue ?? ""

        switch type {
        case "exec", "plugin":
            // Command executed server-side; show any output
            if !output.isEmpty {
                appendSlashOutput(output, context: context)
            }
        case "send", "skill":
            // These send a prompt — extract the message and send it
            let message = obj["message"]?.stringValue ?? output
            if !message.isEmpty {
                _ = await sendMessage(message, attachments: [], context: context)
            }
        case "prefill":
            if let notice = obj["notice"]?.stringValue, !notice.isEmpty {
                appendSlashOutput(notice, context: context)
            }
            let message = obj["message"]?.stringValue ?? output
            if !message.isEmpty, isCurrentComposerSubmission(context) {
                prefillComposer(message)
            }
        case "alias":
            // Re-execute with the target command
            let target = obj["target"]?.stringValue ?? obj["command"]?.stringValue ?? obj["name"]?.stringValue ?? ""
            if !target.isEmpty {
                do {
                    guard isCurrentComposerSubmission(context) else { return }
                    let nestedCommand = aliasArgument.isEmpty ? target : "\(target) \(aliasArgument)"
                    let nested = try await executeGatewaySlash(
                        client: client,
                        sessionID: sessionID,
                        command: nestedCommand,
                        context: context
                    )
                    guard isCurrentComposerSubmission(context) else { return }
                    await handleSlashResult(
                        nested,
                        depth: depth + 1,
                        aliasArgument: aliasArgument,
                        client: client,
                        sessionID: sessionID,
                        context: context
                    )
                } catch {
                    guard isCurrentComposerSubmission(context) else { return }
                    appendSlashOutput(
                        AppLocalization.string("⚠️ Alias target failed: \(UserFacingError.message(for: error))"),
                        context: context
                    )
                }
            } else if !output.isEmpty {
                appendSlashOutput(output, context: context)
            }
        default:
            // Unknown type — show output if present
            if !output.isEmpty {
                appendSlashOutput(output, context: context)
            }
        }
    }

    func appendSlashOutput(
        _ text: String,
        context: ComposerSubmissionContext? = nil
    ) {
        if let context {
            guard isCurrentComposerSubmission(context) else { return }
        }
        // Mid-turn ordering rule: slash output must not land below the live
        // reasoning card's eventual commit.
        settleReasoningSegmentIntoTranscript()
        messages.append(ChatMessage(
            // Unique: two notes can land in the same instant.
            id: "slash-\(UUID().uuidString)",
            role: .system,
            content: text,
            rawContent: nil,
            timestamp: Self.localTimestamp(),
            author: nil
        ))
        cacheMessagePresentation()
    }

    /// `[btw "question"]` / `[bg task]` over the answer, as Desktop and the
    /// TUI label it.
    static func sideAgentNote(kind: SideAgentKind, taskId: String, text: String, question: String?) -> String {
        let header: String
        switch kind {
        case .btw: header = question.map { "[btw \"\($0)\"]" } ?? "[btw]"
        case .background: header = taskId.isEmpty ? "[bg]" : "[bg \(taskId)]"
        }
        return "\(header)\n\(text)"
    }

    private static func formatSlashHelp() -> String {
        AppLocalization.string("**Slash Commands**\n\nType `/` followed by a command name.\n\n**Built-in:**\n• `/new` — Start a new conversation\n• `/model` — Open the model picker\n• `/yolo` — Toggle auto-approve mode\n• `/help` — Show this help\n\nUse the suggestions list to discover gateway commands.")
    }
}
