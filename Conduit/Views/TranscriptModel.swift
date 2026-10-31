//
//  TranscriptModel.swift
//  Conduit
//
//  What the chat's transcript draws, in order (#1533, the transcript
//  rewrite): the chat's rows (Hermes', or the saved copy's standing in), the
//  running turn's live rows, a send waiting on screen, and the lines above
//  or in place of them (Load earlier, the saved copy's status, an empty
//  chat). It's the one place that decides them; ChatView's body used to
//  spread that over the transcript's stack. Each update says what it
//  changed by row id (TranscriptChangeSet), and the recorder logs it, so a
//  trace says which rows came, went or changed. A group room's rows are
//  decided here too (GroupRoomTranscript).
//

import Foundation

/// One row of the transcript.
struct TranscriptRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// "Load earlier messages", or its progress line while a page loads.
        case loadEarlier(isLoading: Bool)
        /// A saved copy with no rows of its own: the chat on its way, or no
        /// copy saved.
        case savedCopyStatus(isOpening: Bool)
        /// A chat with nothing in it yet.
        case empty
        /// One of the chat's rows.
        case message(ChatMessageScrollTarget)
        /// The running turn's open thinking card. Its text comes from the
        /// live projection, not from here.
        case thinking
        /// The reply streaming in, its text from the live projection too.
        /// `isActive`: still being written ("Responding", not "Finishing").
        case streaming(isActive: Bool)
        /// The running turn's working line.
        case working(TranscriptWorkingLine)
        /// A message sent while the chat was on its way.
        case pendingSend(PendingComposerSend)
        /// A group room's row (GroupRoomTranscript).
        case room(GroupRoomRow)
    }

    let id: String
    let kind: Kind

    static let loadEarlierID = "transcript-load-earlier"
    static let savedCopyStatusID = "transcript-saved-copy"
    static let emptyID = "transcript-empty"
    static let streamingID = "streaming"
    static let workingID = "typing"
    static let pendingSendID = "pending-send"

    /// Whether `other` draws as this row does. One of the chat's rows is
    /// what it draws (its message and its places in runs of steps or
    /// reviews), not where it sits among the targets: a page of earlier
    /// messages landing above it moves it down without changing it.
    func drawsSame(as other: TranscriptRow) -> Bool {
        guard id == other.id else { return false }
        if case .message(let target) = kind, case .message(let otherTarget) = other.kind {
            return target.message == otherTarget.message
                && target.step == otherTarget.step
                && target.stepsAbove == otherTarget.stepsAbove
                && target.reviewRun == otherTarget.reviewRun
        }
        return kind == other.kind
    }
}

/// What the working line says, apart from its timer's ticks.
struct TranscriptWorkingLine: Equatable {
    /// The tool running now.
    var toolName: String?
    /// Its input, for a batch's names.
    var toolInput: String?
    /// Its own words for it ("Messaging Atlas…").
    var toolTitle: String?
    /// Thinking is streaming, with no tool running.
    var isThinking = false
    /// When the turn began, for the timer.
    var startedAt: Date?
    /// Another device is getting this chat's reply.
    var repliesElsewhere = false
}

/// What an update changed, by row id: rows that came, rows that went,
/// rows still there that draw differently (TranscriptRow.drawsSame), and
/// the fewest rows still there that moved for the rest to keep their
/// order. A row can be both changed and moved: it draws differently in its
/// new place (a diffable snapshot takes the move from the ids and redraws
/// the changed rows). Text streaming into a live row isn't a change here:
/// that row reads it from the live projection.
struct TranscriptChangeSet: Equatable {
    var inserted: [String] = []
    var removed: [String] = []
    var changed: [String] = []
    var moved: [String] = []

    var isEmpty: Bool { inserted.isEmpty && removed.isEmpty && changed.isEmpty && moved.isEmpty }

