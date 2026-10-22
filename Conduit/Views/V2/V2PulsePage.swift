//
//  V2PulsePage.swift
//  Conduit
//
//  The Pulse screen (TestFlight and Xcode builds, pulse branch): what Pulse
//  brought up, newest first, as cards. Each card links back to the chat
//  the promise was made in, says why Pulse spoke up, and takes a thumbs up
//  or down; a thumbs down asks why, and each answer changes what Pulse does
//  on the host (PulseFeed.swift). What Pulse learned is listed, with each
//  kind's loudness, and every lesson can be undone. A reply box at the
//  bottom talks to Pulse in its own chat.
//

import SwiftUI

/// The Chats bar's Pulse button: a dot while cards are unseen.
struct V2PulseButton: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.v2Shell) private var shell

    var body: some View {
        NavigationLink(value: V2Route.pulse) {
            V2CapsuleIcon(systemImage: "waveform.path.ecg", dot: appState.pulseUnseen > 0 ? Color.conduitAccent : nil)
        }
        .buttonStyle(PressableButtonStyle())
        .simultaneousGesture(TapGesture().onEnded { Haptics.selection() })
        .accessibilityLabel(appState.pulseUnseen > 0
            ? AppLocalization.string("Pulse, new cards")
            : AppLocalization.string("Pulse"))
        .accessibilityIdentifier("chats.pulse")
        // While the Chats tab shows, every minute: new cards light the dot and
        // mark their messages in the chats.
        .task(id: PulseRefreshKey(dashboard: appState.activeDashboardID,
                                  active: scenePhase == .active && shell.isTabActive)) {
            guard scenePhase == .active, shell.isTabActive else { return }
            while !Task.isCancelled {
                await appState.refreshPulseFeed()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

private struct PulseRefreshKey: Hashable {
    let dashboard: UUID?
    let active: Bool
}

/// The mark under a message whose promise Pulse follows up: opens its card.
struct PulseMessageMark: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.conduitAccent)
                // The message action row's 34 pt, like the buttons beside it.
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(AppLocalization.string("Pulse follows this up"))
        .accessibilityHint(AppLocalization.string("Opens its card in Pulse"))
    }
}

