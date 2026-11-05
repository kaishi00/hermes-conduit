//
//  RichDiffCardViews.swift
//  Conduit
//
//  A diff card in the chat and its full view. In the chat the card is
//  drawn from what it carries, so it holds one height from its first
//  frame: a summary, then one small file's first lines, or a row per file.
//  A tap opens the sheet, where every file folds open to numbered lines
//  with the changed words picked out, read from the host when the card
//  only lists its files (RichDiffLoader).
//

import SwiftUI
import UIKit

// MARK: - The card

struct RichDiffCard: View {
    let card: RichCard

    /// What the chat shows before "Show all": a single file's lines, or a
    /// row per file.
    static let shownLines = 20
    static let shownFiles = 6

    @State private var opened: RichDiffOpened?

    var body: some View {
        if let diff = card.diff {
            RichInfoCardFrame(title: card.title, source: card.source) {
                VStack(alignment: .leading, spacing: 10) {
                    RichDiffSummary(diff: diff)
                    if diff.files.count == 1, let file = diff.files.first, !file.hunks.isEmpty {
                        singleFile(file, in: diff)
                    } else {
                        fileRows(diff)
                    }
                }
            }
            .sheet(item: $opened) { opened in
                RichDiffSheet(card: card, diff: diff, focus: opened.file)
            }
        }
    }

    private func singleFile(_ file: RichDiffFile, in diff: RichDiff) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                opened = RichDiffOpened(file: file.id)
            } label: {
                RichDiffFileRow(file: file, opens: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the changes"))
            RichDiffLinesPreview(file: file, limit: Self.shownLines)
            if file.lineCount > Self.shownLines {
                Button(AppLocalization.string("Show all \(file.lineCount) lines")) {
                    opened = RichDiffOpened(file: file.id)
                }
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(Color.conduitAccent)
            }
        }
    }

    @ViewBuilder
    private func fileRows(_ diff: RichDiff) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(diff.files.prefix(Self.shownFiles)) { file in
                if diff.opensWhole {
                    Button {
                        opened = RichDiffOpened(file: file.id)
                    } label: {
                        RichDiffFileRow(file: file, opens: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the changes"))
                } else {
                    RichDiffFileRow(file: file, opens: false)
                }
            }
            let moreCount = diff.fileCount - min(diff.files.count, Self.shownFiles)
            if moreCount > 0 {
                if diff.opensWhole {
                    Button(AppLocalization.string("\(moreCount) more files")) {
                        opened = RichDiffOpened(file: diff.files.count > Self.shownFiles ? Self.shownFiles : nil)
                    }
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.conduitAccent)
                    .frame(minHeight: 36)
                } else {
                    Text(AppLocalization.string("\(moreCount) more files"))
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The file a tap opens the sheet at; nil opens it at the top.
struct RichDiffOpened: Identifiable {
    let file: Int?
    var id: Int { file ?? -1 }
}

/// "3 files changed", the lines added and removed, and a bar of five
/// blocks in their proportion, as code hosts show it.
struct RichDiffSummary: View {
    let diff: RichDiff

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(AppLocalization.string("\(diff.fileCount) files changed"))
                .scaledFont(.subheadline.weight(.semibold))
            RichDiffCounts(added: diff.added, removed: diff.removed)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Self.blockColor(index, added: diff.added, removed: diff.removed))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Green blocks for the share added, red for removed, grey past them.
    static func blocks(added: Int, removed: Int) -> (added: Int, removed: Int) {
        let total = added + removed
        guard total > 0 else { return (0, 0) }
        var green = Int((Double(added) / Double(total) * 5).rounded())
        var red = 5 - green
        if added > 0, green == 0 { green = 1; red = 4 }
        if removed > 0, red == 0 { red = 1; green = 4 }
        // A small change doesn't fill the bar.
        if total < 5 {
            green = min(green, added)
            red = min(red, removed)
        }
        return (green, red)
    }

    private static func blockColor(_ index: Int, added: Int, removed: Int) -> Color {
        let blocks = blocks(added: added, removed: removed)
        if index < blocks.added { return .green }
        if index < blocks.added + blocks.removed { return .red }
        return Color.primary.opacity(0.15)
    }
}

/// "+12 −4", green and red.
struct RichDiffCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(added.formatted(.number.locale(AppLocalization.formattingLocale)))")
                .foregroundStyle(.green)
            Text(verbatim: "\u{2212}\(removed.formatted(.number.locale(AppLocalization.formattingLocale)))")
                .foregroundStyle(.red)
        }
        .scaledFont(.caption.weight(.semibold))
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AppLocalization.string("\(Int(added)) lines added") + ", "
                                 + AppLocalization.string("\(Int(removed)) lines removed")))
    }
}