    /// From `old` to `new`, both with unique ids. The rows both start or
    /// end with unchanged (most updates touch only the end) are skipped
    /// before anything is compared by id.
    static func between(_ old: [TranscriptRow], _ new: [TranscriptRow]) -> TranscriptChangeSet {
        var start = 0
        while start < old.count, start < new.count, old[start].drawsSame(as: new[start]) {
            start += 1
        }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1].drawsSame(as: new[newEnd - 1]) {
            oldEnd -= 1
            newEnd -= 1
        }
        var changes = TranscriptChangeSet()
        let before = old[start..<oldEnd]
        let after = new[start..<newEnd]
        guard !before.isEmpty || !after.isEmpty else { return changes }
        let beforeByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterIDs = Set(after.map(\.id))
        for row in after {
            if let was = beforeByID[row.id] {
                if !was.drawsSame(as: row) { changes.changed.append(row.id) }
            } else {
                changes.inserted.append(row.id)
            }
        }
        changes.removed = before.filter { !afterIDs.contains($0.id) }.map(\.id)
        // Rows in both whose order changed (a saved row Hermes places
        // elsewhere): all but the longest run of them still in order.
        let oldPlace = Dictionary(before.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        changes.moved = outOfOrder(after.map(\.id).filter { oldPlace[$0] != nil }, oldPlace: oldPlace)
        return changes
    }

    /// The ids, in their new order, that leave the longest run in their
    /// old order (`oldPlace`) when taken out: one row moved across three
    /// others is that one row, not four.
    private static func outOfOrder(_ ids: [String], oldPlace: [String: Int]) -> [String] {
        let places = ids.map { oldPlace[$0] ?? 0 }
        // Patience sorting: tails[k] is the index of the lowest last place
        // a run in order of length k + 1 ends at, and `previous` links each
        // index to the one before it in its run.
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: places.count)
        for (index, place) in places.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if places[tails[middle]] < place { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var inOrder = Set<Int>()
        var index = tails.last ?? -1
        while index >= 0 {
            inOrder.insert(index)
            index = previous[index]
        }
        return ids.indices.filter { !inOrder.contains($0) }.map { ids[$0] }
    }

    /// The recorder's line: counts, then the first ids of each kind. Row
    /// ids name no message text.
    func traceLine(rowCount: Int) -> String {
        "rows n=\(rowCount) +\(inserted.count) -\(removed.count) ~\(changed.count)"
            + (moved.isEmpty ? "" : " >\(moved.count)")
            + Self.ids("+", inserted) + Self.ids("-", removed) + Self.ids("~", changed) + Self.ids(">", moved)
    }

    /// The recorder's line for the chat's rows left out for a repeated id.
    static func repeatedLine(_ repeatedIDs: [String]) -> String {
        "rows repeated n=\(repeatedIDs.count)" + ids("", repeatedIDs)
    }

    private static func ids(_ mark: String, _ list: [String]) -> String {
        list.isEmpty ? "" : " \(mark)[\(list.prefix(3).joined(separator: ","))\(list.count > 3 ? ",..." : "")]"
    }
}

/// The transcript's rows and what they read from the transcript as a
/// whole, brought up to date from an Input. An update with the input it
/// last had does nothing, so ChatView can ask on every body evaluation.
struct TranscriptModel {
    /// The running turn as the transcript draws it.
    struct LiveTurn: Equatable {
        var shape = LiveTurnShape()
        /// A turn runs in the live chat (AppState.isBusy).
        var isBusy = false
        /// Another device is getting this chat's reply.
        var repliesElsewhere = false
        /// The live chat is the one drawn: not under a saved copy of another
        /// chat (one picked in the saved list), whose turn it isn't.
        var isShown = true
        /// The working line's tool and timer.
        var working = TranscriptWorkingLine()

