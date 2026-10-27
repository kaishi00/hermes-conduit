//
//  V2WorkspaceViews.swift
//  Conduit
//
//  The Folder tab in Artifacts (#1389): the open chat's working folder, or a
//  project's, as a tree. Files open in the viewers chats use (Quick Look
//  for pictures, PDFs and documents) or as text, Markdown drawn, and a text
//  file can be edited. With the plugin's workspace routes (0.107+) it also
//  searches names and lines inside files, lists recent files, and makes,
//  renames, moves, duplicates, deletes and uploads files. A file path
//  tapped in a reply opens here. On a wide window the tab sits in a panel
//  beside the chat; on a phone, in the chat's Artifacts sheet.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Which half of Artifacts shows.
enum ArtifactsTab: String, CaseIterable, Identifiable {
    case made
    case folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .made: return AppLocalization.string("Artifacts")
        case .folder: return AppLocalization.string("Folder")
        }
    }
}

struct ArtifactsTabPicker: View {
    @Binding var tab: ArtifactsTab

    var body: some View {
        Picker(AppLocalization.string("Show"), selection: Binding(get: { tab }, set: {
            Haptics.selection()
            tab = $0
        })) {
            ForEach(ArtifactsTab.allCases) { option in
                Text(verbatim: option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .dynamicTypeSize(...DynamicTypeSize.pinnedChromeCap)
    }
}

/// The Folder tab.
struct WorkspaceFolderView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var explorer = WorkspaceExplorer()
    /// Whether the open chat's folder is offered (a chat is open).
    let includesChat: Bool
    /// Whether this tab shows the files replies' paths name. Only the open
    /// chat's tab does, so a page elsewhere doesn't take them.
    var handlesReveals = false

    @State private var rootPath: String?
    @State private var query = ""
    @State private var showsRecent = false
    @State private var viewing: WorkspaceEntry?
    @State private var opening: String?
    @State private var page: OpenPage?
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var moving: WorkspaceEntry?
    @State private var deleting: WorkspaceEntry?
    @State private var uploadFolder: String?
    @State private var showsImporter = false
    @State private var failure: String?

    private struct OpenPage: Identifiable {
        let id = UUID()
        let name: String
        let html: String
    }

    /// A name to ask for: a new folder or file in `folder`, or a new name
    /// for `entry`.
    private struct NamePrompt: Identifiable {
        enum Kind { case folder, file, rename }
        let id = UUID()
        let kind: Kind
        let folder: String
        var entry: WorkspaceEntry?
    }

    private var roots: [WorkspaceRoot] { appState.workspaceRoots(includingChat: includesChat) }

    private var root: WorkspaceRoot? {
        roots.first { $0.path == rootPath } ?? roots.first
    }

    private struct Key: Equatable {
        let dashboard: UUID?
        let profile: String
        let root: String?
    }

    private var key: Key {
        Key(dashboard: appState.activeDashboardID, profile: appState.workspaceProfile, root: root?.path)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 8)
                if root != nil, explorer.canChange {
                    searchField
                        .padding(.bottom, 6)
                }
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await explorer.refresh() }
        .task { explorer.attach(appState) }
        .task(id: key) {
            explorer.attach(appState)
            guard let root = key.root else {
                explorer.close()
                return
            }
            await explorer.open(root: root, profile: key.profile)
        }
        .task(id: query) {
            // Typing settles before the host is asked.
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            await explorer.runSearch(query)
        }
        .onChange(of: appState.workspaceChanges) { _, _ in
            Task { await explorer.refresh() }
        }
        .task(id: handlesReveals ? appState.workspaceReveal?.id : nil) {
            guard handlesReveals, let reveal = appState.workspaceReveal else { return }
            appState.workspaceReveal = nil
            await show(reveal)
        }
        .sheet(item: $viewing, onDismiss: { explorer.closeFile() }) { entry in
            WorkspaceFileSheet(explorer: explorer, entry: entry, root: root)
                .environmentObject(appState)
        }
        .sheet(item: $page) { page in
            HTMLPreviewSheet(name: page.name, html: page.html)
        }
        .sheet(item: $moving) { entry in
            WorkspaceMoveSheet(explorer: explorer, entry: entry)
                .environmentObject(appState)
        }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField(AppLocalization.string("Name"), text: $promptText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(prompt?.kind == .rename ? AppLocalization.string("Rename") : AppLocalization.string("Create")) {
                if let prompt { submit(prompt, name: promptText) }
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) { prompt = nil }
        }
        .confirmationDialog(
            deleting.map { AppLocalization.string("Delete \($0.name)?") } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Delete"), role: .destructive) {
                guard let entry = deleting else { return }
                deleting = nil
                Task { await perform { client, root in try await client.delete(root: root, path: entry.path) } }
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(deleting?.isDirectory == true
                 ? AppLocalization.string("The folder and everything in it are deleted from your Hermes host. This can't be undone.")
                 : AppLocalization.string("The file is deleted from your Hermes host. This can't be undone."))
        }
        .alert(AppLocalization.string("Couldn't do that"), isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button(AppLocalization.string("OK"), role: .cancel) { failure = nil }
        } message: {
            Text(verbatim: failure ?? "")
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, let folder = uploadFolder else { return }
            Task { await upload(urls, into: folder) }
        }
    }

