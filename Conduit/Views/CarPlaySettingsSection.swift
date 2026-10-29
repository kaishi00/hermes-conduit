//
//  CarPlaySettingsSection.swift
//  Conduit
//
//  Settings > Voice > CarPlay: whether the car opens on the chat list, the
//  shortcuts the car's Shortcuts grid offers, and the voice screen's
//  status sounds. Saved on this device.
//

import SwiftUI

@MainActor
struct CarPlaySettingsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var preferences: CarPlayPreferences

    @State private var editingID: UUID?
    @State private var draftTitle = ""
    @State private var draftPrompt = ""

    init() {
        preferences = CarPlayPreferences.shared
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("CarPlay"), symbol: "car.fill", tint: .conduitAura) {
            Toggle("Choose a chat first", isOn: Binding(
                get: { preferences.choosesChatFirst },
                set: { preferences.setChoosesChatFirst($0) }
            ))
            .accessibilityIdentifier("voice.carPlayChooseChat")
            Text("CarPlay opens on your pinned and recent chats, with New voice chat at the top. Off: Voice starts as soon as CarPlay opens.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)

            Toggle("Status sounds", isOn: Binding(
                get: { preferences.playsSounds },
                set: { preferences.setPlaysSounds($0) }
            ))
            .accessibilityIdentifier("voice.carPlaySounds")
            Text("A soft tone when your turn is sent and a low one if Voice fails, in the classic voice mode.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Shortcuts")
                    .scaledFont(.subheadline.weight(.semibold))
                Text("One tap in the car starts the prompt as a Voice Job and opens a conversation, which speaks the result when the job is done.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                if preferences.shortcuts.isEmpty {
                    Label("No shortcuts yet.", systemImage: "minus.circle")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(preferences.shortcuts) { shortcut in
                    shortcutRow(shortcut)
                }
                if editingID != nil || preferences.canAddShortcut {
                    TextField(AppLocalization.string("Name, like Morning brief"), text: $draftTitle)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text(AppLocalization.string("Shortcut name")))
                        .accessibilityIdentifier("voice.carPlayShortcutTitle")
                    TextField(AppLocalization.string("What to ask Hermes"), text: $draftPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .accessibilityLabel(Text(AppLocalization.string("Shortcut prompt")))
                        .accessibilityIdentifier("voice.carPlayShortcutPrompt")
                    HStack {
                        if editingID != nil {
                            Button("Cancel", action: clearDraft)
                                .buttonStyle(.settings)
                        }
                        Spacer()
                        Button(editingID == nil ? AppLocalization.string("Add") : AppLocalization.string("Save"), action: commitDraft)
                            .buttonStyle(.settingsPrimary)
                            .disabled(!canCommit)
                    }
                } else {
                    Text("CarPlay shows up to 8 shortcuts.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canCommit: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shortcutRow(_ shortcut: CarPlayShortcut) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: shortcut.title)
                    .scaledFont(.subheadline)
                Text(verbatim: shortcut.prompt)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            SettingsRowMenu(itemName: shortcut.title, onEdit: {
                editingID = shortcut.id
                draftTitle = shortcut.title
                draftPrompt = shortcut.prompt
            }, onDelete: {
                preferences.delete(id: shortcut.id)
                if editingID == shortcut.id { clearDraft() }
            })
        }
        .padding(.vertical, 2)
    }

    private func commitDraft() {
        let shortcut = CarPlayShortcut(id: editingID ?? UUID(), title: draftTitle, prompt: draftPrompt)
        guard preferences.save(shortcut) else { return }
        clearDraft()
    }

    private func clearDraft() {
        editingID = nil
        draftTitle = ""
        draftPrompt = ""
    }
}
