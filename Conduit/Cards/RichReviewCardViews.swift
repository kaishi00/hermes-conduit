//
//  RichReviewCardViews.swift
//  Conduit
//
//  How a review card looks (RichReviewCard.swift): a quick pick draws its
//  options in the chat to tap one and send it; a review lists its
//  decisions and opens the review sheet, where each option's page draws at
//  a phone, tablet or desktop width, light or dark, and each decision is
//  marked Approve, Change or Skip with a note. A round already marked, and
//  earlier rounds, open read-only with their marks.
//

import SwiftUI

struct RichReviewCard: View {
    let card: RichCard

    @Environment(\.richCardActions) private var context
    @ObservedObject private var taps = RichCardTapMemory.shared
    @State private var round: RichReviewRound?
    @State private var failed = false
    @State private var picked: String?
    @State private var note = ""
    @State private var reviewing = false
    @State private var fullScreen: RichReviewFullPage?

    var body: some View {
        if let review = card.review {
            RichInfoCardFrame(title: card.title, source: card.source) {
                VStack(alignment: .leading, spacing: 12) {
                    RichReviewHeader(review: review)
                    if review.isQuickPick, let decision = review.decisions.first {
                        quickPick(review, decision)
                    } else {
                        decisionRows(review)
                    }
                    RichReviewSettledLines(settled: review.settled)
                    if failed {
                        HStack(spacing: 8) {
                            Text("The options couldn't be loaded.")
                                .scaledFont(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Try again") { Task { await load(review) } }
                                .scaledFont(.footnote.weight(.semibold))
                        }
                    }
                    footer(review)
                }
            }
            .task(id: review.id + "#\(review.round)") { await load(review) }
            .sheet(isPresented: $reviewing) {
                RichReviewSheet(card: card, review: review, onSent: { sent(review) })
                    .environment(\.richCardActions, context)
            }
            .sheet(item: $fullScreen) { page in
                RichReviewFullScreen(page: page)
            }
        }
    }

    // MARK: Quick pick

    private func quickPick(_ review: RichReview, _ decision: RichReviewDecision) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = decision.text {
                Text(verbatim: text)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(decision.options) { option in
                    RichReviewOptionTile(option: option, html: round?.page(decision: decision.id, option: option.id),
                                         selected: shownPick(review, decision) == option.id,
                                         onSelect: {
                                             // The saved copy can't send, so nothing is picked there.
                                             guard !isSent(review), context?.tap != nil else { return }
                                             Haptics.light()
                                             picked = option.id
                                         },
                                         onExpand: {
                                             fullScreen = RichReviewFullPage(
                                                 option: option, html: round?.page(decision: decision.id, option: option.id))
                                         })
                }
            }
            if !isSent(review), context?.tap != nil {
                HStack(spacing: 8) {
                    TextField("Add a note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    sendPickButton(review, decision)
                }
            }
        }
    }

    /// The pick shown selected: the user's, or the one sent.
    private func shownPick(_ review: RichReview, _ decision: RichReviewDecision) -> String? {
        if let sentMark = round?.marks[decision.id] { return sentMark.option }
        return picked
    }

    @ViewBuilder
    private func sendPickButton(_ review: RichReview, _ decision: RichReviewDecision) -> some View {
        let state = tapState
        Button {
            guard let picked else { return }
            let marks = [decision.id: RichReviewMark(kind: .approve, option: picked, note: note)]
            send(review, marks: marks, note: "")
        } label: {
            HStack(spacing: 6) {
                if state == .sending { ProgressView().controlSize(.small) }
                Text("Send")
            }
            .scaledFont(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.conduitAccent))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(picked == nil || state != nil || !(context?.canSend ?? false) || !(context?.composer?.isEmpty ?? true))
    }

    // MARK: Review

