//
//  ComposerSuggestionKeys.swift
//  Conduit
//
//  A hardware keyboard on a suggestion list over a composer field (slash
//  commands, @mentions): Up and Down move a highlight through its rows,
//  Return or Tab picks the highlighted row (Tab the first when none is),
//  Escape closes the list. Without a highlight Return keeps its own job,
//  so `/status` and Return still sends. ReturnKeyTextView reads the keys;
//  the composer that shows the list owns the rows and the pick.
//

import Foundation

enum ComposerSuggestionKey: Equatable {
    case up
    case down
    /// Return or Tab: pick the highlighted row.
    case choose
    /// Tab with nothing highlighted: pick the first row.
    case chooseFirst
    case dismiss
}

/// What the field's keys act on: set while a list shows.
struct ComposerSuggestionKeys {
    /// Whether a row is highlighted, so Return picks it.
    var hasHighlight: Bool
    var handle: (ComposerSuggestionKey) -> Void
}

enum ComposerSuggestionHighlight {
    /// The row highlighted after an arrow: Down from none takes the first
    /// row, Up from none the last, and both wrap around.
    static func moved(_ index: Int?, by key: ComposerSuggestionKey, count: Int) -> Int? {
        guard count > 0 else { return nil }
        switch key {
        case .down:
            guard let index, index < count else { return 0 }
            return (index + 1) % count
        case .up:
            guard let index, index < count else { return count - 1 }
            return (index - 1 + count) % count
        case .choose, .chooseFirst, .dismiss:
            return index.map { min($0, count - 1) }
        }
    }

    /// The row a pick takes: the highlighted one, or the first for Tab.
    static func picked(_ index: Int?, by key: ComposerSuggestionKey, count: Int) -> Int? {
        guard count > 0 else { return nil }
        switch key {
        case .choose:
            guard let index, index < count else { return nil }
            return index
        case .chooseFirst:
            guard let index, index < count else { return 0 }
            return index
        case .up, .down, .dismiss:
            return nil
        }
    }
}
