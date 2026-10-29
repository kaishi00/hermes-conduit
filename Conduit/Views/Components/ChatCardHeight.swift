//
//  ChatCardHeight.swift
//  Conduit
//
//  The height a card drawn in a web page takes in its message (an HTML
//  preview, a diagram, a formula), and when it takes it.
//
//  A card mounts at the room it reserves (the height it measured on this
//  phone before, else a placeholder) and its page reports its real height a
//  moment later. Taking that height moves everything under the card, and
//  when the card is above what the reader is looking at, the reader with
//  it: UIKit keeps the distance from the top (#1238). So the card hands the
//  measurement to the chat's scroll engine, which lets the card take it once
//  the reader's scrolling has rested and moves the offset by the growth
//  above the viewport in the same layout pass (ChatScrollEngine.cardMeasured).
//  Outside a chat (a job sheet, the saved copy) there is no engine and the
//  card takes its height at once.
//
//  A picture arriving in its row (ChatRowArrival) goes the same way: the
//  loading line stays until the reader's scrolling rests, and the row's
//  growth above the viewport is made good in the pass that lands it. So
//  does a failure taking the place of what a row or card shows (a picture's
//  label, a page's file card), whose height only its layout tells. What
//  memory already holds for a row (its picture, the picture's size) shows
//  without asking only on the row's first frame, or where the row has that
//  height already.
//

import SwiftUI

@MainActor
final class ChatCardHeight: ObservableObject, ChatScrollMeasuredCard {
    /// The height the card draws at once taken; nil while it holds the room
    /// it reserved.
    @Published private(set) var taken: CGFloat?
    /// The page the taken height came from. A page being replaced (a
    /// reload, another document) hides until it reports again, in the same
    /// room.
    @Published private(set) var drawnPage: AnyHashable?
    /// The room the card took when it was first laid out, fixed for its
    /// lifetime so a height remembered after the first frame never resizes
    /// it unannounced.
    private(set) var reserved: CGFloat?
    /// The card's frame in the transcript stack's space (`cardStackFrame`),
    /// nil before its first layout. The first one fixes the room; a change
    /// in height is a growth landing, which the engine waits for.
    var stackFrame: CGRect? {
        didSet {
            guard let stackFrame else { return }
            if reserved == nil, stackFrame.height > 0 { reserved = stackFrame.height }
            if stackFrame.height != oldValue?.height { engine?.cardFrameChanged(self) }
        }
    }
    /// The engine the last measurement went through.
    private weak var engine: ChatScrollEngine?
    private var measured: (height: CGFloat, page: AnyHashable)?

    /// The height the card's frame takes now: the taken one, else the room
    /// it reserved when first laid out, else `height`, which the first
    /// layout then reserves (`stackFrame`). Reading it changes nothing, so a
    /// body can call it.
    func frameHeight(reserving height: CGFloat) -> CGFloat {
        taken ?? reserved ?? height
    }

    /// Whether `page` has reported and shows.
    func isDrawn(_ page: AnyHashable) -> Bool {
        drawnPage == page
    }

    /// Whether `page` has reported, shown yet or not.
    func hasMeasured(_ page: AnyHashable) -> Bool {
        measured?.page == page || drawnPage == page
    }

    /// The page reported its height: through the engine when there is one.
    func pageMeasured(_ height: CGFloat, page: AnyHashable, engine: ChatScrollEngine?) {
        measured = (height, page)
        self.engine = engine
        if let engine {
            engine.cardMeasured(self)
        } else {
            takeMeasuredHeight()
        }
    }

    /// Another page is loading in the card's frame: it keeps its height and
    /// hides until that page reports.
    func pageReplaced() {
        measured = nil
        if drawnPage != nil { drawnPage = nil }
    }

    // MARK: - ChatScrollMeasuredCard

    var pendingGrowth: CGFloat {
        guard let measured else { return 0 }
        return measured.height - (stackFrame?.height ?? taken ?? reserved ?? measured.height)
    }

    func takeMeasuredHeight() {
        guard let measured else { return }
        if taken != measured.height { taken = measured.height }
        if drawnPage != measured.page { drawnPage = measured.page }
    }
}

extension View {
    /// Keeps `card` told where this view is in the transcript stack's space
    /// and how tall it is, which change with layout, never with a scroll
    /// tick.
    func cardStackFrame(_ card: ChatCardHeight) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: CoordinateSpace.named(ChatScrollEngine.coordinateSpaceName))
        } action: { frame in
            // Layout callbacks arrive on the main thread; said so, whatever
            // isolation the SDK gives this closure.
            MainActor.assumeIsolated { card.stackFrame = frame }
        }
    }
}

