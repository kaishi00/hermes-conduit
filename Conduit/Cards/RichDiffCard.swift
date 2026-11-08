//
//  RichDiffCard.swift
//  Conduit
//
//  A diff card (plugin 0.133+): changes Hermes showed line by line, for a
//  review, a commit, a config or two versions of a text. The plugin reads
//  the patch on the host (card_schema.read_diff) into files, hunks and
//  lines, so the app never parses a patch: it numbers the lines from each
//  hunk's starts and picks out the words a changed line changed.
//
//  A short diff travels whole on its card. A longer one lists its files and
//  names the whole diff the host keeps (`id`), read from the plugin's
//  GET /boards/diffs when the user opens it (RichDiffLoader).
//

import Foundation

struct RichDiff: Equatable, Hashable {
    let files: [RichDiffFile]
    /// Over every file, those not listed too.
    let added: Int
    let removed: Int
    /// Files changed past those listed.
    let moreFiles: Int
    /// The whole diff on the host, when the card carries only its files.
    let keptID: String?

    init?(json: Any?) {
        guard let json = json as? [String: Any] else { return nil }
        let files = (json["files"] as? [[String: Any]] ?? []).enumerated().compactMap { RichDiffFile(json: $1, index: $0) }
        guard !files.isEmpty else { return nil }
        self.files = files
        added = (json["added"] as? NSNumber)?.intValue ?? files.reduce(0) { $0 + $1.added }
        removed = (json["removed"] as? NSNumber)?.intValue ?? files.reduce(0) { $0 + $1.removed }
        moreFiles = (json["more_files"] as? NSNumber)?.intValue ?? 0
        keptID = (json["id"] as? String).flatMap { RichCardSchema.isDiffID($0) ? $0 : nil }
    }

    /// Whether the card carries the lines, not only the files.
    var hasLines: Bool { files.contains { !$0.hunks.isEmpty } }

    /// Every file changed, listed or not.
    var fileCount: Int { files.count + moreFiles }

    /// The lines the card's hunks hold.
    var lineCount: Int { files.reduce(0) { $0 + $1.lineCount } }

    /// Whether the user can see more than the card shows: the whole diff
    /// on the host, or lines past what the card draws.
    var opensWhole: Bool { keptID != nil || hasLines }
}

struct RichDiffFile: Equatable, Hashable, Identifiable {
    enum Status: String {
        case modified, added, deleted, renamed
    }

    /// Its place in the diff.
    let id: Int
    let path: String
    let oldPath: String?
    let status: Status
    let binary: Bool
    let added: Int
    let removed: Int
    /// Its hunks stop short of all its changes.
    let cut: Bool
    let hunks: [RichDiffHunk]

    init?(json: [String: Any], index: Int) {
        guard let path = json["path"] as? String, !path.isEmpty,
              let status = (json["status"] as? String).flatMap(Status.init(rawValue:)) else { return nil }
        id = index
        self.path = path
        oldPath = json["old_path"] as? String
        self.status = status
        binary = json["binary"] as? Bool ?? false
        added = (json["added"] as? NSNumber)?.intValue ?? 0
        removed = (json["removed"] as? NSNumber)?.intValue ?? 0
        cut = json["cut"] as? Bool ?? false
        hunks = binary ? [] : (json["hunks"] as? [[String: Any]] ?? []).compactMap(RichDiffHunk.init(json:))
    }

    /// The file's name, its folder dimmed beside it.
    var name: String { (path as NSString).lastPathComponent }

    var folder: String? {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }

    var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }

    /// The lines between two hunks that didn't change, after each hunk but
    /// the last (nil where the patch says nothing).
    func unchangedAfter(_ index: Int) -> Int? {
        guard hunks.indices.contains(index + 1) else { return nil }
        let gap = hunks[index + 1].oldStart - hunks[index].oldEnd
        return gap > 0 ? gap : nil
    }

    /// The file as a patch, for Copy.
    var patch: String {
        var lines = [status == .added ? "--- /dev/null" : "--- a/\(oldPath ?? path)",
                     status == .deleted ? "+++ /dev/null" : "+++ b/\(path)"]
        for hunk in hunks {
            lines.append(hunk.header)
            lines.append(contentsOf: hunk.lines.map(\.patchLine))
        }
        return lines.joined(separator: "\n")
    }
}

struct RichDiffHunk: Equatable, Hashable {
    let oldStart: Int
    let newStart: Int
    /// What the patch names after @@, like the function.
    let context: String?
    let lines: [RichDiffLine]

    init?(json: [String: Any]) {
        guard let oldStart = (json["old_start"] as? NSNumber)?.intValue,
              let newStart = (json["new_start"] as? NSNumber)?.intValue else { return nil }
        let raw = (json["lines"] as? [String] ?? []).filter(RichCardSchema.isDiffLine)
        guard !raw.isEmpty else { return nil }
        self.oldStart = oldStart
        self.newStart = newStart
        context = json["context"] as? String
        lines = RichDiffLine.numbered(raw, oldStart: oldStart, newStart: newStart)
    }

