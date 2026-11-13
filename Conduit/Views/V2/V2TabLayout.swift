//
//  V2TabLayout.swift
//  Conduit
//
//  The tab bar's order and which tabs it shows (issue 2084): Settings >
//  Appearance > Tabs. The first tab shown is the one Conduit opens on. One
//  stored list holds the order and the hidden tabs together, so a sync
//  never lands half of a change.
//

import SwiftUI

/// The tabs in the user's order, with the ones they hid.
struct V2TabLayout: Equatable {
    /// The stored list: every tab's name in order, a hidden one written
    /// with a leading "-" (`["chats", "bots", "-tasks", "settings"]`).
    static let key = "conduit.v2.tabs"

    /// The order nobody has changed. Bots comes first: picking a bot and
    /// talking to it is Conduit's home, and direct sessions are a tab over
    /// (designs/bot-mode-coordinator/bots-home-ui.md).
    static let standardOrder: [V2Tab] = [.bots, .chats, .tasks, .settings]

    /// Tabs the bar always shows. Settings is the only way back to this
    /// choice, and Sessions is where a notification, a widget, a link or a
    /// Shortcut puts the chat it opens.
    static let alwaysShown: Set<V2Tab> = [.chats, .settings]

    static let standard = V2TabLayout(stored: nil)

    /// Every tab, shown or hidden, in the user's order.
    private(set) var order: [V2Tab]
    private(set) var hidden: Set<V2Tab>
    /// Names this build doesn't know (a tab a newer Conduit added, synced
    /// from another device), written back as they came so saving here
    /// doesn't drop them there.
    private(set) var unknown: [String]

    /// Reads a stored list, forgiving anything odd in it: a name twice
    /// counts once, a tab that can't be hidden isn't, and a tab the list
    /// leaves out is shown after the ones it names.
    init(stored: [String]?) {
        var order: [V2Tab] = []
        var hidden: Set<V2Tab> = []
        var unknown: [String] = []
        for token in stored ?? [] {
            let isHidden = token.hasPrefix("-")
            let name = isHidden ? String(token.dropFirst()) : token
            guard let tab = V2Tab(rawValue: name) else {
                if !name.isEmpty, !unknown.contains(token) { unknown.append(token) }
                continue
            }
            guard !order.contains(tab) else { continue }
            order.append(tab)
            if isHidden, !Self.alwaysShown.contains(tab) { hidden.insert(tab) }
        }
        for tab in Self.standardOrder where !order.contains(tab) {
            order.append(tab)
        }
        self.order = order
        self.hidden = hidden
        self.unknown = unknown
    }

    /// The list as stored.
    var stored: [String] {
        order.map { hidden.contains($0) ? "-" + $0.rawValue : $0.rawValue } + unknown
    }

    /// The tabs the bar lists, in order.
    var shown: [V2Tab] { order.filter { !hidden.contains($0) } }

    /// The tab Conduit opens on: the first one shown.
    var first: V2Tab { shown.first ?? .chats }

    /// The bar's tabs while `selected` is showing. A hidden tab something
    /// else opened (a link to a task with Tasks hidden, a Bot Chat kept
    /// from before Bots was hidden) stands in the bar, in its place, until
    /// the reader leaves it: a screen with no selected tab in the bar would
    /// read as lost.
    func bar(selected: V2Tab) -> [V2Tab] {
        order.filter { !hidden.contains($0) || $0 == selected }
    }

    /// The tabs made with the shell, before anyone opens them: the one it
    /// opens on, Sessions (where a chat opened from outside is pushed) and
    /// Bots while the bar shows it. A hidden Bots isn't made until
    /// something opens it.
    func madeAtLaunch(opensOn: V2Tab) -> Set<V2Tab> {
        var tabs: Set<V2Tab> = [opensOn, .chats]
        if !hidden.contains(.bots) { tabs.insert(.bots) }
        return tabs
    }