/// A file's row: what happened to it, its name with the folder dimmed,
/// and its counts.
struct RichDiffFileRow: View {
    let file: RichDiffFile
    let opens: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: Self.symbol(file))
                .scaledFont(.subheadline)
                .foregroundStyle(Self.tint(file))
                .frame(minWidth: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: file.name)
                    .scaledFont(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = detail {
                    Text(verbatim: detail)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let status = Self.statusName(file) {
                Text(verbatim: status)
                    .scaledFont(.caption2.weight(.semibold))
                    .foregroundStyle(Self.tint(file))
            }
            if !file.binary {
                RichDiffCounts(added: file.added, removed: file.removed)
            }
            if opens {
                Image(systemName: "chevron.right")
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The folder, or where a renamed file came from.
    private var detail: String? {
        if file.status == .renamed, let old = file.oldPath { return "\u{2190} \(old)" }
        return file.folder
    }

    static func symbol(_ file: RichDiffFile) -> String {
        if file.binary { return "doc.fill" }
        switch file.status {
        case .added: return "plus.square"
        case .deleted: return "minus.square"
        case .renamed: return "arrow.right.square"
        case .modified: return "square.and.pencil"
        }
    }

    static func tint(_ file: RichDiffFile) -> Color {
        switch file.status {
        case .added: return .green
        case .deleted: return .red
        case .renamed: return Color.conduitAccent
        case .modified: return .secondary
        }
    }

    static func statusName(_ file: RichDiffFile) -> String? {
        if file.binary { return AppLocalization.string("Binary") }
        switch file.status {
        case .added: return AppLocalization.string("New")
        case .deleted: return AppLocalization.string("Deleted")
        case .renamed: return AppLocalization.string("Renamed")
        case .modified: return nil
        }
    }
}

/// A single file's first lines in the chat, wrapped, with its hunk bars.
struct RichDiffLinesPreview: View {
    let file: RichDiffFile
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(RichDiffRow.rows(file, limit: limit).enumerated()), id: \.offset) { _, row in
                RichDiffRowView(row: row, digits: RichDiffRow.digits(file), wraps: true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Rows

/// One row of a file's changes: a hunk's bar, a line, or the unchanged
/// lines between two hunks.
enum RichDiffRow: Equatable {
    case hunk(RichDiffHunk)
    case line(RichDiffLine)
    case unchanged(Int)

    /// A file's rows in order, the first `limit` lines at most.
    static func rows(_ file: RichDiffFile, limit: Int = .max) -> [RichDiffRow] {
        var rows: [RichDiffRow] = []
        var left = limit
        for (index, hunk) in file.hunks.enumerated() {
            guard left > 0 else { break }
            rows.append(.hunk(hunk))
            for line in hunk.lines.prefix(left) { rows.append(.line(line)) }
            left -= min(left, hunk.lines.count)
            if left > 0, let gap = file.unchangedAfter(index) { rows.append(.unchanged(gap)) }
        }
        return rows
    }

    /// How many digits the file's largest line number has, so its
    /// numbers line up.
    static func digits(_ file: RichDiffFile) -> Int {
        let largest = file.hunks.flatMap(\.lines).reduce(0) { max($0, $1.old ?? 0, $1.new ?? 0) }
        return max(String(largest).count, 2)
    }
}

struct RichDiffRowView: View {
    let row: RichDiffRow
    let digits: Int
    let wraps: Bool
    var language = ""

    var body: some View {
        switch row {
        case .hunk(let hunk):
            Text(verbatim: hunk.header)
                .scaledFont(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.conduitAccent.opacity(0.08))
        case .line(let line):
            RichDiffLineView(line: line, digits: digits, wraps: wraps, language: language)
        case .unchanged(let count):
            Label {
                Text(AppLocalization.string("\(count) unchanged lines"))
            } icon: {
                Image(systemName: "ellipsis")
            }
            .scaledFont(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04))
        }
    }
}

struct RichDiffLineView: View {
    let line: RichDiffLine
    let digits: Int
    let wraps: Bool
    var language = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.old)
            number(line.new)
            Text(verbatim: sign)
                .foregroundStyle(signColor)
                .frame(minWidth: 14)
                .accessibilityHidden(true)
            Text(Self.highlighted(line, language: language))
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: true)
                .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
                .padding(.trailing, 8)
        }
        .scaledFont(.caption.monospaced())
        .padding(.vertical, 1)
        .background(background)
        .contextMenu {
            Button {
                UIPasteboard.general.string = line.text
            } label: {
                Label(AppLocalization.string("Copy Line"), systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(kindName), \(line.text)"))
    }

    private func number(_ value: Int?) -> some View {
        // A template of the widest number holds the column's width.
        ZStack(alignment: .trailing) {
            Text(verbatim: String(repeating: "8", count: digits)).hidden()
            Text(verbatim: value.map(String.init) ?? "")
        }
        .foregroundStyle(.tertiary)
        .padding(.leading, 6)
        .accessibilityHidden(true)
    }

    private var sign: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "\u{2212}"
        case .context: return " "
        }
    }

    private var signColor: Color {
        switch line.kind {
        case .added: return .green
        case .removed: return .red
        case .context: return .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.13)
        case .removed: return Color.red.opacity(0.13)
        case .context: return .clear
        }
    }

    private var kindName: String {
        switch line.kind {
        case .added: return AppLocalization.string("Added")
        case .removed: return AppLocalization.string("Removed")
        case .context: return AppLocalization.string("Unchanged")
        }
    }

    /// The app's code colors, with the part a changed line changed
    /// picked out behind it.
    static func highlighted(_ line: RichDiffLine, language: String) -> AttributedString {
        var text = SyntaxHighlighter.highlight(line.text, language: language)
        guard let changed = line.changed, changed.upperBound <= text.characters.count else { return text }
        let start = text.characters.index(text.startIndex, offsetBy: changed.lowerBound)
        let end = text.characters.index(text.startIndex, offsetBy: changed.upperBound)
        text[start..<end].backgroundColor = line.kind == .added ? Color.green.opacity(0.3) : Color.red.opacity(0.3)
        return text
    }
}

