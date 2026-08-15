import Combine
import SwiftUI
import UIKit

struct MarkdownSelectionSegmentDescriptor: Equatable, Hashable {
    let id: String
    let order: Int
    let separatorBefore: String
}

struct MarkdownSelectionEndpoint: Equatable, Hashable {
    let segmentID: String
    let offset: Int
}

struct MarkdownSelectionSpan: Equatable, Hashable {
    let segmentID: String
    let range: NSRange
}

enum MarkdownSelectionSegmentPlan {
    static func descriptors(for blocks: [MarkdownBlock]) -> [MarkdownSelectionSegmentDescriptor] {
        var descriptors: [MarkdownSelectionSegmentDescriptor] = []
        var order = 0

        func append(_ id: String, separatorBefore: String) {
            descriptors.append(
                MarkdownSelectionSegmentDescriptor(
                    id: id,
                    order: order,
                    separatorBefore: descriptors.isEmpty ? "" : separatorBefore
                )
            )
            order += 1
        }

        for (blockIndex, block) in blocks.enumerated() {
            let blockSeparator = blockIndex == 0 ? "" : "\n\n"

            switch block {
            case .heading(_, let text), .paragraph(let text):
                append("block-\(blockIndex)", separatorBefore: blockSeparator)
                _ = text

            case .quote(let lines):
                if let first = lines.first, let marker = MarkdownParser.calloutMarker(first.text) {
                    append("block-\(blockIndex)", separatorBefore: blockSeparator)
                    _ = marker
                } else {
                    for (lineIndex, line) in lines.enumerated() {
                        let id = lines.count == 1
                            ? "block-\(blockIndex)"
                            : "block-\(blockIndex)-quote-l\(lineIndex)"
                        append(id, separatorBefore: lineIndex == 0 ? blockSeparator : "\n")
                        _ = line
                    }
                }

            case .unorderedList(let items), .orderedList(let items):
                for (itemIndex, item) in items.enumerated() {
                    let id = items.count == 1
                        ? "block-\(blockIndex)"
                        : "block-\(blockIndex)-list-i\(itemIndex)"
                    append(id, separatorBefore: itemIndex == 0 ? blockSeparator : "\n")
                    _ = item
                }

            case .table(let headers, _, let rows):
                let tableRows = [headers] + rows
                for (rowIndex, row) in tableRows.enumerated() {
                    for (cellIndex, cell) in row.enumerated() {
                        let separatorBefore: String
                        if rowIndex == 0, cellIndex == 0 {
                            separatorBefore = blockSeparator
                        } else if cellIndex == 0 {
                            separatorBefore = "\n"
                        } else {
                            separatorBefore = " | "
                        }
                        append("block-\(blockIndex)-table-r\(rowIndex)-c\(cellIndex)", separatorBefore: separatorBefore)
                        _ = cell
                    }
                }

            case .callout:
                append("block-\(blockIndex)", separatorBefore: blockSeparator)

            case .columns(let columns):
                for (columnIndex, column) in columns.enumerated() {
                    let id = columns.count == 1
                        ? "block-\(blockIndex)"
                        : "block-\(blockIndex)-column-\(columnIndex)"
                    append(id, separatorBefore: columnIndex == 0 ? blockSeparator : " | ")
                    _ = column
                }

            case .code(let language, let source):
                if MarkdownLanguage.normalized(language) == "mermaid" {
                    order += 1
                } else {
                    append("block-\(blockIndex)-code", separatorBefore: blockSeparator)
                }
                _ = source

            case .image, .math, .divider:
                order += 1
            }
        }

        return descriptors
    }
}

@MainActor
final class MarkdownSelectionCoordinator: ObservableObject {
    final class SegmentRecord {
        var descriptor: MarkdownSelectionSegmentDescriptor
        var textView: UITextView?

        init(descriptor: MarkdownSelectionSegmentDescriptor, textView: UITextView?) {
            self.descriptor = descriptor
            self.textView = textView
        }
    }

    struct ActiveSelectionState: Equatable {
        var anchor: MarkdownSelectionEndpoint
        var focus: MarkdownSelectionEndpoint
        var anchorWindowPoint: CGPoint
        var focusWindowPoint: CGPoint
    }

    private struct PendingSelectionState {
        var anchor: MarkdownSelectionEndpoint
        var windowPoint: CGPoint
    }

    private enum NativeSelectionEdge {
        case lower
        case upper
    }

    private struct VisibleSelectionSnapshot: Equatable {
        var activeSelectionState: ActiveSelectionState?
        var selectionGestureIsActive: Bool
        var nativeSelectionOwnerSegmentID: String?
    }