    private var promptTitle: String {
        switch prompt?.kind {
        case .folder: return AppLocalization.string("New Folder")
        case .file: return AppLocalization.string("New File")
        case .rename: return AppLocalization.string("Rename")
        case nil: return ""
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(roots) { option in
                    Button {
                        Haptics.selection()
                        rootPath = option.path
                    } label: {
                        Label {
                            Text(verbatim: option.title)
                        } icon: {
                            Image(systemName: option.kind == .chat ? "bubble.left.and.text.bubble.right" : "folder")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.conduitAccent)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: root?.title ?? AppLocalization.string("No folder"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let path = root?.path {
                            Text(verbatim: path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    if roots.count > 1 {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .disabled(roots.count < 2)
            .accessibilityLabel(AppLocalization.string("Folder: \(root?.title ?? AppLocalization.string("No folder"))"))
            if let root, explorer.canChange {
                Menu {
                    actions(in: root.path)
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(AppLocalization.string("Add to Folder"))
            }
        }
        .padding(.top, 8)
        .dynamicTypeSize(...DynamicTypeSize.pinnedChromeCap)
    }

    @ViewBuilder
    private func actions(in folder: String) -> some View {
        Button {
            ask(.folder, in: folder)
        } label: {
            Label(AppLocalization.string("New Folder"), systemImage: "folder.badge.plus")
        }
        Button {
            ask(.file, in: folder)
        } label: {
            Label(AppLocalization.string("New File"), systemImage: "doc.badge.plus")
        }
        Button {
            uploadFolder = folder
            showsImporter = true
        } label: {
            Label(AppLocalization.string("Upload Files"), systemImage: "square.and.arrow.up")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(AppLocalization.string("Search names and inside files"), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if explorer.searching {
                ProgressView()
                    .controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if root == nil {
            unavailable(
                title: Text("No Folder Yet"),
                detail: Text(includesChat
                    ? AppLocalization.string("Hermes hasn't said which folder this chat works in yet. Projects' folders show here too.")
                    : AppLocalization.string("Your projects' folders show here.")),
                symbol: "folder.badge.questionmark"
            )
        } else if let error = explorer.error, explorer.entries.isEmpty {
            unavailable(title: Text("This folder couldn't load"), detail: Text(verbatim: error),
                        symbol: "exclamationmark.triangle", retry: true)
        } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, explorer.canChange {
            searchResults
        } else {
            if !explorer.canChange {
                Label {
                    Text("Update the Conduit plugin on your Hermes host to search this folder and make, move or delete files here. Settings › Conduit plugin can update it.")
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            }
            if !explorer.recent.isEmpty {
                recentSection
            }
            let rows = explorer.rows()
            if rows.isEmpty, let root, explorer.loading.contains(root.path) {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if rows.isEmpty {
                unavailable(title: Text("Empty Folder"), detail: Text("Nothing in this folder yet."), symbol: "folder")
            } else {
                sectionTitle(Text("Files"))
                VStack(spacing: 2) {
                    ForEach(rows, id: \.entry.id) { row in
                        treeRow(row.entry, depth: row.depth)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: Text) -> some View {
        title
            .font(.footnote.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                Haptics.selection()
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { showsRecent.toggle() }
            } label: {
                HStack {
                    sectionTitle(Text("Recently Changed"))
                    Spacer()
                    Image(systemName: showsRecent ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsRecent ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))
            if showsRecent {
                ForEach(explorer.recent.prefix(12)) { entry in
                    fileRow(entry, depth: 0, detail: relativeLocation(entry))
                }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if let result = explorer.search {
            if result.names.isEmpty, result.matches.isEmpty {
                unavailable(title: Text("No Results"), detail: Text("Nothing in this folder matches."),
                            symbol: "magnifyingglass")
            } else {
                if !result.names.isEmpty {
                    sectionTitle(Text("Names"))
                    VStack(spacing: 2) {
                        ForEach(result.names) { entry in
                            fileRow(entry, depth: 0, detail: relativeLocation(entry))
                        }
                    }
                }
                if !result.matches.isEmpty {
                    sectionTitle(Text("Inside Files"))
                    VStack(spacing: 8) {
                        ForEach(result.matches) { match in
                            matchRow(match)
                        }
                    }
                }
                if result.truncated {
                    Text("Showing the first matches. Search for something more specific to find the rest.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    private func unavailable(title: Text, detail: Text, symbol: String, retry: Bool = false) -> some View {
        ContentUnavailableView {
            Label { title } icon: { Image(systemName: symbol) }
        } description: {
            detail
        } actions: {
            if retry {
                Button(AppLocalization.string("Try Again")) { Task { await explorer.refresh() } }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Rows

    private func treeRow(_ entry: WorkspaceEntry, depth: Int) -> some View {
        Group {
            if entry.isDirectory {
                Button {
                    Haptics.selection()
                    Task { await explorer.toggle(entry) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: explorer.expanded.contains(entry.path) ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.conduitAccent)
                        Text(verbatim: entry.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if explorer.loading.contains(entry.path) {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .padding(.leading, CGFloat(depth) * 16)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { menu(entry) }
                .accessibilityValue(explorer.expanded.contains(entry.path)
                                    ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))
            } else {
                fileRow(entry, depth: depth, detail: details(entry))
            }
        }
    }

    private func fileRow(_ entry: WorkspaceEntry, depth: Int, detail: String) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(spacing: 10) {
                if depth > 0 || entry.isDirectory {
                    Color.clear.frame(width: 12)
                }
                Image(systemName: entry.isDirectory ? "folder.fill" : WorkspaceFileKind(name: entry.name).symbol)
                    .foregroundStyle(entry.isDirectory ? Color.conduitAccent : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: entry.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if opening == entry.path {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.leading, CGFloat(depth) * 16)
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu(entry) }
        .accessibilityElement(children: .combine)
    }

    private func matchRow(_ match: WorkspaceSearchMatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: WorkspaceFileKind(name: match.name).symbol)
                    .foregroundStyle(.secondary)
                Text(verbatim: match.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            Text(verbatim: relativeLocation(path: match.path))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            ForEach(match.lines, id: \.self) { line in
                Button {
                    open(WorkspaceEntry(name: match.name, path: match.path, isDirectory: false), line: line.number)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(line.number)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 28, alignment: .trailing)
                        Text(Self.highlighted(line))
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Line \(line.number): \(line.text)"))
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// A match's line with the match itself in bold, tinted.
    static func highlighted(_ line: WorkspaceSearchMatch.Line) -> AttributedString {
        var text = AttributedString(line.text)
        let characters = text.characters
        guard line.matchLength > 0, line.matchStart < characters.count else { return text }
        let start = characters.index(characters.startIndex, offsetBy: line.matchStart)
        let end = characters.index(start, offsetBy: min(line.matchLength, characters.distance(from: start, to: characters.endIndex)))
        text[start..<end].foregroundColor = Color.conduitAccent
        text[start..<end].inlinePresentationIntent = .stronglyEmphasized
        return text
    }

    @ViewBuilder
    private func menu(_ entry: WorkspaceEntry) -> some View {
        if !entry.isDirectory {
            Button {
                open(entry)
            } label: {
                Label(AppLocalization.string("Open"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button {
                share(entry)
            } label: {
                Label(AppLocalization.string("Share or Save"), systemImage: "square.and.arrow.up")
            }
        }
        Button {
            UIPasteboard.general.string = entry.path
        } label: {
            Label(AppLocalization.string("Copy Path"), systemImage: "doc.on.doc")
        }
        if explorer.canChange {
            if entry.isDirectory {
                Section {
                    actions(in: entry.path)
                }
            }
            Section {
                Button {
                    prompt = NamePrompt(kind: .rename, folder: entry.folder, entry: entry)
                    promptText = entry.name
                } label: {
                    Label(AppLocalization.string("Rename"), systemImage: "pencil")
                }
                Button {
                    moving = entry
                } label: {
                    Label(AppLocalization.string("Move"), systemImage: "folder")
                }
                Button {
                    Task { await perform { client, root in try await client.duplicate(root: root, path: entry.path) } }
                } label: {
                    Label(AppLocalization.string("Duplicate"), systemImage: "plus.square.on.square")
                }
            }
            Button(role: .destructive) {
                deleting = entry
            } label: {
                Label(AppLocalization.string("Delete"), systemImage: "trash")
            }
        }
    }

    private func details(_ entry: WorkspaceEntry) -> String {
        var parts: [String] = []
        if let size = entry.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let modified = entry.modified { parts.append(Self.dateText(modified)) }
        return parts.joined(separator: " · ")
    }

    static func dateText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    /// Where a file sits in the open folder, for search and recent rows.
    private func relativeLocation(_ entry: WorkspaceEntry) -> String {
        let place = relativeLocation(path: entry.folder)
        let parts = [place, entry.modified.map(Self.dateText) ?? ""].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    private func relativeLocation(path: String) -> String {
        guard let root = root?.path else { return path }
        let base = AppState.normalizedWorkspacePath(root)
        guard path.hasPrefix(base) else { return path }
        let rest = path.dropFirst(base.count).drop { $0 == "/" }
        return rest.isEmpty ? (base as NSString).lastPathComponent : String(rest)
    }

    // MARK: - Opening

    private func open(_ entry: WorkspaceEntry, line: Int? = nil) {
        guard opening == nil else { return }
        Haptics.light()
        switch WorkspaceFileKind(name: entry.name) {
        case .text, .markdown:
            viewing = entry
            Task { await explorer.view(entry, line: line) }
        case .page:
            opening = entry.path
            Task {
                defer { opening = nil }
                guard let dataURL = await resolver.dataURL(for: entry.path),
                      let html = HTMLPreviewPage.decodedDocument(fromDataURL: dataURL) else {
                    failure = AppLocalization.string("This file couldn't be opened.")
                    return
                }
                page = OpenPage(name: entry.name, html: html)
            }
        case .quickLook:
            quickLook(entry)
        }
    }

    private func share(_ entry: WorkspaceEntry) {
        quickLook(entry)
    }

    /// Quick Look, which also offers Share and Save to Files.
    private func quickLook(_ entry: WorkspaceEntry) {
        guard opening == nil else { return }
        opening = entry.path
        let resolver = resolver
        Task {
            defer { opening = nil }
            switch await resolver.file(for: entry.path) {
            case .downloaded(let download):
                if MediaPreviewPresenter.shared.present(downloaded: download) { return }
            case .tooLarge:
                failure = AppLocalization.string("Too large to open on this phone")
                return
            case .unavailable:
                break
            }
            guard let dataURL = await resolver.dataURL(for: entry.path),
                  await MediaPreviewPresenter.shared.present(dataURL: dataURL, filename: entry.name) else {
                failure = AppLocalization.string("This file couldn't be opened.")
                return
            }
        }
    }

    private var resolver: GatewayMediaDataURLResolver {
        appState.gatewayMediaResolver(for: explorer.scope?.profile ?? appState.workspaceProfile)
    }

    /// A path a reply named: the chat's own folder when it's there, and the
    /// file opens, at its line for a search match.
    private func show(_ reveal: WorkspaceReveal) async {
        if let chat = roots.first(where: { $0.kind == .chat }),
           reveal.path.hasPrefix(AppState.normalizedWorkspacePath(chat.path)), root?.path != chat.path {
            rootPath = chat.path
            if let root = root?.path {
                await explorer.open(root: root, profile: appState.workspaceProfile)
            }
        }
        query = ""
        let entry = await explorer.reveal(reveal.path, line: reveal.line)
        open(entry, line: reveal.line)
    }

    // MARK: - Changing

    private func ask(_ kind: NamePrompt.Kind, in folder: String) {
        promptText = ""
        prompt = NamePrompt(kind: kind, folder: folder)
    }

    private func submit(_ prompt: NamePrompt, name: String) {
        self.prompt = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            switch prompt.kind {
            case .folder:
                await perform { client, root in try await client.makeFolder(root: root, in: prompt.folder, name: name) }
            case .file:
                await perform { client, root in try await client.makeFile(root: root, in: prompt.folder, name: name) }
            case .rename:
                guard let entry = prompt.entry, name != entry.name else { return }
                await perform { client, root in
                    try await client.move(root: root, path: entry.path, to: entry.folder, name: name)
                }
            }
        }
    }

    private func perform(_ action: (WorkspaceFilesClient, String) async throws -> Void) async {
        if let error = await explorer.change(action) {
            failure = UserFacingError.message(for: error)
        }
    }

    private func upload(_ urls: [URL], into folder: String) async {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= WorkspaceFolderView.maxUploadBytes,
                  let data = try? await Task.detached(priority: .userInitiated, operation: { try Data(contentsOf: url) }).value,
                  data.count <= WorkspaceFolderView.maxUploadBytes else {
                failure = AppLocalization.string("\(url.lastPathComponent) is too large to upload. Files up to 25 MB can be uploaded.")
                continue
            }
            await perform { client, root in
                try await client.upload(root: root, in: folder, name: url.lastPathComponent, data: data)
            }
        }
    }

    /// The plugin takes up to 25 MB a file.
    static let maxUploadBytes = 25 * 1024 * 1024
}

/// How a file opens: as text (Markdown drawn), as a page, or in Quick Look.
enum WorkspaceFileKind: Equatable {
    case text
    case markdown
    case page
    case quickLook

    init(name: String) {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["md", "markdown", "mdown"].contains(ext) {
            self = .markdown
        } else if ["html", "htm"].contains(ext) {
            self = .page
        } else if Self.quickLookTypes.contains(ext) {
            self = .quickLook
        } else {
            self = .text
        }
    }

    static let quickLookTypes: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "ico", "pdf",
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "mp4", "mov", "m4v", "webm",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "rtf",
        "zip", "tar", "gz", "tgz", "7z", "rar", "dmg", "epub", "usdz",
    ]

    var symbol: String {
        switch self {
        case .markdown: return "doc.richtext"
        case .page: return "globe"
        case .quickLook: return "doc.viewfinder"
        case .text: return "doc.text"
        }
    }
}

/// A text file from the Folder tab: Markdown drawn (or its source), any
/// other text with line numbers, scrolled to a search match's line. A file
/// in the open folder can be edited when the plugin can save it; a save
/// that finds the file changed on the host asks before replacing it.
struct WorkspaceFileSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var explorer: WorkspaceExplorer
    let entry: WorkspaceEntry
    let root: WorkspaceRoot?

    @State private var showsSource = false
    @State private var editing = false
    @State private var draft = ""
    @State private var saving = false
    @State private var conflict = false
    @State private var failure: String?

    private var shown: WorkspaceEntry { explorer.viewed ?? entry }

    private var canEdit: Bool {
        guard explorer.canChange, explorer.contains(shown.path), let preview = explorer.preview else { return false }
        return !preview.binary && !preview.truncated
    }

    var body: some View {
        NavigationStack {
            Group {
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 8)
                } else {
                    reader
                }
            }
            .navigationTitle(Text(verbatim: shown.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { fileToolbar }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(editing && draft != explorer.preview?.text)
        .alert(AppLocalization.string("This file changed on your Hermes host"), isPresented: $conflict) {
            Button(AppLocalization.string("Replace It"), role: .destructive) { Task { await save(force: true) } }
            Button(AppLocalization.string("Keep Editing"), role: .cancel) {}
        } message: {
            Text("It changed after you opened it. Replace it with your version, or keep editing and copy what you need.")
        }
        .alert(AppLocalization.string("Couldn't save"), isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button(AppLocalization.string("OK"), role: .cancel) { failure = nil }
        } message: {
            Text(verbatim: failure ?? "")
        }
    }

    @ToolbarContentBuilder
    private var fileToolbar: some ToolbarContent {
        if editing {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalization.string("Cancel")) { editing = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button(AppLocalization.string("Save")) { Task { await save(force: false) } }
                        .disabled(draft == explorer.preview?.text)
                }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalization.string("Done")) { dismiss() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if WorkspaceFileKind(name: shown.name) == .markdown, explorer.preview != nil {
                    Button {
                        showsSource.toggle()
                    } label: {
                        Image(systemName: showsSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityLabel(showsSource ? AppLocalization.string("Show Formatted") : AppLocalization.string("Show Source"))
                }
                if canEdit {
                    Button(AppLocalization.string("Edit")) {
                        draft = explorer.preview?.text ?? ""
                        editing = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var reader: some View {
        if explorer.previewLoading {
            ProgressView(AppLocalization.string("Loading…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = explorer.previewError {
            ContentUnavailableView {
                Label(AppLocalization.string("Couldn't open this file"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error)
            }
        } else if let preview = explorer.preview {
            if preview.binary {
                ContentUnavailableView {
                    Label(AppLocalization.string("Not a text file"), systemImage: "doc.fill")
                } description: {
                    Text("Use Share or Save from the file's menu to open it in another app.")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical]) {
                        VStack(alignment: .leading, spacing: 12) {
                            metadata(preview)
                            if WorkspaceFileKind(name: shown.name) == .markdown, !showsSource, explorer.viewedLine == nil {
                                MarkdownText(source: preview.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                WorkspaceCodeText(text: preview.text, highlight: explorer.viewedLine)
                            }
                            if preview.truncated {
                                Text("Only the start of this file shows here. Share or Save opens all of it.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                    }
                    .task(id: explorer.viewedLine) {
                        guard let line = explorer.viewedLine else { return }
                        try? await Task.sleep(for: .milliseconds(150))
                        proxy.scrollTo(WorkspaceCodeText.lineID(line), anchor: .center)
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metadata(_ preview: WorkspaceFilePreview) -> some View {
        var parts = [ByteCountFormatter.string(fromByteCount: Int64(preview.byteSize), countStyle: .file)]
        if let modified = shown.modified { parts.append(WorkspaceFolderView.dateText(modified)) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: shown.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(verbatim: parts.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func save(force: Bool) async {
        let text = draft
        let file = shown
        saving = true
        defer { saving = false }
        var saved: WorkspaceEntry?
        let error = await explorer.change { client, root in
            saved = try await client.save(root: root, path: file.path, content: text, readAt: force ? nil : file.modified)
        }
        if let error {
            if case DashboardTicketBridgeError.http(status: 409, _) = error {
                conflict = true
            } else {
                failure = UserFacingError.message(for: error)
            }
            return
        }
        explorer.saved(saved ?? file, text: text)
        editing = false
    }
}

/// A text file's lines, numbered, one line marked.
struct WorkspaceCodeText: View {
    let text: String
    let highlight: Int?

    static func lineID(_ line: Int) -> String { "line-\(line)" }

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        ScrollView(.horizontal, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: "\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 30, alignment: .trailing)
                        Text(verbatim: line.isEmpty ? " " : line)
                            .font(.caption.monospaced())
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 1)
                    .background(highlight == index + 1 ? Color.conduitAccent.opacity(0.18) : Color.clear)
                    .id(Self.lineID(index + 1))
                }
            }
        }
    }
}

/// Where to move a file or folder: the open folder's folders, one level at
/// a time.
struct WorkspaceMoveSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var explorer: WorkspaceExplorer
    let entry: WorkspaceEntry

    @State private var folder: String?
    @State private var folders: [WorkspaceEntry] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var moving = false

    private var current: String { folder ?? explorer.root ?? "" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(verbatim: current)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                    if let root = explorer.root, AppState.normalizedWorkspacePath(current) != AppState.normalizedWorkspacePath(root) {
                        Button {
                            folder = (current as NSString).deletingLastPathComponent
                        } label: {
                            Label(AppLocalization.string("Up One Folder"), systemImage: "arrow.turn.left.up")
                        }
                    }
                }
                Section {
                    if loading {
                        ProgressView()
                    } else if let failure {
                        Text(verbatim: failure)
                            .foregroundStyle(.secondary)
                    } else if folders.isEmpty {
                        Text("No folders here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(folders.filter { $0.path != entry.path }) { child in
                        Button {
                            folder = child.path
                        } label: {
                            Label(child.name, systemImage: "folder.fill")
                        }
                    }
                }
            }
            .navigationTitle(AppLocalization.string("Move \(entry.name)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if moving {
                        ProgressView()
                    } else {
                        Button(AppLocalization.string("Move Here")) { Task { await move() } }
                            .disabled(current == entry.folder || current.isEmpty)
                    }
                }
            }
            .task(id: current) { await load() }
        }
    }

    private func load() async {
        guard let root = explorer.root, let profile = explorer.scope?.profile, !current.isEmpty else { return }
        loading = true
        failure = nil
        defer { loading = false }
        let asked = current
        do {
            let listing = try await appState.workspaceFilesClient(profile: profile).list(root: root, path: asked)
            guard asked == current else { return }
            folders = listing.entries.filter(\.isDirectory)
        } catch {
            guard asked == current else { return }
            folders = []
            failure = UserFacingError.message(for: error)
        }
    }

    private func move() async {
        moving = true
        defer { moving = false }
        let target = current
        if let error = await explorer.change({ client, root in
            try await client.move(root: root, path: entry.path, to: target, name: entry.name)
        }) {
            failure = UserFacingError.message(for: error)
            return
        }
        dismiss()
    }
}
