//
//  TranscriptBlankWatch.swift
//  Conduit
//
//  A transcript on screen whose rows aren't drawn (Eric 2026-11-10, issue
//  1942): the chat showed its title and composer, and the jump button over
//  nothing, until a tap. Not reproduced on a simulator or on a test phone,
//  so the transcript watches for it and saves a chat trace when it happens.
//

import UIKit

/// Once a second while its transcript is on screen and the app is active:
/// do rows cross the part of the transcript the reader sees, and does a
/// cell draw any of them? Two checks in a row with none drawn log what the
/// transcript held (ChatViewportTrace) and save a `blank` chat trace
/// (ChatViewportWatch), after laying the transcript out once and logging
/// whether that drew the rows, which tells a pass UIKit never ran from
/// cells it ran and left empty. Nothing else changes: the reader's offset,
/// the rows and their cells are left as they are.
@MainActor
final class TranscriptBlankWatch {
    static let interval: TimeInterval = 1
    /// Checks in a row with nothing drawn before it's taken as blank: a
    /// pass under way leaves a check's moment empty.
    static let blankChecks = 2

    private weak var controller: TranscriptViewController?
    private let save: @MainActor () -> Void
    private var timer: Timer?
    private var blankRun = 0

    /// `save` saves the blank trace; a test passes its own.
    init(
        controller: TranscriptViewController,
        save: @escaping @MainActor () -> Void = { ChatViewportWatch.shared.blankScreen() }
    ) {
        self.controller = controller
        self.save = save
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // Coarse: a blank screen lasts until a tap.
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        blankRun = 0
    }

    func check() {
        guard let controller else { stop(); return }
        let collectionView = controller.collectionView
        // Off screen or in the background, nothing was checked: start over
        // without saying the rows were drawn.
        guard collectionView.window != nil, collectionView.bounds.height > 0,
              UIApplication.shared.applicationState == .active else {
            blankRun = 0
            return
        }
        guard let finding = Self.finding(in: collectionView, layout: controller.layout) else {
            if blankRun >= Self.blankChecks {
                ChatViewportTrace.shared.log("blank screen drawn again after \(blankRun) checks")
            }
            blankRun = 0
            return
        }
        blankRun += 1
        guard blankRun == Self.blankChecks else { return }
        for line in Self.describe(finding, collectionView: collectionView, scroller: controller.scroller) {
            ChatViewportTrace.shared.log(line)
        }
        // Before the save, so the trace carries it: the save copies the
        // recorder as it stands.
        collectionView.setNeedsLayout()
        collectionView.layoutIfNeeded()
        let drawn = Self.finding(in: collectionView, layout: controller.layout) == nil
        ChatViewportTrace.shared.log("blank screen after a layout pass: \(drawn ? "drawn" : "still blank")")
        save()
    }

    /// What a blank transcript holds: rows crossing what the reader sees,
    /// none of them drawn. Nil when a row there is drawn, or none is there.
    struct Finding: Equatable {
        /// The rows crossing what the reader sees (TranscriptLayout's frames).
        var rowsOnScreen: [TranscriptRowFrame]
        /// The cells there, and why each draws nothing.
        var cells: [String]
    }

    static func finding(in collectionView: UICollectionView, layout: TranscriptLayout) -> Finding? {
        guard let surface = collectionView as? TranscriptScrollSurface else { return nil }
        let band = surface.visibleBand
        guard band.upperBound - band.lowerBound > 1 else { return nil }
        let rows = layout.rows(crossing: band)
        guard !rows.isEmpty else { return nil }
        let seen = CGRect(x: 0, y: band.lowerBound, width: collectionView.bounds.width, height: band.upperBound - band.lowerBound)
        var cells: [String] = []
        for case let cell as TranscriptCell in collectionView.visibleCells where cell.frame.intersects(seen) {
            guard let reason = emptiness(of: cell) else { return nil }
            cells.append("\(cell.hostedRowID.map(shortID) ?? "none") \(reason)")
        }
        return Finding(rowsOnScreen: rows, cells: cells)
    }

    /// Why a cell draws nothing, or nil when it draws its row.
    static func emptiness(of cell: TranscriptCell) -> String? {
        guard let hosting = cell.hosting, cell.hostedRowID != nil else { return "no hosting" }
        if cell.isHidden || cell.alpha < 0.01 { return "cell hidden" }
        guard hosting.isViewLoaded, let view = hosting.viewIfLoaded else { return "no view" }
        if view.superview !== cell.rowContainer { return "view elsewhere" }
        if view.window == nil { return "no window" }
        if view.isHidden || view.alpha < 0.01 { return "view hidden" }
        if (view.layer.presentation()?.opacity ?? 1) < 0.01 { return "view faded" }
        if view.bounds.height < 1 { return String(format: "view h %.1f", view.bounds.height) }
        if view.subviews.isEmpty, view.layer.sublayers?.isEmpty != false { return "view empty" }
        return nil
    }

    /// A row id's last 10 characters, so four rows or cells fit a line.
    static func shortID(_ id: String) -> String {
        String(id.suffix(10))
    }

    /// The trace's lines: the transcript's geometry and state, then the
    /// rows and cells, each line in the relay's 160 characters with the
    /// time the trace puts before it.
    static func describe(
        _ finding: Finding,
        collectionView: UICollectionView,
        scroller: TranscriptScroller
    ) -> [String] {
        let inset = collectionView.adjustedContentInset
        var speed: Float = 1
        var layer: CALayer? = collectionView.layer
        while let current = layer {
            speed *= current.speed
            layer = current.superlayer
        }
        let surface = collectionView as? TranscriptScrollSurface
        var lines = [
            String(
                format: "blank screen: offset %.1f content %.1f rows %.1f reserve %.1f viewport %.1f inset %.1f/%.1f",
                collectionView.contentOffset.y, collectionView.contentSize.height, surface?.rowsHeight ?? 0,
                surface?.reservedContentHeight ?? 0, collectionView.bounds.height, inset.top, inset.bottom
            ),
            String(
                format: "blank screen: following %d jump %d paused %d cells %d items %d needsLayout %d speed %.2f hidden %d alpha %.2f",
                scroller.isFollowingLatest ? 1 : 0, scroller.chrome.inputs.showsJumpToLatest ? 1 : 0,
                scroller.isPaused ? 1 : 0, collectionView.visibleCells.count, collectionView.indexPathsForVisibleItems.count,
                collectionView.layer.needsLayout() ? 1 : 0, speed, collectionView.isHidden ? 1 : 0, collectionView.alpha
            ),
        ]
        let rows = finding.rowsOnScreen.prefix(4).map { String(format: "%@ %.0f-%.0f", shortID($0.id), $0.minY, $0.maxY) }
        lines.append("blank screen rows: " + rows.joined(separator: ", "))
        lines.append("blank screen cells: " + (finding.cells.isEmpty ? "none" : finding.cells.prefix(4).joined(separator: ", ")))
        return lines
    }
}
