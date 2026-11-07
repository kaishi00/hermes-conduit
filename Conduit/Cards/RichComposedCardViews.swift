//
//  RichComposedCardViews.swift
//  Conduit
//
//  How a card Hermes built looks (RichComposedCard.swift), and the button
//  row any card can carry. Conduit owns the fonts, colors and spacing; a
//  section marked "more" folds until the card is opened. Fields keep what
//  the user types until a tap button sends it with the card.
//

import SwiftUI
import UIKit

struct RichComposedCard: View {
    let card: RichCard

    @State private var values: [String: String] = [:]
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.richCardActions) private var context

    var body: some View {
        RichInfoCardFrame(title: card.title, source: card.source) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(shownSections.enumerated()), id: \.offset) { _, section in
                    RichComposedSection(card: card, section: section, values: $values)
                }
                if card.sections.contains(where: \.more) {
                    Button {
                        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { open.toggle() }
                    } label: {
                        Text(open ? AppLocalization.string("Show less") : AppLocalization.string("Show more"))
                            .scaledFont(.caption.weight(.semibold))
                            .foregroundStyle(Color.conduitAccent)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
                if !card.actions.isEmpty {
                    RichCardButtonRow(card: card, buttons: card.actions, values: values)
                }
            }
        }
        .onAppear(perform: startValues)
        .onChange(of: card.normalizedJSON) { _, _ in
            values = [:]
            open = false
            startValues()
        }
        // A board's tabs draw one card at a time, so a tab switch remounts
        // this view: what was typed and folded is kept for when it's back.
        .onChange(of: values) { _, new in
            RichCardFieldMemory.shared.keep(card: card, chat: chat, values: new, open: open)
        }
        .onChange(of: open) { _, new in
            RichCardFieldMemory.shared.keep(card: card, chat: chat, values: values, open: new)
        }
    }

    /// Outside a chat (the saved copy, a room, the call screen) the card's
    /// fields keep to themselves.
    private var chat: [String] { context?.sessionIDs ?? [] }

    private var shownSections: [RichSection] {
        open ? card.sections : card.sections.filter { !$0.more }
    }

    private func startValues() {
        if let kept = RichCardFieldMemory.shared.kept(card: card, chat: chat) {
            values = kept.values
            open = kept.open
        }
        for section in card.sections {
            for element in section.elements {
                if let field = element.field, values[field.id] == nil { values[field.id] = field.startingValue }
            }
        }
    }
}

private struct RichComposedSection: View {
    let card: RichCard
    let section: RichSection
    @Binding var values: [String: String]

    var body: some View {
        let shown = section.elements.filter { $0.kind != .button }
        let buttons = section.elements.compactMap(\.button)
        VStack(alignment: .leading, spacing: 8) {
            if !shown.isEmpty {
                if section.row {
                    ViewThatFits(in: .horizontal) {
                        // The row measures its elements' own widths (text on one line,
                        // fields, pictures and bars at fixed widths), never the card's,
                        // so a row too wide for the card stacks instead
                        // (see EqualWidthHStack on children that defeat ViewThatFits).
                        HStack(alignment: .firstTextBaseline, spacing: 12) { elements(shown, inRow: true) }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 8) { elements(shown) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) { elements(shown) }
                }
            }
            if !buttons.isEmpty {
                RichCardButtonRow(card: card, buttons: buttons, values: values)
            }
        }
    }

    @ViewBuilder
    private func elements(_ elements: [RichElement], inRow: Bool = false) -> some View {
        ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
            RichElementView(element: element, inRow: inRow, values: $values)
        }
    }
}

private struct RichElementView: View {
    let element: RichElement
    /// Side by side in a row: takes its own width rather than the card's.
    var inRow = false
    @Binding var values: [String: String]

