//
//  AppState+DelegateAgents.swift
//  Conduit
//
//  The turn's delegate agents (subagents): their roster, steering,
//  interrupting, ending and tailing one, and pausing delegation. Moved out
//  of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Delegate agents

    /// Asks Hermes which delegate agents are still running and finishes
    /// the cards it no longer lists, so a missed `subagent.complete` can't
    /// leave an agent "Running" for good (#492). Gateways without
    /// `subagent.list` leave the cards as they are.
    func refreshDelegateAgents() async {
        guard let client else { return }
        let cutoff = Date().addingTimeInterval(-Self.delegateAgentRosterGrace)
        let sessionIDs = Set(delegateAgents.lazy
            .filter { $0.status == .running && $0.hasGatewayID && !$0.sessionId.isEmpty }
            .map(\.sessionId))
        delegateAgentSeenAt = delegateAgentSeenAt.filter { id, _ in delegateAgents.contains { $0.id == id } }
        for sessionID in sessionIDs {
            guard let roster = try? await client.subagentRoster(sessionId: sessionID),
                  self.client === client else { continue }
            let liveIDs = Set(roster.map(\.id))
            // A card's latest news is its last event, published or not.
            let seen = delegateAgents.map { agent -> DelegateAgentActivity in
                var stamped = agent
                if let at = delegateAgentSeenAt[agent.id], at > stamped.updatedAt { stamped.updatedAt = at }
                return stamped
            }
            let reconciled = DelegateAgentActivity.reconciled(
                seen,
                sessionId: sessionID,
                liveIDs: liveIDs,
                changedBefore: cutoff
            )
            // Unchanged cards leave the gateway's own agent count alone.
            guard reconciled != seen else { continue }
            delegateAgents = reconciled
            activeAgents = DelegateAgentActivity.activeCount(delegateAgents)
        }
    }

    /// Reads the delegate agents Hermes still has for the chat just opened
    /// (`sessionID`, its live id) and gives each one this chat has no card
    /// for a card: they were started before it was opened, or while the
    /// socket was down, so no `subagent.*` frame of theirs reached it, and
    /// the chat would read as finished while they work (issue 2142).
    /// Gateways without `subagent.list` leave the cards as they are.
    /// A read that failed on the way (not Hermes' own answer) is tried once
    /// more while the chat is still the open one: with no cards, the chat
    /// would show no waiting line until an agent's next frame.
    @discardableResult
    func adoptDelegateRoster(for sessionID: String, retries: Int = 1) async -> [DelegateAgentActivity]? {
        guard let client, !sessionID.isEmpty else { return nil }
        // The answer is about the chat it was asked for, on the connection
        // that asked: another chat opened meanwhile keeps its own cards.
        let stillOpen: () -> Bool = { [weak self] in
            guard let self, self.client === client, let open = self.activeSessionId else { return false }
            return self.knownSessionIDs(for: open).contains(sessionID)
        }
        let roster: [DelegateAgentActivity]
        do {
            roster = try await client.subagentRoster(sessionId: sessionID)
        } catch {
            guard retries > 0, !(error is RpcError) else { return nil }
            try? await Task.sleep(for: .seconds(3))
            guard stillOpen() else { return nil }
            return await adoptDelegateRoster(for: sessionID, retries: retries - 1)
        }
        guard stillOpen() else { return nil }
        // Only the runtime the chat has now moves cards: a late answer about
        // an earlier one never moves them back.
        let adopted = DelegateAgentActivity.adopting(delegateAgents, roster: roster, moving: activeSessionId == sessionID)
        if adopted != delegateAgents {
            delegateAgents = adopted
            setActiveAgents(DelegateAgentActivity.activeCount(adopted))
        }
        return roster
    }

    /// Whether a refused Steer or Stop may end `agent`'s card. A card from
    /// an earlier runtime of the open chat ends only when the roster of the
    /// runtime Hermes has now doesn't list it: the refusal was about the old
    /// runtime, and a roster that couldn't be read proves nothing (issue
    /// 2206). A card Hermes still lists moves to that runtime, so the next
    /// try reaches it.
    private func refusalEndsDelegateAgent(_ agent: DelegateAgentActivity) async -> Bool {
        guard let open = activeSessionId, open != agent.sessionId else { return true }
        // A resume's catalog row names the new runtime and the durable id,
        // not the one the card was made under: the open chat's resume-wide
        // aliases name it, and a card still kept is the open chat's own
        // (keepDelegateAgents).
        let aliases = knownSessionIDs(for: open).union(activeChatScrollSessionIdentity.equivalentSessionIDs)
        guard aliases.contains(agent.sessionId)
                || delegateAgents.contains(where: { $0.id == agent.id && $0.sessionId == agent.sessionId })
        else { return true }
        guard let roster = await adoptDelegateRoster(for: open, retries: 0),
              // Resumed again meanwhile: that roster is an earlier runtime's.
              activeSessionId == open else { return false }
        return !roster.contains { $0.id == agent.id }
    }

    /// How many delegate agents of the open chat are still queued or
    /// running while its own turn has ended: the chat's waiting line
    /// (issue 2142). The cards are the open conversation's only
    /// (`keepDelegateAgents`), so another chat's agents never count here.
    var backgroundAgentsAwaited: Int {
        isBusy ? 0 : DelegateAgentActivity.activeCount(delegateAgents)
    }

    /// What a Steer or Stop on a delegate agent's card came to.
    enum DelegateAgentControlResult: Equatable {
        case done
        /// Hermes no longer has the agent running for this chat.
        case notRunning
        case failed
    }

    /// Sends `text` to one running delegate agent (#820). Hermes hands it
    /// over at the agent's next tool step.
    func steerDelegateAgent(_ agent: DelegateAgentActivity, text: String) async -> DelegateAgentControlResult {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, agent.hasGatewayID, !agent.sessionId.isEmpty, !text.isEmpty else { return .failed }
        let queued: Bool
        do {
            queued = try await client.steerSubagent(sessionId: agent.sessionId, subagentId: agent.id, text: text)
        } catch {
            return .failed
        }
        // A client swapped during the call answered for another connection.
        guard self.client === client else { return .failed }
        if queued { return .done }
        guard await refusalEndsDelegateAgent(agent), self.client === client else { return .failed }
        endDelegateAgent(agent)
        return .notRunning
    }

    /// Stops one running delegate agent (#820). The card shows it stopped
    /// at once; Hermes' own end event can't change that (`merged` keeps the
    /// first end).
    func interruptDelegateAgent(_ agent: DelegateAgentActivity) async -> DelegateAgentControlResult {
        guard let client, agent.hasGatewayID, !agent.sessionId.isEmpty else { return .failed }
        let found: Bool
        do {
            found = try await client.interruptSubagent(sessionId: agent.sessionId, subagentId: agent.id)
        } catch {
            return .failed
        }
        // A client swapped during the call answered for another connection.
        guard self.client === client else { return .failed }
        if !found {
            guard await refusalEndsDelegateAgent(agent), self.client === client else { return .failed }
        }
        endDelegateAgent(agent, as: found ? .interrupted : .completed)
        return found ? .done : .notRunning
    }

    /// Ends one card Hermes said it no longer runs (or that was just
    /// stopped), whatever the roster grace: that answer is about this agent,
    /// not a roster that may lag.
    private func endDelegateAgent(_ agent: DelegateAgentActivity, as status: DelegateAgentActivity.Status = .completed) {
        guard let index = delegateAgents.firstIndex(where: { $0.id == agent.id && $0.sessionId == agent.sessionId }),
              delegateAgents[index].status.isActive else { return }
        let now = Date()
        delegateAgents[index] = delegateAgents[index].ended(as: status, at: now)
        delegateAgents[index].updatedAt = now
        activeAgents = delegateAgents.filter { $0.status.isActive }.count
    }

    /// The end of one running delegate agent's live transcript (#820), or
    /// nil when it couldn't be read.
    func tailDelegateAgent(_ agent: DelegateAgentActivity) async -> SubagentTail? {
        guard let client, agent.hasGatewayID, !agent.sessionId.isEmpty else { return nil }
        let tail = try? await client.tailSubagent(sessionId: agent.sessionId, subagentId: agent.id)
        return self.client === client ? tail : nil
    }

    /// Whether Hermes is holding new delegate agents, or nil when this
    /// Hermes can't say (#820).
    func loadDelegationPaused() async -> Bool? {
        guard let client else { return nil }
        guard let owner = currentDashboardRuntimeOwner() else { return try? await client.delegationPaused() }
        // The pause holds every profile, so every profile's page opens on it.
        let answer = try? await keepingAnswer(
            profile: KeptRoute.everyProfile, owner: owner, keptAs: { _ in KeptRoute.delegationStatus }
        ) {
            ["paused": try await client.delegationPaused()]
        }
        return answer?["paused"] as? Bool
    }

    /// Whether delegation was paused when a page last read it on this
    /// dashboard, under any profile, kept on the phone, or nil when that
    /// isn't kept.
    func keptDelegationPaused() -> Bool? {
        keptAnswer(KeptRoute.delegationStatus, profile: KeptRoute.everyProfile)?["paused"] as? Bool
    }

    /// Holds or releases new delegate agents; returns the state Hermes
    /// reports, or nil when it failed.
    func setDelegationPaused(_ paused: Bool) async -> Bool? {
        guard let client else { return nil }
        guard let owner = currentDashboardRuntimeOwner() else { return try? await client.setDelegationPaused(paused) }
        let answer = try? await keepingAnswer(
            profile: KeptRoute.everyProfile, owner: owner, keptAs: { _ in KeptRoute.delegationStatus }, writes: true
        ) {
            ["paused": try await client.setDelegationPaused(paused)]
        }
        return answer?["paused"] as? Bool
    }

    /// Keeps only the delegate cards of the conversation now open (its
    /// `sessionIDs`; none for a new chat, another profile or server). The
    /// sheet is per conversation, and `refreshDelegateAgents` asks the
    /// current client about every running card's session.
    func keepDelegateAgents(of sessionIDs: Set<String>) {
        guard delegateAgents.contains(where: { !sessionIDs.contains($0.sessionId) }) else { return }
        delegateAgents.removeAll { !sessionIDs.contains($0.sessionId) }
        activeAgents = delegateAgents.filter { $0.status.isActive }.count
    }
}