// MARK: - The sheet

struct RichDiffSheet: View {
    let card: RichCard
    /// What the card carries: the lines of a short diff, the files of a
    /// long one.
    let diff: RichDiff
    let focus: Int?

    /// Past this many lines a file starts folded, when there are others.
    static let foldedLines = 400

    @State private var whole: RichDiff?
    @State private var failure: RichDiffLoader.LoadError?
    @State private var failed = false
    @State private var folded: Set<Int> = []
    @State private var foldedSet = false
    /// Files the user folded or opened, kept as they left them when the
    /// whole diff arrives.
    @State private var touched: Set<Int> = []
    @State private var attempt = 0
    @AppStorage("richCards.diffWrapsLines") private var wraps = true
    @Environment(\.dismiss) private var dismiss

    private var shown: RichDiff { whole ?? diff }
    private var loading: Bool { whole == nil && !diff.hasLines && diff.keptID != nil && !failed }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(wraps ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        VStack(alignment: .leading, spacing: 8) {
                            RichDiffSummary(diff: shown)
                            if card.source != nil { RichInfoSourceLine(source: card.source) }
                            state
                        }
                        .padding(16)
                        ForEach(shown.files) { file in
                            Section {
                                if !folded.contains(file.id) { fileBody(file) }
                            } header: {
                                header(file)
                            }
                            .id(file.id)
                        }
                        if shown.moreFiles > 0 {
                            Text(AppLocalization.string("\(Int(shown.moreFiles)) more files"))
                                .scaledFont(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }
                    }
                }
                .task(id: attempt) { await load() }
                .onAppear { foldDefaults(shown) }
                .onChange(of: whole) { _, read in
                    if let read { foldedSet = false; foldDefaults(read) }
                    jump(proxy)
                }
                .task {
                    // Laid out first, then moved to the file tapped.
                    jump(proxy)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Toggle(isOn: $wraps) {
                                Label(AppLocalization.string("Wrap Lines"), systemImage: "text.word.spacing")
                            }
                            if shown.files.count > 1 {
                                Section(AppLocalization.string("Files")) {
                                    ForEach(shown.files) { file in
                                        Button(file.path) {
                                            folded.remove(file.id)
                                            touched.insert(file.id)
                                            withAnimation { proxy.scrollTo(file.id, anchor: .top) }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .accessibilityLabel(Text("More"))
                        }
                    }
                }
            }
            .navigationTitle(Text(verbatim: card.title ?? AppLocalization.string("Changes")))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var state: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading the changes…")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if failed {
            VStack(alignment: .leading, spacing: 6) {
                Text(failure == .gone ? AppLocalization.string("These changes are no longer kept on Hermes.")
                     : AppLocalization.string("The changes couldn't be loaded."))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                if failure != .gone {
                    Button("Try Again") {
                        failed = false
                        attempt += 1
                    }
                    .scaledFont(.footnote.weight(.semibold))
                }
            }
        }
    }

    private func header(_ file: RichDiffFile) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy) {
                    if folded.contains(file.id) { folded.remove(file.id) } else { folded.insert(file.id) }
                    touched.insert(file.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: folded.contains(file.id) ? "chevron.right" : "chevron.down")
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 14)
                        .accessibilityHidden(true)
                    RichDiffFileRow(file: file, opens: false)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(Text(verbatim: folded.contains(file.id) ? AppLocalization.string("Collapsed")
                                     : AppLocalization.string("Expanded")))
            if !file.hunks.isEmpty {
                Menu {
                    Button {
                        UIPasteboard.general.string = file.patch
                    } label: {
                        Label(AppLocalization.string("Copy Changes"), systemImage: "doc.on.doc")
                    }
                    Button {
                        UIPasteboard.general.string = file.path
                    } label: {
                        Label(AppLocalization.string("Copy Path"), systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 32, minHeight: 32)
                        .contentShape(Rectangle())
                        .accessibilityLabel(Text("More"))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    @ViewBuilder
    private func fileBody(_ file: RichDiffFile) -> some View {
        if file.binary {
            note(AppLocalization.string("A binary file: no lines to show."))
        } else if file.hunks.isEmpty {
            if !loading, !failed { note(AppLocalization.string("No lines changed.")) }
        } else {
            let digits = RichDiffRow.digits(file)
            let language = (file.path as NSString).pathExtension.lowercased()
            ForEach(Array(RichDiffRow.rows(file).enumerated()), id: \.offset) { _, row in
                RichDiffRowView(row: row, digits: digits, wraps: wraps, language: language)
            }
            if file.cut { note(AppLocalization.string("Its other changes aren't shown.")) }
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    /// Long, deleted and binary files start folded when there are others,
    /// except the one tapped.
    private func foldDefaults(_ diff: RichDiff) {
        guard !foldedSet else { return }
        foldedSet = true
        guard diff.files.count > 1 else { return }
        let defaults = diff.files.filter { file in
            file.id != focus && !touched.contains(file.id)
                && (file.binary || file.status == .deleted || file.lineCount > Self.foldedLines)
        }.map(\.id)
        folded = folded.intersection(touched).union(defaults)
    }

    private func jump(_ proxy: ScrollViewProxy) {
        guard let focus, focus > 0 else { return }
        proxy.scrollTo(focus, anchor: .top)
    }

    private func load() async {
        guard whole == nil, !diff.hasLines, let id = diff.keptID else { return }
        do {
            whole = try await RichDiffLoader.shared.diff(id)
        } catch {
            failure = (error as? RichDiffLoader.LoadError) ?? .notConnected
            if case DashboardTicketBridgeError.http(let status, _) = error, status == 404 { failure = .gone }
            failed = true
        }
    }
}
