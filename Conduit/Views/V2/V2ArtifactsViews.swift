//
//  V2ArtifactsViews.swift
//  Conduit
//
//  What a profile's chats produced: files Hermes sent or wrote, the pages it
//  drew, files the user attached and links. The Artifacts page (Chats bar)
//  lists every chat in the profile (each profile All shows, while it's on)
//  and every bot's Bot Chat; a chat's … menu opens the same list for that
//  chat alone. The host's notifier plugin reads them (plugin 0.40+).
//  Tapping opens the viewer the chat itself uses: Quick Look for files, the
//  full-screen page for HTML, Safari for links. Beside the list, the
//  Folder tab browses the chat's folder or a project's (V2WorkspaceViews).
//

import ImageIO
import SwiftUI
import UIKit

/// Which artifacts a list shows.
enum ArtifactScope: Equatable {
    /// Every chat in the active profile (in each profile All shows, while
    /// it's on), and every bot's Bot Chat.
    case profile
    /// One chat, by every id it's known by.
    case chat([String])

    var sessionIDs: [String] {
        if case .chat(let ids) = self { return ids }
        return []
    }
}

/// The page pushed from the Chats bar: Artifacts, and the Folder tab for
/// the projects' folders.
struct V2ArtifactsPage: View {
    @EnvironmentObject private var appState: AppState
    @State private var tab: ArtifactsTab = .made

    var body: some View {
        ZStack {
            V2Backdrop(drifts: false)
            VStack(spacing: 0) {
                ArtifactsTabPicker(tab: $tab)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                switch tab {
                case .made:
                    ArtifactsList(scope: .profile, chatIsOpen: false) { item in
                        appState.showArtifactInChat(item, chatIsOpen: false)
                    }
                case .folder:
                    WorkspaceFolderView(includesChat: false)
                }
            }
        }
        .navigationTitle(Text("Artifacts"))
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MinimisedLiveVoiceBar()
        }
    }
}

/// The open chat's artifacts and its folder, from its … menu, a file path
/// tapped in a reply, or beside the chat on a wide window (`inPanel`).
struct ChatArtifactsContent: View {
    @EnvironmentObject private var appState: AppState
    /// Read once: the open chat's ids when it opened.
    let sessionIDs: [String]
    @Binding var tab: ArtifactsTab
    /// Beside the chat rather than in a sheet of its own: no navigation bar
    /// of its own, so the list's search is a field in the list.
    var inPanel = false
    let showInChat: (ArtifactItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ArtifactsTabPicker(tab: $tab)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            switch tab {
            case .made:
                if sessionIDs.isEmpty {
                    ContentUnavailableView {
                        Label("No Artifacts Yet", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Files, pages and links from this chat show up here once Hermes has saved it.")
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ArtifactsList(scope: .chat(sessionIDs), chatIsOpen: true, inPanel: inPanel, showInChat: showInChat)
                }
            case .folder:
                WorkspaceFolderView(includesChat: true, handlesReveals: true)
            }
        }
    }
}

/// The open chat's artifacts, from its … menu, in a sheet.
struct ChatArtifactsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// Read once: the open chat's ids when the sheet opened.
    let sessionIDs: [String]
    @State var tab: ArtifactsTab
    /// The tab now showing, so a later open knows whether to switch.
    var onTabChange: (ArtifactsTab) -> Void = { _ in }

    init(sessionIDs: [String], tab: ArtifactsTab = .made, onTabChange: @escaping (ArtifactsTab) -> Void = { _ in }) {
        self.sessionIDs = sessionIDs
        _tab = State(initialValue: tab)
        self.onTabChange = onTabChange
    }

