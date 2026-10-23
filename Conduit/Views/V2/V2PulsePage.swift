//
//  V2PulsePage.swift
//  Conduit
//
//  The Pulse screen (TestFlight and Xcode builds, pulse branch): what Pulse
//  brought up, as cards. A morning brief comes first with the cards it
//  brought, then what's new and what's still open, then Done and cleared,
//  folded. Each card links back to the chat it came from and takes a thumbs
//  up or down; a follow-up's thumbs down asks why, and each answer changes
//  what Pulse does on the host (PulseFeed.swift). Swiping a card away is
//  Not now: off the list, nothing learned, with Undo. What Pulse learned is
//  listed, with each kind's loudness, and every lesson can be undone.
//  Pulse's own chat, where its hidden turns run, isn't shown: the cards are
//  the way to answer it.
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
    @State private var ratingCards: Set<Int> = []
    @State private var actingCard: Int?
    @State private var finishingCards: Set<Int> = []
    @State private var showsCleared = false
    /// Handled briefs opened again from their folded row.
    @State private var expandedBriefs: Set<Int> = []
    /// The cards unseen when the page opened: they read as new while it's up.
    @State private var newCards: Set<Int>?
    /// The last Done or Not now, for the Undo bar.
    @State private var undo: PulseUndo?
    /// Do it opened their chat but Pulse wasn't told; kept across refreshes
    /// until the card is done.
    @State private var untoldCards: Set<Int> = []

    private var client: PulseClient { appState.pulseClient }

    var body: some View {
        ZStack {
            V2Backdrop(drifts: false)
            content
        }
        .navigationTitle(Text("Pulse"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
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
            // Stacked on the call bar, so it never covers the call's controls.
            VStack(spacing: 0) {
                if let undo {
                    undoBar(undo)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
        .task(id: undo?.id) {
            guard undo != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            // A newer undo restarted this task: that one clears its own bar.
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { undo = nil }
        }
        .onAppear { isShown = true }
        .onDisappear {
            isShown = false
            newCards = nil
            focusedCard = nil
            voiceOverCard = nil
            undo = nil  // an undo belongs to the visit that made it
            expandedBriefs = []
            expandedWhy = []
        }
        .onChange(of: appState.activeDashboardID) { _, _ in
            reasonCard = nil
            errorMessage = nil
            // Another dashboard: its own cards.
            page = nil
            loadError = nil
            learnedNote = nil
            focusedCard = nil
            expandedWhy = []
            ratingCards = []
            finishingCards = []
            actingCard = nil
            showsCleared = false
            expandedBriefs = []
            newCards = nil
            undo = nil
            untoldCards = []
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
        let layout = PulseLayout(cards: page.cards, keeping: focusedCard.map { [$0] } ?? [])
        let fresh = layout.open.filter { newCards?.contains($0.id) == true }
        let earlier = layout.open.filter { newCards?.contains($0.id) != true }
        // A brief's new cards count too, though they show in its block.
        let freshInBriefs = layout.briefs.flatMap(\.items).filter { !$0.isCleared && newCards?.contains($0.id) == true }
        return ScrollViewReader { proxy in
            List {
                Group {
                    summary(layout, new: fresh.count + freshInBriefs.count).pulseRow()
                    if let learnedNote {
                        Label {
                            Text(verbatim: learnedNote)
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .pulseRow()
                    }
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                            .pulseRow()
                    }
                    ForEach(layout.briefs) { brief in
                        briefRows(brief)
                    }
                    if !fresh.isEmpty {
                        sectionHeading(AppLocalization.string("New"))
                        ForEach(fresh) { card in listedCard(card) }
                    }
                    if !earlier.isEmpty {
                        if !fresh.isEmpty || !layout.briefs.isEmpty {
                            sectionHeading(AppLocalization.string("Earlier"))
                        }
                        ForEach(earlier) { card in listedCard(card) }
                    }
                    if layout.clearedCount > 0 {
                        clearedToggle(count: layout.clearedCount)
                        if showsCleared {
                            ForEach(layout.clearedBriefs) { brief in
                                briefRows(brief)
                            }
                            ForEach(layout.cleared) { card in listedCard(card) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: focusedCard) { _, card in
                guard let card else { return }
                withAnimation { proxy.scrollTo(card, anchor: .top) }
                // Once the scroll has brought the card into the list.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard focusedCard == card else { return }
                    voiceOverCard = card
                }
            }
            .onAppear {
                guard let card = focusedCard else { return }
                proxy.scrollTo(card, anchor: .top)
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard focusedCard == card else { return }
                    voiceOverCard = card
                }
            }
        }
    }

    /// The line under the title: how many are new, or that nothing is open.
    @ViewBuilder private func summary(_ layout: PulseLayout, new count: Int) -> some View {
        let open = layout.open.count + layout.briefs.reduce(0) { $0 + $1.left }
        if count > 0 || open == 0 {
            Text(verbatim: count > 0 ? AppLocalization.string("\(count) new since you last looked")
                                     : AppLocalization.string("You're all caught up"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
            .pulseRow()
    }

    private func listedCard(_ card: PulseCard) -> some View {
        cardView(card)
            .accessibilityElement(children: .contain)
            .accessibilityFocused($voiceOverCard, equals: card.id)
            .id(card.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { notNowButton(card) }
            .pulseRow()
    }

    /// Not now: off the list, nothing learned. A plugin before 0.68.0 can't take it.
    @ViewBuilder private func notNowButton(_ card: PulseCard) -> some View {
        if card.dismissedAt == nil, card.doneAt == nil, canDismiss {
            Button {
                // One request per card: not while its Done is still out.
                guard !isBusy(card) else { return }
                Haptics.light()
                dismiss(card, true)
            } label: {
                Label(AppLocalization.string("Not now"), systemImage: "clock")
            }
            .tint(.gray)
        }
    }

    private var canDismiss: Bool { appState.notifierPlugin.reports(PulseClient.dismissCapability) }

    // MARK: Morning brief

    /// A morning brief and the cards it brought, as one block: open while
    /// anything in it is, else one row that opens it again.
    @ViewBuilder private func briefRows(_ brief: PulseLayout.Brief) -> some View {
        if brief.isHandled, !expandedBriefs.contains(brief.id) {
            handledBriefRow(brief)
                .id(brief.card.id)
                .pulseRow()
        } else {
            briefHeader(brief)
                .id(brief.card.id)
                .pulseRow(bottom: 0)
            ForEach(Array(brief.items.enumerated()), id: \.element.id) { index, item in
                briefItem(item, last: index == brief.items.count - 1)
                    .accessibilityElement(children: .contain)
                    .accessibilityFocused($voiceOverCard, equals: item.id)
                    .id(item.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) { notNowButton(item) }
                    .pulseRow(top: 0, bottom: index == brief.items.count - 1 ? 6 : 0)
            }
        }
    }

    private static let briefShape: CGFloat = 22

    private func briefHeader(_ brief: PulseLayout.Brief) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sunrise")
                    .foregroundStyle(Color.conduitAccent)
                    .accessibilityHidden(true)
                Text("Morning brief")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if brief.isHandled {
                    Button {
                        withAnimation(.snappy) { _ = expandedBriefs.remove(brief.id) }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(AppLocalization.string("Fold the morning brief"))
                }
                Text(verbatim: briefStamp(brief))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !brief.card.news.isEmpty {
                Text(brief.card.formattedNews)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(briefBackground(top: true, bottom: false))
    }

    /// "08:00 · 2 left".
    private func briefStamp(_ brief: PulseLayout.Brief) -> String {
        let time = brief.card.createdAt.map { $0.formatted(date: .omitted, time: .shortened) }
        let left = brief.isHandled ? AppLocalization.string("All handled")
            : AppLocalization.string("\(Int(brief.left)) left")
        return [time, left].compactMap { $0 }.joined(separator: " · ")
    }

    private func briefItem(_ card: PulseCard, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(Color.conduitAccent.opacity(0.2))
                .frame(height: 1)
                .padding(.horizontal, -16)
            if card.isCleared {
                HStack(spacing: 8) {
                    Image(systemName: card.dismissedAt != nil ? "clock" : "checkmark.circle")
                        .foregroundStyle(card.dismissedAt != nil ? Color.secondary : Color.green)
                        .accessibilityHidden(true)
                    Text(card.formattedNews)
                        .font(.subheadline)
                        .strikethrough(card.doneAt != nil)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    clearedUndoButton(card)
                }
                .padding(.vertical, 4)
            } else {
                topicLine(card)
                Text(card.formattedNews)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                actionRow(card)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 0)
        .padding(.bottom, last ? 12 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(briefBackground(top: false, bottom: last))
    }

    private func briefBackground(top: Bool, bottom: Bool) -> some View {
        let radius = Self.briefShape
        return UnevenRoundedRectangle(topLeadingRadius: top ? radius : 0, bottomLeadingRadius: bottom ? radius : 0,
                                      bottomTrailingRadius: bottom ? radius : 0, topTrailingRadius: top ? radius : 0,
                                      style: .continuous)
            .fill(Color.conduitAccent.opacity(0.10))
    }

    private func handledBriefRow(_ brief: PulseLayout.Brief) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.snappy) { _ = expandedBriefs.insert(brief.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sunrise")
                    .foregroundStyle(Color.conduitAccent)
                Text(AppLocalization.string("Morning brief · all \(brief.items.count) handled"))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.conduitAccent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.conduitAccent.opacity(0.24)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(AppLocalization.string("Shows what the brief brought")))
    }

    // MARK: Done and cleared

    private func clearedToggle(count: Int) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.snappy) { showsCleared.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                Text(AppLocalization.string("Done and cleared"))
                Text(verbatim: "\(count)")
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(showsCleared ? 180 : 0))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.secondary.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .accessibilityHint(Text(AppLocalization.string("Shows the cards that are done or swiped away")))
        .accessibilityAddTraits(showsCleared ? .isSelected : [])
        .accessibilityIdentifier("pulse.done-cards")
        .pulseRow()
    }

    // MARK: Undo

    private func undoBar(_ undo: PulseUndo) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: undo.message)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(AppLocalization.string("Undo")) {
                Haptics.selection()
                withAnimation(.snappy) { self.undo = nil }
                if let card = page?.cards.first(where: { $0.id == undo.card }) {
                    switch undo.action {
                    case .dismissed: dismiss(card, false)
                    case .done: markDone(card, false)
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .tint(.conduitAccent)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }

    private func showUndo(_ action: PulseUndo.Action, card: Int) {
        // The page was left before the plugin answered: no bar comes back later.
        guard isShown else { return }
        let message = action == .dismissed ? AppLocalization.string("Moved to Done and cleared. Pulse learned nothing from it.")
                                           : AppLocalization.string("Marked done")
        withAnimation(.snappy) { undo = PulseUndo(card: card, action: action, message: message) }
        AccessibilityNotification.Announcement(message).post()
    }

    private static var untoldNote: String {
        AppLocalization.string("Pulse couldn't be told about this one. Tap Done once it's taken care of.")
    }

    /// One request at a time per card, whichever of its buttons sent it.
    private func isBusy(_ card: PulseCard) -> Bool {
        actingCard == card.id || finishingCards.contains(card.id) || ratingCards.contains(card.id)
    }

    private func cardView(_ card: PulseCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            topicLine(card)
            Text(card.formattedNews)
                .font(.body)
                .strikethrough(card.doneAt != nil)
                .foregroundStyle(card.isCleared ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !card.quote.isEmpty, !card.isCleared {
                Text(verbatim: "“\(card.quote)”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if appState.pulseCardHasChat(card) {
                chatLink(card)
            }
            if expandedWhy.contains(card.id), !card.why.isEmpty {
                Text(verbatim: card.why)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
            }
            actionRow(card)
            if card.rating == "down", let reason = PulseDownReason(rawValue: card.reason) {
                Text(verbatim: reason.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(focusedCard == card.id ? Color.conduitAccent.opacity(0.8) : Color.white.opacity(0.14),
                              lineWidth: focusedCard == card.id ? 1.5 : 1)
        )
        // A cleared card steps back.
        .opacity(card.isCleared ? 0.7 : 1)
    }

    /// The coloured dot and what it's about, and when.
    private func topicLine(_ card: PulseCard) -> some View {
        let tint = PulseTopicTint.color(card)
        return HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(verbatim: card.heading)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityAddTraits(.isHeader)
            if let created = card.createdAt {
                Text(verbatim: "· " + PulseTopicTint.stamp(created))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if card.isHeld {
                Text("For the morning brief")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !card.why.isEmpty, !card.isNoticed {
                Button {
                    withAnimation {
                        if expandedWhy.contains(card.id) { expandedWhy.remove(card.id) } else { expandedWhy.insert(card.id) }
                    }
                } label: {
                    Text("Why?")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .accessibilityValue(expandedWhy.contains(card.id)
                    ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))
            }
        }
    }

    /// The chat it came from, a tap away.
    private func chatLink(_ card: PulseCard) -> some View {
        Button {
            appState.openPulseCardChat(card)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left")
                Text(verbatim: card.chatTitle.isEmpty ? AppLocalization.string("Open the chat") : card.chatTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }

    /// Do it and Done on the left, the thumbs on the right; for a cleared
    /// card, what happened to it and Undo.
    @ViewBuilder private func actionRow(_ card: PulseCard) -> some View {
        if card.isCleared {
            HStack(spacing: 8) {
                clearedLabel(card)
                Spacer(minLength: 0)
                clearedUndoButton(card)
            }
        } else {
            HStack(spacing: 8) {
                if card.doneAt == nil, untoldCards.contains(card.id) {
                    Label(Self.untoldNote, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if card.isActionable { doItButton(card) }
                    if canMarkDone(card) { doneButton(card) }
                }
                Spacer(minLength: 0)
                if card.isRatable {
                    thumb(card, up: true)
                    thumb(card, up: false)
                }
            }
        }
    }

    private func clearedLabel(_ card: PulseCard) -> some View {
        let title = card.dismissedAt != nil ? AppLocalization.string("Not now")
            : card.doneBy == "pulse" ? AppLocalization.string("Done, seen in the chat") : AppLocalization.string("Done")
        return Label(title, systemImage: card.dismissedAt != nil ? "clock" : "checkmark.circle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(card.dismissedAt != nil ? Color.secondary : Color.green)
    }

    /// Puts a swiped-away card back, or takes Done off.
    @ViewBuilder private func clearedUndoButton(_ card: PulseCard) -> some View {
        if card.dismissedAt != nil, canDismiss {
            Button {
                Haptics.selection()
                dismiss(card, false)
            } label: {
                Text(AppLocalization.string("Put back"))
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(.borderless)
            .disabled(isBusy(card))
            .accessibilityHint(Text(AppLocalization.string("Puts the card back on the list")))
        } else if card.doneAt != nil, appState.notifierPlugin.reports(PulseClient.doneCapability) {
            Button {
                Haptics.selection()
                markDone(card, false)
            } label: {
                Text(AppLocalization.string("Undo"))
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(.borderless)
            .disabled(isBusy(card))
            .accessibilityLabel(Text(AppLocalization.string("Undo Done")))
            .accessibilityHint(Text(AppLocalization.string("Pulse checks on it again")))
            .accessibilityIdentifier("pulse.card.undo-done")
        }
    }

    private func doItButton(_ card: PulseCard) -> some View {
        Button {
            Haptics.selection()
            let failure = AppLocalization.string("Couldn't open that chat. Try again.")
            let dashboard = appState.activeDashboardID
            actingCard = card.id
            Task {
                defer { if actingCard == card.id { actingCard = nil } }
                let opened = await appState.actOnPulseCard(card)
                guard appState.activeDashboardID == dashboard else { return }
                if !opened {
                    errorMessage = failure
                    return
                }
                if errorMessage == failure { errorMessage = nil }
                // Pulse reads the chat once Hermes has answered and marks the card done itself.
                // Only a card Pulse can mark done, with a Done button to fall back on.
                if canMarkDone(card), appState.notifierPlugin.reports(PulseClient.actedCapability) {
                    do {
                        try await client.acted(card: card.id)
                        untoldCards.remove(card.id)
                    } catch {
                        guard appState.activeDashboardID == dashboard else { return }
                        untoldCards.insert(card.id)
                        AccessibilityNotification.Announcement(Self.untoldNote).post()
                    }
                }
            }
        } label: {
            Label(AppLocalization.string("Do it"), systemImage: "arrow.right.circle.fill")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(.conduitAccent)
        .accessibilityHint(Text(AppLocalization.string("Opens the chat with this reminder ready to send")))
        .disabled(actingCard != nil || isBusy(card))
        .accessibilityIdentifier("pulse.card.do-it")
    }

    /// The plugin takes Done (0.64.0) and this card is a follow-up's.
    private func canMarkDone(_ card: PulseCard) -> Bool {
        card.canBeDone && appState.notifierPlugin.reports(PulseClient.doneCapability)
    }

    private func doneButton(_ card: PulseCard) -> some View {
        Button {
            Haptics.selection()
            markDone(card, true)
        } label: {
            Label(AppLocalization.string("Done"), systemImage: "checkmark.circle")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.conduitAccent)
        .accessibilityHint(Text(AppLocalization.string("Tells Pulse this is taken care of, so it stops checking on it")))
        .disabled(isBusy(card))
        .accessibilityIdentifier("pulse.card.done")
    }

    private func thumb(_ card: PulseCard, up: Bool) -> some View {
        let chosen = card.rating == (up ? "up" : "down")
        return Button {
            Haptics.selection()
            // A report item has no ladder for a reason to move: its thumbs down is enough.
            if up || card.isNoticed { rate(card, up: up, reason: nil) } else { reasonCard = card }
        } label: {
            Image(systemName: up ? (chosen ? "hand.thumbsup.fill" : "hand.thumbsup")
                                 : (chosen ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(chosen ? Color.conduitAccent : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isBusy(card))
        .accessibilityLabel(up ? AppLocalization.string("Useful") : AppLocalization.string("Not useful"))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    // MARK: Actions

    private func load() async {
        let dashboard = appState.activeDashboardID
        do {
            let loaded = try await client.feed()
            guard appState.activeDashboardID == dashboard else { return }
            page = loaded
            if newCards == nil, isShown {
                newCards = Set(loaded.cards.filter { $0.seenAt == nil && !$0.isCleared }.map(\.id))
            }
            loadError = nil
            errorMessage = nil
            learnedNote = nil
            appState.applyPulseFeed(loaded)
            if let request = appState.pulseOpenRequest, isShown { focus(request) }
            if isShown, loaded.unseen > 0, (try? await client.markSeen(nil)) != nil,
               appState.activeDashboardID == dashboard {
                appState.pulseUnseen = 0
            }
        } catch {
            guard appState.activeDashboardID == dashboard else { return }
            if page == nil { loadError = PulseRefusal.message(for: error) }
        }
    }

    private func focus(_ request: PulseOpenRequest) {
        appState.pulseOpenRequest = nil
        guard let card = request.card else { return }
        focusedCard = card
        expandedWhy.insert(card)
        // A card a folded brief brought: the brief opens to show it.
        if let tag = page?.cards.first(where: { $0.id == card })?.brief, !tag.isEmpty,
           let brief = page?.cards.first(where: { $0.kind == "brief" && $0.brief == tag }) {
            expandedBriefs.insert(brief.id)
        }
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

    /// Not now (or Put back): off the list into Done and cleared, nothing
    /// learned; the card moves at once.
    private func dismiss(_ card: PulseCard, _ dismissed: Bool) {
        finishingCards.insert(card.id)
        let dashboard = appState.activeDashboardID
        Task {
            defer { finishingCards.remove(card.id) }
            do {
                let changed = try await client.dismiss(card: card.id, dismissed: dismissed)
                guard appState.activeDashboardID == dashboard else { return }
                guard changed else { return await load() }
                withAnimation(.snappy) {
                    if let index = page?.cards.firstIndex(where: { $0.id == card.id }) {
                        page?.cards[index].dismissedAt = dismissed ? Date() : nil
                    }
                    if focusedCard == card.id, dismissed { focusedCard = nil; voiceOverCard = nil }
                }
                if dismissed { showUndo(.dismissed, card: card.id) }
                errorMessage = nil
            } catch {
                guard appState.activeDashboardID == dashboard else { return }
                errorMessage = PulseRefusal.message(for: error)
            }
        }
    }

    /// Done (or Undo) on a follow-up card: the promise closes or comes
    /// back; the card shows it at once.
    private func markDone(_ card: PulseCard, _ done: Bool) {
        finishingCards.insert(card.id)
        let dashboard = appState.activeDashboardID
        Task {
            defer { finishingCards.remove(card.id) }
            do {
                let changed = try await client.markDone(card: card.id, done: done)
                guard appState.activeDashboardID == dashboard else { return }
                // The plugin had nothing to change (the card or its item is
                // gone): show what it has instead.
                guard changed else { return await load() }
                if let index = page?.cards.firstIndex(where: { $0.id == card.id }) {
                    page?.cards[index].doneAt = done ? Date() : nil
                    page?.cards[index].doneBy = done ? "user" : ""
                }
                // Handled like Not now: it folds with the rest (Undo brings it back).
                if done, focusedCard == card.id { focusedCard = nil; voiceOverCard = nil }
                if done {
                    untoldCards.remove(card.id)
                    showUndo(.done, card: card.id)
                }
                errorMessage = nil
            } catch {
                guard appState.activeDashboardID == dashboard else { return }
                errorMessage = PulseRefusal.message(for: error)
            }
        }
    }
}

/// The Undo bar's last Done or Not now.
struct PulseUndo: Equatable {
    enum Action { case done, dismissed }

    let id = UUID()
    let card: Int
    let action: Action
    let message: String
}

/// A card's colour by what it's about, and when it came, as the card says it.
enum PulseTopicTint {
    static func color(_ card: PulseCard) -> Color {
        guard card.isNoticed else { return .conduitAccent }
        switch card.topic {
        case "commitment", "promise", "follow-up": return .conduitAccent
        case "date", "reminder": return .blue
        case "watch": return .purple
        case "intention", "interest": return .teal
        case "fact": return .green
        default: return .secondary
        }
    }

    /// The time for today's, else the weekday and time.
    static func stamp(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

private extension View {
    /// A Pulse screen row: no list chrome, the cards' own spacing.
    func pulseRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
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