        /// Its rows, in order: the open thinking card, the reply streaming
        /// in, and the working line while nothing streams yet or another
        /// device gets the reply.
        var rows: [TranscriptRow] {
            guard isShown else { return [] }
            var rows: [TranscriptRow] = []
            if let id = shape.thinkingID {
                rows.append(TranscriptRow(id: id, kind: .thinking))
            }
            if shape.streams {
                rows.append(TranscriptRow(id: TranscriptRow.streamingID, kind: .streaming(isActive: isBusy)))
            }
            if (isBusy && !shape.streams) || repliesElsewhere {
                var line = working
                line.isThinking = shape.thinkingID != nil
                line.repliesElsewhere = repliesElsewhere
                rows.append(TranscriptRow(id: TranscriptRow.workingID, kind: .working(line)))
            }
            return rows
        }
    }

    /// Everything that decides the rows besides the targets themselves,
    /// which `targetsRevision` stands for.
    struct Input: Equatable {
        /// The scroller's target cache revision: its targets are the
        /// chat's rows (AppState.chatRowsOnScreen).
        var targetsRevision: UInt64 = 0
        /// The conversation drawn: opened and closed rows are remembered
        /// per conversation (ChatRowDisclosure).
        var conversation = ChatScrollSessionIdentity.none
        var displayPreferences = ProfileDisplayPreferences()
        /// A turn runs in the chat drawn (AppState.chatOnScreenIsBusy): its
        /// trailing run of steps stays open.
        var isBusy = false
        /// A run of steps or reviews opened or closed (ChatRowDisclosure's
        /// groupToggles).
        var disclosureRevision: UInt64 = 0
        var live = LiveTurn()
        /// A message sent while the chat was on its way.
        var pendingSend: PendingComposerSend?
        /// "Load earlier messages" is offered, and whether a page is loading.
        var loadsEarlier = false
        var isLoadingEarlier = false
        /// The chat on screen has rows (AppState.chatRowsOnScreen) the
        /// scroller hasn't been given yet, as on a new view's first pass:
        /// it isn't an empty chat, or a saved copy without rows.
        var rowsOnTheirWay = false
        /// The saved copy is the chat on screen.
        var showsSavedCopy = false
        /// A saved copy is up at all, over the live chat's rows or not.
        var hasSavedCopy = false
        /// A chat picked in the saved list is opening while Conduit connects
        /// (not offline): with no rows, it says so.
        var savedCopyIsOpening = false
    }

    private(set) var rows: [TranscriptRow] = []
    private(set) var facts = ChatRowFacts()
    /// The chat's rows left out because an earlier row has their id. Ids
    /// are unique in practice; the trace names any that aren't.
    private(set) var repeatedIDs: [String] = []
    private var input: Input?

    /// Brings the rows up to `input`, `targets` being the ones its revision
    /// names. Nil when nothing changed, else what did (possibly nothing,
    /// when only an input that draws the same rows did).
    @MainActor
    mutating func update(
        _ input: Input,
        targets: [ChatMessageScrollTarget],
        disclosure: ChatRowDisclosure
    ) -> TranscriptChangeSet? {
        guard input != self.input else { return nil }
        let previous = self.input
        self.input = input
        if previous?.targetsRevision != input.targetsRevision || previous?.isBusy != input.isBusy {
            facts = ChatRowFacts(rows: targets.map(\.message), isBusy: input.isBusy)
        }
        let next = Self.rows(for: input, targets: targets, disclosure: disclosure, repeatedIDs: &repeatedIDs)
        let changes = TranscriptChangeSet.between(rows, next)
        rows = next
        return changes
    }

    /// The rows, in order: Load earlier; the saved copy's status or an
    /// empty chat's welcome while there are no rows; the chat's rows that
    /// draw (a step folded into its run, or a review into its run, draws
    /// nothing); the live turn's; the send waiting. Ids are unique, the
    /// chat's rows winning: a live row's id matching a settled row (the
    /// thinking card a moment after it settles) isn't drawn twice.
    @MainActor
    static func rows(
        for input: Input,
        targets: [ChatMessageScrollTarget],
        disclosure: ChatRowDisclosure
    ) -> [TranscriptRow] {
        var repeatedIDs: [String] = []
        return rows(for: input, targets: targets, disclosure: disclosure, repeatedIDs: &repeatedIDs)
    }