    private func decisionRows(_ review: RichReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(review.decisions) { decision in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: decision.title)
                        .scaledFont(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if let mark = round?.marks[decision.id] {
                        RichReviewMarkBadge(mark: mark, decision: decision)
                    } else {
                        Text(verbatim: decision.options.map(\.id).joined(separator: " · "))
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
        }
    }

    @ViewBuilder
    private func footer(_ review: RichReview) -> some View {
        let sent = isSent(review)
        if !review.isQuickPick || sent {
            HStack(spacing: 10) {
                if sent {
                    Label {
                        Text("Sent")
                    } icon: {
                        Image(systemName: "checkmark")
                    }
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // The saved copy can't read the host's pages or send marks.
                if !review.isQuickPick, context != nil {
                    Button {
                        Haptics.light()
                        reviewing = true
                    } label: {
                        Text("Review")
                            .scaledFont(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20)
                            .frame(minHeight: 44)
                            .foregroundStyle(sent ? Color.conduitAccent : .white)
                            .background(Capsule().fill(sent ? Color.conduitAccent.opacity(0.12) : Color.conduitAccent))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the options"))
                }
            }
        }
    }

    // MARK: State

    private var tapState: RichCardTapMemory.State? {
        guard let context else { return nil }
        return taps.state(card: card, button: RichReviewTap.action, chat: context.chat, sameChat: context.sameChat)
    }

    private func isSent(_ review: RichReview) -> Bool {
        tapState == .sent || round?.wasSent == true
    }

    private func load(_ review: RichReview) async {
        // A kept round draws at once; one not yet answered is asked again,
        // since another device may have answered it since.
        let kept = RichReviewLoader.shared.kept(review.id, review.round)
        if let kept {
            round = kept
            failed = false
            if kept.wasSent { return }
        }
        do {
            let loaded = try await RichReviewLoader.shared.round(review.id, review.round, fresh: kept != nil)
            guard !Task.isCancelled else { return }
            round = loaded
            failed = false
        } catch {
            guard !Task.isCancelled, kept == nil else { return }
            // Pictures draw without the host; pages need it.
            failed = review.hasPages
        }
    }

    private func sent(_ review: RichReview) {
        RichReviewLoader.shared.forget(review.id, review.round)
        Task { await load(review) }
    }

    private func send(_ review: RichReview, marks: [String: RichReviewMark], note: String) {
        guard let context else { return }
        RichReviewSender.send(card: card, review: review, marks: marks, note: note, context: context) {
            sent(review)
        }
    }
}

/// Posts a review's marks as a tap, then the user's message about them.
@MainActor
enum RichReviewSender {
    static func send(card: RichCard, review: RichReview, marks: [String: RichReviewMark], note: String,
                     context: RichCardActionContext, onSent: @escaping @MainActor () -> Void) {
        guard context.canSend, context.composer?.isEmpty ?? true, let tap = context.tap,
              marks.values.contains(where: \.isComplete) else {
            Haptics.error()
            return
        }
        let label = review.isQuickPick ? AppLocalization.string("Picked") : AppLocalization.string("Sent review")
        let body = RichReviewTap.body(card: card, review: review, marks: marks, note: note, label: label)
        let message = RichReviewTap.message(label: label, review: review, marks: marks, title: card.title)
        let key = RichCardTapMemory.key(card: card, button: RichReviewTap.action, chat: context.chat)
        RichCardTapMemory.shared.set(key, .sending)
        Task { @MainActor in
            do {
                try await tap(body, message)
                RichCardTapMemory.shared.set(key, .sent)
                Haptics.success()
                onSent()
            } catch {
                RichCardTapMemory.shared.set(key, nil)
                Haptics.error()
                UIAccessibility.post(notification: .announcement,
                                     argument: AppLocalization.string("Failed to send: \(error.localizedDescription)"))
            }
        }
    }
}

/// "Pick one", or the review's round, and the workstream it's for.
struct RichReviewHeader: View {
    let review: RichReview

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: review.isQuickPick ? "hand.tap" : "rectangle.split.2x1")
                .foregroundStyle(Color.conduitAccent)
                .accessibilityHidden(true)
            Group {
                if review.isQuickPick {
                    Text("Pick one")
                } else {
                    Text(verbatim: "\(AppLocalization.string("Review")) · \(AppLocalization.string("Round")) \(review.round)")
                }
            }
            .scaledFont(.caption.weight(.bold))
            .foregroundStyle(Color.conduitAccent)
            Spacer(minLength: 0)
            if let ref = review.forRef {
                Text(AppLocalization.string("For \(ref)"))
                    .scaledFont(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue.opacity(0.16)))
                    .foregroundStyle(Color.blue)
            }
        }
    }
}

