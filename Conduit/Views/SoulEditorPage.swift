import SwiftUI

/// A profile's SOUL.md on a page of its own, the whole height to write in.
/// Edit Bot > Personality and Settings > Edit profile > Personality both
/// open it, so a bot and its profile have one editor.
struct SoulEditorPage: View {
    @Binding var soul: String
    let isReadOnly: Bool
    let footer: String
    /// Why the last save didn't land, under the field.
    var error: String? = nil
    /// Held still while a save is out, keeping its look and its text.
    var isDisabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A field the page's height, drawn as the editor's rows are,
            // so it reads as something to type in.
            Group {
                if isReadOnly {
                    // The kept SOUL, shown until Hermes answers: still
                    // scrolls and selects, but can't be changed.
                    ScrollView {
                        Text(verbatim: soul)
                            .scaledFont(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(5)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    TextEditor(text: $soul)
                        .scaledFont(.callout.monospaced())
                        .scrollContentBackground(.hidden)
                        .disabled(isDisabled)
                }
            }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .settingsCard()
            if let error {
                Text(error)
                    .scaledFont(.footnote)
                    .foregroundStyle(.red)
            }
            Text(footer)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background { SettingsBackdrop().ignoresSafeArea() }
        .navigationTitle(AppLocalization.string("Personality"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The Personality row's opening lines of the SOUL, or what an empty one
/// means.
struct SoulPreview: View {
    let soul: String
    let emptyText: String

    var body: some View {
        let opening = Self.opening(of: soul)
        Group {
            if opening.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: opening)
                    .scaledFont(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    /// The SOUL's first three lines, at most 300 characters, so VoiceOver
    /// reads the opening the row shows rather than the whole SOUL.
    static func opening(of soul: String) -> String {
        let trimmed = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        var opening = lines.prefix(3).joined(separator: "\n")
        if opening.count > 300 { opening = String(opening.prefix(300)) }
        return opening.count < trimmed.count ? opening + "…" : opening
    }
}

/// Settings > Edit profile > Personality: the profile's SOUL.md as Edit
/// Bot shows it, one row opening the shared page, saved there on its own.
/// Only where Hermes can save it (bot profiles served, connected).
struct ProfilePersonalitySection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let profile: String
    @EnvironmentObject private var appState: AppState
    /// Hermes' answer this visit; nil until it lands.
    @State private var loaded: String?
    @State private var kept: String?
    @State private var readFailed = false
    @State private var isLoading = false
    /// Counts reads, so only the newest one's answer is shown.
    @State private var loadRun = 0

    var body: some View {
        if appState.canEditProfileSoul {
            ConduitSettingsSection(title: AppLocalization.string("Personality"), symbol: "theatermasks", tint: .purple) {
                if let shown = loaded ?? kept {
                    NavigationLink {
                        ProfileSoulEditor(profile: profile, loaded: loaded, kept: kept) { loaded = $0 }
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            SoulPreview(soul: shown, emptyText: AppLocalization.string("Not set"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            SettingsChevron()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if loaded == nil, readFailed { readFailure }
                } else if readFailed {
                    readFailure
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                Text(AppLocalization.string("Saved as the profile's SOUL.md, the same one Edit Bot shows.", table: .settings))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            .task(id: profile) {
                loaded = nil
                readFailed = false
                await load()
            }
        }
    }

    /// A read that failed says so and asks again on a tap, so a Hermes
    /// that comes back doesn't need Edit profile left and opened again.
    @ViewBuilder
    private var readFailure: some View {
        Text(AppLocalization.string("Could not load this profile's personality.", table: .settings))
            .foregroundStyle(.secondary)
        if isLoading {
            // The note stays up until the read asked again answers.
            ProgressView()
                .frame(maxWidth: .infinity)
        } else {
            Button(AppLocalization.string("Try Again")) {
                Task { await load() }
            }
            .buttonStyle(.settings)
        }
    }

    private func load() async {
        loadRun += 1
        let run = loadRun
        isLoading = true
        kept = appState.keptProfileSoul(profile)
        let answer = await appState.loadProfileSoul(profile)
        // A newer read, or a profile switch, owns what's shown.
        guard !Task.isCancelled, run == loadRun else { return }
        isLoading = false
        if let answer { loaded = answer }
        readFailed = answer == nil
    }
}

/// The shared page with its own Save: Edit Bot saves with the rest of the
/// bot, Edit profile saves the SOUL alone.
private struct ProfileSoulEditor: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let profile: String
    /// Hermes' SOUL; the kept one shows read-only until it lands.
    let loaded: String?
    let kept: String?
    let onSaved: (String) -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// What's typed; nil until the first edit, so Hermes' answer landing
    /// while the page is open shows.
    @State private var draft: String?
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        SoulEditorPage(
            soul: Binding(get: { draft ?? loaded ?? kept ?? "" }, set: { draft = $0 }),
            // A save compares with Hermes' own, never the kept copy.
            isReadOnly: loaded == nil,
            footer: AppLocalization.string("Saved as the profile's SOUL.md, the same one Edit Bot shows.", table: .settings),
            error: error,
            isDisabled: isSaving
        )
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button(AppLocalization.string("Save"), action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        guard let loaded, let draft else { return false }
        return draft != loaded
    }

    private func save() {
        guard canSave, let draft else { return }
        isSaving = true
        error = nil
        Task { @MainActor in
            let message = await appState.saveProfileSoul(draft, profile: profile)
            isSaving = false
            // A failed save keeps what was typed, to try again.
            if let message {
                Haptics.warning()
                error = message
                return
            }
            Haptics.success()
            onSaved(draft)
            dismiss()
        }
    }
}