    nonisolated let objectWillChange = ObservableObjectPublisher()
    private static weak var activeVisibleSelectionCoordinator: MarkdownSelectionCoordinator?
    private var currentRevision: String = ""
    private var recordsByID: [String: SegmentRecord] = [:]
    private var orderedSegmentIDs: [String] = []
    private var activeSelectionState: ActiveSelectionState?
    private var pendingSelectionState: PendingSelectionState?
    private var selectionGestureIsActive = false
    private var isApplyingSelectionRanges = false
    /// Readable by selection observers: the segment whose text view owns the
    /// native (private-gesture) selection, so a new touch landing on that
    /// view's selection or handles can keep driving the drag.
    private(set) var nativeSelectionOwnerSegmentID: String?
    private var nativeSelectionAnchorEdge: NativeSelectionEdge?
    /// True once the owner's native selection chrome (highlight + handles)
    /// has been dismissed because the coordinator owns a cross-block
    /// selection: the owner drops first responder, and a non-first-responder
    /// text view with a programmatic range renders nothing. The overlay
    /// draws every span in that state.
    private var isOwnerNativeChromeSuppressed = false

    func replaceSegments(_ descriptors: [MarkdownSelectionSegmentDescriptor], revision: String) {
        let before = visibleSelectionSnapshot()

        let revisionChanged = revision != currentRevision
        if revisionChanged {
            if !currentRevision.isEmpty {
                clearSelectionRanges()
            }
            resetSelectionState()
        }

        currentRevision = revision

        var latestByID: [String: (descriptor: MarkdownSelectionSegmentDescriptor, index: Int)] = [:]
        for (index, descriptor) in descriptors.enumerated() {
            latestByID[descriptor.id] = (descriptor, index)
        }

        let ordered = latestByID.values
            .sorted {
                if $0.descriptor.order != $1.descriptor.order {
                    return $0.descriptor.order < $1.descriptor.order
                }
                return $0.index < $1.index
            }
            .map(\.descriptor)

        orderedSegmentIDs = ordered.map(\.id)
        let currentIDs = Set(orderedSegmentIDs)
        recordsByID = recordsByID.filter { currentIDs.contains($0.key) }

        for descriptor in ordered {
            if let record = recordsByID[descriptor.id] {
                record.descriptor = descriptor
            } else {
                recordsByID[descriptor.id] = SegmentRecord(descriptor: descriptor, textView: nil)
            }
        }
        applySelectionRanges()
        publishIfVisibleSelectionChanged(from: before)
    }

    func register(descriptor: MarkdownSelectionSegmentDescriptor, textView: UITextView) {
        let existingRecord = recordsByID[descriptor.id]
        let registrationChanged = existingRecord?.descriptor != descriptor || existingRecord?.textView !== textView
        guard registrationChanged || !orderedSegmentIDs.contains(descriptor.id) else {
            applySelectionRanges()
            return
        }

        recordsByID[descriptor.id] = SegmentRecord(descriptor: descriptor, textView: textView)
        if !orderedSegmentIDs.contains(descriptor.id) {
            orderedSegmentIDs.append(descriptor.id)
            orderedSegmentIDs.sort { lhs, rhs in
                let lhsOrder = recordsByID[lhs]?.descriptor.order ?? .max
                let rhsOrder = recordsByID[rhs]?.descriptor.order ?? .max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs < rhs
            }
        }
        applySelectionRanges()
        if activeSelectionState != nil {
            objectWillChange.send()
        }
    }

    func unregister(segmentID: String, textView: UITextView) {
        guard let current = recordsByID[segmentID]?.textView, current === textView else { return }
        let before = visibleSelectionSnapshot()
        let activeSelectionContainsSegment = activeSpans.contains { $0.segmentID == segmentID }

        clearSelectionRange(in: current)
        recordsByID[segmentID]?.textView = nil

        if pendingSelectionState?.anchor.segmentID == segmentID {
            pendingSelectionState = nil
        }

        if activeSelectionContainsSegment {
            resetSelectionState()
            clearSelectionRanges()
        }

        publishIfVisibleSelectionChanged(from: before)
    }

    func text(for segmentID: String) -> String? {
        guard let textView = recordsByID[segmentID]?.textView else { return nil }
        return textView.attributedText?.string ?? textView.text
    }

    func orderedEndpoints(
        from start: MarkdownSelectionEndpoint,
        to end: MarkdownSelectionEndpoint
    ) -> (start: MarkdownSelectionEndpoint, end: MarkdownSelectionEndpoint) {
        let startIndex = orderedIndex(for: start.segmentID)
        let endIndex = orderedIndex(for: end.segmentID)

        if let startIndex, let endIndex {
            if startIndex == endIndex {
                return start.offset <= end.offset ? (start, end) : (end, start)
            }

            return startIndex < endIndex ? (start, end) : (end, start)
        }

        return (start, end)
    }

