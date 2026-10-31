//
//  TranscriptLayout.swift
//  Conduit
//
//  The chat transcript's collection view layout (#1533, the transcript
//  rewrite): one column of rows, top to bottom, with the lazy stack's
//  spacing, each row as tall as it measures.
//

import UIKit

/// The transcript's collection view layout (#1533, the transcript rewrite).
/// One column of rows, with the spacing the lazy stack had, each row as
/// tall as it measures. A row not measured yet is as tall as it measured
/// last time at this width and text size (TranscriptHeights), else a guess
/// from its text. So every row has a frame at once and TranscriptScroller
/// finds any place without waiting for a pass. A row changing height moves
/// the rows under it in the same pass, and the scroller keeps the reader's
/// row where it was.
///
/// Each item is a row with the gap above it: the cell draws the gap too
/// (TranscriptCellRoot's top padding), so a row reaching up into it (the
/// steps of one run, drawn as one card) is drawn and tapped there, as in
/// the stack. The row's own frame, the one the scroller goes by, starts
/// below the gap.
@MainActor
final class TranscriptLayout: UICollectionViewLayout {
    /// Above the first item: the stack's top padding and its 1 pt top
    /// anchor.
    static let topPadding: CGFloat = 18 + 1
    /// Above each row, the first included: the stack's spacing.
    static let rowGap = ChatStepStyle.transcriptRowSpacing
    /// Under the last row: the stack's spacing and its 1 pt bottom anchor,
    /// so the latest row ends where it did above the composer.
    static let bottomPadding: CGFloat = ChatStepStyle.transcriptRowSpacing + 1
    /// Beside the rows, inside the safe area: the stack's padding.
    static let sideMargin: CGFloat = 18

    /// The rows drawn, in order.
    private(set) var rows: [TranscriptRow] = []
    /// The rows the next snapshot brings, taken up by the pass that has
    /// their count: until then the attributes and frames are the old rows'.
    private var pendingRows: [TranscriptRow]?
    /// Those of them that draw something else than before, or came in:
    /// guessed again once they're taken up.
    private var pendingChanges: Set<String> = []
    private var indexByID: [String: Int] = [:]
    /// Each item's top and height (the gap above its row included).
    private var itemTop: [CGFloat] = []
    private var itemHeight: [CGFloat] = []
    /// The first item whose frame is out of date.
    private var dirtyFrom: Int?
    private var contentHeight: CGFloat = 0
    /// The rows' bottom the next pass lays out, kept as rows change height
    /// between passes (`noteHeight`).
    private var pendingRowsBottom: CGFloat = 0
    /// Whether the next pass asks for the content size: one invalidating
    /// everything or the rows' count does, one for some rows never does.
    private var asksContentSize = true
    /// A cell's measurement's change to the content's height, for the
    /// context UIKit asks for next (invalidationContext(forPreferred…)).
    private var preferredAdjustment: CGFloat = 0
    /// Heights measured for the conversation, width and text size drawn.
    private var heights = TranscriptHeightTable()
    /// The rows not measured yet, as tall as their text guesses, worked out
    /// once per width and scope, and again for a row that draws something
    /// else: a pass from a row that measured lays out every row under it,
    /// and a long chat's would be guessed again in each.
    private var estimates: [String: CGFloat] = [:]
    /// What decides a height besides the width: the conversation (row ids
    /// repeat across them) and the text's size and face.
    private(set) var scope = ""
    private var preparedWidth: CGFloat = 0
    /// The safe area beside the transcript (a landscape notch, a wide
    /// window's readable column), leading and trailing.
    private(set) var sideInsets: (leading: CGFloat, trailing: CGFloat) = (0, 0)
    private var requestedReserve: CGFloat = 0
    /// The least content height the last pass gave the transcript (the
    /// room under a sent message for its reply, #1436).
    private(set) var appliedReserve: CGFloat = 0
    /// Bumped by every pass that moved a frame or the content's height, so
    /// the collection view can tell the scroller only of passes that did.
    private(set) var generation: UInt64 = 0

    override var flipsHorizontallyInOppositeLayoutDirection: Bool { true }

    // MARK: - Inputs

    /// The rows the snapshot about to be applied draws, and the ids of
    /// those that draw something else than the rows set last, or came in.
    func setRows(_ newRows: [TranscriptRow], changed: [String]) {
        pendingRows = newRows
        pendingChanges.formUnion(changed)
    }

