//
//  PinnedReplyViews.swift
//  Conduit
//
//  Pinned replies (#918): Pin and Pin reply in a reply's long-press menu,
//  Pin taking just the selected passage (#1147), the bar over the open chat, the
//  overview of every pin with its label editor, and the flash that shows a
//  pinned passage after the jump (AppState+PinnedReplies).
//

import SwiftUI
import UIKit

/// Pins or unpins a reply from its text: the selection menu's Pin takes
/// just the selected passage and Pin reply all of it (#1147), as does
/// VoiceOver's action on the text (#918); the reply's action row has no
/// Pin. Only a reply in a chat that can pin provides one.
/// Equal by reply, so a re-created value does not re-run the text views'
/// updates; whether something is pinned right now is asked when the menu
/// opens, for the same reason.
struct ChatPinReplyAction: Equatable {
    let messageID: String
    private let pinned: @MainActor () -> Bool
    private let handler: @MainActor () -> Void
    private let passagePinned: @MainActor (String) -> Bool
    private let passageHandler: @MainActor (String, _ toggles: Bool) -> Void

    init(
        messageID: String,
        isPinned: @escaping @MainActor () -> Bool,
        toggle: @escaping @MainActor () -> Void,
        isPassagePinned: @escaping @MainActor (String) -> Bool = { _ in false },
        pinPassage: @escaping @MainActor (String, _ toggles: Bool) -> Void = { _, _ in }
    ) {
        self.messageID = messageID
        self.pinned = isPinned
        self.handler = toggle
        self.passagePinned = isPassagePinned
        self.passageHandler = pinPassage
    }

    /// The open chat's action for `message`, or nil where replies can't be
    /// pinned (a room, the saved copy, a chat with no id yet).
    @MainActor
    init?(message: ChatMessage, appState: AppState) {
        guard message.role == .assistant, appState.canPinReplies else { return nil }
        let id = message.id
        self.init(
            messageID: id,
            isPinned: { [weak appState] in
                appState?.openChatPinnedMessageIDs.contains(id) ?? false
            },
            toggle: { [weak appState] in
                guard let appState else { return }
                Haptics.light()
                // The reply as it is now, not as it was when the row drew.
                appState.togglePinnedReply(appState.messages.first { $0.id == id } ?? message)
            },
            isPassagePinned: { [weak appState] passage in
                appState?.isPassagePinned(passage, messageID: id) ?? false
            },
            pinPassage: { [weak appState] passage, toggles in
                guard let appState else { return }
                Haptics.light()
                let current = appState.messages.first { $0.id == id } ?? message
                if toggles {
                    appState.togglePinnedPassage(passage, of: current)
                } else {
                    appState.pinPassage(passage, of: current)
                }
            }
        )
    }

    /// Whether the whole reply is pinned.
    @MainActor
    var isPinned: Bool { pinned() }

    /// Pins or unpins the whole reply.
    @MainActor
    func callAsFunction() { handler() }

    @MainActor
    func isPinned(passage: String) -> Bool { passagePinned(passage) }

    /// Pins the selected passage, or unpins it when it is pinned already.
    @MainActor
    func togglePassage(_ passage: String) { passageHandler(passage, true) }

    /// Pins the selected passage unless it is pinned already.
    @MainActor
    func pinPassage(_ passage: String) { passageHandler(passage, false) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messageID == rhs.messageID
    }
}

private struct ChatPinReplyActionKey: EnvironmentKey {
    static let defaultValue: ChatPinReplyAction? = nil
}

extension EnvironmentValues {
    var chatPinReplyAction: ChatPinReplyAction? {
        get { self[ChatPinReplyActionKey.self] }
        set { self[ChatPinReplyActionKey.self] = newValue }
    }
}