    func spans(from anchor: MarkdownSelectionEndpoint, to focus: MarkdownSelectionEndpoint) -> [MarkdownSelectionSpan] {
        let ordered = orderedEndpoints(from: anchor, to: focus)
        guard
            let startIndex = orderedIndex(for: ordered.start.segmentID),
            let endIndex = orderedIndex(for: ordered.end.segmentID),
            startIndex <= endIndex
        else {
            return []
        }

        if startIndex == endIndex {
            let length = textLength(for: ordered.start.segmentID)
            let lower = clamp(ordered.start.offset, to: length)
            let upper = clamp(ordered.end.offset, to: length)
            return [
                MarkdownSelectionSpan(
                    segmentID: ordered.start.segmentID,
                    range: NSRange(location: lower, length: max(0, upper - lower))
                )
            ]
        }

        let barrierIndices = selectionBarrierIndices(from: startIndex, to: endIndex)
        guard !barrierIndices.isEmpty else {
            return normalizedSpans(
                from: ordered.start,
                to: ordered.end,
                startIndex: startIndex,
                endIndex: endIndex
            )
        }

        guard let anchorIndex = orderedIndex(for: anchor.segmentID) else {
            return normalizedSpans(
                from: ordered.start,
                to: ordered.end,
                startIndex: startIndex,
                endIndex: endIndex
            )
        }

        if anchorIndex == startIndex {
            let clippedEndIndex = barrierIndices[0]
            let clippedEndSegmentID = orderedSegmentIDs[clippedEndIndex]
            return normalizedSpans(
                from: ordered.start,
                to: MarkdownSelectionEndpoint(
                    segmentID: clippedEndSegmentID,
                    offset: textLength(for: clippedEndSegmentID)
                ),
                startIndex: startIndex,
                endIndex: clippedEndIndex
            )
        }

        if anchorIndex == endIndex {
            let clippedStartIndex = barrierIndices[barrierIndices.count - 1] + 1
            let clippedStartSegmentID = orderedSegmentIDs[clippedStartIndex]
            return normalizedSpans(
                from: MarkdownSelectionEndpoint(segmentID: clippedStartSegmentID, offset: 0),
                to: ordered.end,
                startIndex: clippedStartIndex,
                endIndex: endIndex
            )
        }

        return normalizedSpans(
            from: ordered.start,
            to: ordered.end,
            startIndex: startIndex,
            endIndex: endIndex
        )
    }

    private func normalizedSpans(
        from start: MarkdownSelectionEndpoint,
        to end: MarkdownSelectionEndpoint,
        startIndex: Int,
        endIndex: Int
    ) -> [MarkdownSelectionSpan] {
        if startIndex == endIndex {
            let length = textLength(for: start.segmentID)
            let lower = clamp(start.offset, to: length)
            let upper = clamp(end.offset, to: length)
            return [
                MarkdownSelectionSpan(
                    segmentID: start.segmentID,
                    range: NSRange(location: lower, length: max(0, upper - lower))
                )
            ]
        }

        var spans: [MarkdownSelectionSpan] = []
        for index in startIndex...endIndex {
            let segmentID = orderedSegmentIDs[index]
            let length = textLength(for: segmentID)
            let range: NSRange

            if index == startIndex {
                let lower = clamp(start.offset, to: length)
                range = NSRange(location: lower, length: max(0, length - lower))
            } else if index == endIndex {
                let upper = clamp(end.offset, to: length)
                range = NSRange(location: 0, length: upper)
            } else {
                range = NSRange(location: 0, length: length)
            }

            spans.append(MarkdownSelectionSpan(segmentID: segmentID, range: range))
        }

        return spans
    }

