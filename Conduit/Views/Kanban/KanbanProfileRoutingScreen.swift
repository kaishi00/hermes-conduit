import SwiftUI

/// Profiles — the routing descriptions used by the Kanban orchestrator and
/// decomposer (V3A §4). A push-style list; each row opens the description
/// editor for that profile.
struct KanbanProfileRoutingScreen: View {
    @EnvironmentObject private var store: KanbanStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.profiles.isEmpty {
                        Text("No profiles on this Hermes server yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.profiles) { profile in
                            NavigationLink {
                                KanbanProfileDescriptionEditorView(profile: profile)
                                    .environmentObject(store)
                            } label: {
                                profileRow(profile)
                            }
                        }
                    }
                } footer: {
                    Text("Hermes routes triage decomposition across these profiles by their routing description. A clear description helps the decomposer pick the right specialist.")
                }
            }
            .navigationTitle("Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func profileRow(_ profile: KanbanProfile) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(profile.name)
                    .font(.subheadline.weight(.semibold))
                if profile.isDefault {
                    Text("default")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if profile.descriptionAuto {
                    Label("auto", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleOnly)
                }
                Spacer()
                if profile.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("undescribed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            let trimmed = profile.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                Text(trimmed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Single-profile routing description editor (V3A §4).
///
/// Ownership rules (all enforced by KanbanProfileDescriptionPolicy):
/// - The editor captures its baseline ONCE at open; the draft belongs to the
///   user until saved.
/// - "Generate Automatically" persists generated text server-side
///   immediately, so it can NEVER silently overwrite an unsaved manual draft:
///   a dirty draft forces an explicit discard confirmation first.
/// - A save/generation completion is UI-inert for a different profile
///   identity; underneath, KanbanStore's generation guard is the hard
///   boundary.
struct KanbanProfileDescriptionEditorView: View {
    @EnvironmentObject private var store: KanbanStore
    @Environment(\.dismiss) private var dismiss

    private let profile: KanbanProfile

    @State private var draft: String
    @State private var baseline: KanbanProfileDescriptionPolicy.Snapshot
    @State private var isSaving = false
    @State private var isGenerating = false
    @State private var notice: String?
    @State private var errorMessage: String?
    @State private var showDiscardConfirmation = false

    init(profile: KanbanProfile) {
        self.profile = profile
        let snapshot = KanbanProfileDescriptionPolicy.Snapshot(
            profile: profile.name,
            description: profile.description,
            isAuto: profile.descriptionAuto
        )
        _baseline = State(initialValue: snapshot)
        _draft = State(initialValue: profile.description)
    }

    /// Dirty compares the TRIMMED draft against the server-trimmed baseline,
    /// so a trailing newline from the TextEditor can never produce a no-op
    /// PATCH that "saves" the same text back.
    private var isDirty: Bool {
        KanbanProfileDescriptionPolicy.isDirty(draft: trimmedDraft, baseline: baseline.description)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draft)
                    .frame(minHeight: 140)
                    .accessibilityLabel("Routing description for \(profile.name)")
                if baseline.isAuto {
                    Label("Automatically generated — review recommended", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Routing Description")
            } footer: {
                Text("The decomposer reads these descriptions to route child tasks to the best specialist profile. Saving an empty description clears it (Hermes then falls back to name matching).")
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving { ProgressView() } else { Text("Save") }
                        Spacer()
                    }
                }
                .disabled(!isDirty || isSaving || isGenerating)

                Button {
                    requestGenerate()
                } label: {
                    HStack {
                        Spacer()
                        if isGenerating { ProgressView() } else { Label("Generate Automatically", systemImage: "sparkles") }
                        Spacer()
                    }
                }
                .disabled(isSaving || isGenerating)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            if let notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard & Generate", role: .destructive) {
                // Explicitly drop the unsaved draft BEFORE generating (the
                // generation would otherwise persist over the editor's draft).
                draft = KanbanProfileDescriptionPolicy.discard(draft: draft, baseline: baseline.description)
                Task { await generate() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Generating replaces the current text. Your unsaved edits will be lost.")
        }
        .interactiveDismissDisabled(isSaving || isGenerating)
    }

    private func requestGenerate() {
        switch KanbanProfileDescriptionPolicy.resolveGenerate(draft: trimmedDraft, baseline: baseline.description) {
        case .allowed:
            Task { await generate() }
        case .requiresDiscard:
            // Never silently overwrite an unsaved manual draft.
            showDiscardConfirmation = true
        }
    }

    private func save() async {
        // Freeze the server/board ownership BEFORE the first suspension point:
        // a completion from a stale generation is UI-inert - it must not
        // rewrite the editor's baseline/draft or show "saved" for a server
        // that no longer owns this screen (review W-1).
        let sessionProfile = profile.name
        let generation = store.currentConfigurationGeneration
        isSaving = true
        errorMessage = nil
        notice = nil
        defer {
            if store.isCurrentConfiguration(generation) {
                isSaving = false
            }
        }
        do {
            try await store.updateProfileDescription(profile: sessionProfile, description: trimmedDraft)
            guard store.isCurrentConfiguration(generation) else { return }
            baseline = KanbanProfileDescriptionPolicy.Snapshot(profile: sessionProfile, description: trimmedDraft, isAuto: false)
            draft = trimmedDraft
            notice = "Description saved."
        } catch {
            guard store.isCurrentConfiguration(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func generate() async {
        let sessionProfile = profile.name
        let generation = store.currentConfigurationGeneration
        isGenerating = true
        errorMessage = nil
        notice = nil
        defer {
            if store.isCurrentConfiguration(generation) {
                isGenerating = false
            }
        }
        do {
            // Generated text is persisted server-side immediately with
            // description_auto=true; the editor adopts the authoritative text.
            let outcome = try await store.autoDescribeProfile(profile: sessionProfile, overwrite: true)
            guard store.isCurrentConfiguration(generation) else { return }
            if outcome.ok {
                let generated = outcome.description ?? ""
                baseline = KanbanProfileDescriptionPolicy.Snapshot(profile: sessionProfile, description: generated, isAuto: true)
                draft = generated
                notice = "Generated automatically — review recommended."
            } else {
                // Semantic refusal (e.g. "no auxiliary client configured"):
                // the backend reason IS the product semantics.
                errorMessage = outcome.reason ?? "Hermes could not generate a description."
            }
        } catch {
            guard store.isCurrentConfiguration(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }
}