    /// The conversation and text size the heights belong to; a new one
    /// measures again, from the heights it measured before.
    func setScope(_ newScope: String) {
        guard newScope != scope else { return }
        scope = newScope
        loadHeightTable()
        invalidateLayout()
    }

    func setSideInsets(leading: CGFloat, trailing: CGFloat) {
        guard abs(leading - sideInsets.leading) > 0.5 || abs(trailing - sideInsets.trailing) > 0.5 else { return }
        sideInsets = (leading, trailing)
        // Another width for the rows: every height may change.
        loadHeightTable()
        invalidateLayout()
    }

    /// The least content height from the next pass (TranscriptScrollSurface).
    func reserveContentHeight(_ height: CGFloat) {
        guard abs(height - requestedReserve) > 0.5 else { return }
        requestedReserve = height
        invalidateLayout()
    }

    /// A row's content changed height after it was measured (a picture
    /// loading, a card taking its height, a reply streaming in): `size` is
    /// its cell's, the gap included, at the width it was laid out at.
    /// Taken only for that width.
    func rowResized(_ id: String, to size: CGSize) {
        guard abs(size.width - itemWidth) <= 0.5, size.height > 0 else { return }
        let height = pixelRounded(size.height)
        guard heights[id].map({ abs($0 - height) > 0.5 }) ?? true else { return }
        guard let index = indexByID[id] else {
            heights[id] = height
            return
        }
        let adjustment = noteHeight(height, at: index)
        switch rows[index].kind {
        case .thinking, .streaming:
            // The live turn's text arriving, a line at a time: logged, it
            // would push out of the recorder the moves the trace is for.
            break
        default:
            ChatViewportTrace.shared.log(String(format: "row %@ resized to %.1f", id, height))
        }
        ChatViewportWatch.shared.rowResized()
        markDirty(from: index)
        let context = UICollectionViewLayoutInvalidationContext()
        context.invalidateItems(at: [IndexPath(item: index, section: 0)])
        context.contentSizeAdjustment = CGSize(width: 0, height: adjustment)
        invalidateLayout(with: context)
    }

    /// Keeps a row's new height and returns how much the content's height
    /// changes by. A pass for some rows never asks for the content size
    /// again, so its context carries the change; one that asks (another
    /// count of rows, a pass invalidating everything) takes none.
    private func noteHeight(_ height: CGFloat, at index: Int) -> CGFloat {
        let row = rows[index]
        let before = self.height(of: row)
        heights[row.id] = height
        let contentBefore = max(pendingRowsBottom, requestedReserve)
        pendingRowsBottom += height - before
        return asksContentSize ? 0 : max(pendingRowsBottom, requestedReserve) - contentBefore
    }

    // MARK: - Frames

    /// The rows' width: the column inside the safe area and the margins.
    var itemWidth: CGFloat {
        max(0, preparedWidth - sideInsets.leading - sideInsets.trailing - 2 * Self.sideMargin)
    }

    /// The row's own frame in content space, below its gap; nil for a row
    /// not drawn.
    func rowFrame(_ id: String) -> TranscriptRowFrame? {
        guard let index = indexByID[id], index < itemTop.count else { return nil }
        return rowFrame(at: index)
    }

    /// The rows whose frames cross `band`, top first.
    func rows(crossing band: ClosedRange<CGFloat>) -> [TranscriptRowFrame] {
        guard !itemTop.isEmpty else { return [] }
        var frames: [TranscriptRowFrame] = []
        var index = firstItem(endingBelow: band.lowerBound)
        while index < itemTop.count, itemTop[index] + Self.rowGap < band.upperBound {
            let frame = rowFrame(at: index)
            if frame.maxY > band.lowerBound, frame.minY < band.upperBound {
                frames.append(frame)
            }
            index += 1
        }
        return frames
    }

    private func rowFrame(at index: Int) -> TranscriptRowFrame {
        let top = itemTop[index]
        return TranscriptRowFrame(
            id: rows[index].id,
            minY: top + Self.rowGap,
            maxY: max(top + Self.rowGap, top + itemHeight[index])
        )
    }