    /// The rows, with `repeatedIDs` set to the chat's rows left out for an
    /// id an earlier one has.
    @MainActor
    static func rows(
        for input: Input,
        targets: [ChatMessageScrollTarget],
        disclosure: ChatRowDisclosure,
        repeatedIDs: inout [String]
    ) -> [TranscriptRow] {
        repeatedIDs = []
        var messages: [TranscriptRow] = []
        messages.reserveCapacity(targets.count)
        var ids = Set<String>(minimumCapacity: targets.count)
        for target in targets where target.drawsRow(
            preferences: input.displayPreferences,
            isBusy: input.isBusy,
            disclosure: disclosure
        ) {
            guard ids.insert(target.id).inserted else {
                repeatedIDs.append(target.id)
                continue
            }
            messages.append(TranscriptRow(id: target.id, kind: .message(target)))
        }

        var rows: [TranscriptRow] = []
        rows.reserveCapacity(messages.count + 4)
        func add(_ row: TranscriptRow) {
            guard ids.insert(row.id).inserted else { return }
            rows.append(row)
        }
        if input.loadsEarlier {
            add(TranscriptRow(id: TranscriptRow.loadEarlierID, kind: .loadEarlier(isLoading: input.isLoadingEarlier)))
        }
        if targets.isEmpty, !input.rowsOnTheirWay {
            if input.showsSavedCopy {
                if input.savedCopyIsOpening {
                    add(TranscriptRow(id: TranscriptRow.savedCopyStatusID, kind: .savedCopyStatus(isOpening: true)))
                } else if input.pendingSend == nil {
                    add(TranscriptRow(id: TranscriptRow.savedCopyStatusID, kind: .savedCopyStatus(isOpening: false)))
                }
            } else if !input.hasSavedCopy, input.pendingSend == nil {
                add(TranscriptRow(id: TranscriptRow.emptyID, kind: .empty))
            }
        }
        rows.append(contentsOf: messages)
        input.live.rows.forEach(add)
        if let pending = input.pendingSend {
            add(TranscriptRow(id: TranscriptRow.pendingSendID, kind: .pendingSend(pending)))
        }
        return rows
    }
}

/// ChatView's transcript model, updated in its body. A plain class, so an
/// update during a render asks for no other render.
@MainActor
final class TranscriptModelBox {
    private(set) var model = TranscriptModel()

    func update(
        _ input: TranscriptModel.Input,
        targets: [ChatMessageScrollTarget],
        disclosure: ChatRowDisclosure
    ) -> TranscriptModel {
        let repeated = model.repeatedIDs
        if let changes = model.update(input, targets: targets, disclosure: disclosure) {
            if !changes.isEmpty {
                ChatViewportTrace.shared.log(changes.traceLine(rowCount: model.rows.count))
            }
            if model.repeatedIDs != repeated, !model.repeatedIDs.isEmpty {
                ChatViewportTrace.shared.log(TranscriptChangeSet.repeatedLine(model.repeatedIDs))
            }
        }
        return model
    }
}

// MARK: - Group rooms

/// What one of a group room's rows draws (GroupChatView). The room's members
/// ride along: a change of name redraws the rows naming them.
enum GroupRoomRow: Equatable {
    /// A room event (GroupEventRow), and whether it continues the run of
    /// the row above (the speaker's picture and name once).
    case event(GroupEvent, members: [GroupMember], continuesRun: Bool)
    /// The user's message on its way, under the id its event will have:
    /// "Sending…" while its send is out, else Retry.
    case pending(text: String, members: [GroupMember], isSending: Bool)
    /// The member whose turn is running.
    case responding(GroupMember)
    /// A room with nothing in it yet.
    case empty(roomID: String, members: [GroupMember])
}

