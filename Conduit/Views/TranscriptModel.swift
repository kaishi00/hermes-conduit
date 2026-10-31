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
//  trace says which rows came, went or changed. The lazy stack draws the
//  rows for now; the collection view that replaces it will draw the same.
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
/// rows still there in another order. Text streaming into a live row isn't
/// a change here: that row reads it from the live projection.
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
        // elsewhere): each one whose place among them differs.
        let stayedBefore = before.map(\.id).filter { afterIDs.contains($0) }
        let stayedAfter = after.map(\.id).filter { beforeByID[$0] != nil }
        changes.moved = zip(stayedBefore, stayedAfter).filter { $0.0 != $0.1 }.map(\.1)
        return changes
    }

    /// The recorder's line: counts, then the first ids of each kind. Row
    /// ids name no message text.
    func traceLine(rowCount: Int) -> String {
        func ids(_ mark: String, _ list: [String]) -> String {
            list.isEmpty ? "" : " \(mark)[\(list.prefix(3).joined(separator: ","))\(list.count > 3 ? ",..." : "")]"
        }
        return "rows n=\(rowCount) +\(inserted.count) -\(removed.count) ~\(changed.count)"
            + (moved.isEmpty ? "" : " >\(moved.count)")
            + ids("+", inserted) + ids("-", removed) + ids("~", changed) + ids(">", moved)
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
        /// device gets the reply. The scroll engine's live tail is the same
        /// rule (ChatView.liveTurn), so both always agree.
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

        var hasRows: Bool { !rows.isEmpty }
    }

    /// Everything that decides the rows besides the targets themselves,
    /// which `targetsRevision` stands for.
    struct Input: Equatable {
        /// The scroll engine's target cache revision: its targets are the
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
        let next = Self.rows(for: input, targets: targets, disclosure: disclosure)
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
        var messages: [TranscriptRow] = []
        messages.reserveCapacity(targets.count)
        var ids = Set<String>(minimumCapacity: targets.count)
        for target in targets where target.drawsRow(
            preferences: input.displayPreferences,
            isBusy: input.isBusy,
            disclosure: disclosure
        ) {
            guard ids.insert(target.id).inserted else { continue }
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
        if targets.isEmpty {
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
        if let changes = model.update(input, targets: targets, disclosure: disclosure), !changes.isEmpty {
            ChatViewportTrace.shared.log(changes.traceLine(rowCount: model.rows.count))
        }
        return model
    }
}
