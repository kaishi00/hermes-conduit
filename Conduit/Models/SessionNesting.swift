//
//  SessionNesting.swift
//  Conduit
//
//  The Sessions drawer nests voice-spawned rows under the session that
//  started them (#556): a background job under the call that started it,
//  a call attached to a chat under that chat. Pure list shaping: the view
//  resolves nothing, SessionNesting.parentKey reads the voice tag and the
//  device's call-chat links, and the rules (alias matching, orphan rows,
//  parent cycles, flattening, signal aggregation) stay testable without
//  a gateway.
//

import Foundation

/// The Sessions drawer's rows: parents with the rows they spawned nested
/// underneath. Roots keep the server's recent order; children sort newest
/// first.
enum SessionNesting {
    struct Node: Identifiable, Equatable {
        let session: SessionSummary
        let children: [Node]

        var id: String { session.id }

        /// Every row this nest hides while collapsed, grandchildren
        /// included — what a parent's count badge reports.
        var descendantCount: Int {
            children.reduce(children.count) { $0 + $1.descendantCount }
        }

        /// The row and every row below it, for actions that address what
        /// the parent shows (its aggregate read state).
        var sessionsInNest: [SessionSummary] {
            [session] + children.flatMap(\.sessionsInNest)
        }
    }

    /// Groups `sessions` by `parentKeyOf`. A row nests only under a row in
    /// the same list, matched on any id it answers to; of two rows
    /// answering to the same id, the one carrying it as its own id or
    /// stored id beats one borrowing it as an alias, and the earlier row
    /// breaks what's left. A row that names itself, names no row in the
    /// list, or closes a parent cycle stays at the top level, so a missing
    /// link degrades to today's flat list instead of losing a row.
    static func group(_ sessions: [SessionSummary], parentKeyOf: (SessionSummary) -> String?) -> [Node] {
        // 0 = a row's own id or stored id, 1 = a borrowed alias: a
        // reconciliation alias must not steal a key its owner carries.
        var rowForKey: [String: Int] = [:]
        var rankForKey: [String: Int] = [:]
        for (index, session) in sessions.enumerated() {
            for id in session.nestingIDs {
                let rank = (id == session.id || id == session.storedSessionId) ? 0 : 1
                if let existing = rankForKey[id], existing <= rank { continue }
                rankForKey[id] = rank
                rowForKey[id] = index
            }
        }

        var parentRow = [Int?](repeating: nil, count: sessions.count)
        for (index, session) in sessions.enumerated() {
            guard let key = parentKeyOf(session).flatMap({ $0.isEmpty ? nil : $0 }),
                  let parent = rowForKey[key], parent != index else { continue }
            parentRow[index] = parent
        }

        // A parent cycle would swallow its every member below the top
        // level; the row where a cycle closes is freed as a root.
        // 0 = new, 1 = on the current path, 2 = resolved.
        var state = [UInt8](repeating: 0, count: sessions.count)
        for start in sessions.indices {
            var path: [Int] = []
            var row = start
            while state[row] == 0 {
                state[row] = 1
                path.append(row)
                guard let next = parentRow[row] else { break }
                row = next
            }
            if state[row] == 1 { parentRow[row] = nil }
            for visited in path { state[visited] = 2 }
        }

        var childrenByRow = [[Int]](repeating: [], count: sessions.count)
        for row in sessions.indices {
            if let parent = parentRow[row] { childrenByRow[parent].append(row) }
        }
        let byNewest: (Int, Int) -> Bool = { lhs, rhs in
            switch (sessions[lhs].lastActivityAt, sessions[rhs].lastActivityAt) {
            case let (left?, right?):
                // A total order: sorted(by:) is not guaranteed stable, so
                // equal timestamps fall back to the listing's order.
                return left == right ? lhs < rhs : left > right
            // A row without a timestamp keeps its list position after
            // every row that has one.
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs < rhs
            }
        }
        func node(_ row: Int) -> Node {
            Node(session: sessions[row], children: childrenByRow[row].sorted(by: byNewest).map(node))
        }

        return sessions.indices.filter { parentRow[$0] == nil }.map(node)
    }

