//
//  PluginSettingsViews.swift
//  Conduit
//
//  A plugin's own settings on its page in Settings > Capabilities > Plugins,
//  as Hermes Desktop's plugin settings form shows them: the fields its
//  manifest declares, edited as text and saved together. A secret is asked
//  for, written to the profile's `.env` and never shown or kept here.
//

import SwiftUI

struct PluginSettingsSection: View {
    @EnvironmentObject private var appState: AppState
    let pluginName: String
    let canManage: Bool
    let store: CapabilitiesStore

    @State private var key: String?
    @State private var fields: [PluginSettingField] = []
    @State private var draft: [String: String] = [:]
    @State private var loadError: String?
    @State private var saving = false
    @State private var message: String?
    @State private var saved = false
    /// The newest load: an older one's answer (a second Try Again) is dropped.
    @State private var loadID = 0

    /// Edits only while connected, on the default profile the store now
    /// serves: a page pushed on it keeps `canManage` across a switch.
    private var canEdit: Bool {
        canManage && appState.isConnected && store.canManagePlugins && store.serves(appState.currentCapabilitiesOwner)
    }

    private var dirty: Bool {
        fields.contains { field in
            guard let raw = draft[field.key] else { return false }
            return field.kind == .secret ? !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : raw != field.initialText
        }
    }

    var body: some View {
        Group {
            if !fields.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Settings")
                        .scaledFont(.headline)
                    ForEach(fields) { field in
                        PluginSettingFieldRow(field: field, raw: binding(field), disabled: !canEdit || saving)
                    }
                    if let message {
                        Text(verbatim: message)
                            .scaledFont(.footnote)
                            .foregroundStyle(saved ? Color.secondary : Color.orange)
                    }
                    if canEdit {
                        Button {
                            save()
                        } label: {
                            Label(saving ? AppLocalization.string("Saving…") : AppLocalization.string("Save Settings"), systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .frame(minHeight: 44)
                        }
                        .disabled(saving || !dirty)
                        .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
                    } else {
                        Text("Hermes keeps plugin settings for the host's default profile. Switch to it to change them.")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .settingsCard()
            } else if let loadError {
                HStack(spacing: 8) {
                    Text(verbatim: AppLocalization.string("Couldn't read its settings: \(loadError)"))
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(AppLocalization.string("Try Again")) {
                        Task { await load() }
                    }
                    .scaledFont(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 16)
            }
        }
        .task(id: LoadKey(name: pluginName, scope: scope, connected: appState.isConnected)) {
            await load()
        }
    }

    /// Reads again for another dashboard or profile, once the store has
    /// been pointed at it.
    private var scope: CapabilityDetailScope {
        let owner = appState.currentCapabilitiesOwner
        return CapabilityDetailScope(owner: owner, ready: store.serves(owner))
    }

    private struct LoadKey: Equatable {
        let name: String
        let scope: CapabilityDetailScope
        let connected: Bool
    }

    /// Whether a load's answer is still this page's to show.
    private func isCurrent(_ id: Int, _ owner: CapabilitySnapshotOwner) -> Bool {
        id == loadID && !Task.isCancelled && appState.currentCapabilitiesOwner == owner && store.serves(owner)
    }

    private func binding(_ field: PluginSettingField) -> Binding<String> {
        Binding(
            get: { draft[field.key] ?? field.initialText },
            set: { value in
                draft[field.key] = value
                saved = false
                message = nil
            }
        )
    }

    private func load() async {
        loadID += 1
        let id = loadID
        let owner = appState.currentCapabilitiesOwner
        // Offline, or before the store serves this dashboard and profile,
        // the form isn't shown: nothing kept, nothing stale to save.
        guard appState.isConnected, let client = appState.client, store.serves(owner) else {
            clear()
            return
        }
        do {
            let answer = try await client.pluginSettingFields(plugin: pluginName, profile: owner.profile)
            guard isCurrent(id, owner) else { return }
            key = answer?.key
            apply(answer?.fields ?? [])
            loadError = nil
        } catch {
            guard isCurrent(id, owner), !(error is CancellationError) else { return }
            // A Hermes without plugin settings offers none.
            if let rpc = error as? RpcError, rpc.code == HermesClient.methodNotFoundCode {
                clear()
                return
            }
            // Fields from before a failed reload may be stale: show the
            // error and Try Again instead, so nothing old is saved.
            clear()
            loadError = UserFacingError.message(for: error)
        }
    }

    private func clear() {
        key = nil
        fields = []
        draft = [:]
        loadError = nil
        message = nil
    }

    /// Takes Hermes' fields and starts the form on them, keeping what the
    /// person is typing in a field Hermes didn't change.
    private func apply(_ next: [PluginSettingField]) {
        let previous = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0) })
        draft = draft.filter { entry in
            guard let old = previous[entry.key], let new = next.first(where: { $0.key == entry.key }) else { return false }
            return old == new && new.kind != .secret
        }
        fields = next
    }

    private func save() {
        let owner = appState.currentCapabilitiesOwner
        guard canEdit, !saving, let key, let client = appState.client else { return }
        let plan: PluginSettings.Save
        do {
            plan = try PluginSettings.save(fields: fields, draft: draft)
        } catch {
            saved = false
            message = UserFacingError.message(for: error)
            return
        }
        guard !plan.isEmpty else { return }
        Haptics.selection()
        saving = true
        message = nil
        Task {
            defer { saving = false }
            do {
                let next = try await store.savePluginSettings(save: plan) { values, profile in
                    try await client.savePluginSettings(key: key, values: values, profile: profile)
                }
                guard appState.currentCapabilitiesOwner == owner, store.serves(owner) else { return }
                draft = [:]
                if let next { fields = next } else { await load() }
                Haptics.success()
                saved = true
                message = AppLocalization.string("Saved. The plugin reads its new settings.")
            } catch {
                guard !(error is CancellationError) else { return }
                saved = false
                message = UserFacingError.message(for: error)
            }
        }
    }
}

private struct PluginSettingFieldRow: View {
    let field: PluginSettingField
    @Binding var raw: String
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch field.kind {
            case .boolean:
                Toggle(isOn: Binding(get: { raw == "true" }, set: { raw = $0 ? "true" : "false" })) {
                    title
                }
                .tint(.conduitAccent)
            case .enum:
                HStack {
                    title
                    Spacer(minLength: 8)
                    Picker(selection: $raw) {
                        ForEach(field.choices, id: \.self) { choice in
                            Text(verbatim: choice).tag(choice)
                        }
                    } label: {
                        Text(verbatim: field.label)
                    }
                    .labelsHidden()
                    .tint(.conduitAccent)
                    .accessibilityLabel(Text(verbatim: field.label))
                }
            case .json:
                title
                TextEditor(text: $raw)
                    .scaledFont(.footnote.monospaced())
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel(Text(verbatim: field.label))
            case .secret:
                title
                SecureField(field.hasValue ? AppLocalization.string("Saved. Enter a new one to replace it.") : AppLocalization.string("Not set"), text: $raw)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(verbatim: field.label))
            case .number:
                title
                TextField(text: $raw) { Text(verbatim: field.label) }
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
            case .string:
                title
                TextField(text: $raw) { Text(verbatim: field.label) }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
            }
            if !field.description.isEmpty {
                Text(verbatim: field.description)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(disabled)
    }

    private var title: some View {
        HStack(spacing: 4) {
            Text(verbatim: field.label)
                .scaledFont(.subheadline.weight(.semibold))
            if field.required {
                Text(verbatim: "*")
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Required"))
            }
        }
    }
}