/// Decisions an earlier round settled.
struct RichReviewSettledLines: View {
    let settled: [RichReviewSettled]

    var body: some View {
        if !settled.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(settled.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.approved ? "checkmark.circle.fill" : "forward.circle")
                            .foregroundStyle(entry.approved ? Color.green : Color.secondary)
                            .accessibilityHidden(true)
                        Text(verbatim: [entry.title, entry.choice].compactMap { $0 }.joined(separator: ": "))
                            .scaledFont(.footnote)
                        (entry.approved ? Text("Approved earlier") : Text("Skipped earlier"))
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// A mark sent on a decision, as its row shows it.
struct RichReviewMarkBadge: View {
    let mark: RichReviewMark
    let decision: RichReviewDecision

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: RichReviewMarkBadge.symbol(mark.kind)).accessibilityHidden(true)
            Text(RichReviewMarkBadge.word(mark.kind))
            if mark.kind != .skip, let option = decision.option(mark.option) {
                Text(verbatim: option.id)
            }
        }
        .scaledFont(.footnote.weight(.semibold))
        .foregroundStyle(RichReviewMarkBadge.color(mark.kind))
    }

    static func symbol(_ kind: RichReviewMark.Kind) -> String {
        switch kind {
        case .approve: return "checkmark.circle.fill"
        case .change: return "pencil.circle.fill"
        case .skip: return "forward.circle"
        }
    }

    static func word(_ kind: RichReviewMark.Kind) -> LocalizedStringKey {
        switch kind {
        case .approve: return "Approve"
        case .change: return "Change"
        case .skip: return "Skip"
        }
    }

    static func color(_ kind: RichReviewMark.Kind) -> Color {
        switch kind {
        case .approve: return .green
        case .change: return .orange
        case .skip: return .secondary
        }
    }
}

/// One option of a quick pick: its picture or page, label and line.
struct RichReviewOptionTile: View {
    let option: RichReviewOption
    let html: String?
    let selected: Bool
    let onSelect: () -> Void
    let onExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RichReviewPreview(option: option, html: html, cssWidth: RichReviewWidth.phone.cssWidth, light: nil)
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSelect)
                Button(action: onExpand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .scaledFont(.caption2.weight(.bold))
                        .padding(6)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel(Text("Open full screen"))
            }
            HStack(spacing: 4) {
                Text(verbatim: option.name)
                    .scaledFont(.footnote.weight(.semibold))
                    .lineLimit(2)
                if selected {
                    Image(systemName: "checkmark")
                        .scaledFont(.caption.weight(.bold))
                        .foregroundStyle(Color.conduitAccent)
                        .accessibilityHidden(true)
                }
            }
            if let text = option.text {
                Text(verbatim: text)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.conduitAccent.opacity(0.10) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.conduitAccent : Color.primary.opacity(0.10), lineWidth: selected ? 2 : 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(.default, onSelect)
        // The combined tile swallows the expand button, so it's an action of its own.
        .accessibilityAction(named: Text("Open full screen"), onExpand)
    }
}

/// The widths a page can be drawn at, as on the device it's for.
enum RichReviewWidth: String, CaseIterable, Identifiable {
    case phone, tablet, desktop

    var id: String { rawValue }

    var cssWidth: CGFloat {
        switch self {
        case .phone: return 390
        case .tablet: return 820
        case .desktop: return 1280
        }
    }

    var symbol: String {
        switch self {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .desktop: return "desktopcomputer"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .phone: return "Phone"
        case .tablet: return "Tablet"
        case .desktop: return "Desktop"
        }
    }
}

