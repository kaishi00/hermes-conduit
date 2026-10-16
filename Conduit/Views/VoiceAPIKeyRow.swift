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
    /// Variables Hermes reads, in its order. The first set one is shown and
    /// replaced; with none set, a new key is saved under the first.
    let keys: [String]
    /// One line on what the key is for, under the row.
    var note: String? = nil

    @State private var draft = ""
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var saveError: String?

    private var configured: VoiceCredentialStatus? { service.configuredCredential(among: keys) }
    private var targetKey: String { configured?.key ?? keys.first ?? "" }

    var body: some View {
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
                        .font(.subheadline)
                        .disabled(isSaving)
                        .accessibilityIdentifier("voice.apiKey.\(targetKey).replace")
                }
            }
            if configured == nil || isEditing {
                SecureField(AppLocalization.string("Paste API key"), text: $draft)
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
                    .buttonStyle(.borderedProminent)
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
                    .accessibilityLabel(Text(AppLocalization.string("Key set on Hermes")))
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
        guard !value.isEmpty, !targetKey.isEmpty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        if await service.saveCredential(value, key: targetKey) {
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
    let keys: [String]
    var note: String? = nil

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("API key"), symbol: "key.fill", tint: .conduitAura) {
            VoiceAPIKeyRow(service: service, keys: keys, note: note)
        }
    }
}