    var body: some View {
        NavigationStack {
            ChatArtifactsContent(sessionIDs: sessionIDs, tab: $tab) { item in
                dismiss()
                appState.showArtifactInChat(item, chatIsOpen: true)
            }
            .navigationTitle(tab == .made ? Text("In This Chat") : Text("Folder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: tab) { _, now in onTabChange(now) }
    }
}

/// Search, kind chips and the list itself, paged from the host.
private struct ArtifactsList: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scope: ArtifactScope
    /// A chat's own sheet: rows give the time rather than the chat's name.
    let chatIsOpen: Bool
    /// Beside the chat: the search is a field in the list and the Show
    /// Missing Files toggle a chip, since the chat's bar isn't the list's.
    var inPanel = false
    let showInChat: (ArtifactItem) -> Void

    @AppStorage(ArtifactsClient.showMissingKey) private var showMissing = false
    @State private var filter: ArtifactFilter = .all
    @State private var query = ""
    @State private var feed: ArtifactFeed?
    @State private var loadedKey: ArtifactsListKey?
    @State private var isLoading = false
    /// The cursor the next page is being read from. Apart from
    /// `isLoading`, which swaps an empty list for the centred spinner: that
    /// swap unmounted the pager and cancelled its read, so a page with
    /// nothing to list never paged on. A cursor rather than a flag, so a
    /// pager restarted on a new cursor isn't turned away by the old read
    /// still unwinding.
    @State private var loadingBefore: ArtifactFeed.Cursor?
    @State private var failure: String?
    @State private var generation = 0
    @State private var openingID: String?
    @State private var page: OpenPage?
    @State private var missing: ArtifactItem?
    /// The open alert is for a file too big for the phone, not a gone one.
    @State private var missingIsTooLarge = false
    /// Cancelled when the list goes, so a slow fetch can't present a viewer
    /// over whatever screen the user moved on to.
    @State private var openTask: Task<Void, Never>?
    /// The open in flight: a cancelled one finishing late can't clear a
    /// newer open's spinner, even of the same item.
    @State private var openToken: UUID?

    private struct OpenPage: Identifiable {
        let id = UUID()
        let name: String
        let html: String
    }

    private var currentKey: ArtifactsListKey {
        ArtifactsListKey(dashboard: appState.activeDashboardID, profile: appState.activeProfile,
                         sources: appState.artifactSources(for: scope), filter: filter,
                         query: query.trimmingCharacters(in: .whitespacesAndNewlines), showMissing: showMissing)
    }

    private var items: [ArtifactItem] { feed?.items ?? [] }
    private var nextBefore: ArtifactFeed.Cursor? { feed?.nextCursor }

    var body: some View {
        list
        .modifier(ArtifactsListChrome(inPanel: inPanel, query: $query, showMissing: $showMissing,
                                      offersMissing: appState.supportsArtifacts))
        .task(id: currentKey) {
            // Typing settles before the host is asked.
            if loadedKey != nil, currentKey.query != loadedKey?.query {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            await reload()
        }
        .sheet(item: $page) { page in
            HTMLPreviewSheet(name: page.name, html: page.html)
        }
        .onDisappear { openTask?.cancel() }
        .alert(
            missingIsTooLarge ? Text("Too large to open on this phone") : Text("This file is no longer on your Hermes host."),
            isPresented: Binding(get: { missing != nil }, set: { if !$0 { missing = nil } })
        ) {
            Button("OK", role: .cancel) { missing = nil }
        } message: {
            Text(verbatim: missing?.path ?? "")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                if inPanel {
                    ArtifactsInlineSearch(query: $query)
                        .padding(.bottom, 6)
                }
                chips
                    .padding(.bottom, 6)
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await reload() }
    }

    // MARK: - Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ArtifactFilter.allCases) { option in
                    let isOn = option == filter
                    Button {
                        Haptics.selection()
                        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { filter = option }
                    } label: {
                        Text(option.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isOn ? Color.conduitAccent : Color.primary.opacity(0.75))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(
                                isOn ? Color.conduitAccent.opacity(0.18) : Color.primary.opacity(0.06),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().strokeBorder(isOn ? Color.conduitAccent.opacity(0.45) : Color.primary.opacity(0.08))
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
                if inPanel, appState.supportsArtifacts {
                    Button {
                        Haptics.selection()
                        showMissing.toggle()
                    } label: {
                        Label("Show Missing Files", systemImage: showMissing ? "checkmark.circle.fill" : "circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(showMissing ? Color.conduitAccent : Color.primary.opacity(0.75))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(showMissing ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
        .dynamicTypeSize(...DynamicTypeSize.pinnedChromeCap)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !appState.supportsArtifacts {
            unavailable(
                title: Text("Update the Conduit plugin"),
                detail: Text("Update the Conduit plugin on your Hermes host to see artifacts here. Settings › Conduit plugin can update it."),
                symbol: "arrow.down.circle"
            )
        } else if items.isEmpty, isLoading || loadedKey != currentKey {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if items.isEmpty, let failure {
            unavailable(title: Text("Artifacts couldn't load"), detail: Text(verbatim: failure),
                        symbol: "exclamationmark.triangle", retry: true)
        } else if items.isEmpty, nextBefore == nil {
            // Hidden missing files may be all there is, so the way back
            // is offered under either message.
            let hiddenNote = showMissing ? Text(verbatim: "")
                : Text(verbatim: " ") + Text("Files no longer on your Hermes host are hidden.")
            if currentKey.query.isEmpty && filter == .all {
                unavailable(
                    title: Text("No Artifacts Yet"),
                    detail: Text("Files Hermes sends or writes, pages it draws, files you attach and links show up here.")
                        + hiddenNote,
                    symbol: "square.grid.2x2",
                    showMissingAction: !showMissing
                )
            } else {
                unavailable(title: Text("No Results"), detail: Text("Nothing here matches.") + hiddenNote,
                            symbol: "magnifyingglass", showMissingAction: !showMissing)
            }
        } else {
            ForEach(ArtifactsClient.days(items)) { day in
                section(day.day, items: day.items)
            }
            // The last filter's rows, dimmed until the new ones arrive.
            .opacity(loadedKey == currentKey ? 1 : 0.45)
            .allowsHitTesting(loadedKey == currentKey)
            if nextBefore != nil {
                if failure != nil {
                    Button("Try Again") {
                        failure = nil
                        Task { await loadMore() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    if items.isEmpty, !showMissing {
                        // A history of deleted files can take a few pages
                        // to get past.
                        VStack(spacing: 8) {
                            Text("Files no longer on your Hermes host are hidden.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Show Missing Files") { showMissing = true }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                    // Reaching the end reads the next page.
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 60)
                        // Asked again once the stores' first pages are in:
                        // the cursor may not change when they land.
                        .task(id: isLoading ? nil : nextBefore) { await loadMore() }
                }
            }
        }
    }

    private func unavailable(title: Text, detail: Text, symbol: String, retry: Bool = false,
                             showMissingAction: Bool = false) -> some View {
        ContentUnavailableView {
            Label { title } icon: { Image(systemName: symbol) }
        } description: {
            detail
        } actions: {
            if retry {
                Button("Try Again") { Task { await reload() } }
            }
            if showMissingAction {
                Button("Show Missing Files") { showMissing = true }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    @ViewBuilder
    private func section(_ day: Date, items: [ArtifactItem]) -> some View {
        Text(Self.dayTitle(day))
            .font(.footnote.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
        let visual = items.filter(\.isVisual)
        if !visual.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(visual) { item in
                    tile(item)
                }
            }
            .padding(.bottom, 8)
        }
        VStack(spacing: 8) {
            ForEach(items.filter { !$0.isVisual }) { item in
                row(item)
            }
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return AppLocalization.string("Today") }
        if calendar.isDateInYesterday(day) { return AppLocalization.string("Yesterday") }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return day.formatted(sameYear
            ? .dateTime.weekday(.wide).month(.wide).day()
            : .dateTime.month(.wide).day().year())
    }

    // MARK: - Items

    private func tile(_ item: ArtifactItem) -> some View {
        Button {
            open(item)
        } label: {
            ArtifactThumbnail(item: item, resolver: resolver(for: item),
                              dashboard: appState.activeDashboardID, profile: item.otherProfile ?? appState.activeProfile)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if openingID == item.id {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08))
                }
                .opacity(item.exists ? 1 : 0.45)
                .overlay(alignment: .topLeading) {
                    // Over the dimming, which alone reads as a dark picture,
                    // and clear of the name along the bottom.
                    if !item.exists {
                        Label("Missing", systemImage: "exclamationmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(5)
                            .dynamicTypeSize(...DynamicTypeSize.xLarge)
                            // The tile's label says it already.
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .contextMenu { menu(item) }
        .accessibilityLabel(Text(verbatim: accessibilityName(item)))
    }

    private func row(_ item: ArtifactItem) -> some View {
        Button {
            open(item)
        } label: {
            HStack(spacing: 12) {
                ArtifactIcon(kind: item.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: detail(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if openingID == item.id {
                    ProgressView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 60)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08))
            }
            .opacity(item.exists ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .contextMenu { menu(item) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func menu(_ item: ArtifactItem) -> some View {
        Button {
            open(item)
        } label: {
            Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        Button {
            showInChat(item)
        } label: {
            Label("Show in Chat", systemImage: "text.bubble")
        }
        if let url = item.url {
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.url = url
            } label: {
                Label("Copy Link", systemImage: "link")
            }
        } else if let path = item.path {
            Button {
                UIPasteboard.general.string = path
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
    }

    private func detail(_ item: ArtifactItem) -> String {
        var parts = [Self.kindLabel(item.kind)]
        if item.source == .attached { parts.append(AppLocalization.string("You sent")) }
        if !item.exists {
            parts.append(AppLocalization.string("No longer on the host"))
        } else if let size = item.size, item.kind != .link {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let host = item.host, item.kind == .link {
            parts.append(host)
        }
        if chatIsOpen {
            parts.append(item.date.formatted(date: .omitted, time: .shortened))
        } else if let chat = chatName(item) {
            parts.append(chat)
        }
        return parts.joined(separator: " · ")
    }

    /// A Bot Chat goes by its bot's name; another profile's chat is led by
    /// that profile's.
    private func chatName(_ item: ArtifactItem) -> String? {
        if item.isBotChat { return item.otherProfileLabel }
        let parts = [item.otherProfileLabel ?? "", item.sessionTitle].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Another profile's files are read through that profile.
    private func resolver(for item: ArtifactItem) -> GatewayMediaDataURLResolver {
        item.otherProfile.map { appState.gatewayMediaResolver(for: $0) } ?? appState.gatewayMediaResolver
    }

    private func accessibilityName(_ item: ArtifactItem) -> String {
        [item.name, Self.kindLabel(item.kind), item.exists ? "" : AppLocalization.string("No longer on the host"),
         chatIsOpen ? "" : chatName(item) ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static func kindLabel(_ kind: ArtifactItem.Kind) -> String {
        switch kind {
        case .image: return AppLocalization.string("Image")
        case .video: return AppLocalization.string("Video")
        case .audio: return AppLocalization.string("Audio")
        case .page: return AppLocalization.string("Page")
        case .document: return AppLocalization.string("Document")
        case .file: return AppLocalization.string("File")
        case .link: return AppLocalization.string("Link")
        }
    }

    // MARK: - Opening

    private func open(_ item: ArtifactItem) {
        if let url = item.url, item.path == nil {
            openURL(url)
            return
        }
        guard let path = item.path, openingID == nil else { return }
        guard item.exists else {
            missingIsTooLarge = false
            missing = item
            return
        }
        Haptics.light()
        if item.kind == .image {
            openImage(item, path: path)
            return
        }
        openingID = item.id
        let token = UUID()
        openToken = token
        let resolver = resolver(for: item)
        openTask = Task { @MainActor in
            // A cancelled open unwinding late leaves a newer open's spinner,
            // also one of the same item on another dashboard.
            defer {
                if openToken == token {
                    openingID = nil
                    openToken = nil
                }
            }
            if item.kind == .page {
                guard let dataURL = await resolver.dataURL(for: path), !Task.isCancelled else { return }
                guard let html = HTMLPreviewPage.decodedDocument(fromDataURL: dataURL) else {
                    openFailed(item)
                    return
                }
                page = OpenPage(name: item.name, html: html)
                return
            }
            switch await resolver.file(for: path) {
            case .downloaded(let download):
                guard !Task.isCancelled else {
                    MediaPreviewPresenter.removeDirectory(download.directory)
                    return
                }
                if MediaPreviewPresenter.shared.present(downloaded: download) { return }
            case .tooLarge:
                openFailed(item, tooLarge: true)
                return
            case .unavailable:
                break
            }
            // A cancelled download reads as unavailable; no fallback for a
            // list that has gone.
            guard !Task.isCancelled else { return }
            guard let dataURL = await resolver.dataURL(for: path), !Task.isCancelled else { return }
            guard await MediaPreviewPresenter.shared.present(dataURL: dataURL, filename: item.name) else {
                openFailed(item)
                return
            }
        }
    }

    /// A picture opens among the list's pictures, in the order they show,
    /// and swipes to the next one.
    private func openImage(_ item: ArtifactItem, path: String) {
        let tapped = galleryItem(item, path: path)
        let images = ArtifactsClient.days(items).flatMap(\.items).compactMap { other -> ImageGalleryItem? in
            guard other.kind == .image, other.exists, let path = other.path else { return nil }
            return other.id == item.id ? tapped : galleryItem(other, path: path)
        }
        ImageGallery.open(tapped, in: ImageGallerySource { images })
    }

    private func galleryItem(_ item: ArtifactItem, path: String) -> ImageGalleryItem {
        .hostFile(path: path, title: item.name, resolver: resolver(for: item))
    }

    private func openFailed(_ item: ArtifactItem, tooLarge: Bool = false) {
        guard !Task.isCancelled else { return }
        Haptics.error()
        missingIsTooLarge = tooLarge
        missing = item
    }

    // MARK: - Loading

    private func reload() async {
        let key = currentKey
        if !key.showsRows(of: loadedKey) {
            // Another server's list isn't shown, even dimmed, under this one,
            // nor a file of it still opening: also when this one has no
            // artifacts to show.
            feed = nil
            failure = nil
            loadedKey = nil
            openTask?.cancel()
            openTask = nil
            openingID = nil
            openToken = nil
        } else if loadedKey?.profile != key.profile {
            // Another profile's rows may stay up, dimmed, but its file
            // still opening is not presented under this one.
            openTask?.cancel()
            openTask = nil
            openingID = nil
            openToken = nil
        }
        // Every reload, also one that loads nothing, outdates the request
        // before it: the previous dashboard's page can't land under this one.
        generation &+= 1
        let ticket = generation
        guard appState.supportsArtifacts else {
            isLoading = false
            return
        }
        isLoading = true
        defer { if ticket == generation { isLoading = false } }
        // One store at a time: the host reads two lists at once at most.
        // A refresh keeps the list it refreshes until every store answers.
        let refreshing = loadedKey == key
        var pages: [ArtifactPage?] = []
        for (index, source) in key.sources.enumerated() {
            do {
                pages.append(try await appState.artifactsClient.page(
                    source, filter: key.filter, query: key.query, showMissing: key.showMissing
                ))
            } catch is CancellationError {
                return
            } catch {
                // A bot's chat that can't be read leaves the rest listed;
                // the first store is the list itself.
                if index > 0 {
                    pages.append(nil)
                } else {
                    // A failed refresh keeps the list it was refreshing (and
                    // the end of it keeps paging).
                    guard ticket == generation, loadedKey != key else { return }
                    failure = UserFacingError.message(for: error)
                    feed = nil
                    loadedKey = key
                    return
                }
            }
            guard ticket == generation else { return }
            // Otherwise each store shows as it arrives, so a slow one
            // doesn't hold the page blank; the feed holds older rows back.
            guard !refreshing || pages.count == key.sources.count else { continue }
            feed = ArtifactFeed(sources: Array(key.sources.prefix(pages.count)), pages: pages)
            failure = nil
            loadedKey = key
        }
    }

    private func loadMore() async {
        guard let cursor = nextBefore, let key = loadedKey, key == currentKey, !isLoading,
              loadingBefore != cursor, key.sources.indices.contains(cursor.source) else { return }
        let ticket = generation
        loadingBefore = cursor
        defer { if loadingBefore == cursor { loadingBefore = nil } }
        do {
            let result = try await appState.artifactsClient.page(
                key.sources[cursor.source], filter: key.filter, query: key.query,
                showMissing: key.showMissing, before: cursor.before
            )
            guard ticket == generation else { return }
            feed?.append(result, at: cursor)
        } catch is CancellationError {
            return
        } catch {
            // The end of the list offers Try Again.
            guard ticket == generation else { return }
            failure = UserFacingError.message(for: error)
        }
    }
}

/// What an artifacts list was read for. The dashboard is part of it: two
/// servers' profiles can share a name (every server has a "default"), and
/// switching servers keeps the Chats tab's screens.
struct ArtifactsListKey: Equatable {
    let dashboard: UUID?
    let profile: String
    /// The stores it reads: the profile's (All's), and bots' for their Bot
    /// Chats.
    var sources: [ArtifactSource] = []
    let filter: ArtifactFilter
    let query: String
    var showMissing = true

    /// Whether rows read for `loaded` may stay up, dimmed, while this key's
    /// rows load: another filter or search, not another server.
    func showsRows(of loaded: ArtifactsListKey?) -> Bool {
        loaded?.dashboard == dashboard
    }

    /// One host path can be another file in another profile, or on another
    /// server.
    static func thumbnailCacheKey(dashboard: UUID?, profile: String, path: String) -> NSString {
        NSString(string: "\(dashboard?.uuidString ?? "")\u{0}\(profile)\u{0}\(path)")
    }
}

/// A row's round-cornered kind glyph.
private struct ArtifactIcon: View {
    let kind: ArtifactItem.Kind

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch kind {
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .audio: return "waveform"
        case .page: return "chart.xyaxis.line"
        case .document: return "doc.text"
        case .file: return "doc"
        case .link: return "link"
        }
    }

    private var tint: Color {
        switch kind {
        case .page: return .conduitAccent
        case .document, .file: return .red
        case .audio: return .blue
        case .image, .video: return .purple
        case .link: return .secondary
        }
    }
}

/// An image's thumbnail (read from the host and kept small), or a video's
/// play glyph, in a grid tile.
private struct ArtifactThumbnail: View {
    let item: ArtifactItem
    let resolver: GatewayMediaDataURLResolver
    let dashboard: UUID?
    let profile: String
    @State private var image: UIImage?

    private var cacheKey: NSString {
        ArtifactsListKey.thumbnailCacheKey(dashboard: dashboard, profile: profile, path: item.path ?? "")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.primary.opacity(0.08))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            } else {
                placeholderGlyph
            }
            if image == nil {
                Text(verbatim: item.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(7)
            }
        }
        .task(id: cacheKey) { await loadThumbnail() }
    }

    private var placeholderGlyph: some View {
        Image(systemName: item.kind == .video ? "play.fill" : "photo")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadThumbnail() async {
        guard item.kind == .image else { return }
        if item.path == nil, let url = item.url {
            // A web image: fetched and downsampled within bounds, like the
            // same picture in the chat.
            if let cached = BoundedRemoteImage.cachedImage(url, maxPixelSize: 360) {
                image = cached
                return
            }
            image = nil
            guard case .image(let thumbnail) = await BoundedRemoteImage.load(url, maxPixelSize: 360),
                  !Task.isCancelled else { return }
            image = thumbnail
            return
        }
        guard item.exists, let path = item.path else { return }
        if let cached = ArtifactThumbnailCache.shared.object(forKey: cacheKey) {
            image = cached
            return
        }
        image = nil
        guard let dataURL = await resolver.dataURL(for: path), !Task.isCancelled else { return }
        let thumbnail = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = DataURLLimits.decodeBase64DataURL(dataURL),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 360,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
        guard let thumbnail, !Task.isCancelled else { return }
        ArtifactThumbnailCache.shared.setObject(thumbnail, forKey: cacheKey)
        image = thumbnail
    }
}

/// Thumbnails by host path, so scrolling back doesn't read them again.
private enum ArtifactThumbnailCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()
}

/// The list's search and its Show Missing Files toggle: in the navigation
/// bar of the page or sheet it fills, or (beside the chat, `inPanel`) in
/// the list itself.
private struct ArtifactsListChrome: ViewModifier {
    let inPanel: Bool
    @Binding var query: String
    @Binding var showMissing: Bool
    let offersMissing: Bool

    func body(content: Content) -> some View {
        if inPanel {
            content
        } else {
            content
                .searchable(text: $query, prompt: Text("Search names and chats"))
                .toolbar {
                    if offersMissing {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Toggle("Show Missing Files", isOn: $showMissing)
                            } label: {
                                Label("More", systemImage: "ellipsis.circle")
                            }
                        }
                    }
                }
        }
    }
}

/// The list's search beside the chat.
private struct ArtifactsInlineSearch: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(AppLocalization.string("Search names and chats"), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
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
}