/// The slim bar over the open chat showing one pinned reply. A tap goes to
/// that reply and moves the bar to the one before it, round to the latest
/// again, as Telegram does; a long press offers Unpin and the overview.
struct PinnedReplyBar: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    /// Oldest first, as the replies sit in the chat.
    let pins: [PinnedReply]
    let jump: (PinnedReply) -> Void
    let unpin: (PinnedReply) -> Void
    /// Opens the label editor for a pin (#1147).
    let label: (PinnedReply) -> Void
    let showAll: () -> Void
    /// Into `pins`; nil shows the latest.
    @State private var shownIndex: Int?

    private var index: Int {
        guard let shownIndex else { return pins.count - 1 }
        return min(max(shownIndex, 0), pins.count - 1)
    }

    private var title: String {
        pins.count > 1
            ? AppLocalization.string("Pinned reply \(String(index + 1)) of \(String(pins.count))")
            : AppLocalization.string("Pinned reply")
    }

    var body: some View {
        if let pin = pins.indices.contains(index) ? pins[index] : nil {
            Button {
                Haptics.selection()
                jump(pin)
                shownIndex = PinnedReplies.nextBarIndex(after: index, count: pins.count)
            } label: {
                HStack(spacing: 10) {
                    PinnedReplyBarIndicator(count: pins.count, selected: index)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.conduitAccent)
                        Text(pin.title)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "pin.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            // The transcript scrolls under the bar: a near-solid fill keeps
            // the excerpt readable over it.
            .background(
                Color(uiColor: .systemBackground).opacity(0.88),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .conduitGlassControl(cornerRadius: 14, tint: .conduitAccent.opacity(0.10))
            .contextMenu {
                Button(role: .destructive) {
                    Haptics.light()
                    shownIndex = nil
                    unpin(pin)
                } label: {
                    Label(AppLocalization.string("Unpin"), systemImage: "pin.slash")
                }
                Button {
                    label(pin)
                } label: {
                    Label(PinnedReplyLabelEditor.actionTitle(for: pin), systemImage: "tag")
                }
                Button {
                    showAll()
                } label: {
                    Label(AppLocalization.string("All pinned replies"), systemImage: "pin")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(title), \(pin.title)"))
            .accessibilityHint(AppLocalization.string("Goes to the pinned reply"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: AppLocalization.string("Unpin")) {
                shownIndex = nil
                unpin(pin)
            }
            .accessibilityAction(named: PinnedReplyLabelEditor.actionTitle(for: pin)) { label(pin) }
            .accessibilityAction(named: AppLocalization.string("All pinned replies")) { showAll() }
            .accessibilityIdentifier("chat.pinnedReplyBar")
            // Pins added, removed or reordered (earlier messages loaded):
            // back to the latest, so the index never names another reply.
            .onChange(of: pins.map(\.id)) { _, _ in shownIndex = nil }
        }
    }
}

/// Telegram's segments beside the bar: one per pin, the shown one lit. Past
/// a few pins it draws one bar with the shown position lit.
private struct PinnedReplyBarIndicator: View {
    let count: Int
    let selected: Int

    private static let height: CGFloat = 30
    private static let maxSegments = 4

    var body: some View {
        VStack(spacing: 2) {
            if count <= 1 {
                Capsule().fill(Color.conduitAccent)
            } else {
                let segments = min(count, Self.maxSegments)
                let lit = count <= Self.maxSegments
                    ? selected
                    : Int((Double(selected) / Double(count - 1) * Double(segments - 1)).rounded())
                ForEach(0..<segments, id: \.self) { segment in
                    Capsule()
                        .fill(Color.conduitAccent.opacity(segment == lit ? 1 : 0.3))
                }
            }
        }
        .frame(width: 3, height: Self.height)
        .accessibilityHidden(true)
    }
}

/// Every pinned reply of the profile, a section per chat. A tap opens the
/// chat at the reply, or at the passage a pin holds; a pin can be labelled
/// from here (#1147).
struct PinnedRepliesSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var labelingPin: PinnedReply?

    var body: some View {
        let sections = PinnedReplies.overview(appState.activePinnedReplies)
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                List {
                    if sections.isEmpty {
                        ContentUnavailableView(
                            AppLocalization.string("No pinned replies"),
                            systemImage: "pin",
                            description: Text(AppLocalization.string("Long-press a reply and choose Pin for the selected text or Pin reply for all of it. It stays at the top of its chat and shows here."))
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(sections, id: \.sessionID) { section in
                            Section {
                                ForEach(section.pins) { pin in
                                    row(pin)
                                }
                            } header: {
                                Text(section.pins.first.map(appState.pinnedReplyChatTitle) ?? "")
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: AppLocalization.string("Pinned replies"), close: { dismiss() })
            }
        }
        .pinnedReplyLabelEditor($labelingPin) { pin, label in
            appState.setPinnedReplyLabel(pin, to: label)
        }
        .accessibilityIdentifier("pinnedReplies.sheet")
    }

    private func row(_ pin: PinnedReply) -> some View {
        Button {
            Haptics.selection()
            dismiss()
            // After the sheet goes, so the chat it opens is the one shown.
            DispatchQueue.main.async { appState.showPinnedReply(pin) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if let label = pin.label {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // A passage reads as a quote of its reply.
                    if pin.isPassage {
                        Image(systemName: "text.quote")
                            .font(.caption)
                            .foregroundStyle(Color.conduitAccent)
                            .accessibilityHidden(true)
                    }
                    Text(pin.shownText)
                        .font(pin.label == nil ? .subheadline : .footnote)
                        .foregroundStyle(pin.label == nil ? Color.primary : Color.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Text(pin.pinnedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                appState.unpinReply(pin)
            } label: {
                Label(AppLocalization.string("Unpin"), systemImage: "pin.slash")
            }
            Button {
                labelingPin = pin
            } label: {
                Label(PinnedReplyLabelEditor.actionTitle(for: pin), systemImage: "tag")
            }
            .tint(Color.conduitAccent)
        }
        .contextMenu {
            Button {
                labelingPin = pin
            } label: {
                Label(PinnedReplyLabelEditor.actionTitle(for: pin), systemImage: "tag")
            }
            Button(role: .destructive) {
                appState.unpinReply(pin)
            } label: {
                Label(AppLocalization.string("Unpin"), systemImage: "pin.slash")
            }
        }
        .accessibilityHint(AppLocalization.string("Opens the chat at this reply"))
        .accessibilityAction(named: PinnedReplyLabelEditor.actionTitle(for: pin)) { labelingPin = pin }
        .accessibilityAction(named: AppLocalization.string("Unpin")) { appState.unpinReply(pin) }
        .accessibilityIdentifier("pinnedReplies.row")
    }
}

/// Edits a pin's label in an alert (#1147): a short name such as
/// "Security recommendations" that the bar and the list show. Saving it
/// blank clears it.
struct PinnedReplyLabelEditor: ViewModifier {
    @Binding var pin: PinnedReply?
    let save: (PinnedReply, String) -> Void
    @State private var draft = ""

    static func actionTitle(for pin: PinnedReply) -> String {
        AppLocalization.string(pin.label == nil ? "Add label" : "Edit label")
    }

    func body(content: Content) -> some View {
        content
            .alert(
                AppLocalization.string("Label this pin"),
                isPresented: Binding(
                    get: { pin != nil },
                    set: { if !$0 { pin = nil } }
                ),
                presenting: pin
            ) { editing in
                TextField(AppLocalization.string("Label"), text: $draft)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("pinnedReplies.labelField")
                Button(AppLocalization.string("Save")) {
                    save(editing, draft)
                    pin = nil
                }
                Button(AppLocalization.string("Cancel"), role: .cancel) {
                    pin = nil
                }
            } message: { _ in
                Text(AppLocalization.string("A short name for the pins list, such as Security recommendations."))
            }
            .onChange(of: pin?.id) { _, _ in
                draft = pin?.label ?? ""
            }
            // The limit shows as you type, not as a cut on save.
            .onChange(of: draft) { _, text in
                if text.count > PinnedReply.labelLength {
                    draft = String(text.prefix(PinnedReply.labelLength))
                }
            }
    }
}

extension View {
    func pinnedReplyLabelEditor(
        _ pin: Binding<PinnedReply?>,
        save: @escaping (PinnedReply, String) -> Void
    ) -> some View {
        modifier(PinnedReplyLabelEditor(pin: pin, save: save))
    }
}

/// Bumped whenever pins change, for UIKit chrome that caches whether a
/// selection is pinned (the cross-block pill).
@MainActor
enum PinnedRepliesRevision {
    static var value = 0
}

/// Flashes a pinned passage once its reply is on screen (#1147): finds the
/// passage in the reply's text blocks, scrolls the first of them into view
/// when the reply is taller than the screen, and lights the passage for a
/// moment, as a search result is.
@MainActor
enum PinnedPassageFlasher {
    private static let hosts = NSHashTable<SelectableTextViewHostView>.weakObjects()

    static func register(_ host: SelectableTextViewHostView) {
        hosts.add(host)
    }

    /// Flashes `passage` in the reply `messageID` once the jump to its row
    /// has laid it out; looks once more if the row isn't drawn yet.
    static func flash(_ passage: String, inMessage messageID: String) {
        // A newer jump replaces one still waiting for its row or its
        // scroll, so an older passage never lights after it.
        pending?.cancel()
        pending = Task { @MainActor in
            for delay in [0.3, 0.5] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                guard let placed = place(passage, inMessage: messageID) else { continue }
                if placed.scrolled { try? await Task.sleep(for: .seconds(0.35)) }
                guard !Task.isCancelled else { return }
                guard !placed.blocks.isEmpty else { return }
                let reduceMotion = UIAccessibility.isReduceMotionEnabled
                for entry in placed.blocks {
                    entry.host.flashPassage(rects: entry.rects, reduceMotion: reduceMotion)
                }
                UIAccessibility.post(notification: .announcement, argument: AppLocalization.string("Pinned passage"))
                return
            }
        }
    }

    private static var pending: Task<Void, Never>?

    /// Where the passage sits in the reply's blocks on screen, scrolled
    /// into view; nil while the reply's text isn't on screen. No blocks
    /// when the reply shows but not the passage.
    private static func place(
        _ passage: String,
        inMessage messageID: String
    ) -> (blocks: [(host: SelectableTextViewHostView, rects: [CGRect])], scrolled: Bool)? {
        let candidates = hosts.allObjects.filter { $0.replyMessageID == messageID && $0.window != nil }
        guard !candidates.isEmpty else { return nil }
        var found: [(host: SelectableTextViewHostView, ranges: [NSRange])] = []
        for host in candidates {
            // Read without mounting a text view; only the blocks holding
            // the passage mount one, to measure it.
            let ranges = PinnedPassageMatch.ranges(of: passage, in: host.displayedText)
            if !ranges.isEmpty { found.append((host, ranges)) }
        }
        let placed = found.compactMap { entry -> (host: SelectableTextViewHostView, rects: [CGRect])? in
            let rects = entry.host.passageRects(for: entry.ranges)
            return rects.isEmpty ? nil : (entry.host, rects)
        }
        guard !placed.isEmpty else { return ([], false) }
        return (placed, scrollIntoView(placed))
    }

    /// Brings the top of the passage into view when it's off screen, a
    /// quarter of the way down. Whether it scrolled.
    private static func scrollIntoView(_ placed: [(host: SelectableTextViewHostView, rects: [CGRect])]) -> Bool {
        guard let first = placed.first, let scrollView = enclosingTranscript(of: first.host) else { return false }
        var union = CGRect.null
        for entry in placed {
            for rect in entry.rects { union = union.union(entry.host.convert(rect, to: scrollView)) }
        }
        guard !union.isNull else { return false }
        let inset = scrollView.adjustedContentInset
        let visibleTop = scrollView.contentOffset.y + inset.top
        let visibleHeight = scrollView.bounds.height - inset.top - inset.bottom
        guard visibleHeight > 0 else { return false }
        let visibleBottom = visibleTop + visibleHeight
        let fits = union.height <= visibleHeight
        if union.minY >= visibleTop, fits ? union.maxY <= visibleBottom : union.minY < visibleBottom {
            return false
        }
        let minOffset = -inset.top
        let maxOffset = max(minOffset, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        let target = min(max(union.minY - inset.top - visibleHeight * 0.25, minOffset), maxOffset)
        guard abs(target - scrollView.contentOffset.y) > 1 else { return false }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: target),
            animated: !UIAccessibility.isReduceMotionEnabled
        )
        return true
    }

    /// The transcript's scroll view: the nearest one that scrolls
    /// vertically, past a table's or code block's sideways one.
    private static func enclosingTranscript(of view: UIView) -> UIScrollView? {
        var candidate = view.superview
        while let current = candidate {
            if let scrollView = current as? UIScrollView,
               scrollView.isScrollEnabled,
               scrollView.contentSize.height > scrollView.bounds.height + 1 || scrollView.alwaysBounceVertical {
                return scrollView
            }
            candidate = current.superview
        }
        return nil
    }
}

extension SelectableTextViewHostView {
    /// Where `ranges` of the text sit, in this view's coordinates; mounts
    /// the text view to measure them.
    func passageRects(for ranges: [NSRange]) -> [CGRect] {
        let textView = mountedTextView
        textView.layoutIfNeeded()
        let length = (textView.text as NSString?)?.length ?? 0
        var rects: [CGRect] = []
        for range in ranges {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clamped.length > 0,
                  let start = textView.position(from: textView.beginningOfDocument, offset: clamped.location),
                  let end = textView.position(from: start, offset: clamped.length),
                  let textRange = textView.textRange(from: start, to: end) else { continue }
            for selection in textView.selectionRects(for: textRange) {
                let rect = selection.rect
                guard !rect.isNull, !rect.isInfinite, rect.width > 0.5, rect.height > 0.5 else { continue }
                rects.append(textView.convert(rect, to: self))
            }
        }
        return rects
    }

    /// Lights `rects` behind the text, then fades them out.
    func flashPassage(rects: [CGRect], reduceMotion: Bool) {
        let marks = rects.map { rect -> UIView in
            let mark = UIView(frame: rect.insetBy(dx: -2, dy: -1))
            mark.backgroundColor = UIColor(Color.conduitAccent).withAlphaComponent(0.28)
            mark.layer.cornerRadius = 4
            mark.layer.cornerCurve = .continuous
            mark.isUserInteractionEnabled = false
            mark.alpha = 0
            insertSubview(mark, at: 0)
            return mark
        }
        UIView.animate(withDuration: reduceMotion ? 0.01 : 0.2) {
            marks.forEach { $0.alpha = 1 }
        } completion: { _ in
            UIView.animate(withDuration: 0.8, delay: 1.4, options: [.curveEaseOut]) {
                marks.forEach { $0.alpha = 0 }
            } completion: { _ in
                marks.forEach { $0.removeFromSuperview() }
            }
        }
    }
}