    /// Whether the drawer groups its rows. A search or a status filter is
    /// a lookup, not a browse: it flattens the list to the matching rows.
    static func shouldGroup(query: String, statusFilterActive: Bool) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !statusFilterActive
    }

    /// The drawer's rows: nested while browsing, flat while narrowing.
    /// A parent a filter excluded leaves the list, and its children
    /// degrade to top-level rows by design — the nest never hides a row.
    static func rows(
        _ sessions: [SessionSummary],
        query: String,
        statusFilterActive: Bool,
        parentKeyOf: (SessionSummary) -> String?
    ) -> [Node] {
        guard shouldGroup(query: query, statusFilterActive: statusFilterActive) else {
            return sessions.map { Node(session: $0, children: []) }
        }
        return group(sessions, parentKeyOf: parentKeyOf)
    }

    /// The drawer's Pinned and Recent sections (#606). The whole list is
    /// grouped once, so a pinned chat nests its calls and jobs like any
    /// other parent. A pinned row never nests under another row, so it
    /// always stays in Pinned; every other row follows its root into
    /// whichever section that root lands in.
    static func sections(
        _ sessions: [SessionSummary],
        query: String,
        statusFilterActive: Bool,
        isPinned: (SessionSummary) -> Bool,
        parentKeyOf: (SessionSummary) -> String?
    ) -> (pinned: [Node], recent: [Node]) {
        let nodes = rows(
            sessions,
            query: query,
            statusFilterActive: statusFilterActive,
            parentKeyOf: { isPinned($0) ? nil : parentKeyOf($0) }
        )
        var pinned: [Node] = []
        var recent: [Node] = []
        for node in nodes {
            if isPinned(node.session) {
                pinned.append(node)
            } else {
                recent.append(node)
            }
        }
        return (pinned, recent)
    }

    /// The nest's own signals: the row's own unread/live status merged
    /// with its children's, so a collapsed nest never hides activity. A
    /// child waiting on the user outranks one still working.
    static func signals(
        _ node: Node,
        isUnread: (SessionSummary) -> Bool,
        liveStatus: (SessionSummary) -> SessionLiveStatus?
    ) -> (isUnread: Bool, liveStatus: SessionLiveStatus?) {
        let childSignals = node.children.map { signals($0, isUnread: isUnread, liveStatus: liveStatus) }
        let unread = isUnread(node.session) || childSignals.contains { $0.isUnread }
        let statuses = [liveStatus(node.session)] + childSignals.map(\.liveStatus)
        if statuses.contains(.needsInput) { return (unread, .needsInput) }
        if statuses.contains(.working) { return (unread, .working) }
        return (unread, nil)
    }

    /// The key of the row `session` nests under: the call that started a
    /// voice job, or the chat a saved call was attached to. Classic voice
    /// runs in its chat's own session and untagged rows stay top level.
    static func parentKey(
        for session: SessionSummary,
        tag: VoiceSessionTag?,
        chatLinks: VoiceCallChatLinks,
        profile: String
    ) -> String? {
        guard let tag else { return nil }
        switch tag.kind {
        case .job:
            return tag.parentID
        case .call:
            return chatLinks.chatKey(forCallIDs: session.nestingIDs, profile: profile)
        case .classic:
            return nil
        }
    }

    /// The stable identity a nest's expansion is keyed on: the stored id
    /// outlives the runtime id a reconciling row may be re-listed under.
    static func nestKey(of session: SessionSummary) -> String {
        guard let stored = session.storedSessionId, !stored.isEmpty else { return session.id }
        return stored
    }

    /// The ancestors of the row `active` identifies within `nodes`, and
    /// whether any row there answers to the id, even as a borrowed alias
    /// — the drawer treats an empty ancestor answer differently when the
    /// row is listed (it is genuinely top level, or its parent left the
    /// list) than when it is absent (the list is mid-refresh). Rows
    /// answering to the id rank like the grouping's parent resolution:
    /// the one carrying it as its own id or stored id beats one borrowing
    /// it as an alias. Equal ranks fall to the tree's own order (roots in
    /// listing order, children newest-first), which matches the
    /// grouping's earlier-row rule except in the degenerate case of two
    /// same-rank claimants in different subtrees.
    static func ancestorKeys(of active: String, in nodes: [Node]) -> (keys: Set<String>, rowIsListed: Bool) {
        var bestRank = Int.max
        var bestAncestors: [String] = []
        var rowIsListed = false
        func walk(_ nodes: [Node], ancestors: [String]) {
            for node in nodes {
                if let rank = claimRank(node.session, for: active) {
                    rowIsListed = true
                    if rank < bestRank {
                        bestRank = rank
                        bestAncestors = ancestors
                    }
                }
                walk(node.children, ancestors: ancestors + [nestKey(of: node.session)])
            }
        }
        walk(nodes, ancestors: [])
        return (Set(bestAncestors), rowIsListed)
    }

    /// 0 = the row owns the id (its own or its stored one), 1 = it borrows
    /// the id as an alias; nil = no claim. An empty id claims nothing,
    /// like the ids `nestingIDs` filters out.
    private static func claimRank(_ session: SessionSummary, for id: String) -> Int? {
        guard !id.isEmpty else { return nil }
        if session.id == id || session.storedSessionId == id { return 0 }
        return session.alternateIds.contains(id) ? 1 : nil
    }

    /// The parent a nested row's VoiceOver value names, or nil when there
    /// is nothing to name — no parent, an empty title — or the row's own
    /// second line already names it (a job's "From ‹call›").
    static func parentAccessibilityValueTitle(detail: String?, parentTitle: String?) -> String? {
        guard let parent = parentTitle, !parent.isEmpty else { return nil }
        return detail == AppLocalization.string("From \(parent)") ? nil : parent
    }

    /// What a row's read toggle addresses: nothing for a leaf (its own
    /// state, as every flat row) or a read nest, or the whole nest for a
    /// parent whose dot is lit — whose "Mark as read" clears what it
    /// shows. A non-nil answer IS the lit dot, so a read parent's toggle
    /// can never fall into a nest-wide path by branch order.
    static func readToggleInputs(
        for node: Node,
        aggregateIsUnread: Bool
    ) -> NestReadToggle? {
        guard !node.children.isEmpty, aggregateIsUnread else { return nil }
        return NestReadToggle(sessions: node.sessionsInNest)
    }
}

