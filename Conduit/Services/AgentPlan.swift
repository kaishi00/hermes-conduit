//
//  AgentPlan.swift
//  Conduit
//
//  The agent's task list, read from Hermes' `todo` tool (tools/todo_tool.py)
//  for the plan card (docs/PLAN_CARD.md). Every `todo` call
//  returns the whole list, so the newest result is the plan; a call still
//  without its result is read from its arguments, a merge applied over the
//  last whole list before it. `session.resume` carries the same snapshot as
//  `todo_state` for a chat whose last plan is older than the loaded page.
//

import Foundation

struct AgentPlanItem: Equatable, Identifiable {
    enum Status: String, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled

        var isOpen: Bool { self == .pending || self == .inProgress }
    }

    let id: String
    var content: String
    var status: Status
    /// The id of the item this one is a subtask of.
    var parent: String?
}

struct AgentPlan: Equatable {
    var items: [AgentPlanItem]
    /// Hermes' write counter (0.21+); nil when the source didn't say.
    var revision: Int?

    /// Hermes' own bound on a list (`MAX_TODO_ITEMS`).
    static let maxItems = 256
    static let maxContentCharacters = 4000

    var isEmpty: Bool { items.isEmpty }

    /// Nothing left to do: every item completed or cancelled.
    var isFinished: Bool { !items.isEmpty && !items.contains { $0.status.isOpen } }

    /// The items the count is out of: a cancelled one isn't work left or done.
    var countedTotal: Int { items.filter { $0.status != .cancelled }.count }
    var completedCount: Int { items.filter { $0.status == .completed }.count }

    /// 0...1, for the progress bar and ring.
    var progress: Double {
        let total = countedTotal
        guard total > 0 else { return isFinished ? 1 : 0 }
        return Double(completedCount) / Double(total)
    }

    /// What the agent is on: the item in progress, else the first pending.
    var currentIndex: Int? {
        items.firstIndex { $0.status == .inProgress } ?? items.firstIndex { $0.status == .pending }
    }

    var current: AgentPlanItem? { currentIndex.map { items[$0] } }

    /// How deep each item sits under its parents, capped for layout.
    func depth(of item: AgentPlanItem, cap: Int = 2) -> Int {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var depth = 0
        var seen: Set<String> = [item.id]
        var node = item
        while let parent = node.parent, let next = byID[parent], seen.insert(parent).inserted {
            depth += 1
            if depth >= cap { break }
            node = next
        }
        return depth
    }

    /// Whether `self` is a different plan from `previous`, not an update of
    /// it: fewer than half of its items keep an earlier item's id and text.
    func isNewPlan(comparedTo previous: AgentPlan?) -> Bool {
        guard let previous, !previous.items.isEmpty else { return true }
        guard !items.isEmpty else { return false }
        let earlier = Dictionary(previous.items.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first })
        let kept = items.filter { earlier[$0.id] == $0.content }.count
        return kept * 2 < items.count
    }
}

// MARK: - Reading Hermes' JSON

extension AgentPlan {
    /// A `todo` result (`{"todos": [...], "revision": N}`) or `todo_state`.
    /// Nil for anything else: an error, a read of an unused list.
    init?(snapshot object: [String: Any]) {
        guard let rows = object["todos"] as? [Any] else { return nil }
        self.init(items: Self.validated(rows), revision: Self.integer(object["revision"]))
    }

    init?(snapshotJSON text: String?) {
        guard let object = Self.jsonObject(text) else { return nil }
        self.init(snapshot: object)
    }

    /// Replace-or-merge, as `TodoStore.write` does it.
    func applying(merge rows: [Any]) -> AgentPlan {
        var items = self.items
        var index = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for case let row as [String: Any] in Self.dedupedByID(rows) {
            let id = Self.string(row["id"])
            guard !id.isEmpty else { continue }
            if let position = index[id] {
                let content = Self.string(row["content"])
                if !content.isEmpty { items[position].content = Self.capped(content) }
                if let status = AgentPlanItem.Status(rawValue: Self.string(row["status"]).lowercased()) {
                    items[position].status = status
                }
                if row.keys.contains("parent") {
                    let parent = Self.string(row["parent"])
                    items[position].parent = parent.isEmpty || parent == id ? nil : parent
                }
            } else {
                index[id] = items.count
                items.append(Self.item(row))
            }
        }
        return AgentPlan(items: Self.sanitizedParents(Array(items.prefix(Self.maxItems))), revision: nil)
    }

    static func validated(_ rows: [Any]) -> [AgentPlanItem] {
        var items = dedupedByID(rows).map { row -> AgentPlanItem in
            guard let row = row as? [String: Any] else {
                return AgentPlanItem(id: "?", content: AppLocalization.string("(invalid item)"), status: .pending)
            }
            return item(row)
        }
        // A row without a usable id gets one no other row has, so the
        // plan's lists never see the same id twice.
        var used = Set(items.map(\.id).filter { $0 != "?" })
        var next = 0
        for index in items.indices where items[index].id == "?" {
            while used.contains("?\(next)") { next += 1 }
            let item = items[index]
            items[index] = AgentPlanItem(id: "?\(next)", content: item.content, status: item.status, parent: item.parent)
            used.insert("?\(next)")
        }
        return sanitizedParents(Array(items.prefix(maxItems)))
    }