    func copiedAttributedText(from start: MarkdownSelectionEndpoint, to end: MarkdownSelectionEndpoint) -> NSAttributedString {
        let spans = spans(from: start, to: end)
        struct CopyPiece {
            let separatorBefore: String
            let text: NSAttributedString
        }

        var pieces: [CopyPiece] = []

        for span in spans {
            guard let record = recordsByID[span.segmentID], let textView = record.textView else { continue }
            let attributed = textView.attributedText ?? NSAttributedString(string: textView.text ?? "")
            let safeRange = clampedRange(span.range, to: attributed.length)
            let selectedText = safeRange.length > 0
                ? attributed.attributedSubstring(from: safeRange)
                : NSAttributedString(string: "")

            pieces.append(
                CopyPiece(
                    separatorBefore: record.descriptor.separatorBefore,
                    text: selectedText
                )
            )
        }

        while pieces.first?.text.length == 0 {
            pieces.removeFirst()
        }
        while pieces.last?.text.length == 0 {
            pieces.removeLast()
        }

        let result = NSMutableAttributedString()

        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: piece.separatorBefore))
            }

            result.append(piece.text)
        }

        return result
    }

    private func orderedIndex(for segmentID: String) -> Int? {
        orderedSegmentIDs.firstIndex(of: segmentID)
    }

    private func textLength(for segmentID: String) -> Int {
        if let length = recordsByID[segmentID]?.textView?.attributedText?.length {
            return length
        }
        return text(for: segmentID)?.utf16.count ?? 0
    }

    private func clamp(_ offset: Int, to length: Int) -> Int {
        min(max(offset, 0), length)
    }

    private func clampedRange(_ range: NSRange, to length: Int) -> NSRange {
        let lower = clamp(range.location, to: length)
        let upper = clamp(NSMaxRange(range), to: length)
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    private func selectionBarrierExists(between leftSegmentID: String, and rightSegmentID: String) -> Bool {
        guard
            let leftOrder = recordsByID[leftSegmentID]?.descriptor.order,
            let rightOrder = recordsByID[rightSegmentID]?.descriptor.order
        else {
            return false
        }
        return rightOrder - leftOrder > 1
    }

    private func selectionBarrierIndices(from startIndex: Int, to endIndex: Int) -> [Int] {
        guard startIndex < endIndex else { return [] }
        return (startIndex..<endIndex).filter { index in
            selectionBarrierExists(between: orderedSegmentIDs[index], and: orderedSegmentIDs[index + 1])
        }
    }

    private func initialNativeSelectionAnchorEdge(
        segmentID: String,
        lower: Int,
        upper: Int
    ) -> NativeSelectionEdge {
        guard
            let pendingSelectionState,
            pendingSelectionState.anchor.segmentID == segmentID
        else {
            return .lower
        }

        let pendingOffset = clamp(pendingSelectionState.anchor.offset, to: textLength(for: segmentID))
        let distanceToLower = abs(pendingOffset - lower)
        let distanceToUpper = abs(pendingOffset - upper)
        return distanceToUpper < distanceToLower ? .upper : .lower
    }

    var hasActiveSelection: Bool {
        activeSelectionState != nil
    }

    var hasCrossSegmentSelection: Bool {
        activeSpans.count > 1
    }

    var activeSpans: [MarkdownSelectionSpan] {
        guard let activeSelectionState else { return [] }
        return spans(from: activeSelectionState.anchor, to: activeSelectionState.focus)
    }

    var isApplyingNativeSelectionRanges: Bool {
        isApplyingSelectionRanges
    }

    var isSelectionGestureActive: Bool {
        selectionGestureIsActive
    }

    func beginSelection(segmentID: String, offset: Int, windowPoint: CGPoint) {
        claimVisibleSelectionOwnership()
        let before = visibleSelectionSnapshot()
        let endpoint = MarkdownSelectionEndpoint(segmentID: segmentID, offset: offset)
        activeSelectionState = ActiveSelectionState(
            anchor: endpoint,
            focus: endpoint,
            anchorWindowPoint: windowPoint,
            focusWindowPoint: windowPoint
        )
        pendingSelectionState = nil
        nativeSelectionOwnerSegmentID = segmentID
        nativeSelectionAnchorEdge = nil
        selectionGestureIsActive = true
        applySelectionRanges()
        publishIfVisibleSelectionChanged(from: before)
    }

    func beginPendingSelection(segmentID: String, offset: Int, windowPoint: CGPoint) {
        // While a selection drag is underway, the private text-selection
        // gesture re-delivers a synthetic touchesBegan as it takes over the
        // touch; that re-delivery must not clear the in-progress selection.
        // The observer recognizer ends the gesture on touch-up, so a genuine
        // later tap still reaches this path and clears as before.
        guard !selectionGestureIsActive else { return }

        if let previous = Self.activeVisibleSelectionCoordinator, previous !== self {
            previous.clearSelection()
        }

        if activeSelectionState != nil {
            clearSelection()
        }

        pendingSelectionState = PendingSelectionState(
            anchor: MarkdownSelectionEndpoint(segmentID: segmentID, offset: offset),
            windowPoint: windowPoint
        )
    }

    func cancelPendingSelection() {
        pendingSelectionState = nil
    }

    func activateSelection(segmentID: String, selectedRange: NSRange, windowPoint: CGPoint) {
        updateNativeSelection(
            segmentID: segmentID,
            selectedRange: selectedRange,
            lowerWindowPoint: windowPoint,
            upperWindowPoint: windowPoint
        )
    }

    func updateNativeSelection(
        segmentID: String,
        selectedRange: NSRange,
        lowerWindowPoint: CGPoint,
        upperWindowPoint: CGPoint
    ) {
        let length = textLength(for: segmentID)
        let lower = clamp(selectedRange.location, to: length)
        let upper = clamp(NSMaxRange(selectedRange), to: length)
        guard upper > lower else { return }

        // While the selection's focus sits in another segment, the owner's
        // private gesture (and the first-responder dance when the edit menu
        // appears, or an out-of-bounds handle drag ends) keeps reporting the
        // owner's own range — capped at its bounds, sometimes an empty caret.
        // Honoring those reports would collapse the cross-block selection
        // after the finger lifts, right when the user goes to copy. Reports
        // from the segment the focus currently sits in still flow through: a
        // fresh touch on text clears state via beginPendingSelection first,
        // and dragging back into the owner keeps native granularity there.
        if let focusSegmentID = activeSelectionState?.focus.segmentID,
           focusSegmentID != segmentID,
           nativeSelectionOwnerSegmentID == segmentID {
            return
        }

        claimVisibleSelectionOwnership()
        let before = visibleSelectionSnapshot()
        let anchorEdge: NativeSelectionEdge
        if activeSelectionState != nil,
           nativeSelectionOwnerSegmentID == segmentID,
           let nativeSelectionAnchorEdge {
            anchorEdge = nativeSelectionAnchorEdge
        } else {
            anchorEdge = initialNativeSelectionAnchorEdge(
                segmentID: segmentID,
                lower: lower,
                upper: upper
            )
        }

        let lowerEndpoint = MarkdownSelectionEndpoint(segmentID: segmentID, offset: lower)
        let upperEndpoint = MarkdownSelectionEndpoint(segmentID: segmentID, offset: upper)
        let pendingWindowPoint = pendingSelectionState?.anchor.segmentID == segmentID
            ? pendingSelectionState?.windowPoint
            : nil
        let anchor = anchorEdge == .upper ? upperEndpoint : lowerEndpoint
        let focus = anchorEdge == .upper ? lowerEndpoint : upperEndpoint
        let anchorWindowPoint = pendingWindowPoint
            ?? (anchorEdge == .upper ? upperWindowPoint : lowerWindowPoint)
        let focusWindowPoint = anchorEdge == .upper ? lowerWindowPoint : upperWindowPoint

        activeSelectionState = ActiveSelectionState(
            anchor: anchor,
            focus: focus,
            anchorWindowPoint: anchorWindowPoint,
            focusWindowPoint: focusWindowPoint
        )
        pendingSelectionState = nil
        nativeSelectionOwnerSegmentID = segmentID
        nativeSelectionAnchorEdge = anchorEdge
        selectionGestureIsActive = true
        applySelectionRanges()
        publishIfVisibleSelectionChanged(from: before)
    }

    func updateSelection(windowPoint: CGPoint) {
        if let endpoint = endpoint(at: windowPoint) {
            updateSelection(
                segmentID: endpoint.segmentID,
                offset: endpoint.offset,
                windowPoint: windowPoint
            )
            return
        }

        // Between blocks (spacers, dividers, card chrome) the finger still
        // means "keep dragging the selection": resolve to the nearest
        // registered text view and clamp to its leading/trailing edge, so
        // fast drags with sparse touch samples don't freeze the focus in
        // dead zones.
        if let endpoint = nearestEndpoint(at: windowPoint) {
            updateSelection(
                segmentID: endpoint.segmentID,
                offset: endpoint.offset,
                windowPoint: windowPoint
            )
            return
        }

        guard var activeSelectionState else { return }
        activeSelectionState.focusWindowPoint = windowPoint
        self.activeSelectionState = activeSelectionState
        applySelectionRanges()
    }

    func updateSelection(segmentID: String, offset: Int, windowPoint: CGPoint) {
        guard var activeSelectionState else { return }

        let before = visibleSelectionSnapshot()
        activeSelectionState.focus = MarkdownSelectionEndpoint(segmentID: segmentID, offset: offset)
        activeSelectionState.focusWindowPoint = windowPoint
        self.activeSelectionState = activeSelectionState
        applySelectionRanges()
        publishIfVisibleSelectionChanged(from: before)
    }

    /// Anchor-side counterpart to updateSelection(windowPoint:), used when
    /// dragging the custom anchor handle: the focus stays put while the
    /// selection's leading endpoint follows the finger.
    func updateAnchorSelection(windowPoint: CGPoint) {
        if let endpoint = endpoint(at: windowPoint) ?? nearestEndpoint(at: windowPoint) {
            updateAnchorSelection(
                segmentID: endpoint.segmentID,
                offset: endpoint.offset,
                windowPoint: windowPoint
            )
            return
        }

        guard var activeSelectionState else { return }
        activeSelectionState.anchorWindowPoint = windowPoint
        self.activeSelectionState = activeSelectionState
        applySelectionRanges()
    }

    func updateAnchorSelection(segmentID: String, offset: Int, windowPoint: CGPoint) {
        guard var activeSelectionState else { return }

        let before = visibleSelectionSnapshot()
        activeSelectionState.anchor = MarkdownSelectionEndpoint(segmentID: segmentID, offset: offset)
        activeSelectionState.anchorWindowPoint = windowPoint
        self.activeSelectionState = activeSelectionState
        applySelectionRanges()
        publishIfVisibleSelectionChanged(from: before)
    }

    var activeAnchorEndpoint: MarkdownSelectionEndpoint? {
        activeSelectionState?.anchor
    }

    var activeFocusEndpoint: MarkdownSelectionEndpoint? {
        activeSelectionState?.focus
    }

    /// Caret-style rect (window coordinates) for a selection endpoint —
    /// the trailing edge of the character before the offset, or the leading
    /// edge for offset 0. Drives the custom handle positions.
    func caretRect(for endpoint: MarkdownSelectionEndpoint, in window: UIWindow) -> CGRect? {
        guard
            let textView = recordsByID[endpoint.segmentID]?.textView,
            textView.window === window
        else { return nil }

        textView.layoutIfNeeded()
        let length = textView.textStorage.length
        let lineHeight = textView.font?.lineHeight ?? 16
        let viewRect: CGRect
        if length == 0 {
            viewRect = CGRect(x: 0, y: 0, width: 2, height: lineHeight)
        } else {
            let offset = clamp(endpoint.offset, to: length)
            let characterIndex = offset > 0 ? offset - 1 : 0
            let glyphRange = textView.layoutManager.glyphRange(
                forCharacterRange: NSRange(location: characterIndex, length: 1),
                actualCharacterRange: nil
            )
            if glyphRange.length > 0 {
                var glyphRect = textView.layoutManager.boundingRect(
                    forGlyphRange: glyphRange,
                    in: textView.textContainer
                )
                if offset > 0 {
                    glyphRect.origin.x = glyphRect.maxX
                }
                glyphRect.size.width = 2
                viewRect = glyphRect
            } else {
                viewRect = CGRect(x: offset > 0 ? textView.textContainer.size.width : 0, y: 0, width: 2, height: lineHeight)
            }
        }

        let insetRect = viewRect.offsetBy(
            dx: textView.textContainerInset.left - textView.contentOffset.x,
            dy: textView.textContainerInset.top - textView.contentOffset.y
        )
        let windowRect = textView.convert(insetRect, to: window)
        guard !windowRect.isNull else { return nil }
        return windowRect
    }

    func endSelection() {
        let before = visibleSelectionSnapshot()
        selectionGestureIsActive = false
        pendingSelectionState = nil
        applySelectionRanges()

        // A cross-segment selection is coordinator-owned from here on: the
        // custom handles and copy pill take over, so the owner drops first-
        // responder and its ranges are re-applied programmatically — which
        // renders without the system's native handles (they cannot travel
        // outside the owner's own text view). Within-block selections keep
        // the fully native flow.
        if hasCrossSegmentSelection,
           let ownerID = nativeSelectionOwnerSegmentID,
           let owner = recordsByID[ownerID]?.textView,
           owner.isFirstResponder {
            owner.resignFirstResponder()
            applySelectionRanges()
        }

        publishIfVisibleSelectionChanged(from: before)
    }

    func clearSelection() {
        let before = visibleSelectionSnapshot()
        resetSelectionState()
        clearSelectionRanges()
        publishIfVisibleSelectionChanged(from: before)
    }

    func copiedAttributedTextForActiveSelection() -> NSAttributedString {
        guard let activeSelectionState else { return NSAttributedString(string: "") }
        return copiedAttributedText(from: activeSelectionState.anchor, to: activeSelectionState.focus)
    }

    func highlightRects(in window: UIWindow?) -> [CGRect] {
        guard let window, activeSelectionState != nil else { return [] }
        let nativeSelectionOwnerSegmentID = nativeSelectionOwnerSegmentID

        return activeSpans.flatMap { span -> [CGRect] in
            guard
                let textView = recordsByID[span.segmentID]?.textView,
                textView.window === window
            else {
                return []
            }
            // While the owner's native chrome is visible (within-block
            // selection, or the first instants of a drag), its span shows the
            // native highlight and must not double-draw under the overlay.
            // From the moment a selection spans blocks the native chrome is
            /// tint-suppressed and the overlay covers every span.
            if span.segmentID == nativeSelectionOwnerSegmentID,
               textView.isFirstResponder,
               !isOwnerNativeChromeSuppressed {
                return []
            }
            return selectionRects(for: span.range, in: textView, window: window)
        }
    }

    private func endpoint(at windowPoint: CGPoint) -> MarkdownSelectionEndpoint? {
        for segmentID in orderedSegmentIDs {
            guard
                let textView = recordsByID[segmentID]?.textView,
                let window = textView.window
            else {
                continue
            }

            let windowBounds = textView.convert(textView.bounds, to: window)
            guard windowBounds.contains(windowPoint) else { continue }

            let localPoint = textView.convert(windowPoint, from: window)
            return MarkdownSelectionEndpoint(
                segmentID: segmentID,
                offset: utf16Offset(for: localPoint, in: textView)
            )
        }

        return nil
    }

    /// Resolves a window point that hit no text view to the nearest
    /// registered one, clamping the offset to the nearest edge: above the
    /// view selects from its start, below selects through its end, and a
    /// horizontal miss picks the closest insertion point on the line.
    private func nearestEndpoint(at windowPoint: CGPoint) -> MarkdownSelectionEndpoint? {
        var nearest: (segmentID: String, textView: UITextView, distance: CGFloat)?

        for segmentID in orderedSegmentIDs {
            guard
                let textView = recordsByID[segmentID]?.textView,
                let window = textView.window
            else {
                continue
            }

            let bounds = textView.convert(textView.bounds, to: window)
            let dx = max(bounds.minX - windowPoint.x, 0, windowPoint.x - bounds.maxX)
            let dy = max(bounds.minY - windowPoint.y, 0, windowPoint.y - bounds.maxY)
            let distance = hypot(dx, dy)
            if nearest == nil || distance < nearest!.distance {
                nearest = (segmentID, textView, distance)
            }
        }

        guard let (segmentID, textView, _) = nearest, let window = textView.window else { return nil }

        let bounds = textView.convert(textView.bounds, to: window)
        let offset: Int
        if windowPoint.y < bounds.minY {
            offset = 0
        } else if windowPoint.y > bounds.maxY {
            offset = textLength(for: segmentID)
        } else {
            let clamped = CGPoint(
                x: min(max(windowPoint.x, bounds.minX), bounds.maxX),
                y: min(max(windowPoint.y, bounds.minY), bounds.maxY)
            )
            offset = utf16Offset(for: textView.convert(clamped, from: window), in: textView)
        }
        return MarkdownSelectionEndpoint(segmentID: segmentID, offset: offset)
    }

    private func utf16Offset(for localPoint: CGPoint, in textView: UITextView) -> Int {
        let length = textView.textStorage.length
        guard length > 0 else { return 0 }

        textView.layoutIfNeeded()
        _ = textView.layoutManager.glyphRange(for: textView.textContainer)

        let textContainerPoint = CGPoint(
            x: localPoint.x - textView.textContainerInset.left + textView.contentOffset.x,
            y: localPoint.y - textView.textContainerInset.top + textView.contentOffset.y
        )
        var fraction: CGFloat = 0
        let characterIndex = textView.layoutManager.characterIndex(
            for: textContainerPoint,
            in: textView.textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        let insertionIndex = characterIndex + (fraction > 0.5 ? 1 : 0)
        return clamp(insertionIndex, to: length)
    }

    /// Internal for tests: the selection suites drive span re-application
    /// directly to verify chrome dismissal behavior.
    func applySelectionRanges() {
        guard activeSelectionState != nil else {
            clearSelectionRanges()
            return
        }

        updateOwnerNativeChromeSuppression()

        isApplyingSelectionRanges = true
        defer { isApplyingSelectionRanges = false }

        let spansBySegmentID = Dictionary(uniqueKeysWithValues: activeSpans.map { ($0.segmentID, $0.range) })

        for segmentID in orderedSegmentIDs {
            guard let textView = recordsByID[segmentID]?.textView else { continue }
            if let range = spansBySegmentID[segmentID] {
                setSelectedRange(range, in: textView)
            } else {
                clearSelectionRange(in: textView)
            }
        }
    }

    private func clearSelectionRanges() {
        isApplyingSelectionRanges = true
        defer { isApplyingSelectionRanges = false }

        for record in recordsByID.values {
            guard let textView = record.textView else { continue }
            clearSelectionRange(in: textView)
        }
    }

    /// While a selection spans blocks, the coordinator draws every span in
    /// the overlay and the owner's native chrome must not render alongside
    /// it. Clearing the tint renders iOS 26's selection black rather than
    /// hiding it, so instead the owner resigns first responder at the first
    /// cross-block instant — a non-first-responder text view renders no
    /// native selection at all, while the gesture machinery (recognizer and
    /// delegate reports, not first-responder based) keeps driving the drag.
    private func updateOwnerNativeChromeSuppression() {
        guard let ownerID = nativeSelectionOwnerSegmentID,
              let owner = recordsByID[ownerID]?.textView
        else { return }

        if hasCrossSegmentSelection, !isOwnerNativeChromeSuppressed, owner.isFirstResponder {
            isOwnerNativeChromeSuppressed = true
            owner.resignFirstResponder()
        }
    }

    private func setSelectedRange(_ range: NSRange, in textView: UITextView) {
        let safeRange = clampedRange(range, to: textView.textStorage.length)
        guard textView.selectedRange != safeRange else { return }
        textView.selectedRange = safeRange
    }

    private func clearSelectionRange(in textView: UITextView) {
        let location = clamp(textView.selectedRange.location, to: textView.textStorage.length)
        let emptyRange = NSRange(location: location, length: 0)
        guard textView.selectedRange != emptyRange else { return }
        textView.selectedRange = emptyRange
    }

    private func selectionRects(for range: NSRange, in textView: UITextView, window: UIWindow) -> [CGRect] {
        let safeRange = clampedRange(range, to: textView.textStorage.length)
        guard safeRange.length > 0 else { return [] }

        textView.layoutIfNeeded()
        _ = textView.layoutManager.glyphRange(for: textView.textContainer)

        let glyphRange = textView.layoutManager.glyphRange(
            forCharacterRange: safeRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return [] }

        var rects: [CGRect] = []
        textView.layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: glyphRange,
            in: textView.textContainer
        ) { rect, _ in
            let viewRect = rect.offsetBy(
                dx: textView.textContainerInset.left - textView.contentOffset.x,
                dy: textView.textContainerInset.top - textView.contentOffset.y
            )
            let windowRect = textView.convert(viewRect, to: window)
            if !windowRect.isNull, !windowRect.isEmpty {
                rects.append(windowRect.integral)
            }
        }
        return rects
    }

    private func visibleSelectionSnapshot() -> VisibleSelectionSnapshot {
        VisibleSelectionSnapshot(
            activeSelectionState: activeSelectionState,
            selectionGestureIsActive: selectionGestureIsActive,
            nativeSelectionOwnerSegmentID: nativeSelectionOwnerSegmentID
        )
    }

    private func publishIfVisibleSelectionChanged(from before: VisibleSelectionSnapshot) {
        if visibleSelectionSnapshot() != before {
            objectWillChange.send()
        }
    }

    private func claimVisibleSelectionOwnership() {
        if let previous = Self.activeVisibleSelectionCoordinator, previous !== self {
            previous.clearSelection()
        }
        Self.activeVisibleSelectionCoordinator = self
        MarkdownSelectionChromeLocator.shared.selectionOwnerDidChange()
    }

    #if DEBUG
    /// Selection-fixture affordance: copies the app's active cross-block
    /// selection to the pasteboard and returns it, so UI tests and manual
    /// passes can verify the copy path without driving the system menu.
    static func copyActiveSelectionToPasteboard() -> String? {
        guard let coordinator = activeVisibleSelectionCoordinator else { return nil }
        let text = coordinator.copiedAttributedTextForActiveSelection().string
        guard !text.isEmpty else { return nil }
        UIPasteboard.general.string = text
        return text
    }
    #endif

    private func resetSelectionState() {
        activeSelectionState = nil
        pendingSelectionState = nil
        selectionGestureIsActive = false
        nativeSelectionOwnerSegmentID = nil
        nativeSelectionAnchorEdge = nil
        if Self.activeVisibleSelectionCoordinator === self {
            Self.activeVisibleSelectionCoordinator = nil
            MarkdownSelectionChromeLocator.shared.selectionOwnerDidChange()
        }
        isOwnerNativeChromeSuppressed = false
    }

    /// The coordinator owning the currently visible selection, used by the
    /// window-level selection chrome (handles + copy pill).
    static var activeCoordinator: MarkdownSelectionCoordinator? {
        activeVisibleSelectionCoordinator
    }
}
