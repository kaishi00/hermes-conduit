//
//  V2ArtifactsViews.swift
//  Conduit
//
//  What a profile's chats produced: files Hermes sent or wrote, the pages it
//  drew, files the user attached and links. The Artifacts page (Chats bar)
//  lists every chat in the profile; a chat's … menu opens the same list for
//  that chat alone. The host's notifier plugin reads them (plugin 0.40+).
//  Tapping opens the viewer the chat itself uses: Quick Look for files, the
//  full-screen page for HTML, Safari for links.
//

import ImageIO
import SwiftUI
import UIKit

/// Which artifacts a list shows.
enum ArtifactScope: Equatable {
    /// Every chat in the active profile.
    case profile
    /// One chat, by every id it's known by.
    case chat([String])

    var sessionIDs: [String] {
        if case .chat(let ids) = self { return ids }
        return []
    }
}

/// The page pushed from the Chats bar.
struct V2ArtifactsPage: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            V2Backdrop(drifts: false)
            ArtifactsList(scope: .profile, chatIsOpen: false) { item in
                appState.showArtifactInChat(item, chatIsOpen: false)
            }
        }
        .navigationTitle(Text("Artifacts"))
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MinimisedLiveVoiceBar()
        }
    }
}

/// The open chat's artifacts, from its … menu.
struct ChatArtifactsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// Read once: the open chat's ids when the sheet opened.
    let sessionIDs: [String]

    var body: some View {
        NavigationStack {
            Group {
                if sessionIDs.isEmpty {
                    ContentUnavailableView {
                        Label("No Artifacts Yet", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Files, pages and links from this chat show up here once Hermes has saved it.")
                    }
                } else {
                    ArtifactsList(scope: .chat(sessionIDs), chatIsOpen: true) { item in
                        dismiss()
                        appState.showArtifactInChat(item, chatIsOpen: true)
                    }
                }
            }
            .navigationTitle(Text("In This Chat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
    let showInChat: (ArtifactItem) -> Void

    @State private var filter: ArtifactFilter = .all
    @State private var query = ""
    @State private var items: [ArtifactItem] = []
    @State private var nextBefore: Int?
    @State private var loadedKey: LoadKey?
    @State private var isLoading = false
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

    private struct LoadKey: Equatable {
        let profile: String
        let filter: ArtifactFilter
        let query: String
    }

    private struct OpenPage: Identifiable {
        let id = UUID()
        let name: String
        let html: String
    }

    private var currentKey: LoadKey {
        LoadKey(profile: appState.activeProfile, filter: filter,
                query: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                chips
                    .padding(.bottom, 6)
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $query, prompt: Text("Search names and chats"))
        .refreshable { await reload() }
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
            if currentKey.query.isEmpty && filter == .all {
                unavailable(
                    title: Text("No Artifacts Yet"),
                    detail: Text("Files Hermes sends or writes, pages it draws, files you attach and links show up here."),
                    symbol: "square.grid.2x2"
                )
            } else {
                unavailable(title: Text("No Results"), detail: Text("Nothing here matches."),
                            symbol: "magnifyingglass")
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
                    // Reaching the end reads the next page.
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .task(id: nextBefore) { await loadMore() }
                }
            }
        }
    }

    private func unavailable(title: Text, detail: Text, symbol: String, retry: Bool = false) -> some View {
        ContentUnavailableView {
            Label { title } icon: { Image(systemName: symbol) }
        } description: {
            detail
        } actions: {
            if retry {
                Button("Try Again") { Task { await reload() } }
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
            ArtifactThumbnail(item: item, resolver: appState.gatewayMediaResolver, profile: appState.activeProfile)
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
        } else if !item.sessionTitle.isEmpty {
            parts.append(item.sessionTitle)
        }
        return parts.joined(separator: " · ")
    }

    private func accessibilityName(_ item: ArtifactItem) -> String {
        [item.name, Self.kindLabel(item.kind), chatIsOpen ? "" : item.sessionTitle]
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
        openingID = item.id
        let resolver = appState.gatewayMediaResolver
        openTask = Task { @MainActor in
            defer { openingID = nil }
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

    private func openFailed(_ item: ArtifactItem, tooLarge: Bool = false) {
        guard !Task.isCancelled else { return }
        Haptics.error()
        missingIsTooLarge = tooLarge
        missing = item
    }

    // MARK: - Loading

    private func reload() async {
        guard appState.supportsArtifacts else { return }
        let key = currentKey
        generation &+= 1
        let ticket = generation
        isLoading = true
        defer { if ticket == generation { isLoading = false } }
        do {
            let result = try await appState.artifactsClient.page(
                profile: key.profile, sessionIDs: scope.sessionIDs, filter: key.filter, query: key.query
            )
            guard ticket == generation else { return }
            items = result.items
            nextBefore = result.nextBefore
            failure = nil
            loadedKey = key
        } catch is CancellationError {
            return
        } catch {
            // A failed refresh keeps the list it was refreshing (and the end
            // of it keeps paging).
            guard ticket == generation, loadedKey != key else { return }
            failure = UserFacingError.message(for: error)
            items = []
            nextBefore = nil
            loadedKey = key
        }
    }

    private func loadMore() async {
        guard let before = nextBefore, let key = loadedKey, key == currentKey, !isLoading else { return }
        let ticket = generation
        isLoading = true
        defer { if ticket == generation { isLoading = false } }
        do {
            let result = try await appState.artifactsClient.page(
                profile: key.profile, sessionIDs: scope.sessionIDs, filter: key.filter, query: key.query,
                before: before
            )
            guard ticket == generation else { return }
            items = ArtifactsClient.merged(items, with: result.items)
            nextBefore = result.nextBefore
        } catch is CancellationError {
            return
        } catch {
            // The end of the list offers Try Again.
            guard ticket == generation else { return }
            failure = UserFacingError.message(for: error)
        }
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
    let profile: String
    @State private var image: UIImage?

    /// One host path can be another file in another profile.
    private var cacheKey: NSString { NSString(string: "\(profile)\u{0}\(item.path ?? "")") }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.primary.opacity(0.08))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            } else if item.kind == .image, let url = item.url {
                AsyncImage(url: url) { phase in
                    if let picture = phase.image {
                        picture.resizable().scaledToFill()
                    } else {
                        placeholderGlyph
                    }
                }
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
        guard item.kind == .image, item.exists, let path = item.path else { return }
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