    private static func item(_ row: [String: Any]) -> AgentPlanItem {
        let id = string(row["id"])
        let content = string(row["content"])
        let parent = string(row["parent"])
        return AgentPlanItem(
            id: id.isEmpty ? "?" : id,
            content: content.isEmpty ? AppLocalization.string("(no description)") : capped(content),
            status: AgentPlanItem.Status(rawValue: string(row["status"]).lowercased()) ?? .pending,
            parent: parent.isEmpty || parent == id ? nil : parent
        )
    }

    /// The last row for each id, in its own position.
    private static func dedupedByID(_ rows: [Any]) -> [Any] {
        var last: [String: Int] = [:]
        for (offset, row) in rows.enumerated() {
            let id = (row as? [String: Any]).map { string($0["id"]) } ?? ""
            last[id.isEmpty ? "__invalid_\(offset)" : id] = offset
        }
        return last.values.sorted().map { rows[$0] }
    }

    /// A parent that's missing, or a chain that loops, makes the item a root.
    private static func sanitizedParents(_ items: [AgentPlanItem]) -> [AgentPlanItem] {
        let ids = Set(items.map(\.id))
        var result = items.map { item -> AgentPlanItem in
            var item = item
            if let parent = item.parent, !ids.contains(parent) { item.parent = nil }
            return item
        }
        let byID = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in result.indices {
            var seen: Set<String> = [result[index].id]
            var node = result[index]
            while let parent = node.parent, let next = byID[parent] {
                guard seen.insert(parent).inserted else {
                    result[index].parent = nil
                    break
                }
                node = next
            }
        }
        return result
    }

    private static func capped(_ content: String) -> String {
        content.count > maxContentCharacters ? String(content.prefix(maxContentCharacters - 1)) + "…" : content
    }

    static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        // A JSON true is an NSNumber too; it's no count.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, abs(double) < 1e15 else { return nil }
        return Int(double)
    }

    static func jsonObject(_ text: String?) -> [String: Any]? {
        guard let text, text.count <= 512_000 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - From the transcript

enum AgentPlanTranscript {
    static let toolName = "todo"

    /// The newest plan the transcript shows, and the row it ends at; nil
    /// when the chat never wrote one.
    static func latest(in messages: [ChatMessage]) -> (plan: AgentPlan, messageID: String, timestamp: String)? {
        var merges: [[Any]] = []
        var newest: ChatMessage?
        for message in messages.reversed() {
            guard message.role == .tool, let tool = message.tool,
                  tool.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == toolName else { continue }
            let step = read(tool)
            switch step {
            case .skip:
                continue
            case .merge(let rows):
                newest = newest ?? message
                merges.append(rows)
            case .whole(let plan):
                let anchor = newest ?? message
                // Oldest merge first, as they were written.
                let replayed = merges.reversed().reduce(plan) { $0.applying(merge: $1) }
                return (merges.isEmpty ? plan : replayed, anchor.id, anchor.timestamp)
            }
        }
        // Merges with no whole list before them in the loaded page: they
        // add to nothing Conduit can see, so they show what they say.
        guard let newest, !merges.isEmpty else { return nil }
        let plan = merges.reversed().reduce(AgentPlan(items: [], revision: nil)) { $0.applying(merge: $1) }
        return plan.isEmpty ? nil : (plan, newest.id, newest.timestamp)
    }

    enum Step {
        case whole(AgentPlan)
        case merge([Any])
        case skip
    }

    /// What one `todo` row says. Its result is the whole list; an error or
    /// a read says nothing new. A row without a result (still running, or a
    /// compact row) is read from its arguments.
    static func read(_ tool: ToolActivity) -> Step {
        if let output = tool.output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let plan = AgentPlan(snapshotJSON: output) { return .whole(plan) }
            return .skip
        }
        guard let arguments = AgentPlan.jsonObject(tool.input) else { return .skip }
        var rows = arguments["todos"]
        // Models sometimes send the list as a JSON string.
        if let text = rows as? String, let data = text.data(using: .utf8) {
            rows = try? JSONSerialization.jsonObject(with: data)
        }
        guard let list = rows as? [Any] else { return .skip }
        let merge = (arguments["merge"] as? Bool) ?? ((arguments["merge"] as? String)?.lowercased() == "true")
        return merge ? .merge(list) : .whole(AgentPlan(items: AgentPlan.validated(list), revision: nil))
    }
}

// MARK: - What the card fits

/// The rows the plan card shows when the plan is longer than it fits: the
/// item before the current one, the current one, and the next ones, with
/// what's above and below folded into a count each.
struct AgentPlanWindow: Equatable {
    let rows: [AgentPlanItem]
    /// Items above the rows.
    let before: Int
    /// Whether everything above is completed or cancelled ("✓ 4 done").
    let beforeAreDone: Bool
    /// Items below the rows.
    let after: Int

    static let maxRows = 5

    init(plan: AgentPlan, maxRows: Int = AgentPlanWindow.maxRows) {
        let items = plan.items
        guard items.count > maxRows, maxRows > 0 else {
            rows = items
            before = 0
            beforeAreDone = true
            after = 0
            return
        }
        // A finished plan shows its end.
        let anchor = plan.currentIndex ?? (items.count - 1)
        let start = min(max(0, anchor - 1), items.count - maxRows)
        rows = Array(items[start..<(start + maxRows)])
        before = start
        beforeAreDone = !items[..<start].contains { $0.status.isOpen }
        after = items.count - start - maxRows
    }
}