    var body: some View {
        switch element.kind {
        case .text:
            Text(verbatim: element.text ?? "")
                .scaledFont(font)
                .foregroundStyle(element.tone == .neutral && element.role == .caption ? Color.secondary : tint)
                .textSelection(.enabled)
                .frame(maxWidth: inRow ? nil : .infinity, alignment: .leading)
                .accessibilityAddTraits(element.role == .heading ? .isHeader : [])
        case .metric:
            VStack(alignment: .leading, spacing: 2) {
                if let label = element.label {
                    Text(verbatim: label).scaledFont(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: element.value ?? "")
                    .scaledFont(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if let change = element.change {
                    Text(verbatim: change).scaledFont(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case .badge:
            Text(verbatim: element.text ?? "")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(element.tone == .neutral ? Color.secondary : tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill((element.tone == .neutral ? Color.secondary : tint).opacity(0.14)))
        case .icon:
            Image(systemName: element.symbol ?? "circle")
                .scaledFont(.title3)
                .foregroundStyle(element.tone == .neutral ? Color.secondary : tint)
                .accessibilityHidden(true)
        case .image:
            if let url = element.url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.secondary.opacity(0.1).frame(height: 120)
                }
                .frame(width: inRow ? 120 : nil)
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(Text(verbatim: element.label ?? ""))
                .accessibilityHidden(element.label?.isEmpty ?? true)
            }
        case .progress:
            VStack(alignment: .leading, spacing: 4) {
                if let label = element.label {
                    Text(verbatim: label).scaledFont(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: min(max(element.progress ?? 0, 0), 1))
                    .tint(element.tone == .neutral ? Color.conduitAccent : tint)
            }
            .frame(width: inRow ? 120 : nil)
        case .divider:
            Divider()
        case .field:
            if let field = element.field {
                RichFieldView(field: field, inRow: inRow, value: Binding(
                    get: { values[field.id] ?? field.startingValue },
                    set: { values[field.id] = $0 }))
            }
        case .button:
            EmptyView()
        }
    }

    private var font: ScaledFont {
        switch element.role {
        case .heading: return .headline
        case .body: return .subheadline
        case .caption: return .caption
        case .mono: return .system(.caption, design: .monospaced)
        }
    }

    private var tint: Color { RichToneColor.color(element.tone) }
}

enum RichToneColor {
    static func color(_ tone: RichTone) -> Color {
        switch tone {
        case .neutral: return Color.primary
        case .accent: return Color.conduitAccent
        case .good: return Color.green
        case .warning: return Color.orange
        case .bad: return Color.red
        }
    }
}

private struct RichFieldView: View {
    let field: RichField
    var inRow = false
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = field.label, field.input != .toggle {
                Text(verbatim: label).scaledFont(.caption).foregroundStyle(.secondary)
            }
            control
        }
        .frame(width: inRow ? 160 : nil, alignment: .leading)
        .frame(maxWidth: inRow ? nil : .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var control: some View {
        switch field.input {
        case .text:
            TextField(text: $value, prompt: field.placeholder.map { Text(verbatim: $0) }, axis: .vertical) {
                Text(verbatim: field.label ?? field.id)
            }
            .lineLimit(field.lines...max(field.lines, 8))
            .scaledFont(.subheadline)
            .textFieldStyle(.roundedBorder)
        case .number:
            VStack(alignment: .leading, spacing: 2) {
                TextField(text: $value, prompt: field.placeholder.map { Text(verbatim: $0) }) {
                    Text(verbatim: field.label ?? field.id)
                }
                .keyboardType(.decimalPad)
                .scaledFont(.subheadline)
                .textFieldStyle(.roundedBorder)
                // The host takes only a number in range, so a tap waits for one (RichCardButtonRow).
                if field.numberText(value) == nil {
                    Label {
                        Text(verbatim: field.numberRange)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
                }
            }
        case .choice:
            Picker(selection: $value) {
                if !field.options.contains(value) {
                    Text(verbatim: "\u{2013}").tag(value)
                }
                ForEach(field.options, id: \.self) { option in
                    Text(verbatim: option).tag(option)
                }
            } label: {
                Text(verbatim: field.label ?? field.id)
            }
            .pickerStyle(.menu)
        case .toggle:
            Toggle(isOn: Binding(get: { value == "on" }, set: { value = $0 ? "on" : "off" })) {
                Text(verbatim: field.label ?? field.id).scaledFont(.subheadline)
            }
        case .date:
            let timed = value.contains("T")
            DatePicker(selection: Binding(
                get: { RichFieldDates.date(value) ?? .now },
                set: { value = RichFieldDates.text($0, timed: timed) }),
                       displayedComponents: timed ? [.date, .hourAndMinute] : [.date]) {
                Text(verbatim: field.label ?? field.id)
            }
            .labelsHidden()
            .accessibilityLabel(Text(verbatim: field.label ?? field.id))
        }
    }
}

/// A date field's text, as the schema writes it: YYYY-MM-DD, or with THH:MM.
enum RichFieldDates {
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    private static let day = formatter("yyyy-MM-dd")
    private static let minute = formatter("yyyy-MM-dd'T'HH:mm")

    static func date(_ text: String) -> Date? {
        text.contains("T") ? minute.date(from: text) : day.date(from: text)
    }

    static func text(_ date: Date, timed: Bool) -> String {
        (timed ? minute : day).string(from: date)
    }
}

// MARK: - Buttons

/// Redraws a card's buttons as the composer's draft changes.
private struct RichDraftGate<Content: View>: View {
    @ObservedObject var composer: PredictiveStore
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

/// A card's buttons: open and copy work anywhere; send and tap only where
/// the open chat can send (RichCardActionContext), and only while it can.
struct RichCardButtonRow: View {
    let card: RichCard
    let buttons: [RichButton]
    let values: [String: String]

    @Environment(\.richCardActions) private var context
    @Environment(\.openURL) private var openURL
    @ObservedObject private var taps = RichCardTapMemory.shared
    @State private var asking: RichButton?

    var body: some View {
        let shown = buttons.filter(isShown)
        if !shown.isEmpty {
            Group {
                if let composer = context?.composer {
                    RichDraftGate(composer: composer) { empty in rows(shown, draftEmpty: empty) }
                } else {
                    rows(shown, draftEmpty: true)
                }
            }
            .confirmationDialog(Text(verbatim: asking?.confirm ?? asking?.label ?? ""),
                                isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                                titleVisibility: .visible, presenting: asking) { button in
                Button(role: button.style == .destructive ? .destructive : nil) {
                    run(button)
                } label: {
                    Text(verbatim: button.label)
                }
            }
        }
    }

    private func isShown(_ button: RichButton) -> Bool {
        switch button.action {
        case .open: return button.openURL != nil
        case .copy: return true
        case .send: return context != nil
        case .tap: return context?.tap != nil
        }
    }

    private func rows(_ shown: [RichButton], draftEmpty: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            // Ideal widths, so long labels stack rather than truncate side by side.
            HStack(spacing: 8) { row(shown, draftEmpty: draftEmpty) }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { row(shown, draftEmpty: draftEmpty) }
        }
    }

    @ViewBuilder
    private func row(_ shown: [RichButton], draftEmpty: Bool) -> some View {
        ForEach(Array(shown.enumerated()), id: \.offset) { _, button in
            let state = button.id.flatMap {
                taps.state(RichCardTapMemory.key(card: card, button: $0), chat: context?.sessionIDs ?? [])
            }
            Button {
                Haptics.light()
                if button.confirm != nil || button.style == .destructive && button.action == .tap {
                    asking = button
                } else {
                    run(button)
                }
            } label: {
                HStack(spacing: 6) {
                    if state == .sending {
                        ProgressView().controlSize(.small)
                    } else if state == .sent {
                        Image(systemName: "checkmark").accessibilityHidden(true)
                    } else if let symbol = button.symbol {
                        Image(systemName: symbol).accessibilityHidden(true)
                    }
                    if state == .sent {
                        Text("Sent")
                    } else {
                        Text(verbatim: button.label)
                    }
                }
                .scaledFont(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(foreground(button))
                .background(Capsule().fill(background(button)))
                // "Sent" alone wouldn't say which of the card's buttons went.
                .accessibilityLabel(state == .sent ? Text(verbatim: "\(button.label), ") + Text("Sent")
                                                   : Text(verbatim: button.label))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled(button, state: state, draftEmpty: draftEmpty))
        }
    }

    private func isDisabled(_ button: RichButton, state: RichCardTapMemory.State?, draftEmpty: Bool) -> Bool {
        switch button.action {
        case .open, .copy: return false
        case .send: return !draftEmpty || !(context?.canSend ?? false)
        // A tap sends the fields as shown, so it waits while a number is out of range.
        case .tap: return state != nil || !draftEmpty || !(context?.canSend ?? false) || !numbersFit
        }
    }

    private var numbersFit: Bool {
        card.sections.allSatisfy { section in
            section.elements.allSatisfy { element in
                guard let field = element.field, field.input == .number else { return true }
                return field.numberText(values[field.id] ?? field.startingValue) != nil
            }
        }
    }

    private func foreground(_ button: RichButton) -> Color {
        switch button.style {
        case .primary: return .white
        case .destructive: return .red
        case .plain: return Color.conduitAccent
        }
    }

    private func background(_ button: RichButton) -> Color {
        switch button.style {
        case .primary: return Color.conduitAccent
        case .destructive: return Color.red.opacity(0.12)
        case .plain: return Color.conduitAccent.opacity(0.12)
        }
    }

    private func run(_ button: RichButton) {
        switch button.action {
        case .open:
            if let url = button.openURL { openURL(url) }
        case .copy:
            UIPasteboard.general.string = button.target
            UIAccessibility.post(notification: .announcement, argument: AppLocalization.string("Copied"))
        case .send:
            guard let context, context.canSend, let target = button.target else { return }
            context.send(target)
        case .tap:
            guard let context, context.canSend, let tap = context.tap, let id = button.id else { return }
            let key = RichCardTapMemory.key(card: card, button: id)
            let body: [String: Any] = ["card": jsonObject(card.normalizedJSON) ?? [:], "action": id,
                                       "values": fieldValues]
            let message = RichCardActionContext.message(label: button.label, title: card.title)
            let chat = context.sessionIDs
            taps.set(key, .sending, chat: chat)
            Task { @MainActor in
                do {
                    try await tap(body, message)
                    RichCardTapMemory.shared.set(key, .sent, chat: chat)
                } catch {
                    RichCardTapMemory.shared.set(key, nil, chat: chat)
                    Haptics.error()
                    UIAccessibility.post(notification: .announcement,
                                         argument: AppLocalization.string("Failed to send: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// The card's fields as the user left them, each from its starting value.
    private var fieldValues: [String: String] {
        var all: [String: String] = [:]
        for section in card.sections {
            for element in section.elements {
                guard let field = element.field else { continue }
                let value = values[field.id] ?? field.startingValue
                all[field.id] = field.input == .number ? field.numberText(value) ?? value : value
            }
        }
        return all
    }

    private func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