/// What a parent row's "Mark as read" clears (#570): the whole nest.
/// A non-nil toggle IS the lit dot, so the dot and what it clears
/// cannot drift apart at a call site: only code in this file — today,
/// `readToggleInputs` alone — can build one.
struct NestReadToggle {
    let sessions: [SessionSummary]

    fileprivate init(sessions: [SessionSummary]) {
        self.sessions = sessions
    }
}

/// The reveal's memory: the last activation and the ancestor path it
/// revealed (#556). Pure, so the re-reveal rules stay testable without
/// a view.
struct NestRevealLatch {
    private(set) var activeID: String?
    private(set) var ancestors: Set<String> = []

    /// The ancestors to expand, or nil when nothing expands: a path other
    /// than the one the latch holds — an activation arriving from
    /// elsewhere, or the same activation whose parenting links just
    /// landed. A sibling activation inside the path the latch holds
    /// expands nothing, so a collapse the user chose stands — unless it
    /// hides the row they just opened (`hiddenAncestors`). Before any row
    /// arrives nothing latches: the tags or links that parent them may
    /// still land; once the list has rows an empty answer is real while
    /// the row is listed — top level, or its parent left the list — and
    /// latches like any other, except for the activation the latch
    /// already holds while its row is absent: that empty answer is the
    /// list mid-refresh, and the remembered path stands so a collapse
    /// survives the row's return. The two are indistinguishable when it
    /// is the parent link that is mid-refresh, so a collapse may then be
    /// forgotten and re-revealed: the latch errs toward revealing, never
    /// hiding, the open row.
    mutating func reveal(
        active: String?,
        ancestors: Set<String>,
        listHasRows: Bool,
        rowIsListed: Bool,
        hiddenAncestors: Set<String>
    ) -> Set<String>? {
        guard let active else {
            activeID = nil
            self.ancestors = []
            return nil
        }
        guard !ancestors.isEmpty || listHasRows else { return nil }
        let pathChanged = ancestors != self.ancestors
        let activeChanged = activeID != active
        activeID = active
        if !ancestors.isEmpty || activeChanged || rowIsListed {
            self.ancestors = ancestors
        }
        guard pathChanged || (activeChanged && !hiddenAncestors.isEmpty) else { return nil }
        guard !ancestors.isEmpty else { return nil }
        return ancestors
    }
}

extension SessionSummary {
    /// Every id the row answers to: its own, its stored id and its aliases.
    var nestingIDs: [String] {
        ([id, storedSessionId].compactMap { $0 } + alternateIds).filter { !$0.isEmpty }
    }
}