/// Something arriving in a row that changes its height (#1238): a picture
/// once it is decoded, or a failure taking the place of what the row shows
/// (a picture's label, a page's file card or "Couldn't draw"). The row
/// shows a loading line until a picture arrives, and a reply picture's
/// height follows the row's width, so the growth is known only once both
/// are: the view keeps the row's frame here (`chatRowFrame`), and when the
/// picture is decoded hands over the height the row will take and what
/// shows it. A failure's height only its layout tells. The engine lets it
/// show like a card taking its height (ChatScrollEngine.cardMeasured); a
/// row already at that height, or one outside a chat, shows it at once.
@MainActor
final class ChatRowArrival: ObservableObject, ChatScrollMeasuredCard {
    /// The row's frame in the transcript stack's space (`chatRowFrame`),
    /// nil before its first layout.
    var stackFrame: CGRect? {
        didSet {
            if stackFrame?.height != oldValue?.height { engine?.cardFrameChanged(self) }
        }
    }
    /// The engine the waiting arrival went through.
    private weak var engine: ChatScrollEngine?
    /// The height the row takes with what arrives in it (nil when only its
    /// layout tells), and what shows it.
    private var pending: (rowHeight: CGFloat?, show: () -> Void)?

    /// A reply picture's height in its row: scaled to the row's width, up
    /// to `maxHeight` (`Image.resizable().scaledToFit().frame(maxHeight:)`).
    /// Zero before the row has a width.
    static func fittedHeight(of size: CGSize, inWidth width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard size.width > 0, size.height > 0, width > 0 else { return 0 }
        return min(maxHeight, width * size.height / size.width)
    }

    /// What arrives is ready: `show` puts it in the row, which then takes
    /// `rowHeight`, or a height only its layout tells when that is nil (a
    /// failure's label or file card). Whether the row grows is its frame
    /// against that, not whether the picture's size is remembered: a
    /// placeholder that took the remembered size keeps its height and shows
    /// it at once, and so does a row not laid out yet (no height to grow
    /// from), while one laid out with the loading line before a cold
    /// launch's kept sizes had loaded waits like any growth.
    func arrive(rowHeight: CGFloat?, engine: ChatScrollEngine?, show: @escaping () -> Void) {
        pending = (rowHeight, show)
        self.engine = engine
        if let engine, rowHeight == nil || abs(pendingGrowth) > 0.5 {
            engine.cardMeasured(self)
        } else {
            takeMeasuredHeight()
        }
    }

    /// The row left the screen: whatever still waits is dropped (the row's
    /// task loads it again when the row is back), and with it the view
    /// `show` wrote to, so nothing keeps the decoded picture.
    func rowDisappeared() {
        pending = nil
    }

    /// Whether the row, as last laid out, has `rowHeight` already, or
    /// hasn't been laid out yet. What memory holds for the row (its
    /// picture, or the picture's size) shows only then: another row of the
    /// same picture, or a cold launch's kept sizes loading, can put it
    /// there after this row was laid out with its loading line, and the
    /// row would grow unannounced. It comes through `arrive` instead.
    func holds(_ rowHeight: CGFloat) -> Bool {
        guard let height = stackFrame?.height else { return true }
        return abs(rowHeight - height) <= 0.5
    }

    // MARK: - ChatScrollMeasuredCard

    var pendingGrowth: CGFloat {
        guard let rowHeight = pending?.rowHeight, rowHeight > 0,
              let height = stackFrame?.height, height > 0 else { return 0 }
        return rowHeight - height
    }

    var growthUnknown: Bool {
        guard let pending else { return false }
        return pending.rowHeight == nil
    }

    func takeMeasuredHeight() {
        guard let pending else { return }
        self.pending = nil
        pending.show()
    }
}

extension View {
    /// Keeps `arrival` told where this row is in the transcript stack's
    /// space and how tall it is, which change with layout, never with a
    /// scroll tick.
    func chatRowFrame(_ arrival: ChatRowArrival) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: CoordinateSpace.named(ChatScrollEngine.coordinateSpaceName))
        } action: { frame in
            MainActor.assumeIsolated { arrival.stackFrame = frame }
        }
    }
}