    /// The first item whose bottom is at or below `y`.
    private func firstItem(endingBelow y: CGFloat) -> Int {
        var low = 0
        var high = itemTop.count
        while low < high {
            let mid = (low + high) / 2
            if itemTop[mid] + itemHeight[mid] < y {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func itemFrame(at index: Int) -> CGRect {
        CGRect(
            x: sideInsets.leading + Self.sideMargin,
            y: itemTop[index],
            width: itemWidth,
            height: itemHeight[index]
        )
    }

    // MARK: - UICollectionViewLayout

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        if let pending = pendingRows, pending.count == count {
            pendingRows = nil
            adopt(pending, changed: pendingChanges)
            pendingChanges = []
        } else if rows.count != count {
            // Never expected: the rows come in with the snapshot. Draw as
            // many as the collection view has rather than answer for items
            // it doesn't.
            adopt(Array(rows.prefix(count)) + (rows.count..<max(count, rows.count)).map {
                TranscriptRow(id: "transcript-unknown-\($0)", kind: .empty)
            }, changed: [])
        }
        let width = collectionView.bounds.width
        if abs(width - preparedWidth) > 0.5 {
            preparedWidth = width
            loadHeightTable()
        }
        var moved = false
        if let start = dirtyFrom {
            dirtyFrom = nil
            var top = start == 0 ? Self.topPadding : itemTop[start - 1] + itemHeight[start - 1]
            for index in start..<rows.count {
                let height = self.height(of: rows[index])
                if abs(itemTop[index] - top) > 0.01 || abs(itemHeight[index] - height) > 0.01 { moved = true }
                itemTop[index] = top
                itemHeight[index] = height
                top += height
            }
        }
        let rowsBottom = (rows.isEmpty ? Self.topPadding : itemTop[rows.count - 1] + itemHeight[rows.count - 1])
            + Self.bottomPadding
        pendingRowsBottom = rowsBottom
        asksContentSize = false
        appliedReserve = requestedReserve
        let height = max(rowsBottom, appliedReserve)
        if moved || abs(height - contentHeight) > 0.01 {
            contentHeight = height
            generation &+= 1
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? preparedWidth, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !itemTop.isEmpty else { return [] }
        var attributes: [UICollectionViewLayoutAttributes] = []
        var index = firstItem(endingBelow: rect.minY)
        while index < itemTop.count, itemTop[index] <= rect.maxY {
            attributes.append(layoutAttributes(at: index))
            index += 1
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, indexPath.item >= 0, indexPath.item < itemTop.count else { return nil }
        return layoutAttributes(at: indexPath.item)
    }

    private func layoutAttributes(at index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = itemFrame(at: index)
        return attributes
    }

    /// Scrolling never lays the rows out again; another width does.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        abs(newBounds.width - preparedWidth) > 0.5
    }

    /// The offset is TranscriptScroller's: an update or a new width leaves
    /// it where it is, and the scroller moves it in the pass that follows.
    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        proposedContentOffset
    }

    /// A cell measured its row (TranscriptCell.preferredLayoutAttributesFitting).
    override func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> Bool {
        let index = originalAttributes.indexPath.item
        guard originalAttributes.indexPath.section == 0, index < rows.count else { return false }
        // Taken only for the width the rows are laid out at, as in
        // rowResized: a cell measured at the last width (a rotation, a
        // split window) is measured again at the new one.
        guard abs(preferredAttributes.size.width - itemWidth) <= 0.5 else { return false }
        let height = pixelRounded(preferredAttributes.size.height)
        // Kept even when the frame already has it: an estimate that
        // happened to match is a measurement now. A change to the content's
        // height still owed (a resize not laid out yet) asks for a context.
        preferredAdjustment = noteHeight(height, at: index)
        return abs(height - itemHeight[index]) > 0.5 || preferredAdjustment != 0
    }

    override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(
            forPreferredLayoutAttributes: preferredAttributes,
            withOriginalAttributes: originalAttributes
        )
        // The scroller keeps the reader's row in place; UIKit's own
        // adjustment would move it twice.
        context.contentOffsetAdjustment = .zero
        context.contentSizeAdjustment = CGSize(width: 0, height: preferredAdjustment)
        preferredAdjustment = 0
        markDirty(from: originalAttributes.indexPath.item)
        return context
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        super.invalidateLayout(with: context)
        if context.invalidateEverything || context.invalidateDataSourceCounts {
            asksContentSize = true
        }
        // New rows are laid out from the first that changed (`adopt`).
        if context.invalidateEverything {
            markDirty(from: 0)
        }
    }

    // MARK: - Private

    private func adopt(_ newRows: [TranscriptRow], changed: Set<String>) {
        // Rows kept from before keep their frames until the pass sets
        // them, so the first one that changed is where the pass starts.
        var start = 0
        while start < rows.count, start < newRows.count, rows[start].id == newRows[start].id {
            start += 1
        }
        let sameIDs = start == rows.count && start == newRows.count
        rows = newRows
        if !sameIDs {
            indexByID = Dictionary(newRows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            itemTop = Array(itemTop.prefix(start)) + Array(repeating: 0, count: newRows.count - start)
            itemHeight = Array(itemHeight.prefix(start)) + Array(repeating: 0, count: newRows.count - start)
            markDirty(from: start)
        }
        // A row not measured yet that draws something else (an edit off
        // screen, the next message sent through the pending row) is
        // guessed from what it draws now, in this pass.
        for id in changed {
            estimates[id] = nil
            if let index = indexByID[id] { markDirty(from: index) }
        }
    }

    private func markDirty(from index: Int) {
        dirtyFrom = min(dirtyFrom ?? index, index)
    }

    /// The row's measured height, else its estimate.
    private func height(of row: TranscriptRow) -> CGFloat {
        if let height = heights[row.id] ?? estimates[row.id] { return height }
        let estimate = Self.estimatedHeight(of: row, width: itemWidth)
        estimates[row.id] = estimate
        return estimate
    }

    /// The heights for the scope and width now; the pass that follows
    /// lays every row out from them.
    private func loadHeightTable() {
        heights = TranscriptHeights.table(for: "\(scope)|\(Int(itemWidth.rounded()))")
        estimates = [:]
        markDirty(from: 0)
    }

    private func pixelRounded(_ value: CGFloat) -> CGFloat {
        let scale = collectionView?.traitCollection.displayScale ?? 0
        let pixels = scale > 0 ? scale : 2
        return (value * pixels).rounded(.up) / pixels
    }

    /// A row never measured: its text's lines at an average width per
    /// character, or a typical height for the rows without text. Only a
    /// start: it measures once it comes near the screen, and the scroller
    /// keeps the reader's row in place when it does.
    static func estimatedHeight(of row: TranscriptRow, width: CGFloat) -> CGFloat {
        TranscriptPerf.note(.rowHeightEstimate)
        switch row.kind {
        case .loadEarlier, .savedCopyStatus, .thinking, .working, .streaming:
            return rowGap + 44
        case .empty:
            return rowGap + 320
        case .pendingSend(let pending):
            return rowGap + textHeight(pending.draftText, width: width * 0.8)
        case .message(let target):
            if target.isStep || target.isReview { return rowGap + 44 }
            let message = target.message
            let attachments = CGFloat(message.attachments?.count ?? 0) * 200
            let width = message.role == .user ? width * 0.8 : width
            return rowGap + textHeight(message.content, width: width) + attachments
        }
    }

    /// Its lines at a scalar per character, counted from the bytes that
    /// start one: enough for a guess, in one pass with no paragraphs to
    /// split off, and no taller for a script of several bytes a character.
    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let charactersPerLine = max(20, width / 8)
        var lines: CGFloat = 0
        var paragraphCharacters = 0
        for byte in text.utf8 {
            if byte == UInt8(ascii: "\n") {
                lines += max(1, (CGFloat(paragraphCharacters) / charactersPerLine).rounded(.up))
                paragraphCharacters = 0
            } else if (byte & 0xC0) != 0x80 {
                paragraphCharacters += 1
            }
        }
        lines += max(1, (CGFloat(paragraphCharacters) / charactersPerLine).rounded(.up))
        return min(6_000, max(44, lines * 22 + 24))
    }
}

/// Row heights measured for one conversation at one width and text size.
@MainActor
final class TranscriptHeightTable {
    private var heights: [String: CGFloat] = [:]

    subscript(id: String) -> CGFloat? {
        get { heights[id] }
        set { heights[id] = newValue }
    }
}

/// The heights the transcript measured this session, by conversation, width
/// and text size, so a chat opened again lays out at its rows' heights at
/// once. The most recent scopes are kept.
@MainActor
enum TranscriptHeights {
    static let keptScopes = 24
    private static var tables: [String: TranscriptHeightTable] = [:]
    private static var order: [String] = []

    static func table(for scope: String) -> TranscriptHeightTable {
        order.removeAll { $0 == scope }
        order.append(scope)
        if let table = tables[scope] { return table }
        let table = TranscriptHeightTable()
        tables[scope] = table
        while order.count > keptScopes {
            tables[order.removeFirst()] = nil
        }
        return table
    }
}
