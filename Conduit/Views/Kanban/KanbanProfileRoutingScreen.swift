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
    /// Local busy-flag ownership: the operation that STARTED isSaving/
    /// isGenerating owns their release, independent of server generations
    /// (a stale completion must still release the flags it owns).
    @State private var liveness = KanbanEditorLiveness()

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
                // V3A final pass: the identity (profile name), the board/server
                // stamp, the SUBMITTED value and the busy state are all frozen
                // synchronously in the button action (saveTapped) BEFORE any
                // Task is spawned - closing the tap -> Task-scheduling gap.
                Button {
                    saveTapped()
                } label: {
                    HStack {
                        Spacer()
                        if isSaving { ProgressView() } else { Text("Save") }
                        Spacer()
                    }
                }
                .disabled(!isDirty || isSaving || isGenerating || !store.isSelectedSnapshotLoaded)

                Button {
                    requestGenerate()
                } label: {
                    HStack {
                        Spacer()
                        if isGenerating { ProgressView() } else { Label("Generate Automatically", systemImage: "sparkles") }
                        Spacer()
                    }
                }
                .disabled(isSaving || isGenerating || !store.isSelectedSnapshotLoaded)
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
                startGenerate()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Generating replaces the current text. Your unsaved edits will be lost.")
        }
        .interactiveDismissDisabled(isSaving || isGenerating)
    }

    // MARK: - V3A final pass: synchronous tap handlers

    /// Save tap: freezes profile identity, board/server stamp, the SUBMITTED
    /// (trimmed) value, the server generation, and the busy state - all
    /// synchronously, BEFORE the Task is spawned. An editor opened for server
    /// A / profile X can therefore never save against server B / profile X,
    /// and a newer local edit made while the request is pending is never
    /// marked saved (the submission is frozen by value).
    private func saveTapped() {
        guard isDirty, !isSaving, !isGenerating,
              store.isSelectedSnapshotLoaded,
              let stamp = store.loadedContextStamp else { return }
        isSaving = true
        errorMessage = nil
        notice = nil
        let submitted = trimmedDraft
        let sessionProfile = profile.name
        let generation = store.currentConfigurationGeneration
        let operationID = liveness.begin()
        Task {
            await performSave(
                submitted: submitted,
                sessionProfile: sessionProfile,
                context: stamp,
                generation: generation,
                operationID: operationID
            )
        }
    }

    private func performSave(
        submitted: String,
        sessionProfile: String,
        context: KanbanBoardContextStamp,
        generation: Int,
        operationID: Int
    ) async {
        do {
            try await store.updateProfileDescription(
                profile: sessionProfile,
                description: submitted,
                expectedContext: context
            )
            // Local busy release is owned by THIS operation, never by the
            // server generation (a stale completion still releases it).
            if liveness.owns(operationID) { isSaving = false }
            guard store.isCurrentConfiguration(generation) else { return }
            // Server/UI result applies only while this operation still owns
            // the current lifecycle AND the editor still edits this profile.
            let outcome = KanbanProfileDescriptionPolicy.saveCompletion(
                submitted: submitted,
                currentRawDraft: draft,
                currentTrimmedDraft: trimmedDraft
            )
            baseline = KanbanProfileDescriptionPolicy.Snapshot(
                profile: sessionProfile,
                description: outcome.baselineDescription,
                isAuto: outcome.baselineIsAuto
            )
            draft = outcome.draft
            errorMessage = nil
            notice = outcome.notice
        } catch {
            if liveness.owns(operationID) { isSaving = false }
            guard store.isCurrentConfiguration(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Requests generation, honoring the dirty-draft gate.
    private func requestGenerate() {
        switch KanbanProfileDescriptionPolicy.resolveGenerate(draft: trimmedDraft, baseline: baseline.description) {
        case .allowed:
            startGenerate()
        case .requiresDiscard:
            // Never silently overwrite an unsaved manual draft.
            showDiscardConfirmation = true
        }
    }

    /// Generate tap (or confirmed discard-and-generate): freezes the profile
    /// identity, board/server stamp, the editor snapshot AT SUBMISSION, the
    /// server generation and the busy state synchronously, before any Task.
    /// The submission snapshot is what generation later compares against:
    /// newer manual typing (after submission) is preserved, never clobbered
    /// by the generated server value.
    private func startGenerate() {
        guard !isGenerating, !isSaving,
              store.isSelectedSnapshotLoaded,
              let stamp = store.loadedContextStamp else { return }
        isGenerating = true
        errorMessage = nil
        notice = nil
        // TRIMMED, matching saveTapped: generateCompletion compares
        // trimmed/trimmed, so a whitespace-ragged submission is never
        // misclassified as "newer typing" (review F-1).
        let submittedDraft = trimmedDraft
        let sessionProfile = profile.name
        let generation = store.currentConfigurationGeneration
        let operationID = liveness.begin()
        Task {
            await performGenerate(
                submittedDraft: submittedDraft,
                sessionProfile: sessionProfile,
                context: stamp,
                generation: generation,
                operationID: operationID
            )
        }
    }

    private func performGenerate(
        submittedDraft: String,
        sessionProfile: String,
        context: KanbanBoardContextStamp,
        generation: Int,
        operationID: Int
    ) async {
        do {
            // Generated text is persisted server-side immediately with
            // description_auto=true; the editor adopts the authoritative text.
            let outcome = try await store.autoDescribeProfile(
                profile: sessionProfile,
                overwrite: true,
                expectedContext: context
            )
            if liveness.owns(operationID) { isGenerating = false }
            guard store.isCurrentConfiguration(generation) else { return }
            if outcome.ok {
                let generated = outcome.description ?? ""
                let completion = KanbanProfileDescriptionPolicy.generateCompletion(
                    submittedDraft: submittedDraft,
                    currentRawDraft: draft,
                    currentTrimmedDraft: trimmedDraft,
                    generated: generated
                )
                baseline = KanbanProfileDescriptionPolicy.Snapshot(
                    profile: sessionProfile,
                    description: completion.baselineDescription,
                    isAuto: completion.baselineIsAuto
                )
                draft = completion.draft
                errorMessage = nil
                notice = completion.notice
            } else {
                // Semantic refusal (e.g. "no auxiliary client configured"):
                // the backend reason IS the product semantics.
                errorMessage = outcome.reason ?? "Hermes could not generate a description."
            }
        } catch {
            if liveness.owns(operationID) { isGenerating = false }
            guard store.isCurrentConfiguration(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }
}