struct V2PulsePage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    /// On screen (not under a chat pushed over it): only then is it read and marked seen.
    @State private var isShown = false
    @ObservedObject var appLanguage = AppLanguageStore.shared

    @State private var page: PulseFeedPage?
    @State private var homeChatID: String?
    @State private var loadError: String?
    @State private var errorMessage: String?
    /// A note on what the last rating changed.
    @State private var learnedNote: String?
    @State private var focusedCard: Int?
    /// VoiceOver lands on the card a Pulse mark opened, as sight does.
    @AccessibilityFocusState private var voiceOverCard: Int?
    @State private var reasonCard: PulseCard?
    @State private var showsLearned = false
    @State private var expandedWhy: Set<Int> = []
    @State private var reply = ""
    @State private var sending = false
    @State private var ratingCards: Set<Int> = []

    private var client: PulseClient { appState.pulseClient }

    var body: some View {
        ZStack {
            V2Backdrop(drifts: false)
            content
        }
        .navigationTitle(Text("Pulse"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if let homeChatID {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.openAppLink(.session(id: homeChatID, profile: AppState.pulseHomeProfile))
                    } label: {
                        Label(AppLocalization.string("Open the Pulse chat"), systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .accessibilityIdentifier("pulse.chat")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsLearned = true
                } label: {
                    Label(AppLocalization.string("What Pulse learned"), systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("pulse.learned")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if homeChatID != nil { replyBar }
                MinimisedLiveVoiceBar()
            }
        }
        .sheet(isPresented: $showsLearned) {
            PulseLearnedSheet {
                learnedNote = nil  // it may name a lesson just undone
                Task { await load() }
            }
            .environmentObject(appState)
        }
        .confirmationDialog(
            AppLocalization.string("What was wrong with it?"),
            isPresented: Binding(get: { reasonCard != nil }, set: { if !$0 { reasonCard = nil } }),
            titleVisibility: .visible,
            presenting: reasonCard
        ) { card in
            ForEach(PulseDownReason.allCases) { reason in
                Button(reason.title) { rate(card, up: false, reason: reason) }
            }
            Button(AppLocalization.string("Just thumbs down")) { rate(card, up: false, reason: nil) }
        } message: { _ in
            Text("Pulse changes what it does with your answer. You can undo it under What Pulse learned.")
        }
        .task(id: PulseRefreshKey(dashboard: appState.activeDashboardID, active: isShown && scenePhase == .active)) {
            guard isShown, scenePhase == .active else { return }
            // Cards that come in while the page is open show up too.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onAppear { isShown = true }
        .onDisappear { isShown = false }
        .onChange(of: appState.activeDashboardID) { _, _ in
            reasonCard = nil
            reply = ""
            errorMessage = nil
            // Another dashboard: its own cards and Pulse chat.
            page = nil
            homeChatID = nil
            loadError = nil
            learnedNote = nil
            focusedCard = nil
            expandedWhy = []
        }
        .onChange(of: appState.pulseOpenRequest) { _, request in
            // Only the page on screen: one covered by a chat leaves it to the one pushed over it.
            if let request, isShown { focus(request) }
        }
    }

    @ViewBuilder private var content: some View {
        if let page {
            if page.cards.isEmpty {
                ContentUnavailableView {
                    Label(AppLocalization.string("Nothing yet"), systemImage: "waveform.path.ecg")
                } description: {
                    Text("Your reports, your morning brief and the news on what Hermes promised to check land here.")
                }
            } else {
                cardList(page)
            }
        } else if let loadError {
            ContentUnavailableView {
                Label(AppLocalization.string("Couldn't read Pulse"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: loadError)
            } actions: {
                Button(AppLocalization.string("Try again")) { Task { await load() } }
            }
        } else {
            ProgressView()
        }
    }

    private func cardList(_ page: PulseFeedPage) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let learnedNote {
                        Label {
                            Text(verbatim: learnedNote)
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    }
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }
                    ForEach(page.cards) { card in
                        cardView(card)
                            .accessibilityElement(children: .contain)
                            .accessibilityFocused($voiceOverCard, equals: card.id)
                            .id(card.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: focusedCard) { _, card in
                guard let card else { return }
                withAnimation { proxy.scrollTo(card, anchor: .top) }
                // Once the scroll has brought the card into the lazy stack.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    voiceOverCard = card
                }
            }
            .onAppear {
                guard let card = focusedCard else { return }
                proxy.scrollTo(card, anchor: .top)
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    voiceOverCard = card
                }
            }
        }
    }

    private func cardView(_ card: PulseCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(verbatim: PulseCardKind.title(card.kind))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.conduitAccent)
                if card.isHeld {
                    Text("For the morning brief")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let created = card.createdAt {
                    Text(created, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(card.formattedNews)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if !card.quote.isEmpty {
                Text(verbatim: "“\(card.quote)”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.chatID.isEmpty {
                Button {
                    appState.openPulseCardChat(card)
                } label: {
                    Label(card.chatTitle.isEmpty ? AppLocalization.string("Open the chat") : card.chatTitle,
                          systemImage: "bubble.left.and.text.bubble.right")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
            }
            if expandedWhy.contains(card.id), !card.why.isEmpty {
                Text(verbatim: card.why)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
            }
            HStack(spacing: 4) {
                if !card.why.isEmpty {
                    Button {
                        withAnimation {
                            if expandedWhy.contains(card.id) { expandedWhy.remove(card.id) } else { expandedWhy.insert(card.id) }
                        }
                    } label: {
                        Text("Why?")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityValue(expandedWhy.contains(card.id)
                        ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))
                }
                Spacer(minLength: 0)
                if card.isRatable {
                    thumb(card, up: true)
                    thumb(card, up: false)
                }
            }
            if card.rating == "down", let reason = PulseDownReason(rawValue: card.reason) {
                Text(verbatim: reason.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.conduitAccent.opacity(focusedCard == card.id ? 0.8 : 0), lineWidth: 1.5)
        )
    }

    private func thumb(_ card: PulseCard, up: Bool) -> some View {
        let chosen = card.rating == (up ? "up" : "down")
        return Button {
            Haptics.selection()
            if up { rate(card, up: true, reason: nil) } else { reasonCard = card }
        } label: {
            Image(systemName: up ? (chosen ? "hand.thumbsup.fill" : "hand.thumbsup")
                                 : (chosen ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(chosen ? Color.conduitAccent : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(ratingCards.contains(card.id))
        .accessibilityLabel(up ? AppLocalization.string("Useful") : AppLocalization.string("Not useful"))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var replyBar: some View {
        HStack(spacing: 8) {
            TextField(AppLocalization.string("Reply to Pulse"), text: $reply, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(.thinMaterial))
                .accessibilityIdentifier("pulse.reply")
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.conduitAccent)
            }
            .disabled(sending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(AppLocalization.string("Send"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    private func load() async {
        let dashboard = appState.activeDashboardID
        do {
            let loaded = try await client.feed()
            guard appState.activeDashboardID == dashboard else { return }
            page = loaded
            loadError = nil
            errorMessage = nil
            learnedNote = nil
            appState.applyPulseFeed(loaded)
            if let home = loaded.homeChatID { homeChatID = home }
            if let request = appState.pulseOpenRequest, isShown { focus(request) }
            if isShown, loaded.unseen > 0, (try? await client.markSeen(nil)) != nil,
               appState.activeDashboardID == dashboard {
                appState.pulseUnseen = 0
            }
        } catch {
            guard appState.activeDashboardID == dashboard else { return }
            if page == nil { loadError = PulseRefusal.message(for: error) }
        }
        if homeChatID == nil, let state = try? await client.state(), appState.activeDashboardID == dashboard {
            homeChatID = state.homeChat?.id
        }
    }

    private func focus(_ request: PulseOpenRequest) {
        appState.pulseOpenRequest = nil
        guard let card = request.card else { return }
        focusedCard = card
        expandedWhy.insert(card)
    }

    private func rate(_ card: PulseCard, up: Bool, reason: PulseDownReason?) {
        ratingCards.insert(card.id)
        let dashboard = appState.activeDashboardID
        Task {
            defer { ratingCards.remove(card.id) }
            do {
                let lessons = try await client.rate(card: card.id, up: up, reason: reason)
                guard appState.activeDashboardID == dashboard else { return }
                if let index = page?.cards.firstIndex(where: { $0.id == card.id }) {
                    page?.cards[index].rating = up ? "up" : "down"
                    page?.cards[index].reason = reason?.rawValue ?? ""
                }
                errorMessage = nil
                learnedNote = lessons.isEmpty ? nil
                    : AppLocalization.string("Pulse learned: \(lessons.map(\.text).joined(separator: "; "))")
            } catch {
                guard appState.activeDashboardID == dashboard else { return }
                errorMessage = PulseRefusal.message(for: error)
            }
        }
    }

    private func send() {
        guard let homeChatID else { return }
        let text = reply
        sending = true
        let dashboard = appState.activeDashboardID
        Task {
            defer { sending = false }
            let sent = await appState.replyInPulseChat(text, chatID: homeChatID)
            guard appState.activeDashboardID == dashboard else { return }
            if sent {
                reply = ""
                errorMessage = nil
            } else {
                errorMessage = AppLocalization.string("Couldn't send that to Pulse. Try again.")
            }
        }
    }
}

/// What Pulse learned: each kind's loudness, and the lessons ratings made,
/// each with Undo.
struct PulseLearnedSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let onChange: () -> Void

    @State private var learned: PulseLearned?
    @State private var errorMessage: String?
    @State private var working = false

    private var client: PulseClient { appState.pulseClient }

    var body: some View {
        NavigationStack {
            List {
                if let learned {
                    Section {
                        ForEach(learned.levels.keys.sorted(), id: \.self) { kind in
                            Picker(PulseCardKind.title(kind), selection: Binding(
                                get: { learned.levels[kind] ?? .push },
                                set: { level in setLevel(level, for: kind) }
                            )) {
                                ForEach(PulseLevel.allCases) { level in
                                    Text(verbatim: level.title).tag(level)
                                }
                            }
                            .disabled(working)
                        }
                    } header: {
                        Text("How Pulse tells you")
                    } footer: {
                        Text("Thumbs move these too: two down make it quieter, two up louder.")
                    }
                    Section {
                        if learned.lessons.isEmpty {
                            Text("Nothing yet. Rate Pulse's cards and what it learns shows up here.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(learned.lessons) { lesson in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: lesson.text)
                                    if let cause = lesson.causeText {
                                        Text(verbatim: cause)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Button(AppLocalization.string("Undo")) { undo(lesson) }
                                    .buttonStyle(.borderless)
                                    .disabled(working)
                            }
                        }
                    } header: {
                        Text("Learned from your ratings")
                    }
                } else if let errorMessage {
                    Text(verbatim: errorMessage).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
                if learned != nil, let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(Text("What Pulse learned"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
            .task(id: appState.activeDashboardID) { await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func load() async {
        do {
            learned = try await client.learned()
            errorMessage = nil
        } catch {
            errorMessage = PulseRefusal.message(for: error)
        }
    }

    private func setLevel(_ level: PulseLevel, for kind: String) {
        run { try await client.setLevel(level, for: kind) }
    }

    private func undo(_ lesson: PulseLesson) {
        run { try await client.undo(lesson: lesson.id) }
    }

    private func run(_ step: @escaping @MainActor () async throws -> PulseLearned) {
        working = true
        let dashboard = appState.activeDashboardID
        Task {
            defer { working = false }
            do {
                let result = try await step()
                guard appState.activeDashboardID == dashboard else { return }
                learned = result
                errorMessage = nil
                onChange()
            } catch {
                guard appState.activeDashboardID == dashboard else { return }
                errorMessage = PulseRefusal.message(for: error)
            }
        }
    }
}