/// A group room's transcript rows (#1533, the transcript rewrite): its
/// visible events, the user's message on its way, the member responding,
/// or the empty room's welcome.
enum GroupRoomTranscript {
    static let respondingID = "room-responding"
    static let emptyID = "room-empty"

    /// The rows, in order. The message on its way takes its event's id, so
    /// its row becomes the event's in place when the send lands, and isn't
    /// drawn twice while both are there.
    static func rows(
        events: [GroupEvent],
        roomID: String,
        members: [GroupMember],
        pending: GroupRoomOutbox.Pending?,
        isSending: Bool,
        responder: GroupMember?
    ) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(events.count + 2)
        var ids = Set<String>(minimumCapacity: events.count + 2)
        func add(_ id: String, _ row: GroupRoomRow) {
            guard ids.insert(id).inserted else { return }
            rows.append(TranscriptRow(id: id, kind: .room(row)))
        }
        for (index, event) in events.enumerated() {
            // A member's run of replies shows its picture and name once,
            // like a group thread in Messages.
            let continuesRun = index > 0 && GroupEventRow.sameSpeaker(events[index - 1], event)
            add(event.id, .event(event, members: members, continuesRun: continuesRun))
        }
        if let pending {
            add(pending.eventID, .pending(text: pending.text, members: members, isSending: isSending))
        }
        if let responder {
            add(respondingID, .responding(responder))
        }
        if rows.isEmpty {
            add(emptyID, .empty(roomID: roomID, members: members))
        }
        return rows
    }

    /// The member message a following room stops at the start of when new
    /// events arrive, as a long chat reply does (#365): the first one after
    /// the row that was last before them. Nil follows to the end: nothing
    /// new from a member, or no row from before (the room just opened, its
    /// first events usually its history), or that row gone.
    static func replyStart(in events: [GroupEvent], after previousLastID: String?) -> String? {
        guard let previousLastID,
              let index = events.lastIndex(where: { $0.id == previousLastID }) else { return nil }
        return events[(index + 1)...].first(where: \.isMemberMessage)?.id
    }
}

/// GroupChatView's rows, built again only when what they draw changes, so
/// the transcript skips comparing them on the room's other updates. It
/// tells the scroller of new events, and of a member starting or ending
/// its turn, as it builds them, before the transcript lays them out: the
/// stop at a new member message is set before the pass that would follow
/// it to its end. What draws nothing new at the end (a turn's heartbeat,
/// the oldest rows trimmed) leaves its stop alone. A plain class, so an
/// update during a render asks for no other render.
@MainActor
final class GroupRoomTranscriptBox {
    struct Input: Equatable {
        var replay = GroupRoomReplay(roomID: "")
        var members: [GroupMember] = []
        var pending: GroupRoomOutbox.Pending?
        var isSending = false
        var responder: GroupMember?
    }

    private var input: Input?
    private(set) var rows: [TranscriptRow] = []
    /// The visible events' ids the rows had.
    private var eventIDs: [String] = []

    func update(_ input: Input, scroller: TranscriptScroller) -> [TranscriptRow] {
        guard input != self.input else { return rows }
        let responderChanged = input.responder != self.input?.responder
        self.input = input
        let events = input.replay.events.filter(GroupRoomTurns.isVisible)
        rows = GroupRoomTranscript.rows(
            events: events,
            roomID: input.replay.roomID,
            members: input.members,
            pending: input.pending,
            isSending: input.isSending,
            responder: input.responder
        )
        let ids = events.map(\.id)
        // Only an event at the end is new: the oldest rows trimmed, or a
        // gap filled, change which rows there are and nothing else.
        let arrived = ids.last != eventIDs.last
        if arrived || responderChanged {
            scroller.roomTranscriptChanged(
                eventIDs: Set(ids),
                replyStart: arrived ? GroupRoomTranscript.replyStart(in: events, after: eventIDs.last) : nil
            )
        } else if ids != eventIDs {
            scroller.roomEventsChanged(Set(ids))
        }
        eventIDs = ids
        return rows
    }
}
