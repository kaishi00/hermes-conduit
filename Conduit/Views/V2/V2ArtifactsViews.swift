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
    /// One bot's profile, its Bot Chat's rows by the bot's name (the Bot
    /// Overview's Artifacts).
    case bot(String)

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
            V2ListCallBar()
        }
    }
}

/// A bot's artifacts in its Bot Overview: everything its profile's chats
/// produced, its Bot Chat's under the bot's name. A row opens its chat
/// once the overview has closed (`willShowInChat`).
struct BotArtifactsList: View {
    @EnvironmentObject private var appState: AppState
    let profile: String
    let willShowInChat: () -> Void

    var body: some View {
        // In a sheet without a navigation bar: search and Show Missing
        // Files sit in the list itself, as beside the chat.
        ArtifactsList(scope: .bot(profile), chatIsOpen: false, inPanel: true) { item in
            willShowInChat()
            appState.showArtifactInChat(item, chatIsOpen: false)
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
    /// With other combined dashboards' artifacts in All: the one dashboard
    /// shown (nil for the one on screen's own), or every one while unset.
    @State private var onlyDashboard: UUID??
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
    @State private var markdown: MarkdownDocument?
    @State private var missing: ArtifactItem?
    /// The open alert is for a file too big for the phone, not a gone one.
    @State private var missingIsTooLarge = false
    /// Cancelled when the list goes, so a slow fetch can't present a viewer
    /// over whatever screen the user moved on to.
    @State private var openTask: Task<Void, Never>?
    /// The open in flight: a cancelled one finishing late can't clear a
    /// newer open's spinner, even of the same item.
    @State private var openToken: UUID?
    /// Saved (issue 2467): showing the saved artifacts instead of the
    /// feed, each read store's saved set (`savedRows[i]` for source i)
    /// and what it was read for.
    @State private var savedOnly = false
    @State private var savedRows: [[ArtifactItem]?] = []
    @State private var savedKey: SavedListKey?
    @State private var savedFailure: String?
    @State private var savedGeneration = 0
    /// The artifact whose note is being written, and the note.
    @State private var noting: ArtifactItem?
    /// The store the note editor was opened on, so a profile or dashboard
    /// switch while it's up can't write the note somewhere else.
    @State private var notingStore: (profile: String, dashboard: UUID?)?
    @State private var noteText = ""
    @State private var saveFailure: String?
    /// Whether `saveFailure` is from Remove from Saved.
    @State private var removeFailed = false

    private struct OpenPage: Identifiable {
        let id = UUID()
        let name: String
        let html: String
    }

    /// What the list is read for: its key, and whether the plugin says it
    /// serves artifacts, so a list opened before it said so (on its kept
    /// rows, just connected or offline) reads once it does.
    private struct Reading: Equatable {
        let key: ArtifactsListKey
        let served: Bool
    }

    private var currentKey: ArtifactsListKey {
        ArtifactsListKey(dashboard: appState.activeDashboardID, profile: appState.activeProfile,
                         sources: shownSources(appState.artifactSources(for: scope)), filter: filter,
                         query: query.trimmingCharacters(in: .whitespacesAndNewlines), showMissing: showMissing)
    }

    /// The dashboards whose artifacts the list can show, the one on screen
    /// first (nil), when All reaches other combined dashboards too.
    private var dashboardChoices: [UUID?] {
        let sources = appState.artifactSources(for: scope)
        var choices: [UUID?] = []
        for source in sources where !choices.contains(source.dashboardID) { choices.append(source.dashboardID) }
        return choices.count > 1 ? choices : []
    }

    /// The stores of the one dashboard picked, or every store; a pick no
    /// longer offered (that dashboard left the group) shows them all.
    private func shownSources(_ sources: [ArtifactSource]) -> [ArtifactSource] {
        guard let only = onlyDashboard else { return sources }
        let picked = sources.filter { $0.dashboardID == only }
        return picked.isEmpty ? sources : picked
    }

    /// The stores Saved reads: this dashboard's, which keeps the pins,
    /// whichever dashboard's chip the feed shows.
    private var ownSources: [ArtifactSource] {
        appState.artifactSources(for: scope).filter { $0.dashboardID == nil }
    }

    private var items: [ArtifactItem] { feed?.items ?? [] }

    /// What Saved is read for: the stores the list reads, on this
    /// dashboard, once the plugin says it keeps them.
    private var currentSavedKey: SavedListKey {
        SavedListKey(dashboard: appState.activeDashboardID, sources: ownSources,
                     served: appState.supportsArtifactPins)
    }

    /// Saved's rows as last read for this list's stores.
    private var savedItems: [ArtifactItem] {
        guard savedKey?.sameStores(as: currentSavedKey) == true else { return [] }
        return ArtifactPinsClient.items(sources: ownSources, saved: savedRows, query: currentKey.query)
    }

    /// Every artifact saved in the stores read, so a row says whether
    /// it's saved; by id and the profile it's saved in.
    private var savedIDs: Set<String> {
        guard savedKey?.sameStores(as: currentSavedKey) == true else { return [] }
        return Set(ArtifactPinsClient.items(sources: ownSources, saved: savedRows).map(\.id))
    }

    private var offersSaved: Bool { appState.supportsArtifactPins }
    private var nextBefore: ArtifactFeed.Cursor? { feed?.nextCursor }

    var body: some View {
        list
        .modifier(ArtifactsListChrome(inPanel: inPanel, query: $query, showMissing: $showMissing,
                                      offersMissing: appState.supportsArtifacts))
        // Before the first frame, so nothing comes or goes when Hermes answers.
        .onAppear { showKept(currentKey) }
        .task(id: Reading(key: currentKey, served: appState.supportsArtifacts)) {
            // Typing settles before the host is asked.
            if loadedKey != nil, currentKey.query != loadedKey?.query {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            await reload()
        }
        .task(id: currentSavedKey) { await reloadSaved() }
        .sheet(item: $page) { page in
            HTMLPreviewSheet(name: page.name, html: page.html)
        }
        .sheet(item: $markdown) { document in
            MarkdownDocumentSheet(document: document)
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
        .alert(
            Text("Note"),
            isPresented: Binding(get: { noting != nil }, set: { if !$0 { noting = nil } })
        ) {
            TextField(AppLocalization.string("Note"), text: Binding(
                get: { noteText },
                // Match the host's code-point limit, keeping each character whole.
                set: { noteText = ArtifactPinsClient.limitedNote($0) }
            ))
            Button("Save") {
                if let item = noting, let store = notingStore {
                    if store.dashboard == appState.activeDashboardID {
                        Task { await save(item, note: noteText, profile: store.profile) }
                    } else {
                        noting = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { noting = nil }
        } message: {
            Text("A few words that show under it in Saved.")
        }
        .alert(
            removeFailed ? Text("Couldn't Remove from Saved") : Text("Couldn't Save"),
            isPresented: Binding(get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } })
        ) {
            Button("OK", role: .cancel) { saveFailure = nil }
        } message: {
            Text(verbatim: saveFailure ?? "")
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
        .refreshable {
            if savedOnly {
                await reloadSaved()
            } else {
                await reload()
            }
        }
    }

    // MARK: - Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ArtifactFilter.allCases) { option in
                    chip(Text(option.title), isOn: !savedOnly && option == filter) {
                        savedOnly = false
                        filter = option
                    }
                    // Saved stands beside All: everything kept, whatever
                    // its kind.
                    // Kept rows show it before the plugin has answered
                    // (offline, just launched); Save itself waits for it.
                    if option == .all, offersSaved || savedOnly
                        || savedKey != nil && appState.notifierPlugin.mayServe(ArtifactPinsClient.capability) {
                        let count = savedIDs.count
                        chip(Text("Saved") + Text(verbatim: count == 0 ? "" : " \(count)"),
                             isOn: savedOnly) {
                            savedOnly = true
                            filter = .all
                        }
                    }
                }
                // Each combined dashboard's own chip, once All reaches
                // theirs: it shows that dashboard's alone, and again every
                // one (Eric, 2026-11-16).
                if !savedOnly, !dashboardChoices.isEmpty {
                    Divider()
                        .frame(height: 22)
                        .accessibilityHidden(true)
                    ForEach(dashboardChoices, id: \.self) { choice in
                        let isOn = onlyDashboard == .some(choice)
                        chip(dashboardChipTitle(choice), isOn: isOn) {
                            onlyDashboard = isOn ? nil : .some(choice)
                        }
                    }
                }
                if inPanel, appState.supportsArtifacts {
                    Button {
                        Haptics.selection()
                        showMissing.toggle()
                    } label: {
                        Label("Show Missing Files", systemImage: showMissing ? "checkmark.circle.fill" : "circle")
                            .scaledFont(.subheadline.weight(.semibold))
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

    /// A dashboard's chip: its name, as its badge gives it.
    private func dashboardChipTitle(_ id: UUID?) -> Text {
        let badge = (id ?? appState.activeDashboardID).flatMap { appState.combinedDashboardBadge($0) }
        return Text(verbatim: badge?.name ?? "")
    }

    private func chip(_ title: Text, isOn: Bool, select: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { select() }
        } label: {
            title
                .scaledFont(.subheadline.weight(.semibold))
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        // Only once the plugin says it doesn't serve artifacts (or is too
        // old to say), never while Conduit hasn't heard from it: kept rows
        // show meanwhile, and with none kept, the loader, or offline, why
        // nothing can load yet.
        if savedOnly {
            savedContent
        } else if !appState.notifierPlugin.mayServe(ArtifactsClient.capability) {
            unavailable(
                title: Text(PluginUpdateAsk.title(AppLocalization.string("Update the Conduit plugin"))),
                detail: Text(PluginUpdateAsk.text(AppLocalization.string("Update the Conduit plugin on your Hermes host to see artifacts here. Settings › Conduit plugin can update it.", table: .chat))),
                symbol: "arrow.down.circle"
            )
        } else if items.isEmpty, loadedKey != currentKey, !appState.supportsArtifacts, !appState.isConnected,
                  !appState.isRecoveringConnection {
            // Nothing kept or loaded: a list kept empty says so below.
            unavailable(
                title: Text("Artifacts couldn't load"),
                detail: Text("Conduit isn't connected to Hermes right now. It reconnects on its own, so try again in a moment."),
                symbol: "wifi.slash"
            )
        } else if items.isEmpty, loadedKey != currentKey || (isLoading && failure != nil) {
            // A list kept or loaded empty says so at once, through a
            // refresh too; Try Again after a failure shows the loader.
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
                                .scaledFont(.footnote)
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

    /// Saved: everything kept in the stores the list reads, the one saved
    /// last first, missing files included (that's what keeping them is
    /// for), searched like the list.
    @ViewBuilder
    private var savedContent: some View {
        let items = savedItems
        if items.isEmpty, savedKey == nil, appState.notifierPlugin.state != .unknown, !appState.supportsArtifactPins {
            // Kept by a plugin from before saved artifacts: nothing to
            // read, so the update notice, as the list gives its own.
            unavailable(
                title: Text(PluginUpdateAsk.title(AppLocalization.string("Update the Conduit plugin"))),
                detail: Text(PluginUpdateAsk.text(AppLocalization.string("Update the Conduit plugin on your Hermes host to see artifacts here. Settings › Conduit plugin can update it.", table: .chat))),
                symbol: "arrow.down.circle"
            )
        } else if items.isEmpty, let savedFailure {
            ContentUnavailableView {
                Label("Saved artifacts couldn't load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: savedFailure)
            } actions: {
                Button("Try Again") { Task { await reloadSaved() } }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        } else if items.isEmpty, savedKey == nil, !appState.supportsArtifactPins, !appState.isConnected,
                  !appState.isRecoveringConnection {
            // Nothing kept, and nothing can be read until Conduit connects.
            unavailable(
                title: Text("Saved artifacts couldn't load"),
                detail: Text("Conduit isn't connected to Hermes right now. It reconnects on its own, so try again in a moment."),
                symbol: "wifi.slash"
            )
        } else if items.isEmpty, savedKey?.sameStores(as: currentSavedKey) != true {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if items.isEmpty, !currentKey.query.isEmpty {
            unavailable(title: Text("No Results"), detail: Text("Nothing here matches."), symbol: "magnifyingglass")
        } else if items.isEmpty {
            unavailable(
                title: Text("Nothing Saved Yet"),
                detail: Text("Long-press an artifact and choose Save to keep it here. Hermes keeps a copy of each file, so it still opens after its chat is gone."),
                symbol: "bookmark"
            )
        } else {
            // In the order saved: a run of pictures shares a grid, so a
            // grid never puts an older picture above a newer file.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ArtifactPinsClient.runs(items)) { run in
                    if run.isVisual {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                            ForEach(run.items) { item in
                                // A picture's note under it, as a row shows its own.
                                VStack(alignment: .leading, spacing: 3) {
                                    tile(item)
                                    if let note = item.note {
                                        Text(verbatim: note)
                                            .scaledFont(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(maxHeight: .infinity, alignment: .top)
                            }
                        }
                    } else {
                        ForEach(run.items) { item in
                            row(item)
                        }
                    }
                }
            }
            .padding(.top, 10)
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
            .scaledFont(.footnote.weight(.bold))
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
        if calendar.isDateInToday(day) { return AppLocalization.string("Today", table: .chat) }
        if calendar.isDateInYesterday(day) { return AppLocalization.string("Yesterday", table: .chat) }
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
                              dashboard: item.dashboardID ?? appState.activeDashboardID,
                              profile: item.otherProfile ?? appState.activeProfile)
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
                .opacity(item.canOpen ? 1 : 0.45)
                .overlay(alignment: .topTrailing) {
                    if savedIDs.contains(item.id) {
                        Image(systemName: "bookmark.fill")
                            .scaledFont(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.5), in: Circle())
                            .padding(5)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // Over the dimming, which alone reads as a dark picture,
                    // and clear of the name along the bottom.
                    if !item.canOpen {
                        Label("Missing", systemImage: "exclamationmark.circle.fill")
                            .scaledFont(.caption2.weight(.semibold))
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
                    HStack(spacing: 5) {
                        Text(verbatim: item.name)
                            .scaledFont(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if savedIDs.contains(item.id) {
                            Image(systemName: "bookmark.fill")
                                .scaledFont(.caption)
                                .foregroundStyle(Color.conduitAccent)
                                .accessibilityHidden(true)
                        }
                    }
                    if let note = item.note {
                        Text(verbatim: note)
                            .scaledFont(.subheadline)
                            .foregroundStyle(Color.primary.opacity(0.8))
                            .lineLimit(2)
                    }
                    Text(verbatim: detail(item))
                        .scaledFont(.caption)
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
            .opacity(item.canOpen ? 1 : 0.55)
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
        // Another dashboard's chat and pins are on that dashboard.
        if item.dashboardID == nil {
            Button {
                showInChat(item)
            } label: {
                Label("Show in Chat", systemImage: "text.bubble")
            }
        }
        if offersSaved, item.dashboardID == nil {
            if let saved = savedItem(item) {
                Button {
                    noteText = saved.note ?? ""
                    notingStore = (saved.otherProfile ?? appState.activeProfile, appState.activeDashboardID)
                    noting = saved
                } label: {
                    if saved.note == nil {
                        Label("Add Note", systemImage: "square.and.pencil")
                    } else {
                        Label("Edit Note", systemImage: "square.and.pencil")
                    }
                }
                Button {
                    Task { await unsave(saved) }
                } label: {
                    Label("Remove from Saved", systemImage: "bookmark.slash")
                }
            } else {
                Button {
                    Task { await save(item, note: nil) }
                } label: {
                    Label("Save", systemImage: "bookmark")
                }
            }
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
        if item.source == .attached { parts.append(AppLocalization.string("You sent", table: .chat)) }
        if !item.exists {
            parts.append(AppLocalization.string("No longer on the host", table: .chat))
            if item.keptPath != nil { parts.append(AppLocalization.string("Kept copy", table: .chat)) }
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
        // Another combined dashboard's are read through its kept connection.
        if let dashboard = item.dashboardID {
            return appState.keptGatewayMediaResolver(dashboardID: dashboard, profile: item.otherProfile ?? "default")
        }
        return item.otherProfile.map { appState.gatewayMediaResolver(for: $0) } ?? appState.gatewayMediaResolver
    }

    private func accessibilityName(_ item: ArtifactItem) -> String {
        [item.name, item.note ?? "", Self.kindLabel(item.kind),
         savedIDs.contains(item.id) ? AppLocalization.string("Saved") : "",
         item.exists ? "" : AppLocalization.string("No longer on the host", table: .chat),
         item.exists || item.keptPath == nil ? "" : AppLocalization.string("Kept copy", table: .chat),
         chatIsOpen ? "" : chatName(item) ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static func kindLabel(_ kind: ArtifactItem.Kind) -> String {
        switch kind {
        case .image: return AppLocalization.string("Image")
        case .video: return AppLocalization.string("Video", table: .chat)
        case .audio: return AppLocalization.string("Audio")
        case .page: return AppLocalization.string("Page", table: .chat)
        case .document: return AppLocalization.string("Document")
        case .file: return AppLocalization.string("File", table: .chat)
        case .link: return AppLocalization.string("Link", table: .chat)
        }
    }

    // MARK: - Opening

    private func open(_ item: ArtifactItem) {
        if let url = item.url, item.path == nil {
            openURL(url)
            return
        }
        guard item.path != nil, openingID == nil else { return }
        // A saved file whose original is gone opens its kept copy.
        guard let path = item.openPath else {
            missingIsTooLarge = false
            missing = item
            return
        }
        Haptics.light()
        if item.kind == .image {
            openImage(item, path: path)
            return
        }
        if MarkdownArtifact.isMarkdown(path) {
            openMarkdown(item, path: path)
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
            await presentAsFile(item, path: path, resolver: resolver)
        }
    }

    /// The reader for a Markdown artifact: `MarkdownText`, the same view the
    /// Folder draws a `.md` with, rather than Quick Look's plain text. A
    /// file that isn't readable UTF-8 falls back to the file's usual viewer.
    private func openMarkdown(_ item: ArtifactItem, path: String) {
        openingID = item.id
        let token = UUID()
        openToken = token
        let resolver = resolver(for: item)
        openTask = Task { @MainActor in
            defer {
                if openToken == token {
                    openingID = nil
                    openToken = nil
                }
            }
            guard let text = await MarkdownArtifact.load(
                path: path, knownSize: item.size, dataURL: { await resolver.dataURL(for: $0) }
            ) else {
                await presentAsFile(item, path: path, resolver: resolver)
                return
            }
            guard !Task.isCancelled else { return }
            // A file the user sent is the user's text, not Hermes': its
            // `MEDIA:` lines stay text and fetch nothing, as in their message.
            let trusted = item.source != .attached
            var dataURL: ((String) async -> String?)?
            if trusted { dataURL = { path in await resolver.dataURL(for: path) } }
            markdown = MarkdownDocument(name: item.name, path: path, text: text,
                                        gatewayMediaDataURL: dataURL,
                                        gatewayMediaFiles: trusted ? resolver : nil)
        }
    }

    /// Downloads the file and opens it in its usual viewer (Quick Look, or
    /// the share sheet for active content). The fallback for a Markdown
    /// file that isn't readable text, and the path every other file takes.
    private func presentAsFile(_ item: ArtifactItem, path: String,
                               resolver: GatewayMediaDataURLResolver) async {
        guard !Task.isCancelled else { return }
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

    /// A picture opens among the list's pictures, in the order they show,
    /// and swipes to the next one.
    private func openImage(_ item: ArtifactItem, path: String) {
        let tapped = galleryItem(item, path: path)
        let shown = savedOnly ? savedItems : ArtifactsClient.days(items).flatMap(\.items)
        let images = shown.compactMap { other -> ImageGalleryItem? in
            guard other.kind == .image, let path = other.openPath else { return nil }
            return other.id == item.id ? tapped : galleryItem(other, path: path)
        }
        if !ImageGallery.open(tapped, in: ImageGallerySource { images }) {
            openFailed(item)
        }
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
        showKept(key)
        // Every reload, also one that loads nothing, outdates the request
        // before it: the previous dashboard's page can't land under this one.
        generation &+= 1
        let ticket = generation
        // Connected, and the plugin never said what it serves (its read
        // failed as Conduit connected): asked again here, as Settings ›
        // Conduit plugin asks on every visit, so the list isn't left on
        // its loader until the next connect.
        if !appState.supportsArtifacts, appState.isConnected, appState.notifierPlugin.state == .unknown {
            isLoading = true
            await appState.refreshNotifierPluginStatusOnce()
            guard ticket == generation else { return }
            if appState.notifierPlugin.state == .unknown, loadedKey != key {
                failure = AppLocalization.string("Couldn't reach this dashboard's notifier.", table: .chat)
                feed = nil
                loadedKey = key
            }
        }
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
                pages.append(try await appState.artifactsClient(for: source).page(
                    source, filter: key.filter, query: key.query, showMissing: key.showMissing,
                    keptIn: answers(for: source)
                ))
            } catch is CancellationError {
                return
            } catch {
                // A bot's chat that can't be read leaves the rest listed,
                // with the rows it listed last time, which don't page on;
                // the first store is the list itself.
                if index > 0 {
                    pages.append(keptPage(source, for: key).map { ArtifactPage(items: $0.items, nextBefore: nil) })
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

    /// Shows the list as it opened last time while Hermes is asked again
    /// (#1533), unless this key's rows are up already: kept only as it
    /// opens, of every kind and unsearched, and only when the list's own
    /// store (the first) kept its page.
    private func showKept(_ key: ArtifactsListKey) {
        guard loadedKey != key, appState.notifierPlugin.mayServe(ArtifactsClient.capability) else { return }
        let pages = key.sources.map { keptPage($0, for: key) }
        guard let first = pages.first, first != nil else { return }
        feed = ArtifactFeed(sources: key.sources, pages: pages)
        failure = nil
        loadedKey = key
    }

    private func keptPage(_ source: ArtifactSource, for key: ArtifactsListKey) -> ArtifactPage? {
        guard let answers = answers(for: source) else { return nil }
        return ArtifactsClient.keptPage(source, filter: key.filter, query: key.query, showMissing: key.showMissing,
                                        in: answers)
    }

    /// Where a store's list is kept: on the dashboard open, for the
    /// store's profile. Another combined dashboard's isn't kept here.
    private func answers(for source: ArtifactSource) -> KeptAnswers? {
        source.dashboardID == nil ? appState.screenAnswers(profile: source.profile) : nil
    }

    /// Reads each store's saved set (once per profile), showing what was
    /// read last time while Hermes is asked, offline too.
    private func reloadSaved() async {
        let key = currentSavedKey
        savedGeneration &+= 1
        let ticket = savedGeneration
        let profiles = key.sources.map(\.profile)
        if savedKey?.sameStores(as: key) != true {
            savedFailure = nil
            let kept = profiles.map { ArtifactPinsClient.kept(profile: $0, in: appState.screenAnswers(profile: $0)) }
            if kept.contains(where: { $0 != nil }) {
                savedRows = kept
                savedKey = key
            } else {
                savedRows = []
                savedKey = nil
            }
        }
        guard key.served else {
            // Connected, and the plugin never said what it serves: asked
            // again, as the feed's refresh asks, so pulling Saved isn't a
            // no-op until the next connect.
            if appState.isConnected, appState.notifierPlugin.state == .unknown {
                await appState.refreshNotifierPluginStatusOnce()
                guard ticket == savedGeneration else { return }
                if currentSavedKey.served {
                    await reloadSaved()
                } else if appState.notifierPlugin.state == .unknown, savedKey == nil {
                    // Still no answer: say so, as the feed does, with Try
                    // Again, rather than leave Saved on its loader.
                    savedFailure = AppLocalization.string("Couldn't reach this dashboard's notifier.", table: .chat)
                }
            }
            return
        }
        var read: [String: [ArtifactItem]] = [:]
        var rows: [[ArtifactItem]?] = []
        for (index, profile) in profiles.enumerated() {
            if let done = read[profile] {
                rows.append(done)
                continue
            }
            do {
                let pins = try await appState.artifactPinsClient.list(
                    profile: profile, keptIn: appState.screenAnswers(profile: profile))
                read[profile] = pins
                rows.append(pins)
            } catch is CancellationError {
                return
            } catch {
                guard ticket == savedGeneration else { return }
                // The list's own store is Saved itself; another keeps
                // what it read last time.
                if index == 0, savedKey?.sameStores(as: key) != true {
                    savedFailure = UserFacingError.message(for: error)
                    savedKey = nil
                    return
                }
                rows.append(savedKey?.sameStores(as: key) == true && index < savedRows.count ? savedRows[index] : nil)
            }
        }
        guard ticket == savedGeneration else { return }
        savedRows = rows
        savedKey = key
        savedFailure = nil
    }

    /// The saved row for `item`, as Saved lists it: tagged with the store
    /// that holds the pin, so Edit Note and Remove act there even when the
    /// list showed it from another profile.
    private func savedItem(_ item: ArtifactItem) -> ArtifactItem? {
        guard savedKey?.sameStores(as: currentSavedKey) == true else { return nil }
        return ArtifactPinsClient.items(sources: ownSources, saved: savedRows).first { $0.id == item.id }
    }

    /// Saves `item` in the profile its store reads (or changes its note),
    /// then reads Saved again so every list shows it.
    private func save(_ item: ArtifactItem, note: String?, profile store: String? = nil) async {
        let profile = store ?? item.otherProfile ?? appState.activeProfile
        let dashboard = appState.activeDashboardID
        noting = nil
        do {
            let saved = try await appState.artifactPinsClient.save(item, note: note, profile: profile)
            guard appState.activeDashboardID == dashboard else { return }
            Haptics.success()
            // Shown at once, and kept if reading Saved again fails.
            changeSavedRows(profile: profile, seeding: true) { rows in
                rows.removeAll { $0.id == saved.id }
                rows.insert(saved, at: 0)
            }
            appState.screenAnswers(profile: profile).noteWrite(ArtifactPinsClient.listPath(profile: profile))
            await reloadSaved()
        } catch is CancellationError {
            return
        } catch {
            guard appState.activeDashboardID == dashboard else { return }
            Haptics.error()
            removeFailed = false
            saveFailure = UserFacingError.message(for: error)
        }
    }

    private func unsave(_ item: ArtifactItem) async {
        let profile = item.otherProfile ?? appState.activeProfile
        let dashboard = appState.activeDashboardID
        do {
            try await appState.artifactPinsClient.remove(item, profile: profile)
            guard appState.activeDashboardID == dashboard else { return }
            Haptics.success()
            changeSavedRows(profile: profile) { rows in rows.removeAll { $0.id == item.id } }
            appState.screenAnswers(profile: profile).noteWrite(ArtifactPinsClient.listPath(profile: profile))
            await reloadSaved()
        } catch is CancellationError {
            return
        } catch {
            guard appState.activeDashboardID == dashboard else { return }
            Haptics.error()
            removeFailed = true
            saveFailure = UserFacingError.message(for: error)
        }
    }

    /// A save or removal the host took, applied to every store of
    /// `profile` before Saved is read again. A save also lands in a store
    /// Saved hasn't read yet (its read failed or hasn't answered), so it
    /// shows at once and stays if reading again fails; a removal there
    /// has nothing to take out.
    private func changeSavedRows(profile: String, seeding: Bool = false,
                                 _ change: (inout [ArtifactItem]) -> Void) {
        let key = currentSavedKey
        if savedKey?.sameStores(as: key) != true {
            guard seeding else { return }
            savedRows = Array(repeating: nil, count: ownSources.count)
            savedKey = key
            savedFailure = nil
        }
        for (index, source) in ownSources.enumerated() where source.profile == profile && index < savedRows.count {
            guard var rows = savedRows[index] ?? (seeding ? [] : nil) else { continue }
            change(&rows)
            savedRows[index] = rows
        }
    }

    private func loadMore() async {
        guard let cursor = nextBefore, let key = loadedKey, key == currentKey, !isLoading,
              loadingBefore != cursor, key.sources.indices.contains(cursor.source) else { return }
        let ticket = generation
        loadingBefore = cursor
        defer { if loadingBefore == cursor { loadingBefore = nil } }
        do {
            let source = key.sources[cursor.source]
            let result = try await appState.artifactsClient(for: source).page(
                source, filter: key.filter, query: key.query,
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

/// What a list's Saved was read for: its stores on a dashboard, and
/// whether the plugin keeps saved artifacts.
struct SavedListKey: Equatable {
    let dashboard: UUID?
    let sources: [ArtifactSource]
    let served: Bool

    /// The same stores, whether or not the plugin had said so yet.
    func sameStores(as other: SavedListKey) -> Bool {
        dashboard == other.dashboard && sources == other.sources
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
        ArtifactsListKey.thumbnailCacheKey(dashboard: dashboard, profile: profile, path: item.openPath ?? item.path ?? "")
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
                    .scaledFont(.caption2.weight(.semibold))
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
        guard let path = item.openPath else { return }
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
        ArtifactThumbnailCache.store(thumbnail, forKey: cacheKey)
        image = thumbnail
    }
}

/// Thumbnails by host path, so scrolling back doesn't read them again.
/// They go with the chats' pictures at Sign Out and Remove Dashboard
/// (`wipeOfflineChatCache`, issue 2512): the next sign-in may be another
/// account.
enum ArtifactThumbnailCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        // About 50 thumbnails of 360 pixels at full size.
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func store(_ image: UIImage, forKey key: NSString) {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        shared.setObject(image, forKey: key, cost: Int(pixels) * 4)
    }

    /// Every dashboard's: NSCache can't list its keys, as
    /// TranscriptImageCache can't tell its files apart by server.
    static func purge() { shared.removeAllObjects() }
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
                .pageSearchable(text: $query, prompt: Text("Search names and chats"))
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
