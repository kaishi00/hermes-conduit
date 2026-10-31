//
//  ChatCardHeight.swift
//  Conduit
//
//  The height a card drawn in a web page takes in its message (an HTML
//  preview, a diagram, a formula).
//
//  A card mounts at the room it reserves (the height it measured on this
//  phone before, else a placeholder) and its page reports its real height a
//  moment later, which the card takes at once. When the card is above what
//  the reader is looking at, a chat's transcript keeps the reader's row
//  where it is as the card grows (TranscriptScroller, #1533), as it does
//  for a picture arriving in its row. A group room's card grows in place
//  until rooms draw on that transcript too.
//

import SwiftUI

@MainActor
final class ChatCardHeight: ObservableObject {
    /// The height the page measured, which the card draws at; nil while it
    /// holds the room it reserved.
    @Published private(set) var taken: CGFloat?
    /// The page the taken height came from. A page being replaced (a
    /// reload, another document) hides until it reports again, in the same
    /// room.
    @Published private(set) var drawnPage: AnyHashable?

    /// The height the card's frame takes now: the taken one, else
    /// `height`, the room it reserves. Reading it changes nothing, so a body
    /// can call it.
    func frameHeight(reserving height: CGFloat) -> CGFloat {
        taken ?? height
    }

    /// Whether `page` has reported and shows.
    func isDrawn(_ page: AnyHashable) -> Bool {
        drawnPage == page
    }

    /// The page reported its height: the card takes it.
    func pageMeasured(_ height: CGFloat, page: AnyHashable) {
        if taken != height { taken = height }
        if drawnPage != page { drawnPage = page }
    }

    /// Another page is loading in the card's frame: it keeps its height and
    /// hides until that page reports.
    func pageReplaced() {
        if drawnPage != nil { drawnPage = nil }
    }
}