/// An option drawn small: a picture, or its page laid out at a device's
/// width and scaled down to fit.
struct RichReviewPreview: View {
    let option: RichReviewOption
    let html: String?
    let cssWidth: CGFloat
    /// Nil follows the app.
    let light: Bool?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let url = option.url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.primary.opacity(0.06)
                }
            } else if let html {
                GeometryReader { geometry in
                    let scale = min(1, max(geometry.size.width, 1) / cssWidth)
                    HTMLPreviewWebView(
                        html: HTMLPreviewPage.framed(html, theme: HTMLPreviewTheme(light: light ?? (colorScheme == .light)),
                                                     presentation: .inline),
                        interactive: false
                    )
                    .frame(width: cssWidth, height: geometry.size.height / scale)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
                .background(light.map { $0 ? Color.white : Color.black } ?? Color.clear)
            } else {
                Color.primary.opacity(0.06)
                    .overlay(ProgressView())
            }
        }
        .clipped()
        .accessibilityLabel(Text(verbatim: option.name))
    }
}

/// An option full screen, where its page can be touched, scrolled and
/// zoomed.
struct RichReviewFullPage: Identifiable {
    let option: RichReviewOption
    let html: String?
    /// The theme the sheet was showing; nil follows the app's.
    var light: Bool?
    var id: String { option.id }
}

struct RichReviewFullScreen: View {
    let page: RichReviewFullPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let html = page.html {
            // At the phone's own width, to touch and scroll, in the theme picked.
            if let light = page.light {
                HTMLPreviewSheet(name: page.option.name, html: html)
                    .environment(\.colorScheme, light ? .light : .dark)
            } else {
                HTMLPreviewSheet(name: page.option.name, html: html)
            }
        } else {
            NavigationStack {
                RichReviewPreview(option: page.option, html: nil, cssWidth: RichReviewWidth.phone.cssWidth,
                                  light: page.light)
                    .scaledToFit()
                    .navigationTitle(Text(verbatim: page.option.name))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            }
        }
    }
}

// MARK: - The review sheet