    var isStandard: Bool { order == Self.standardOrder && hidden.isEmpty }

    func canHide(_ tab: V2Tab) -> Bool { !Self.alwaysShown.contains(tab) }

    func isHidden(_ tab: V2Tab) -> Bool { hidden.contains(tab) }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
    }

    mutating func setHidden(_ tab: V2Tab, _ isHidden: Bool) {
        if isHidden {
            guard canHide(tab) else { return }
            hidden.insert(tab)
        } else {
            hidden.remove(tab)
        }
    }

    /// Back to the standard order with every tab shown.
    mutating func reset() {
        order = Self.standardOrder
        hidden = []
    }
}

/// The saved tab layout, published only when it changes: the shell, both
/// bars, the menu bar's ⌘1 to ⌘4 and the Keyboard Shortcuts sheet follow it.
/// Read here rather than through `@AppStorage`, which redraws its view on
/// every write to the defaults, whatever the key.
@MainActor
final class V2TabLayoutStore: ObservableObject {
    static let shared = V2TabLayoutStore()

    @Published private(set) var layout: V2TabLayout

    private let defaults: UserDefaults
    private var defaultsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = V2TabLayout(stored: defaults.stringArray(forKey: V2TabLayout.key))
        // A write from elsewhere: Sync across devices bringing another
        // device's layout. No queue, as SyncedPreferencesController: with
        // `queue: .main` a write off the main thread waits on main.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    /// Saves the layout and publishes it at once.
    func save(_ layout: V2TabLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        defaults.set(layout.stored, forKey: V2TabLayout.key)
    }

    func reload() {
        let stored = V2TabLayout(stored: defaults.stringArray(forKey: V2TabLayout.key))
        if stored != layout { layout = stored }
    }
}

/// Settings > Appearance > Tabs' sheet: the tabs with drag handles and a
/// switch on each one that can be hidden.
struct V2TabsOrderSheet: View {
    @ObservedObject private var store = V2TabLayoutStore.shared
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .active

    var body: some View {
        let layout = store.layout
        let tabs = layout.order
        NavigationStack {
            ConduitList {
                Section {
                    ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                        row(tab, in: layout)
                            .accessibilityActions {
                                if index > 0 {
                                    Button(AppLocalization.string("Move up")) {
                                        move(from: [index], to: index - 1)
                                    }
                                }
                                if index < tabs.count - 1 {
                                    Button(AppLocalization.string("Move down")) {
                                        move(from: [index], to: index + 2)
                                    }
                                }
                            }
                    }
                    .onMove { source, destination in
                        move(from: source, to: destination)
                    }
                } footer: {
                    Text(AppLocalization.string("Drag tabs into the order you want, and turn off the ones you don't use. Conduit opens on the first tab. Sessions and Settings always stay in the bar.", table: .settings))
                }
                if !layout.isStandard {
                    Section {
                        Button(AppLocalization.string("Reset Tabs", table: .settings)) {
                            Haptics.selection()
                            var next = store.layout
                            next.reset()
                            store.save(next)
                        }
                        .accessibilityIdentifier("settings.tabs.reset")
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(AppLocalization.string("Tabs", table: .settings))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func row(_ tab: V2Tab, in layout: V2TabLayout) -> some View {
        let label = HStack(spacing: 8) {
            Label(tab.title, systemImage: tab.symbol)
            if layout.first == tab {
                Text(AppLocalization.string("Opens first", table: .settings))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if layout.canHide(tab) {
            Toggle(isOn: Binding(
                get: { !store.layout.isHidden(tab) },
                set: { shown in
                    Haptics.selection()
                    var next = store.layout
                    next.setHidden(tab, !shown)
                    store.save(next)
                }
            )) { label }
                .tint(.conduitAccent)
                .accessibilityIdentifier("settings.tabs.show.\(tab.rawValue)")
        } else {
            label
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var next = store.layout
        next.move(fromOffsets: source, toOffset: destination)
        store.save(next)
    }
}
