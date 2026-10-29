//
//  V2PulsePage.swift
//  Conduit
//
//  The Pulse screen: what Pulse
//  brought up, as cards. A morning brief comes first with the cards it
//  brought, then what's new and what's still open, then Done and cleared,
//  folded. Each card links back to the chat it came from and takes a thumbs
//  up or down; a follow-up's thumbs down asks why, and a report card's too
//  once the plugin learns (asksPulseDownReason), and each answer changes
//  what Pulse does on the host (PulseFeed.swift). Swiping a card away is
//  Not now: off the list, nothing learned, with Undo. What Pulse learned is
//  listed, with the loudest each kind gets, and every lesson can be undone.
//  From 0.84.0 a card's Why? names the biggest part learning played, What
//  Pulse learned lists what learning holds with Reset and Start over, and
//  What Pulse left out lists what the reports didn't bring up, with Bring
//  it up. From 0.86.0 a thumbs down's Wrong time puts the card away as Not
//  now does, until a better time, and Not now's later today ends when the
//  night starts. From 0.90.0 a deadline Pulse memory kept from the
//  Shortcuts inbox has its own card, tinted orange, and Do it starts a new
//  chat for it. From 0.96.0 a card's Why? says what Pulse looked at before
//  writing it. From 0.98.0 an event or reminder Pulse would add is a
//  suggestion on its own card, with Add and Not now, then how it went, and
//  Undo once it's on the phone; this phone applies what it tapped without
//  its own change card.
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
        // mark their messages in the chats. At once when the plugin answers
        // after a launch or a reconnect, so the feed names Pulse's chat.
        .task(id: PulseRefreshKey(dashboard: appState.activeDashboardID,
                                  active: scenePhase == .active && shell.isTabActive,
                                  served: appState.notifierPlugin.reports(PulseClient.feedCapability))) {
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
    let served: Bool
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
    @State private var showsLeftOut = false
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
    /// The card Not now asks "until when?" about.
    @State private var restCard: PulseCard?
    /// Quiet for today, or End quiet time, on its way to the plugin.
    @State private var quieting = false
    /// Do it opened their chat but Pulse wasn't told; kept across refreshes
    /// until the card is done.
    @State private var untoldCards: Set<Int> = []
    /// Suggestions Add or Undo was tapped on: they stay where they are while
    /// the page is up, to show how it went.
    @State private var keptCards: Set<Int> = []
    /// The added suggestion Undo asks about before it comes off the phone.
    @State private var undoCard: PulseCard?

    private var client: PulseClient { appState.pulseClient }

    var body: some View {
        ZStack {
            V2Backdrop(drifts: false)
            content
        }
        .navigationTitle(Text("Pulse"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Quiet for today (0.80.2); while Pulse is quiet, the banner says so instead.
            if canQuiet, page != nil, page?.quietNow == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        quiet(true)
                    } label: {
                        Label(AppLocalization.string("Quiet for today"), systemImage: "moon.zzz")
                    }
                    .disabled(quieting)
                    .accessibilityIdentifier("pulse.quiet-today")
                }
            }
            if appState.pulseExplainsLearning {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsLeftOut = true
                    } label: {
                        Label(AppLocalization.string("What Pulse left out"), systemImage: "tray.full")
                    }
                    .accessibilityIdentifier("pulse.left-out")
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
        .sheet(isPresented: $showsLeftOut) {
            PulseLeftOutSheet { card in
                // It shows as new, at the card, once the sheet is down.
                newCards?.insert(card)
                Task {
                    await load()
                    focus(PulseOpenRequest(card: card))
                }
            }
            .environmentObject(appState)
        }
        .confirmationDialog(
            AppLocalization.string("What was wrong with it?"),
            isPresented: Binding(get: { reasonCard != nil }, set: { if !$0 { reasonCard = nil } }),
            titleVisibility: .visible,
            presenting: reasonCard
        ) { card in
            ForEach(appState.pulseDownReasons) { reason in
                Button(reason.title) { rate(card, up: false, reason: reason) }
            }
            Button(AppLocalization.string("Just thumbs down")) { rate(card, up: false, reason: nil) }
        } message: { _ in
            Text("A reason changes what Pulse does right away, and you can undo it under What Pulse learned. Just thumbs down only teaches Pulse.")
        }
        .confirmationDialog(
            AppLocalization.string("Not now, until when?"),
            isPresented: Binding(get: { restCard != nil }, set: { if !$0 { restCard = nil } }),
            titleVisibility: .visible,
            presenting: restCard
        ) { card in
            ForEach(PulseRest.choices(night: page?.night, brief: page?.briefTime)) { rest in
                Button(rest.title) { dismiss(card, true, until: rest) }
            }
        } message: { _ in
            Text("It comes back as new then, unless it got done meanwhile.")
        }
        .confirmationDialog(
            undoCard?.proposal?.isEvent == false ? AppLocalization.string("Remove it from your reminders?")
                : AppLocalization.string("Remove it from your calendar?"),
            isPresented: Binding(get: { undoCard != nil }, set: { if !$0 { undoCard = nil } }),
            titleVisibility: .visible,
            presenting: undoCard
        ) { card in
            Button(AppLocalization.string("Remove"), role: .destructive) { undoProposal(card) }
        } message: { card in
            Text(verbatim: card.proposal?.line ?? card.title)
        }
        .task(id: PulseRefreshKey(dashboard: appState.activeDashboardID, active: isShown && scenePhase == .active,
                                  served: appState.notifierPlugin.reports(PulseClient.feedCapability))) {
            guard isShown, scenePhase == .active else { return }
            // Cards that come in while the page is open show up too, and the
            // feed is read again once the plugin answers after a launch.
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
            reasonCard = nil
            restCard = nil
            undoCard = nil
            keptCards = []
            newCards = nil
            focusedCard = nil
            voiceOverCard = nil
            undo = nil  // an undo belongs to the visit that made it
            expandedBriefs = []
            expandedWhy = []
        }
        .onChange(of: appState.activeDashboardID) { _, _ in
            reasonCard = nil
            restCard = nil
            undoCard = nil
            keptCards = []
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
                VStack(spacing: 12) {
                    if page.quietNow != nil {
                        quietBanner(page)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .scaledFont(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                    }
                    ContentUnavailableView {
                        Label(AppLocalization.string("Nothing yet"), systemImage: "waveform.path.ecg")
                    } description: {
                        Text("Your reports, your morning brief and the news on what Hermes promised to check land here.")
                    } actions: {
                        if appState.pulseExplainsLearning {
                            Button(AppLocalization.string("What Pulse left out")) { showsLeftOut = true }
                        }
                    }
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
        let layout = PulseLayout(cards: page.cards, keeping: keptCards.union(focusedCard.map { [$0] } ?? []))
        let fresh = layout.open.filter { newCards?.contains($0.id) == true }
        let earlier = layout.open.filter { newCards?.contains($0.id) != true }
        // A brief's new cards count too, though they show in its block; one
        // that brought none counts as one.
        let freshInBriefs = layout.briefs.flatMap { $0.isSummary ? [$0.card] : $0.items }
            .filter { !$0.isCleared && newCards?.contains($0.id) == true }
        return ScrollViewReader { proxy in
            List {
                Group {
                    if page.quietNow != nil { quietBanner(page).pulseRow() }
                    summary(layout, new: fresh.count + freshInBriefs.count).pulseRow()
                    if let learnedNote {
                        Label {
                            Text(verbatim: learnedNote)
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .pulseRow()
                    }
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .scaledFont(.footnote)
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
        if count > 0 || layout.isCaughtUp {
            Text(verbatim: count > 0 ? AppLocalization.string("\(count) new since you last looked")
                                     : AppLocalization.string("You're all caught up"))
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(verbatim: title)
            .scaledFont(.footnote.weight(.semibold))
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

    /// Not now: off the list, nothing learned. A plugin before 0.68.0 can't
    /// take it; one from 0.78.3 asks until when, and the card comes back then.
    /// On a suggestion it's for good: it won't be added.
    @ViewBuilder private func notNowButton(_ card: PulseCard) -> some View {
        if card.isProposal {
            if card.proposal?.state == .waiting {
                Button {
                    guard !isBusy(card) else { return }
                    Haptics.light()
                    dismissProposal(card)
                } label: {
                    Label(AppLocalization.string("Not now"), systemImage: "clock")
                }
                .tint(.gray)
            }
        } else if card.dismissedAt == nil, card.doneAt == nil, canDismiss {
            Button {
                // One request per card: not while its Done is still out.
                guard !isBusy(card) else { return }
                Haptics.light()
                if canChooseRest {
                    restCard = card
                } else {
                    dismiss(card, true)
                }
            } label: {
                Label(AppLocalization.string("Not now"), systemImage: "clock")
            }
            .tint(.gray)
        }
    }

    private var canDismiss: Bool { appState.notifierPlugin.reports(PulseClient.dismissCapability) }
    private var canChooseRest: Bool { appState.notifierPlugin.reports(PulseClient.restCapability) }
    private var canQuiet: Bool { appState.notifierPlugin.reports(PulseClient.quietCapability) }

    /// Pulse is quiet (0.80.2): until when, and for a spell (a vacation, or
    /// Quiet for today) End quiet time. A quiet day ends on its own. Until
    /// when is the moment it ends (`quiet_ends_at`) in the phone's own days,
    /// as the user will live it; Settings shows a vacation's day as the
    /// plugin keeps it, in its time zone.
    private func quietBanner(_ page: PulseFeedPage) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "moon.zzz.fill")
                    .scaledFont(.title3)
                    .foregroundStyle(Color.conduitAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pulse is quiet")
                        .scaledFont(.subheadline.weight(.semibold))
                    if let end = page.quietEndsAt {
                        Text(verbatim: PulseQuiet.backText(end))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if page.quietNow == .until, canQuiet {
                Button {
                    quiet(false)
                } label: {
                    Text(verbatim: AppLocalization.string("End quiet time"))
                        .scaledFont(.footnote.weight(.semibold))
                        .frame(minHeight: 44)  // a full 44 pt to tap
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(quieting)
                .accessibilityIdentifier("pulse.quiet-end")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.thinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    // MARK: Morning brief

    /// A morning brief and the cards it brought, as one block, or folded to
    /// one row that opens it again: once the user folds it, or once
    /// everything in it is handled (`PulseLayout.Brief.isFolded`).
    @ViewBuilder private func briefRows(_ brief: PulseLayout.Brief) -> some View {
        // Open when a Pulse mark pointed at it or one of its cards, even before focus() could expand it.
        if brief.isFolded(folded: appState.pulseBriefFold(brief.id),
                          opened: expandedBriefs.contains(brief.id), focused: focusedCard) {
            foldedBriefRow(brief)
                .id(brief.card.id)
                .pulseRow()
        } else {
            briefHeader(brief)
                .id(brief.card.id)
                .pulseRow(bottom: brief.isSummary ? 6 : 0)
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
                    .scaledFont(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($voiceOverCard, equals: brief.card.id)
                Spacer(minLength: 0)
                if let stamp = briefStamp(brief) {
                    Text(verbatim: stamp)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                // Read it, fold it: it stays one row, here and after a relaunch, until it's opened again.
                Button {
                    fold(brief, true)
                } label: {
                    Image(systemName: "chevron.up")
                        .scaledFont(.footnote.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(AppLocalization.string("Fold the morning brief"))
                .accessibilityIdentifier("pulse.brief.fold")
            }
            if !brief.card.news.isEmpty {
                Text(brief.card.formattedNews)
                    .scaledFont(.subheadline)
                    .foregroundStyle(Color.primary.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(briefBackground(top: true, bottom: brief.isSummary))
    }

    /// "08:00 · 2 left", or "08:00" for a brief that brought no cards
    /// (nothing, when it has no time either).
    private func briefStamp(_ brief: PulseLayout.Brief) -> String? {
        let time = brief.card.createdAt.map { $0.formatted(date: .omitted, time: .shortened) }
        if brief.isSummary { return time }
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
                    Image(systemName: card.isResting ? "clock" : "checkmark.circle")
                        .foregroundStyle(card.isResting ? Color.secondary : Color.green)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.formattedNews)
                            .scaledFont(.subheadline)
                            .strikethrough(card.doneAt != nil)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        // Put off until a time: when it comes back, as a cleared card says it, and
                        // Wrong time's says why. Done meanwhile, it doesn't come back.
                        if card.isResting, let back = card.restUntil {
                            Text(verbatim: card.isAwayForWrongTime
                                ? PulseDownReason.wrongTime.title + " · " + PulseRest.backText(back)
                                : PulseRest.backText(back))
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    clearedUndoButton(card)
                }
                .padding(.vertical, 4)
                sourceLink(card)
            } else {
                topicLine(card)
                Text(card.formattedNews)
                    .scaledFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                sourceLink(card)
                whyNote(card)
                actionRow(card)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 0)
        .padding(.bottom, last ? 12 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The card a Pulse mark opened, marked as a standalone card's stroke would.
        .overlay(alignment: .leading) {
            if focusedCard == card.id {
                Capsule().fill(Color.conduitAccent).frame(width: 3).padding(.vertical, 10).padding(.leading, 4)
            }
        }
        .background(briefBackground(top: false, bottom: last))
    }

    private func briefBackground(top: Bool, bottom: Bool) -> some View {
        let radius = Self.briefShape
        return UnevenRoundedRectangle(topLeadingRadius: top ? radius : 0, bottomLeadingRadius: bottom ? radius : 0,
                                      bottomTrailingRadius: bottom ? radius : 0, topTrailingRadius: top ? radius : 0,
                                      style: .continuous)
            .fill(Color.conduitAccent.opacity(0.10))
    }

    /// Opens the brief, or folds it, as the user left it: a fold is kept
    /// for that brief (AppState.pulseFoldedBriefs) until a card in it comes
    /// back open. Folding the brief a Pulse mark pointed into lets the
    /// mark's card go, so it folds at once; an older brief all handled then
    /// goes back to Done and cleared, where it was before the mark.
    private func fold(_ brief: PulseLayout.Brief, _ folded: Bool) {
        Haptics.selection()
        withAnimation(.snappy) {
            if folded {
                expandedBriefs.remove(brief.id)
                if let focused = focusedCard, focused == brief.id || brief.items.contains(where: { $0.id == focused }) {
                    focusedCard = nil
                    voiceOverCard = nil
                }
            } else {
                expandedBriefs.insert(brief.id)
            }
            appState.foldPulseBrief(brief.id, open: folded ? brief.openCards : nil)
        }
    }

    /// A folded brief: when it came and what's left in it ("08:00 · 2 left",
    /// "All handled"), and a tap opens it.
    private func foldedBriefRow(_ brief: PulseLayout.Brief) -> some View {
        Button {
            fold(brief, false)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sunrise")
                    .foregroundStyle(Color.conduitAccent)
                    .accessibilityHidden(true)
                Text("Morning brief")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if let stamp = briefStamp(brief) {
                    Text(verbatim: stamp)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.conduitAccent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.conduitAccent.opacity(0.24)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(Text(AppLocalization.string("Shows what the brief brought")))
        .accessibilityFocused($voiceOverCard, equals: brief.card.id)
        .accessibilityIdentifier("pulse.brief.open")
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
            .scaledFont(.subheadline)
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
                .scaledFont(.subheadline)
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
            .scaledFont(.subheadline.weight(.semibold))
            .tint(.conduitAccent)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }

    private func showUndo(_ action: PulseUndo.Action, card: Int, back: Date? = nil) {
        // The page was left before the plugin answered: no bar comes back later.
        guard isShown else { return }
        var message = AppLocalization.string("Marked done")
        if action == .dismissed {
            message = AppLocalization.string("Moved to Done and cleared. Pulse learned nothing from it.")
            // Put off until a time: the one the plugin set, as the cleared row says it.
            if let back { message = PulseRest.returning(back).undoMessage }
        }
        withAnimation(.snappy) { undo = PulseUndo(card: card, action: action, message: message) }
        AccessibilityNotification.Announcement(message).post()
    }

    /// A card's request failed. It shows at the top of the list, which can
    /// be far above the card tapped, so VoiceOver says it too.
    private func showError(_ message: String) {
        errorMessage = message
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
            if card.isProposal {
                // What Add puts on the phone, in the plugin's words from the change itself.
                Text(verbatim: card.proposal?.line ?? card.title)
                    .scaledFont(.body)
                    .foregroundStyle(card.isCleared ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(card.formattedNews)
                    .scaledFont(.body)
                    .strikethrough(card.doneAt != nil)
                    .foregroundStyle(card.isCleared ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.quote.isEmpty, !card.isCleared {
                Text(verbatim: "“\(card.quote)”")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            sourceLink(card)
            whyNote(card)
            actionRow(card)
            // Put away by Wrong time, its cleared label says so already, unless it got done meanwhile.
            if card.rating == "down", let reason = PulseDownReason(rawValue: card.reason),
               !(card.isAwayForWrongTime && card.isResting) {
                Text(verbatim: reason.title)
                    .scaledFont(.caption)
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
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityAddTraits(.isHeader)
            if let created = card.createdAt {
                Text(verbatim: "· " + PulseTopicTint.stamp(created))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if card.isHeld {
                Text("For the morning brief")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if appState.explainsPulseCard(card) {
                Button {
                    withAnimation {
                        if expandedWhy.contains(card.id) { expandedWhy.remove(card.id) } else { expandedWhy.insert(card.id) }
                    }
                } label: {
                    Text("Why?")
                        .scaledFont(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .accessibilityValue(expandedWhy.contains(card.id)
                    ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))
                .accessibilityHint(AppLocalization.string("Shows why Pulse brought this up"))
            }
        }
    }

    /// Why Pulse brought the card up, once "Why?" is tapped: its reason,
    /// what Pulse looked at first (0.96.0), and what Pulse learned played in
    /// it (0.84.0).
    @ViewBuilder private func whyNote(_ card: PulseCard) -> some View {
        if expandedWhy.contains(card.id), appState.explainsPulseCard(card) {
            VStack(alignment: .leading, spacing: 8) {
                if appState.explainsPulseCardReason(card) {
                    // A card back after a Do it that stalled says so in the app's language.
                    Text(verbatim: card.backText() ?? card.why)
                }
                if appState.pulseLooksFirst, let looked = card.lookedText {
                    Text(verbatim: looked)
                }
                if appState.pulseExplainsLearning, let learned = card.learned {
                    PulseLearnedLine(preference: learned)
                }
            }
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
        }
    }

    /// Where it came from, a tap away: its chat, or the Kanban task whose
    /// worker it came from, which Hermes won't reopen as a chat.
    @ViewBuilder private func sourceLink(_ card: PulseCard) -> some View {
        if appState.pulseCardHasChat(card) {
            chatLink(card)
        } else if let task = appState.pulseCardTask(card) {
            taskLink(card, task: task)
        }
    }

    /// The Kanban task, opened in Tasks, where it can be unblocked or run again.
    private func taskLink(_ card: PulseCard, task: String) -> some View {
        Button {
            appState.openPulseCardTask(card)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                Text(verbatim: AppLocalization.string("Kanban task \(task)"))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .scaledFont(.caption2.weight(.semibold))
            }
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityHint(Text(AppLocalization.string("Opens the task on the board")))
        .accessibilityIdentifier("pulse.card.task")
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
                    .scaledFont(.caption2.weight(.semibold))
            }
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }

    /// Do it and Done on the left, the thumbs on the right; for a cleared
    /// card, what happened to it and Undo. A suggestion has its own.
    @ViewBuilder private func actionRow(_ card: PulseCard) -> some View {
        if card.isProposal {
            proposalRow(card)
        } else if card.isCleared {
            HStack(spacing: 8) {
                clearedLabel(card)
                Spacer(minLength: 0)
                clearedUndoButton(card)
            }
        } else {
            let untold = untoldCards.contains(card.id)
            VStack(alignment: .leading, spacing: 8) {
                // Do it opened the chat but Pulse wasn't told to check it:
                // the note asks for Done, so Done stays.
                if untold {
                    Label(Self.untoldNote, systemImage: "exclamationmark.circle")
                        .scaledFont(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if !untold, appState.canActOnPulseCard(card) { doItButton(card) }
                    if appState.canMarkPulseCardDone(card) { doneButton(card) }
                    Spacer(minLength: 0)
                    if card.isRatable {
                        thumb(card, up: true)
                        thumb(card, up: false)
                    }
                }
            }
        }
    }

    private func clearedLabel(_ card: PulseCard) -> some View {
        Label(card.clearedTitle, systemImage: card.isResting ? "clock" : "checkmark.circle.fill")
            .scaledFont(.footnote.weight(.semibold))
            .foregroundStyle(card.isResting ? Color.secondary : Color.green)
    }

    /// Puts a swiped-away card back, or takes Done off: Undo, too, on one
    /// marked done while it rested, which leaves it put away.
    @ViewBuilder private func clearedUndoButton(_ card: PulseCard) -> some View {
        if card.isResting, canDismiss {
            Button {
                Haptics.selection()
                dismiss(card, false)
            } label: {
                Text(AppLocalization.string("Put back"))
                    .scaledFont(.footnote.weight(.medium))
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
                    .scaledFont(.footnote.weight(.medium))
            }
            .buttonStyle(.borderless)
            .disabled(isBusy(card))
            .accessibilityLabel(Text(AppLocalization.string("Undo Done")))
            .accessibilityHint(Text(card.undoDoneHint))
            .accessibilityIdentifier("pulse.card.undo-done")
        }
    }

    // MARK: Suggestions

    /// A suggestion's row (0.98.0): Add and Not now while it waits, then
    /// where it stands, with Undo once it's on the phone.
    @ViewBuilder private func proposalRow(_ card: PulseCard) -> some View {
        if let proposal = card.proposal {
            if proposal.state == .waiting {
                HStack(spacing: 8) {
                    addButton(card, proposal)
                    Button {
                        Haptics.light()
                        dismissProposal(card)
                    } label: {
                        Text(AppLocalization.string("Not now"))
                            .scaledFont(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.gray)
                    .disabled(isBusy(card))
                    .accessibilityHint(Text(AppLocalization.string("Pulse won't add it")))
                    .accessibilityIdentifier("pulse.card.proposal-not-now")
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        proposalStateLabel(proposal)
                        Spacer(minLength: 0)
                        if proposal.canUndo {
                            Button {
                                Haptics.selection()
                                undoCard = card
                            } label: {
                                Text(AppLocalization.string("Undo"))
                                    .scaledFont(.footnote.weight(.medium))
                            }
                            .buttonStyle(.borderless)
                            .disabled(isBusy(card))
                            .accessibilityHint(Text(proposal.isEvent
                                ? AppLocalization.string("Removes it from your calendar")
                                : AppLocalization.string("Removes it from your reminders")))
                            .accessibilityIdentifier("pulse.card.proposal-undo")
                        }
                    }
                    if !proposal.note.isEmpty, proposal.state == .failed || proposal.state == .changed {
                        Text(verbatim: proposal.note)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func addButton(_ card: PulseCard, _ proposal: PulseProposal) -> some View {
        Button {
            Haptics.selection()
            addProposal(card)
        } label: {
            // The icon's colour is set outright, as Do it's is.
            Label {
                Text(AppLocalization.string("Add"))
            } icon: {
                Image(systemName: proposal.isEvent ? "calendar.badge.plus" : "plus.circle")
                    .foregroundStyle(.white)
            }
            .labelStyle(.titleAndIcon)
            .scaledFont(.footnote.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(.conduitAccent)
        .accessibilityHint(Text(proposal.isEvent ? AppLocalization.string("Adds it to your calendar")
                                                 : AppLocalization.string("Adds it to your reminders")))
        .disabled(isBusy(card))
        .accessibilityIdentifier("pulse.card.proposal-add")
    }

    /// Where a suggestion stands, once it's no longer waiting.
    private func proposalStateLabel(_ proposal: PulseProposal) -> some View {
        HStack(spacing: 6) {
            if proposal.isInFlight {
                // Its text already says Adding… or Removing….
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: Self.proposalSymbol(proposal.state))
                    .foregroundStyle(Self.proposalTint(proposal.state))
                    .accessibilityHidden(true)
            }
            Text(verbatim: proposal.stateText)
                .foregroundStyle(proposal.canUndo ? Color.green : Color.secondary)
        }
        .scaledFont(.footnote.weight(.semibold))
        .accessibilityElement(children: .combine)
    }

    private static func proposalSymbol(_ state: PulseProposal.State) -> String {
        switch state {
        case .added, .changed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .expired: return "clock"
        case .removed: return "arrow.uturn.backward.circle"
        default: return "xmark.circle"
        }
    }

    private static func proposalTint(_ state: PulseProposal.State) -> Color {
        switch state {
        case .added, .changed: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private func doItButton(_ card: PulseCard) -> some View {
        Button {
            Haptics.selection()
            if let refusal = appState.pulseNewChatRefusal(for: card) {
                showError(refusal)
                return
            }
            let failure = appState.pulseCardHasChat(card)
                ? AppLocalization.string("Couldn't open that chat. Try again.")
                : AppLocalization.string("Couldn't start a new chat. Check your connection and try again.")
            let dashboard = appState.activeDashboardID
            actingCard = card.id
            Task {
                defer { if actingCard == card.id { actingCard = nil } }
                let opened = await appState.actOnPulseCard(card)
                guard appState.activeDashboardID == dashboard else { return }
                if !opened {
                    showError(failure)
                    return
                }
                if errorMessage == failure { errorMessage = nil }
                // Pulse reads the chat once Hermes has answered and marks the card done itself.
                // Only a card Pulse can mark done, with a Done button to fall back on.
                if appState.canMarkPulseCardDone(card), appState.notifierPlugin.reports(PulseClient.actedCapability) {
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
            // The icon's colour is set outright: in a prominent button a
            // Label's icon can take the tint, which is the button's own fill,
            // and vanish, leaving the title alone at the right.
            Label {
                Text(AppLocalization.string("Do it"))
            } icon: {
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.white)
            }
            .labelStyle(.titleAndIcon)
            .scaledFont(.footnote.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(.conduitAccent)
        .accessibilityHint(Text(appState.pulseCardHasChat(card)
            ? AppLocalization.string("Opens the chat with this reminder ready to send")
            : AppLocalization.string("Opens a new chat with this reminder ready to send")))
        .disabled(actingCard != nil || isBusy(card))
        .accessibilityIdentifier("pulse.card.do-it")
    }

    private func doneButton(_ card: PulseCard) -> some View {
        Button {
            Haptics.selection()
            markDone(card, true)
        } label: {
            Label(AppLocalization.string("Done"), systemImage: "checkmark.circle")
                .scaledFont(.footnote.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.conduitAccent)
        .accessibilityHint(Text(card.isFound
            ? AppLocalization.string("Tells Pulse this is taken care of, so the next report knows it's done")
            : AppLocalization.string("Tells Pulse this is taken care of, so it stops checking on it")))
        .disabled(isBusy(card))
        .accessibilityIdentifier("pulse.card.done")
    }

    private func thumb(_ card: PulseCard, up: Bool) -> some View {
        let chosen = card.rating == (up ? "up" : "down")
        return Button {
            Haptics.selection()
            if up || !appState.asksPulseDownReason(card) { rate(card, up: up, reason: nil) } else { reasonCard = card }
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
            let loaded = try await client.feed(proposals: appState.pulseSuggests)
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
            if isShown, loaded.unseen > 0, (try? await client.markSeen(nil, proposals: appState.pulseSuggests)) != nil,
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
        // A card a folded brief brought opens that brief while it's focused
        // (briefRows), and the brief folds again once the card is handled.
    }

    private func rate(_ card: PulseCard, up: Bool, reason: PulseDownReason?) {
        ratingCards.insert(card.id)
        let dashboard = appState.activeDashboardID
        Task {
            defer { ratingCards.remove(card.id) }
            do {
                let rated = try await client.rate(card: card.id, up: up, reason: reason)
                guard appState.activeDashboardID == dashboard else { return }
                let now = Date()
                if let index = page?.cards.firstIndex(where: { $0.id == card.id }) {
                    page?.cards[index].rating = up ? "up" : "down"
                    page?.cards[index].reason = reason?.rawValue ?? ""
                    page?.cards[index].ratedAt = now
                }
                if !up, reason == .wrongTime, let back = rated.restUntil {
                    // Wrong time put it away until a better time: it moves as Not now's does, with Undo.
                    withAnimation(.snappy) {
                        if let index = page?.cards.firstIndex(where: { $0.id == card.id }) {
                            page?.cards[index].dismissedAt = now
                            page?.cards[index].restUntil = back
                        }
                        if focusedCard == card.id { focusedCard = nil; voiceOverCard = nil }
                    }
                    showUndo(.dismissed, card: card.id, back: back)
                }
                errorMessage = nil
                learnedNote = rated.lessons.isEmpty ? nil
                    : AppLocalization.string("Pulse learned: \(rated.lessons.map(\.text).joined(separator: "; "))")
            } catch {
                guard appState.activeDashboardID == dashboard else { return }
                showError(PulseRefusal.message(for: error))
            }
        }
    }

    /// Quiet for today (Pulse keeps to itself until midnight; a longer
    /// spell already set stays), or End quiet time; the page then shows it.
    private func quiet(_ on: Bool) {
        guard !quieting else { return }
        quieting = true
        Haptics.light()
        let dashboard = appState.activeDashboardID
        let client = self.client
        Task {
            defer { quieting = false }
            do {
                let until: Any = on ? "today" as Any : NSNull() as Any
                _ = try await client.update(["quiet_until": until])
                guard appState.activeDashboardID == dashboard else { return }
                Haptics.success()
                await load()
            } catch {
                guard appState.activeDashboardID == dashboard else { return }
                errorMessage = PulseRefusal.message(for: error)
                Haptics.error()
            }
        }
    }

    /// Not now (or Put back): off the list into Done and cleared, nothing
    /// learned, until later today, tomorrow or next week when asked; the
    /// card moves at once.
    private func dismiss(_ card: PulseCard, _ dismissed: Bool, until: PulseRest? = nil) {
        finishingCards.insert(card.id)
        let dashboard = appState.activeDashboardID
        Task {
            defer { finishingCards.remove(card.id) }
            do {
                let answer = try await client.dismiss(card: card.id, dismissed: dismissed, until: until)
                guard appState.activeDashboardID == dashboard else { return }
                guard answer.changed else { return await load() }
                withAnimation(.snappy) {
                    if let index = page?.cards.firstIndex(where: { $0.id == card.id }) {
                        page?.cards[index].dismissedAt = dismissed ? Date() : nil
                        page?.cards[index].restUntil = dismissed ? answer.restUntil : nil
                    }
                    if focusedCard == card.id, dismissed { focusedCard = nil; voiceOverCard = nil }
                    if !dismissed { unfold(card) }
                }
                if dismissed { showUndo(.dismissed, card: card.id, back: answer.restUntil) }
                errorMessage = nil
            } catch {
                guard appState.activeDashboardID == dashboard else { return }
                showError(PulseRefusal.message(for: error))
            }
        }
    }

    /// A card put back open with Undo or Put back: the brief that brought
    /// it, folded since, opens to show it (AppState.unfoldPulseCard).
    private func unfold(_ card: PulseCard) {
        guard let cards = page?.cards, let brief = PulseLayout(cards: cards).brief(bringing: card.id) else { return }
        appState.unfoldPulseCard(card.id, in: brief.id)
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
                if !done { unfold(card) }
                if done {
                    untoldCards.remove(card.id)
                    showUndo(.done, card: card.id)
                }
                errorMessage = nil
            } catch {
                guard appState.activeDashboardID == dashboard else { return }
                showError(PulseRefusal.message(for: error))
            }
        }
    }

    /// Add on a suggestion (0.98.0): the plugin asks the phone for it from
    /// what it kept, and this phone applies it without its own change card
    /// (AppState.applyPulseApproval); the card then shows how it went.
    private func addProposal(_ card: PulseCard) {
        changeProposal(card, undo: false)
    }

    /// Undo on an added suggestion, once the dialog said Remove: the plugin
    /// asks the phone to delete it, which this phone does as it did the add.
    private func undoProposal(_ card: PulseCard) {
        changeProposal(card, undo: true)
    }

    private func changeProposal(_ card: PulseCard, undo: Bool) {
        guard let proposal = card.proposal else { return }
        finishingCards.insert(card.id)
        keptCards.insert(card.id)
        let dashboard = appState.activeDashboardID
        Task {
            defer { finishingCards.remove(card.id) }
            do {
                let answer = try await (undo ? client.undoProposal(proposal.id) : client.addProposal(proposal.id))
                guard appState.activeDashboardID == dashboard else { return }
                setProposal(answer, on: card.id)
                errorMessage = nil
                guard let change = undo ? answer.undoID : answer.changeID else {
                    AccessibilityNotification.Announcement(answer.stateText).post()
                    return
                }
                let outcome = await appState.applyPulseApproval(change)
                guard appState.activeDashboardID == dashboard else { return }
                await load()
                guard appState.activeDashboardID == dashboard,
                      let settled = page?.cards.first(where: { $0.id == card.id })?.proposal else { return }
                if !settled.isInFlight {
                    AccessibilityNotification.Announcement(settled.stateText).post()
                } else if outcome == .off {
                    // This phone never gets it: the device sharing the calendar does.
                    showError(AppLocalization.string(
                        "This iPhone doesn't share its calendar with Hermes, so the change waits for a device that does."))
                } else if outcome != .synced {
                    // Still Adding… because this phone's pass didn't get the change, not just slow.
                    showError(AppLocalization.string(
                        "This iPhone couldn't get the change from Hermes yet. Conduit tries again the next time it syncs with Hermes."))
                }
                // Synced and still Adding…: the label says so, and the next load settles it.
            } catch {
                guard appState.activeDashboardID == dashboard else { return }
                showError(PulseRefusal.message(for: error))
                // Where it stands now: added from another device, expired, …
                await load()
            }
        }
    }

    /// Not now on a suggestion: it won't be added, for good, and the card
    /// goes to Done and cleared.
    private func dismissProposal(_ card: PulseCard) {
        guard let proposal = card.proposal else { return }
        finishingCards.insert(card.id)
        let dashboard = appState.activeDashboardID
        Task {
            defer { finishingCards.remove(card.id) }
            do {
                let answer = try await client.dismissProposal(proposal.id)
                guard appState.activeDashboardID == dashboard else { return }
                withAnimation(.snappy) {
                    setProposal(answer, on: card.id)
                    if let index = page?.cards.firstIndex(where: { $0.id == card.id }) {
                        page?.cards[index].dismissedAt = Date()
                    }
                    if focusedCard == card.id { focusedCard = nil; voiceOverCard = nil }
                }
                AccessibilityNotification.Announcement(answer.stateText).post()
                errorMessage = nil
            } catch {
                guard appState.activeDashboardID == dashboard else { return }
                showError(PulseRefusal.message(for: error))
                await load()
            }
        }
    }

    private func setProposal(_ proposal: PulseProposal, on card: Int) {
        guard let index = page?.cards.firstIndex(where: { $0.id == card }) else { return }
        page?.cards[index].proposal = proposal
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
        card.isNoticed ? color(topic: card.topic) : .conduitAccent
    }

    /// A report item's colour by its topic (a card's, or a left-out item's kind).
    static func color(topic: String) -> Color {
        switch topic {
        case "commitment", "promise", "follow-up": return .conduitAccent
        case "date", "reminder": return .blue
        case "watch": return .purple
        case "intention", "interest": return .teal
        case "fact": return .green
        case "deadline": return .orange
        case "next": return .indigo
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

/// What learning holds about one thing (0.84.0): what it's about, then
/// which way it moves things, how strongly and the votes behind it.
struct PulseLearnedLine: View {
    let preference: PulsePreference
    /// Under a "What Pulse learned" heading, as on a card's Why?.
    var headed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if headed {
                Label {
                    Text("What Pulse learned")
                } icon: {
                    Image(systemName: "sparkles")
                }
                .scaledFont(.caption.weight(.semibold))
            }
            Text(verbatim: preference.subject)
                .foregroundStyle(.primary)
            Text(verbatim: preference.detail)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// What Pulse learned: each kind's loudness, what learning holds with Reset
/// and Start over (0.84.0), and the lessons ratings and resets made, each
/// with Undo.
struct PulseLearnedSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let onChange: () -> Void

    @State private var learned: PulseLearned?
    @State private var errorMessage: String?
    @State private var working = false
    @State private var confirmsStartOver = false

    private var client: PulseClient { appState.pulseClient }
    /// A plugin that learns from thumbs, Do it and Done (0.81.1): thumbs no longer move the levels.
    private var learns: Bool { appState.notifierPlugin.reports(PulseClient.learnsCapability) }

    var body: some View {
        NavigationStack {
            List {
                if let learned {
                    Section {
                        ForEach(learned.levels.keys.sorted(), id: \.self) { kind in
                            Picker(PulseCardKind.name(kind), selection: Binding(
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
                        Text(verbatim: PulseLearned.levelsFooter(learns: learns))
                    }
                    if appState.pulseExplainsLearning {
                        preferencesSection(learned)
                    }
                    Section {
                        if learned.lessons.isEmpty {
                            Text(verbatim: PulseLearned.noLessons(learns: learns))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(learned.lessons) { lesson in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: lesson.text)
                                    if let cause = lesson.causeText {
                                        Text(verbatim: cause)
                                            .scaledFont(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Button(AppLocalization.string("Undo")) { undo(lesson) }
                                    .buttonStyle(.borderless)
                                    .disabled(working)
                                    .accessibilityLabel(Text(AppLocalization.string("Undo: \(lesson.text)")))
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
                        .scaledFont(.footnote)
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
            .confirmationDialog(
                AppLocalization.string("Forget everything Pulse learned?"),
                isPresented: $confirmsStartOver,
                titleVisibility: .visible
            ) {
                Button(AppLocalization.string("Forget everything"), role: .destructive) { reset(nil) }
            } message: {
                Text("Pulse forgets what your thumbs, Do it and Done taught it so far and learns again from what you do next. The levels you set and the lessons from your reasons stay, and Undo takes it back.")
            }
            .task(id: appState.activeDashboardID) {
                // Another dashboard's: nothing of the last one stays to be reset or undone.
                learned = nil
                errorMessage = nil
                confirmsStartOver = false
                await load()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// What learning holds, strongest first, each with Reset (but the lean
    /// over Pulse's cards in general, which only Start over forgets).
    private func preferencesSection(_ learned: PulseLearned) -> some View {
        Section {
            if learned.preferences.isEmpty {
                Text(verbatim: PulseLearned.noPreferences)
                    .foregroundStyle(.secondary)
            }
            ForEach(learned.preferences) { preference in
                HStack {
                    PulseLearnedLine(preference: preference, headed: false)
                    Spacer(minLength: 8)
                    if preference.canReset {
                        Button(AppLocalization.string("Reset")) { reset(preference) }
                            .buttonStyle(.borderless)
                            .disabled(working)
                            .accessibilityLabel(Text(AppLocalization.string("Reset what Pulse learned: \(preference.subject)")))
                            .accessibilityHint(Text(AppLocalization.string("Pulse forgets what it learned about this")))
                    }
                }
            }
            if !learned.preferences.isEmpty {
                Button(AppLocalization.string("Start over"), role: .destructive) { confirmsStartOver = true }
                    .disabled(working)
                    .accessibilityIdentifier("pulse.learned.start-over")
            }
        } header: {
            Text("From your thumbs, Do it and Done")
        } footer: {
            Text("Reset makes Pulse forget what it learned about one of these, and Start over forgets all of it. Undo takes either back, under Learned from your ratings.")
        }
    }

    private func load() async {
        let dashboard = appState.activeDashboardID
        let client = self.client
        do {
            let loaded = try await client.learned()
            guard appState.activeDashboardID == dashboard else { return }
            learned = loaded
            errorMessage = nil
        } catch {
            guard appState.activeDashboardID == dashboard else { return }
            errorMessage = PulseRefusal.message(for: error)
        }
    }

    private func setLevel(_ level: PulseLevel, for kind: String) {
        run { client in try await client.setLevel(level, for: kind) }
    }

    private func undo(_ lesson: PulseLesson) {
        run { client in try await client.undo(lesson: lesson.id) }
    }

    /// Forgets one thing learning holds, or everything for nil.
    private func reset(_ preference: PulsePreference?) {
        run { client in try await client.reset(preference) }
    }

    /// The step runs against the dashboard that was active when it was
    /// asked for, not whichever is active once the task starts.
    private func run(_ step: @escaping @MainActor (PulseClient) async throws -> PulseLearned) {
        working = true
        let dashboard = appState.activeDashboardID
        let client = self.client
        Task {
            defer { working = false }
            do {
                let result = try await step(client)
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

/// What Pulse left out (0.84.0): what the latest reports, and from 0.88.0
/// the latest look ahead, considered and didn't bring up, and why, what
/// learning or the user's own rules kept out first, each with Bring it up,
/// which makes it a card on the Pulse screen.
struct PulseLeftOutSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// A card was made of one: the Pulse screen shows it.
    let onBroughtUp: (Int) -> Void

    @State private var entries: [PulseLeftOut]?
    @State private var errorMessage: String?
    @State private var bringing: Int?

    private var client: PulseClient { appState.pulseClient }

    var body: some View {
        NavigationStack {
            List {
                if let entries {
                    let kept = entries.filter(\.isKeptOut)
                    let reported = entries.filter { !$0.isKeptOut && !$0.isLookAhead }
                    let lookedAhead = entries.filter { !$0.isKeptOut && $0.isLookAhead }
                    if entries.isEmpty {
                        Section {
                            Text("Nothing left out lately.")
                                .foregroundStyle(.secondary)
                        } footer: {
                            footer
                        }
                    }
                    if !kept.isEmpty {
                        Section {
                            ForEach(kept) { entry in row(entry) }
                        } header: {
                            Text("Kept out by what you taught Pulse")
                        } footer: {
                            if reported.isEmpty && lookedAhead.isEmpty { footer }
                        }
                    }
                    if !reported.isEmpty {
                        Section {
                            ForEach(reported) { entry in row(entry) }
                        } header: {
                            Text("Left out of the report")
                        } footer: {
                            if lookedAhead.isEmpty { footer }
                        }
                    }
                    if !lookedAhead.isEmpty {
                        Section {
                            ForEach(lookedAhead) { entry in row(entry) }
                        } header: {
                            Text("Left out of the look ahead")
                        } footer: {
                            footer
                        }
                    }
                } else if let errorMessage {
                    Text(verbatim: errorMessage).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
                if entries != nil, let errorMessage {
                    Text(verbatim: errorMessage)
                        .scaledFont(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(Text("What Pulse left out"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
            .task(id: appState.activeDashboardID) {
                entries = nil
                errorMessage = nil
                await load()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var footer: some View {
        if entries?.contains(where: \.isLookAhead) == true {
            Text("From the latest reports and look ahead. Bring it up makes it a card on the Pulse screen, without a notification, and what you do with it teaches Pulse about things like it.")
        } else {
            Text("From the latest reports. Bring it up makes it a card on the Pulse screen, without a notification, and what you do with it teaches Pulse about things like it.")
        }
    }

    private func row(_ entry: PulseLeftOut) -> some View {
        let tint = PulseTopicTint.color(topic: entry.kind)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(verbatim: PulseCardKind.topic(entry.kind))
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                if let created = entry.createdAt {
                    Text(verbatim: "· " + PulseTopicTint.stamp(created))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(verbatim: entry.text)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.chatTitle.isEmpty {
                Label {
                    Text(verbatim: entry.chatTitle)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "bubble.left")
                }
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            }
            Text(verbatim: entry.reason)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // What learning held against it, for one learning kept out.
            if entry.decision == "quieted", let learned = entry.learned {
                PulseLearnedLine(preference: learned)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer(minLength: 0)
                if entry.cardID != nil {
                    Label(AppLocalization.string("On the Pulse screen"), systemImage: "checkmark.circle.fill")
                        .scaledFont(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Button {
                        Haptics.selection()
                        bringUp(entry)
                    } label: {
                        Label(AppLocalization.string("Bring it up"), systemImage: "arrow.up.circle")
                            .scaledFont(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.conduitAccent)
                    .disabled(bringing != nil)
                    .accessibilityLabel(Text(AppLocalization.string("Bring it up: \(entry.text)")))
                    .accessibilityHint(Text(AppLocalization.string("Makes it a card on the Pulse screen")))
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func load() async {
        let dashboard = appState.activeDashboardID
        do {
            let loaded = try await client.leftOut()
            guard appState.activeDashboardID == dashboard else { return }
            entries = loaded
            errorMessage = nil
        } catch {
            guard appState.activeDashboardID == dashboard else { return }
            errorMessage = PulseRefusal.message(for: error)
        }
    }

    private func bringUp(_ entry: PulseLeftOut) {
        bringing = entry.id
        let dashboard = appState.activeDashboardID
        let client = self.client
        Task {
            defer { bringing = nil }
            do {
                let card = try await client.bringUp(entry.id)
                guard appState.activeDashboardID == dashboard else { return }
                if let index = entries?.firstIndex(where: { $0.id == entry.id }) {
                    entries?[index].cardID = card.id
                }
                errorMessage = nil
                Haptics.success()
                onBroughtUp(card.id)
            } catch {
                guard appState.activeDashboardID == dashboard else { return }
                if PulseRefusal(error: error)?.code == "invalid" {
                    // It came up meanwhile, or the journal let it go: the list as it is now.
                    await load()
                    errorMessage = AppLocalization.string("Pulse no longer has that one.")
                } else {
                    errorMessage = PulseRefusal.message(for: error)
                }
                Haptics.error()
            }
        }
    }
}