struct RichReviewSheet: View {
    let card: RichCard
    let review: RichReview
    let onSent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.richCardActions) private var context
    @ObservedObject private var taps = RichCardTapMemory.shared
    @State private var shownRound: Int?
    @State private var loaded: RichReviewRound?
    @State private var failed = false
    /// The card's round couldn't be read but draws from its pictures alone.
    @State private var offline = false
    @State private var decisionIndex = 0
    /// The option each decision shows, by decision id.
    @State private var choices: [String: String] = [:]
    @State private var marks: [String: RichReviewMark] = [:]
    @State private var note = ""
    @State private var width: RichReviewWidth = .phone
    @State private var light: Bool?
    @State private var fullScreen: RichReviewFullPage?

    private var roundNumber: Int { shownRound ?? review.round }

    /// The round's decisions: the card's for its own round, the host's for
    /// an earlier one.
    private var decisions: [RichReviewDecision] {
        roundNumber == review.round ? review.decisions : (loaded?.decisions ?? [])
    }

    /// Marks go only on the card's own round, once, and only once the host
    /// has said whether it was already answered (on another device, say).
    private var editable: Bool {
        roundNumber == review.round && (loaded?.round == review.round || offline) && loaded?.wasSent != true
            && tapState == nil && context?.tap != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                decisionStrip
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if decisions.indices.contains(decisionIndex) {
                            decisionView(decisions[decisionIndex])
                        }
                        if failed {
                            HStack(spacing: 8) {
                                Text("The options couldn't be loaded.")
                                    .scaledFont(.footnote)
                                    .foregroundStyle(.secondary)
                                Button("Try again") { Task { await load() } }
                                    .scaledFont(.footnote.weight(.semibold))
                            }
                        }
                        if roundNumber == review.round {
                            RichReviewSettledLines(settled: review.settled)
                        }
                        if editable {
                            TextField("Note on this round (optional)", text: $note, axis: .vertical)
                                .lineLimit(1...5)
                                .textFieldStyle(.roundedBorder)
                        } else if let sentNote = loaded?.note {
                            Text(verbatim: sentNote)
                                .scaledFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(Text(verbatim: card.title ?? AppLocalization.string("Review")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { sendBar }
            .task(id: roundNumber) { await load() }
            .sheet(item: $fullScreen) { page in
                RichReviewFullScreen(page: page)
            }
        }
    }

    // MARK: Parts

    private var decisionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(decisions.enumerated()), id: \.element.id) { index, decision in
                    Button {
                        decisionIndex = index
                    } label: {
                        HStack(spacing: 5) {
                            if let mark = shownMark(decision) {
                                Image(systemName: RichReviewMarkBadge.symbol(mark.kind))
                                    .foregroundStyle(RichReviewMarkBadge.color(mark.kind))
                                    .accessibilityHidden(true)
                            }
                            Text(verbatim: decision.title)
                                .lineLimit(1)
                        }
                        .scaledFont(.subheadline.weight(index == decisionIndex ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(index == decisionIndex ? Color.conduitAccent.opacity(0.16)
                                                                          : Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(index == decisionIndex ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func decisionView(_ decision: RichReviewDecision) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let text = decision.text {
                Text(verbatim: text)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            switch decision.layout {
            case .side:
                sideBySide(decision)
            case .switch, .beforeAfter:
                oneAtATime(decision)
            }
            if editable {
                markControls(decision)
            } else if let mark = shownMark(decision) {
                VStack(alignment: .leading, spacing: 4) {
                    RichReviewMarkBadge(mark: mark, decision: decision)
                    if !mark.note.isEmpty {
                        Text(verbatim: mark.note)
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if roundNumber != review.round || loaded?.wasSent == true {
                Text("Not marked")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sideBySide(_ decision: RichReviewDecision) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(decision.options) { option in
                    optionPanel(decision, option)
                        .frame(width: 260)
                }
            }
        }
    }

    private func oneAtATime(_ decision: RichReviewDecision) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(selection: Binding(get: { choice(decision) }, set: { choose($0, in: decision) })) {
                ForEach(Array(decision.options.enumerated()), id: \.element.id) { index, option in
                    if decision.layout == .beforeAfter, decision.options.count == 2 {
                        (index == 0 ? Text("Before") : Text("After")).tag(option.id)
                    } else {
                        Text(verbatim: option.id).tag(option.id)
                    }
                }
            } label: {
                Text(verbatim: decision.title)
            }
            .pickerStyle(.segmented)
            if let option = decision.option(choice(decision)) {
                optionPanel(decision, option)
            }
        }
    }

    private func optionPanel(_ decision: RichReviewDecision, _ option: RichReviewOption) -> some View {
        let selected = choice(decision) == option.id
        let html = loaded?.page(decision: decision.id, option: option.id)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RichReviewPreview(option: option, html: html, cssWidth: width.cssWidth, light: light)
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { choose(option.id, in: decision) }
                Button {
                    fullScreen = RichReviewFullPage(option: option, html: html, light: light)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .scaledFont(.caption.weight(.bold))
                        .padding(8)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel(Text("Open full screen"))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.conduitAccent : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
            )
            HStack(spacing: 6) {
                Text(verbatim: option.name)
                    .scaledFont(.subheadline.weight(.semibold))
                if option.recommended {
                    Text("Recommended")
                        .scaledFont(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.conduitAccent.opacity(0.16)))
                }
            }
            if let text = option.text {
                Text(verbatim: text)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func markControls(_ decision: RichReviewDecision) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(RichReviewMark.Kind.allCases, id: \.self) { kind in
                    let on = marks[decision.id]?.kind == kind
                    Button {
                        Haptics.light()
                        mark(kind, decision)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: RichReviewMarkBadge.symbol(kind)).accessibilityHidden(true)
                            Text(RichReviewMarkBadge.word(kind))
                        }
                        .scaledFont(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(on ? Color.white : RichReviewMarkBadge.color(kind))
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(on ? RichReviewMarkBadge.color(kind) : Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            if let mark = marks[decision.id], mark.kind != .skip, let option = decision.option(mark.option) {
                Text(verbatim: option.name)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            // A note goes with a mark: typing one never marks the decision.
            if marks[decision.id] != nil {
                TextField("Add a note (optional)", text: Binding(
                    get: { marks[decision.id]?.note ?? "" },
                    set: { text in
                        guard var mark = marks[decision.id] else { return }
                        mark.note = text
                        marks[decision.id] = mark
                    }), axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker(selection: $width) {
                    ForEach(RichReviewWidth.allCases) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                } label: {
                    Text("Width")
                }
                Picker(selection: $light) {
                    Text("Automatic").tag(Bool?.none)
                    Text("Light").tag(Bool?.some(true))
                    Text("Dark").tag(Bool?.some(false))
                } label: {
                    Text("Appearance")
                }
                if review.round > 1 {
                    Picker(selection: Binding(get: { roundNumber }, set: { shownRound = $0; decisionIndex = 0 })) {
                        ForEach(Array((1...review.round).reversed()), id: \.self) { number in
                            Text(verbatim: "\(AppLocalization.string("Round")) \(number)").tag(number)
                        }
                    } label: {
                        Text("Round")
                    }
                }
            } label: {
                Image(systemName: width.symbol)
            }
            .accessibilityLabel(Text("Width"))
        }
    }

    @ViewBuilder
    private var sendBar: some View {
        if editable {
            let ready = marks.values.contains(where: \.isComplete)
            Button {
                guard let context else { return }
                // The sheet stays up until the marks land, so a failed send keeps them.
                RichReviewSender.send(card: card, review: review, marks: marks, note: note, context: context) {
                    onSent()
                    dismiss()
                }
            } label: {
                Text("Send")
                    .scaledFont(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.conduitAccent.opacity(ready ? 1 : 0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!ready || context == nil || !(context?.canSend ?? false) || !(context?.composer?.isEmpty ?? true))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    // MARK: State

    private var tapState: RichCardTapMemory.State? {
        guard let context else { return nil }
        return taps.state(card: card, button: RichReviewTap.action, chat: context.chat, sameChat: context.sameChat)
    }

    private func shownMark(_ decision: RichReviewDecision) -> RichReviewMark? {
        if editable { return marks[decision.id] }
        return loaded?.marks[decision.id]
    }

    /// The option shown is kept per round, so browsing an earlier round
    /// leaves this round's choices and marks as they were.
    private func choiceKey(_ decision: RichReviewDecision) -> String {
        "\(roundNumber)/\(decision.id)"
    }

    private func choice(_ decision: RichReviewDecision) -> String {
        if let chosen = choices[choiceKey(decision)] { return chosen }
        // A round already marked opens on the option its mark names.
        if !editable, let marked = shownMark(decision)?.option, decision.options.contains(where: { $0.id == marked }) {
            return marked
        }
        return decision.options.first(where: \.recommended)?.id ?? decision.options[0].id
    }

    private func choose(_ option: String, in decision: RichReviewDecision) {
        choices[choiceKey(decision)] = option
        // An approval or a change follows the option shown, on the round being marked.
        if roundNumber == review.round, var mark = marks[decision.id], mark.kind != .skip {
            mark.option = option
            marks[decision.id] = mark
        }
    }

    private func mark(_ kind: RichReviewMark.Kind, _ decision: RichReviewDecision) {
        var mark = marks[decision.id] ?? RichReviewMark(kind: kind)
        if mark.kind == kind, marks[decision.id] != nil, mark.note.isEmpty {
            marks[decision.id] = nil
            return
        }
        mark.kind = kind
        mark.option = kind == .skip ? nil : choice(decision)
        marks[decision.id] = mark
        // On to the next decision not marked yet.
        if kind != .change, let next = decisions.indices.first(where: { $0 > decisionIndex && marks[decisions[$0].id] == nil }) {
            decisionIndex = next
        }
    }

    private func load() async {
        // A round the user has since left doesn't answer for the one shown.
        let number = roundNumber
        do {
            let round = try await RichReviewLoader.shared.round(review.id, number, fresh: number == review.round)
            guard number == roundNumber, !Task.isCancelled else { return }
            loaded = round
            failed = false
            offline = false
        } catch {
            guard number == roundNumber, !Task.isCancelled else { return }
            loaded = nil
            failed = review.hasPages || number != review.round
            offline = !failed
        }
    }
}