    /// The first old line past this hunk.
    var oldEnd: Int { oldStart + lines.filter { $0.kind != .added }.count }

    var header: String {
        let olds = lines.filter { $0.kind != .added }.count
        let news = lines.filter { $0.kind != .removed }.count
        let head = "@@ -\(oldStart),\(olds) +\(newStart),\(news) @@"
        return context.map { "\(head) \($0)" } ?? head
    }
}

struct RichDiffLine: Equatable, Hashable {
    enum Kind {
        case added, removed, context
    }

    let kind: Kind
    let text: String
    /// Its number in the old file and the new one; an added line has no
    /// old one and a removed line no new one.
    let old: Int?
    let new: Int?
    /// The part a changed line changed, in characters, when it's paired
    /// with its other side and they have something in common.
    let changed: Range<Int>?

    var patchLine: String {
        switch kind {
        case .added: return "+" + text
        case .removed: return "-" + text
        case .context: return " " + text
        }
    }

    /// A hunk's lines numbered from its starts, each run of removed lines
    /// followed by added ones paired line by line, so the words a line
    /// changed can be picked out.
    static func numbered(_ raw: [String], oldStart: Int, newStart: Int) -> [RichDiffLine] {
        var old = oldStart
        var new = newStart
        var parsed: [(kind: Kind, text: String, old: Int?, new: Int?)] = []
        for line in raw {
            let text = String(line.dropFirst())
            switch line.first ?? " " {
            case "+":
                parsed.append((.added, text, nil, new))
                new += 1
            case "-":
                parsed.append((.removed, text, old, nil))
                old += 1
            default:
                parsed.append((.context, text, old, new))
                old += 1
                new += 1
            }
        }
        var changed = [Range<Int>?](repeating: nil, count: parsed.count)
        var index = 0
        while index < parsed.count {
            guard parsed[index].kind == .removed else {
                index += 1
                continue
            }
            let removedStart = index
            while index < parsed.count, parsed[index].kind == .removed { index += 1 }
            let addedStart = index
            while index < parsed.count, parsed[index].kind == .added { index += 1 }
            let pairs = min(addedStart - removedStart, index - addedStart)
            for pair in 0..<pairs {
                let (before, after) = changedParts(parsed[removedStart + pair].text, parsed[addedStart + pair].text)
                changed[removedStart + pair] = before
                changed[addedStart + pair] = after
            }
        }
        return parsed.enumerated().map { offset, line in
            RichDiffLine(kind: line.kind, text: line.text, old: line.old, new: line.new, changed: changed[offset])
        }
    }

    /// The middles two lines don't share, past their common start and end;
    /// nil for both when they share nothing (the whole line changed) or
    /// nothing changed.
    static func changedParts(_ before: String, _ after: String) -> (Range<Int>?, Range<Int>?) {
        let left = Array(before)
        let right = Array(after)
        var prefix = 0
        while prefix < left.count, prefix < right.count, left[prefix] == right[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < left.count - prefix, suffix < right.count - prefix,
              left[left.count - 1 - suffix] == right[right.count - 1 - suffix] { suffix += 1 }
        // Leading spaces alone in common don't make two lines alike.
        let shared = left.prefix(prefix).filter { !$0.isWhitespace }.count + suffix
        guard shared > 0, prefix + suffix < max(left.count, right.count) else { return (nil, nil) }
        let before = prefix < left.count - suffix ? prefix..<(left.count - suffix) : nil
        let after = prefix < right.count - suffix ? prefix..<(right.count - suffix) : nil
        return (before, after)
    }
}

/// Reads the whole of a diff the host keeps (GET /boards/diffs), once per
/// launch: a file the user opens again draws from what was read.
@MainActor
final class RichDiffLoader {
    static let shared = RichDiffLoader()

    static let capability = "diff-cards"
    static let path = "/api/plugins/conduit_push/boards/diffs"
    private static let keptReads = 20

    /// The connected Hermes' answer for a path; nil while none is
    /// connected (AppState sets it).
    var read: (@MainActor (String) async throws -> [String: Any])?
    private var diffs: [String: RichDiff] = [:]
    private var order: [String] = []

    enum LoadError: Error {
        case notConnected, gone
    }

    static func readPath(id: String) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return path + "?" + (components.percentEncodedQuery ?? "")
    }

    func diff(_ id: String) async throws -> RichDiff {
        if let kept = diffs[id] { return kept }
        guard RichCardSchema.isDiffID(id), let read else { throw LoadError.notConnected }
        let answer = try await read(Self.readPath(id: id))
        guard let json = RichCardSchema.bundled?.normalizeDiff(answer["diff"]), let diff = RichDiff(json: json) else {
            throw LoadError.gone
        }
        if diffs[id] == nil {
            order.append(id)
            if order.count > Self.keptReads { diffs[order.removeFirst()] = nil }
        }
        diffs[id] = diff
        return diff
    }
}
