//
//  VoiceAPIKeyRow.swift
//  Conduit
//
//  A voice provider's API key, shown where the provider is turned on: the
//  masked key Hermes reports when one is set, or a field to add one. The
//  key is written to the profile's .env on the Hermes host and is never
//  read back in full.
//

import SwiftUI

struct VoiceAPIKeyRow: View {
    @ObservedObject var service: HermesVoiceConfigurationService
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    /// Variables Hermes reads, in its order. The first set one is shown; a
    /// new or replacement key is always saved under the first, which Hermes
    /// reads ahead of the rest, so a shared fallback such as OPENAI_API_KEY
    /// (also used for chat) is never overwritten from here.
    let keys: [String]
    /// One line on what the key is for, under the row.
    var note: String? = nil

    @State private var draft = ""
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var saveError: String?

    private var configured: VoiceCredentialStatus? { service.configuredCredential(among: keys) }
    /// The key shown: the one Hermes uses now, else the one a save writes.
    private var targetKey: String { configured?.key ?? writeKey }
    private var writeKey: String { keys.first ?? "" }

    var body: some View {
        if !targetKey.isEmpty { row }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: configured == nil ? "key" : "checkmark.shield.fill")
                    .foregroundStyle(configured == nil ? Color.secondary : Color.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: targetKey)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityLabel(Text(verbatim: targetKey.replacingOccurrences(of: "_", with: " ")))
                    statusText
                }
                Spacer(minLength: 8)
                if configured != nil, !isEditing {
                    Button(AppLocalization.string("Replace")) { isEditing = true }
                        .buttonStyle(.settings)
                        .disabled(isSaving)
                        .accessibilityIdentifier("voice.apiKey.\(targetKey).replace")
                }
            }
            if configured == nil || isEditing {
                SecureField(AppLocalization.string("Paste API key"), text: $draft)
                    .disabled(isSaving)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit { Task { @MainActor in await save() } }
                    .accessibilityIdentifier("voice.apiKey.\(targetKey).field")
                HStack {
                    if isEditing {
                        Button(AppLocalization.string("Cancel"), role: .cancel) {
                            draft = ""
                            saveError = nil
                            isEditing = false
                        }
                        .buttonStyle(.settings)
                        .disabled(isSaving)
                    }
                    Spacer()
                    Button {
                        Task { @MainActor in await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(configured == nil ? AppLocalization.string("Add key") : AppLocalization.string("Save key"))
                        }
                    }
                    .buttonStyle(.settingsPrimary)
                    .disabled(isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("voice.apiKey.\(targetKey).save")
                }
            }
            if let saveError {
                Text(verbatim: saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var statusText: some View {
        if let configured {
            if let masked = configured.redactedValue {
                Text(verbatim: masked)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(verbatim: AppLocalization.string("Key set on Hermes") + ", " + masked))
            } else {
                Text(AppLocalization.string("Key set on Hermes"))
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        } else if service.isLoading {
            Text(AppLocalization.string("Checking…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if service.snapshot.environmentLoaded {
            Text(AppLocalization.string("No key yet"))
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Text(AppLocalization.string("Hermes didn’t say whether a key is set"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func save() async {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !writeKey.isEmpty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        if await service.saveCredential(value, key: writeKey) {
            draft = ""
            isEditing = false
        } else {
            saveError = service.errorMessage
        }
    }
}

/// A live mode's key card, shown under that mode's settings.
struct VoiceAPIKeySection: View {
    @ObservedObject var service: HermesVoiceConfigurationService
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    let keys: [String]
    var note: String? = nil

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("API key"), symbol: "key.fill", tint: .conduitAura) {
            VoiceAPIKeyRow(service: service, keys: keys, note: note)
        }
    }
}
