import PhotosUI
import SwiftUI

/// New Bot / Edit Bot: Desktop's bot editor, minus its generated block faces.
/// Pictures and colors are stored on the gateway (see `BotManagement`), so
/// whatever is picked here is what Hermes Desktop and every other Conduit
/// show too.
struct BotEditorSheet: View {
    enum Mode: Identifiable {
        case create
        case edit(BotProfile)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let bot): return "edit:\(bot.name)"
            }
        }
    }

    let mode: Mode
    /// Called after a successful save, with the new bot's profile name (for
    /// a create), any best-effort part that did not save, and whether the
    /// new bot can introduce itself (its profile reaches a model).
    let onFinished: (_ createdBotName: String?, _ warning: String?, _ introduces: Bool) -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var draft = BotEditorDraft()
    @State private var details: BotProfileDetails?
    @State private var detailsState: DetailsState = .idle
    @State private var isSaving = false
    /// The combined dashboard picked for a new bot; nil, the one on screen.
    @State private var createDashboard: UUID?
    /// The dashboard the sheet's model list, Start From and skills were read on.
    @State private var fieldsDashboard: UUID?
    @State private var error: String?
    @State private var showingImagePicker = false
    @State private var pickedImage: UIImage?
    /// Choose GIF or Video: the Photos picker, which hands over a GIF's own
    /// file (Choose Photo's crop keeps one frame).
    @State private var showingMotionPicker = false
    @State private var pickedMotion: PhotosPickerItem?
    /// A picked GIF or video is being made into a moving picture.
    @State private var isPreparingAnimation = false
    /// Whether Hermes can generate pictures; nil until asked.
    @State private var canGeneratePictures: Bool?
    @State private var showingGenerator = false
    /// Apple's Image Playground (ImagePlaygroundPicture), as the system
    /// says now.
    @State private var playground: ImagePlaygroundPicture.Availability = .unavailable
    @State private var showingPlayground = false
    @State private var seeded = false
    @State private var showsAdvanced = false
    /// The gateway's message for a model pick it wants confirmed.
    @State private var modelConfirmation: String?
    @State private var capabilitiesLoadFailed = false
    /// The Start From profile the staged lists were read from.
    @State private var capabilitiesSource: String?
    /// The bot's details as Hermes gave them last time (#1533): shown,
    /// read-only, until it answers, and never what a save compares with.
    @State private var keptDetails: BotProfileDetails?
    /// The Start From profile's lists as Hermes gave them last time, shown
    /// read-only until it answers.
    @State private var keptCapabilities: BotCapabilities?

    private enum DetailsState {
        case idle, loading, loaded, failed
    }

    private var editedBot: BotProfile? {
        if case .edit(let bot) = mode { return bot }
        return nil
    }

    private var isCreating: Bool { editedBot == nil }

    /// Edit Bot shows the bot's kept details until Hermes answers.
    private var showsKeptDetails: Bool {
        !isCreating && detailsState != .loaded && keptDetails != nil
    }

    /// The lists shown read-only until Hermes answers: the bot's own on
    /// Edit Bot, the Start From profile's on New Bot.
    private var shownKeptCapabilities: BotCapabilities? {
        isCreating ? keptCapabilities : keptDetails?.capabilities
    }

    var body: some View {
        NavigationStack {
            // Settings' own page: cards with their names over them, so the
            // sheet reads like the Settings tab (Eric 2026-11-05).
            SettingsDetailContainer {
                if let error, !error.isEmpty {
                    Text(error)
                        .scaledFont(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }
                createDashboardRow
                avatarHeader
                faceSection
                nameSection
                ConduitSettingsSection(title: AppLocalization.string("Description"), symbol: "text.alignleft", tint: .blue) {
                    TextField(
                        AppLocalization.string("What this bot is for", table: .bots),
                        text: $draft.description,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                }
                personalitySection
                workSection
                advancedSection
            }
            .navigationTitle(isCreating ? AppLocalization.string("New Bot", table: .bots) : AppLocalization.string("Edit Bot"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(isCreating ? AppLocalization.string("Create") : AppLocalization.string("Save")) {
                            save()
                        }
                        .disabled(!canSave)
                    }
                }
            }
        }
        // Also while the model alert is up: a swipe would drop the pick
        // without saying so.
        .interactiveDismissDisabled(isSaving || modelConfirmation != nil)
        .alert(
            AppLocalization.string("Use This Model?", table: .bots),
            isPresented: Binding(
                get: { modelConfirmation != nil },
                set: { if !$0 { modelConfirmation = nil } }
            ),
            presenting: modelConfirmation
        ) { _ in
            Button(AppLocalization.string("Use Anyway", table: .bots)) { confirmModel() }
            Button(AppLocalization.string("Cancel"), role: .cancel) {
                // Everything else already saved; only the model stays.
                dismiss()
                onFinished(nil, AppLocalization.string("The model was not saved."), false)
            }
        } message: { message in
            Text(verbatim: message)
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(image: $pickedImage)
        }
        .photosPicker(
            isPresented: $showingMotionPicker,
            selection: $pickedMotion,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        )
        .onChange(of: pickedMotion) { _, item in
            guard let item else { return }
            pickedMotion = nil
            useAnimation(item)
        }
        .sheet(isPresented: $showingGenerator) {
            GeneratePictureSheet(
                defaultPrompt: PictureGeneration.botPrompt(
                    name: draft.name.isEmpty ? editedBot?.displayLabel ?? "" : draft.name,
                    description: draft.description
                ),
                forGroup: false
            ) { image in
                usePicture(image)
            }
            .environmentObject(appState)
        }
        .imagePlaygroundPicture(
            isPresented: $showingPlayground,
            prompt: playgroundPrompt,
            source: previewImage,
            onImage: usePicture,
            onFailure: { error = AppLocalization.string("That picture could not be used.") }
        )
        .readsImagePlaygroundAvailability($playground)
        .onChange(of: pickedImage) { _, image in
            guard let image else { return }
            usePicture(image)
            pickedImage = nil
        }
        .onAppear {
            if fieldsDashboard == nil { fieldsDashboard = appState.activeDashboardID }
            seedShown()
        }
        .task { canGeneratePictures = await appState.refreshPictureGeneration() }
        .task { await seed() }
        .task(id: capabilitySource) { await loadStartFromCapabilities() }
        .task {
            // The stored picture, independent of whether the roster row's
            // fetch succeeded.
            if let bot = editedBot { await appState.loadBotAvatarRetrying(bot) }
        }
    }

    // MARK: Sections

    /// Combined, a new bot's sheet picks the dashboard it's made on, the one
    /// on screen to start with, any other kept connected too (Eric,
    /// 2026-11-16: "let users pick on the bot creation sheet").
    @ViewBuilder
    private var createDashboardRow: some View {
        let choices = createDashboardChoices
        if isCreating, !choices.isEmpty, let shown = createDashboardID,
           let badge = appState.combinedDashboardBadge(shown) {
            Menu {
                ForEach(choices, id: \.self) { id in
                    if let choice = appState.combinedDashboardBadge(id) {
                        Button {
                            createDashboard = id
                        } label: {
                            if id == shown {
                                Label { Text(verbatim: choice.name) } icon: { Image(systemName: "checkmark") }
                            } else {
                                Text(verbatim: choice.name)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    CombinedDashboardBadge(dashboardID: shown, size: 20)
                        .accessibilityHidden(true)
                    Text(verbatim: badge.name)
                        .scaledFont(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(.thinMaterial, in: Capsule())
            }
            .disabled(isSaving)
            .frame(maxWidth: .infinity)
        }
    }

    /// The dashboard a new bot goes to: the one picked, else the one on screen.
    private var createDashboardID: UUID? {
        if let createDashboard, createDashboardChoices.contains(createDashboard) { return createDashboard }
        return appState.activeDashboardID
    }

    /// The one on screen, then each other combined dashboard kept connected,
    /// in Saved Dashboards order.
    private var createDashboardChoices: [UUID] {
        guard let active = appState.activeDashboardID, appState.isInCombinedGroup(active) else { return [] }
        let others = appState.savedDashboardRegistry.dashboards.map(\.id).filter {
            $0 != active && appState.isInCombinedGroup($0) && appState.keptDashboardRuntimes[$0] != nil
        }
        return [active] + others
    }

    private var avatarHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                BotAvatarView(
                    name: avatarName,
                    label: avatarLabel,
                    colorString: draft.color,
                    image: previewImage,
                    size: 88,
                    playback: previewPlayback,
                    face: StarterFaces.face(shownFace)
                )
                if isPreparingAnimation {
                    ProgressView()
                        .frame(width: 88, height: 88)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            // The avatar itself is decorative everywhere else; here it is the
            // only sign of whether the bot will have a picture.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(AppLocalization.string("Picture", table: .bots)))
            .accessibilityValue(Text(pictureStateDescription))
            // One menu for every way to set the picture: side by side they
            // wrapped letter by letter on a phone (Eric, 2026-11-06).
            Menu {
                Button {
                    Haptics.light()
                    showingImagePicker = true
                } label: {
                    Label(AppLocalization.string("Choose Photo"), systemImage: "photo")
                }
                Button {
                    Haptics.light()
                    showingMotionPicker = true
                } label: {
                    Label(AppLocalization.string("Choose GIF or Video"), systemImage: "film")
                }
                generateItems
                if let still = previewImage, previewPlayback == nil {
                    Button {
                        Haptics.light()
                        bringToLife(still)
                    } label: {
                        Label(AppLocalization.string("Bring to Life"), systemImage: "wand.and.stars")
                    }
                }
                if previewImage != nil || (hasStoredAvatar && !draft.removesAvatar) {
                    Divider()
                    Button(role: .destructive) {
                        Haptics.light()
                        if draft.newAvatarPNG != nil {
                            // Discarding a fresh pick goes back to the stored
                            // picture; it never deletes it.
                            draft.newAvatarPNG = nil
                        } else {
                            draft.removesAvatar = hasStoredAvatar
                        }
                    } label: {
                        Label(AppLocalization.string("Remove Photo"), systemImage: "trash")
                    }
                } else if draft.removesAvatar {
                    Divider()
                    Button {
                        Haptics.light()
                        draft.removesAvatar = false
                    } label: {
                        Label(AppLocalization.string("Keep Photo", table: .bots), systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                Label(AppLocalization.string("Edit Picture", table: .bots), systemImage: "photo.badge.plus")
            }
            .buttonStyle(.settings)
            .accessibilityIdentifier("bot-editor-picture-menu")
            .scaledFont(.subheadline)
            // A picked GIF or video lands in the draft once it's made, so
            // nothing else may change the picture meanwhile.
            .disabled(isPreparingAnimation)
            Text(AppLocalization.string("A GIF, a short video or a picture brought to life moves on Bots Home and in Hermes Desktop.", table: .bots))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if playground == .canTurnOn {
                Text(AppLocalization.string("Turn on Apple Intelligence in Settings > Apple Intelligence & Siri to create pictures with Image Playground.", table: .bots))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if canGeneratePictures == false, playground != .available {
                Text(AppLocalization.string("Set up image generation in Hermes to generate pictures.", table: .bots))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// Generate, in the picture menu: Image Playground, Hermes' own image
    /// generation, or a submenu of both when both can.
    @ViewBuilder
    private var generateItems: some View {
        let hermes = canGeneratePictures == true
        // Not before an edited bot's SOUL has loaded, which the sheet starts from.
        let apple = playground == .available && (isCreating || showsKeptDetails || detailsState == .loaded || detailsState == .failed)
        if hermes && apple {
            Menu {
                Button {
                    Haptics.light()
                    showingPlayground = true
                } label: {
                    Label(AppLocalization.string("Image Playground"), systemImage: "apple.image.playground")
                }
                Button {
                    Haptics.light()
                    showingGenerator = true
                } label: {
                    Label(AppLocalization.string("With Hermes", table: .bots), systemImage: "sparkles")
                }
            } label: {
                Label(AppLocalization.string("Generate"), systemImage: "sparkles")
            }
        } else if apple || hermes {
            Button {
                Haptics.light()
                if apple { showingPlayground = true } else { showingGenerator = true }
            } label: {
                Label(AppLocalization.string("Generate"), systemImage: "sparkles")
            }
        }
    }

    /// What Image Playground starts from: the bot's name, and its
    /// description and SOUL to pick ideas out of.
    private var playgroundPrompt: ImagePlaygroundPicture.Prompt {
        ImagePlaygroundPicture.Prompt(
            name: draft.name.isEmpty ? editedBot?.displayLabel ?? "" : draft.name,
            // The SOUL shown, kept from last time until Hermes answers.
            details: [draft.description, showsKeptDetails ? keptDetails?.soul ?? "" : draft.soul]
        )
    }

    /// A chosen or generated picture, scaled to the stored square.
    private func usePicture(_ image: UIImage) {
        if let png = BotAvatarImage.normalizedPNG(from: image) {
            draft.newAvatarPNG = png
            draft.removesAvatar = false
            error = nil
        } else {
            error = AppLocalization.string("That picture could not be used.")
        }
    }

    /// A picked GIF or video, made into a looping APNG (AnimatedAvatar) and
    /// saved like any picture; a still picked there is used as one.
    private func useAnimation(_ item: PhotosPickerItem) {
        isPreparingAnimation = true
        error = nil
        Task { @MainActor in
            let source: AnimatedAvatar.Source?
            switch await AnimatedAvatar.pick(from: item) {
            case .animation(let picked): source = picked
            case .still(let image):
                isPreparingAnimation = false
                usePicture(image)
                return
            case .unreadable: source = nil
            }
            let result = await AnimatedAvatar.picture(fromPicked: source)
            isPreparingAnimation = false
            switch result {
            case .success(let apng):
                draft.newAvatarPNG = apng
                draft.removesAvatar = false
            case .failure(let failure):
                error = AnimatedAvatar.message(for: failure)
            }
        }
    }

    /// Bring to Life: the still shown, its subject swaying (LivingPortrait),
    /// as a fresh pick the person saves or discards like any other.
    private func bringToLife(_ image: UIImage) {
        isPreparingAnimation = true
        error = nil
        Task { @MainActor in
            let result = await LivingPortrait.picture(from: image)
            isPreparingAnimation = false
            switch result {
            case .success(let apng):
                draft.newAvatarPNG = apng
                draft.removesAvatar = false
            case .failure(let failure):
                error = LivingPortrait.message(for: failure)
            }
        }
    }

    private var pictureStateDescription: String {
        if draft.newAvatarPNG != nil {
            return AppLocalization.string("New photo chosen", table: .bots)
        }
        if draft.removesAvatar {
            return AppLocalization.string("Photo will be removed", table: .bots)
        }
        return hasStoredAvatar ? AppLocalization.string("Photo set", table: .bots) : AppLocalization.string("No photo", table: .bots)
    }

    /// The twelve starter faces, in place of a color grid: a face brings
    /// its color, and it's what the bot shows until it has a picture
    /// (Eric, 2026-11-17).
    private var faceSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Face", table: .bots), symbol: "face.smiling", tint: .pink) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 8) {
                ForEach(StarterFaces.set.indices, id: \.self) { index in
                    faceButton(index, name: faceName(StarterFaces.set[index]))
                }
            }
            Text(AppLocalization.string("Shown until the bot has a picture. Its color is the bot's color in Conduit.", table: .bots))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// A face's VoiceOver name, by its color. Resolved at each render so a
    /// language change applies at once.
    private func faceName(_ face: StarterFace) -> String {
        switch face.colorName {
        case .purple: AppLocalization.string("Purple")
        case .skyBlue: AppLocalization.string("Sky Blue", table: .bots)
        case .orange: AppLocalization.string("Orange", table: .bots)
        case .mint: AppLocalization.string("Mint", table: .bots)
        case .yellow: AppLocalization.string("Yellow", table: .bots)
        case .pink: AppLocalization.string("Pink")
        case .blue: AppLocalization.string("Blue")
        case .cyan: AppLocalization.string("Cyan", table: .bots)
        case .red: AppLocalization.string("Red", table: .bots)
        case .lime: AppLocalization.string("Lime", table: .bots)
        case .magenta: AppLocalization.string("Magenta", table: .bots)
        case .gray: AppLocalization.string("Gray", table: .bots)
        case nil: AppLocalization.string("Face", table: .bots)
        }
    }

    private func faceButton(_ index: Int, name: String) -> some View {
        let isSelected = shownFace == index
        let face = StarterFaces.face(index)
        return Button {
            Haptics.light()
            draft.face = index
            draft.color = face.hex
        } label: {
            StarterFaceView(face: face)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                        .padding(-4)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var nameSection: some View {
        if let bot = editedBot {
            ConduitSettingsSection(title: AppLocalization.string("Display Name", table: .bots), symbol: "person.text.rectangle", tint: .conduitAccent) {
                TextField(bot.displayName.isEmpty ? bot.name : bot.displayName, text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                Text(AppLocalization.string("Profile ID: \(bot.name)", table: .bots))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            ConduitSettingsSection(title: AppLocalization.string("Name"), symbol: "person.text.rectangle", tint: .conduitAccent) {
                TextField(AppLocalization.string("Name"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                createNameFooter
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var createNameFooter: some View {
        let identity = appState.newBotSlug(for: draft.name, on: createDashboardID)
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(AppLocalization.string("The bot gets its own Hermes profile, chat, memory and skills.", table: .bots))
        } else if !identity.isValid {
            Text(AppLocalization.string("Use at least one letter or number.", table: .bots))
                .foregroundStyle(.red)
        } else if identity.isTaken {
            Text(AppLocalization.string("A profile named \(identity.slug) already exists."))
                .foregroundStyle(.red)
        } else {
            Text(AppLocalization.string("Profile ID: \(identity.slug)", table: .bots))
        }
    }

    /// The bot's SOUL.md as one row with its opening lines, edited on a
    /// page of its own: a long one inline pushed Work and Advanced out of
    /// sight (Eric 2026-11-05).
    @ViewBuilder
    private var personalitySection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Personality"), symbol: "theatermasks", tint: .purple) {
            if isCreating || detailsState == .loaded || keptDetails != nil {
                NavigationLink {
                    SoulEditorPage(
                        // The kept SOUL can't be edited: Hermes' own comes first.
                        soul: showsKeptDetails ? Binding.constant(keptDetails?.soul ?? "") : $draft.soul,
                        isReadOnly: showsKeptDetails,
                        footer: personalityFooter
                    )
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        personalityPreview(showsKeptDetails ? keptDetails?.soul ?? "" : draft.soul)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SettingsChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsKeptDetails, detailsState == .failed {
                    Text(AppLocalization.string("Could not load this bot's personality.", table: .bots))
                        .foregroundStyle(.secondary)
                    detailsRetry
                }
            } else if detailsState == .failed {
                Text(AppLocalization.string("Could not load this bot's personality.", table: .bots))
                    .foregroundStyle(.secondary)
                detailsRetry
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            Text(personalityFooter)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// A details read that failed is asked again on a tap, as Edit
    /// profile's Personality does, rather than closing the editor.
    private var detailsRetry: some View {
        Button(AppLocalization.string("Try Again")) {
            detailsState = .idle
            Task { await seed() }
        }
        .buttonStyle(.settings)
    }

    private var personalityFooter: String {
        isCreating
            ? AppLocalization.string("Optional. Leave empty to start from a short identity built from the name and description.", table: .bots)
            : AppLocalization.string("Saved as the bot's SOUL.md.", table: .bots)
    }

    /// The row's opening lines of the SOUL, or what an empty one means.
    private func personalityPreview(_ soul: String) -> some View {
        SoulPreview(
            soul: soul,
            emptyText: isCreating
                ? AppLocalization.string("Built from the name and description", table: .bots)
                : AppLocalization.string("Not set")
        )
    }

    /// Edit Bot > Work: how the bot's Bot Chat coordinates its work, kept
    /// by the plugin and saved as it's changed there. Only for a bot that
    /// exists, on a plugin that serves it.
    @ViewBuilder
    private var workSection: some View {
        if let bot = editedBot, appState.servesBotWorkSettings {
            // No name over it: its one row is Work.
            SettingsCard {
                NavigationLink {
                    BotWorkSettingsView(profile: bot.name, botName: bot.displayLabel)
                } label: {
                    SettingsLinkRow(title: AppLocalization.string("Work"))
                }
                .buttonStyle(.plain)
                Text(AppLocalization.string("How \(bot.displayLabel) hands tasks to workstreams and keeps track of them in its Bot Chat.", table: .bots))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Desktop's Advanced disclosure. Creating: where the profile starts
    /// from, its model, skills, tools and MCP, shared keys and bundled
    /// skills. Editing: its model, skills, tools and MCP, once the bot's
    /// details have loaded or from its kept ones, read-only.
    @ViewBuilder
    private var advancedSection: some View {
        if isCreating || detailsState == .loaded || showsKeptDetails {
            // No name over it: its own row names it and opens it.
            SettingsCard {
                Button {
                    Haptics.light()
                    withAnimation { showsAdvanced.toggle() }
                    showKeptStartFrom()
                } label: {
                    HStack {
                        Text(AppLocalization.string("Advanced"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .scaledFont(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                // A row like Work's above it, not an accent link.
                .buttonStyle(.plain)
                .accessibilityValue(Text(showsAdvanced ? AppLocalization.string("Shown", table: .bots) : AppLocalization.string("Hidden")))
                if showsAdvanced {
                    if isCreating {
                        ConduitMenuPicker(
                            value: startFromSelection.wrappedValue,
                            choices: [(id: BotCreateRequest.mainProfile, title: AppLocalization.string("Main Profile", table: .bots))]
                                + cloneSources.map { (id: $0.name, title: $0.displayLabel) }
                                + [(id: "", title: AppLocalization.string("Fresh Profile", table: .bots))],
                            onSelect: { startFromSelection.wrappedValue = $0 }
                        ) {
                            Text(AppLocalization.string("Start From", table: .bots)).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        BotModelPicker(provider: $draft.provider, model: $draft.model, allowsInherit: isCreating)
                    } label: {
                        let model = showsKeptDetails ? keptDetails?.model ?? "" : draft.model
                        let provider = showsKeptDetails ? keptDetails?.provider ?? "" : draft.provider
                        if model.isEmpty {
                            ModelChooserLinkRow(
                                title: AppLocalization.string("Model"),
                                value: BotModelPicker.summary(model: model, allowsInherit: isCreating),
                                detail: nil
                            )
                        } else {
                            // The model and provider as the catalog names them.
                            let lines = ModelChooserLinkRow.lines(
                                pick: ModelChooserPick(provider: provider, model: model),
                                providers: appState.keptModelProviders(),
                                defaultTitle: ""
                            )
                            ModelChooserLinkRow(title: AppLocalization.string("Model"), value: lines.value, detail: lines.detail)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(showsKeptDetails)
                    capabilitiesRow
                    if isCreating {
                        Toggle(AppLocalization.string("Share Keys and Accounts", table: .bots), isOn: $draft.shareAuth)
                            .tint(.conduitAccent)
                        Text(AppLocalization.string("Shared keys and accounts stay one set with the main profile, so a sign-in refresh in one never signs the other out. Turn it off for a separate copy.", table: .bots))
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                        Toggle(AppLocalization.string("Skip Bundled Skills", table: .bots), isOn: $draft.noSkills)
                            .tint(.conduitAccent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var capabilitiesRow: some View {
        if isCreating, draft.cloneFrom.isEmpty {
            // Nothing to diff against before the profile exists: a fresh
            // one starts with Hermes' own defaults.
            Text(draft.noSkills
                ? AppLocalization.string("A fresh profile starts with Hermes' default tools. Edit the bot afterwards to change them.", table: .bots)
                : AppLocalization.string("A fresh profile starts with Hermes' bundled skills and default tools. Edit the bot afterwards to change them.", table: .bots))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        } else if draft.capabilities != nil || shownKeptCapabilities != nil {
            // One link per list, for the kept lists and Hermes' answer, so a
            // page open on the kept ones stays open as they become Hermes'
            // own. Each says how many are on (Eric, 2026-11-11).
            let shown = draft.capabilities ?? shownKeptCapabilities ?? BotCapabilities()
            let skillsSkipped = isCreating && draft.noSkills
            NavigationLink {
                BotSkillsView(
                    capabilities: capabilitiesBinding,
                    skillsSkipped: skillsSkipped,
                    sourceLabel: isCreating ? startFromLabel : nil,
                    detailsProfile: isCreating ? capabilitySource : editedBot?.name,
                    editable: draft.capabilities != nil
                )
            } label: {
                SettingsLinkRow(
                    title: AppLocalization.string("Skills"),
                    value: skillsSkipped ? AppLocalization.string("None") : BotCapabilities.onSummary(shown.skills) ?? AppLocalization.string("None")
                )
            }
            .buttonStyle(.plain)
            NavigationLink {
                BotToolsView(capabilities: capabilitiesBinding, editable: draft.capabilities != nil)
            } label: {
                SettingsLinkRow(
                    title: AppLocalization.string("Tools"),
                    value: BotCapabilities.onSummary(shown.toolsets) ?? AppLocalization.string("None")
                )
            }
            .buttonStyle(.plain)
            NavigationLink {
                BotMcpServersView(
                    capabilities: capabilitiesBinding,
                    mcpProfile: editedBot?.name,
                    editable: draft.capabilities != nil
                )
            } label: {
                SettingsLinkRow(
                    title: SettingsNames.mcp,
                    value: BotCapabilities.onSummary(shown.mcpServers) ?? AppLocalization.string("None")
                )
            }
            .buttonStyle(.plain)
            if draft.capabilities == nil, capabilitiesLoadFailed {
                capabilitiesFailure
            }
        } else if capabilitiesLoadFailed {
            capabilitiesFailure
        } else {
            LabeledContent(AppLocalization.string("Skills, Tools and MCP", table: .bots)) {
                ProgressView()
            }
        }
    }

    /// The lists the Skills, Tools and MCP pages switch: Hermes' answer,
    /// or the kept lists, read-only, until it comes.
    private var capabilitiesBinding: Binding<BotCapabilities> {
        Binding(
            get: { draft.capabilities ?? shownKeptCapabilities ?? BotCapabilities() },
            set: { if draft.capabilities != nil { draft.capabilities = $0 } }
        )
    }

    private var capabilitiesFailure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string("Could not load skills, tools or MCP servers.", table: .bots))
                .foregroundStyle(.secondary)
            Button(AppLocalization.string("Try Again")) {
                Task { await loadStartFromCapabilities() }
            }
            .buttonStyle(.settings)
        }
    }

    /// The Start From profile's lists Hermes gave last time, shown in the
    /// same frame as the pick or Advanced opening, until its answer comes.
    private func showKeptStartFrom() {
        keptCapabilities = capabilitySource.flatMap { appState.keptBotCapabilities(startingFrom: $0) }
    }

    /// The profile a new bot's skills, tools and MCP lists are read from
    /// while Advanced is open: its Start From profile. Nil when nothing
    /// should load, a fresh start included: its real set is Hermes'
    /// defaults, which no profile here shows (Desktop reads the main
    /// profile's and diffs against it).
    private var capabilitySource: String? {
        guard isCreating, showsAdvanced, !draft.cloneFrom.isEmpty else { return nil }
        return draft.cloneFrom
    }

    private var startFromLabel: String {
        let source = capabilitySource ?? BotCreateRequest.mainProfile
        if BotManagement.isDefaultProfile(source) { return AppLocalization.string("Main Profile", table: .bots) }
        return appState.botRoster.first { $0.name == source }?.displayLabel ?? source
    }

    /// A new Start From pick replaces the staged lists: picks made against
    /// another profile's set don't carry over.
    private func loadStartFromCapabilities() async {
        guard let source = capabilitySource else {
            // Picks made against another profile don't carry to a fresh one.
            if isCreating, draft.cloneFrom.isEmpty {
                capabilitiesSource = nil
                draft.capabilities = nil
                draft.capabilitiesBaseline = nil
                capabilitiesLoadFailed = false
            }
            return
        }
        guard source != capabilitiesSource || draft.capabilities == nil else { return }
        capabilitiesSource = source
        draft.capabilities = nil
        draft.capabilitiesBaseline = nil
        capabilitiesLoadFailed = false
        showKeptStartFrom()
        let loaded = await appState.loadBotCapabilities(startingFrom: source)
        // A Try Again isn't cancelled with the task: a newer Start From wins.
        guard !Task.isCancelled, source == capabilitySource else { return }
        if let loaded {
            draft.capabilities = loaded
            draft.capabilitiesBaseline = loaded
        } else {
            capabilitiesSource = nil
            capabilitiesLoadFailed = true
        }
    }

    /// Start From, dropping the staged lists at once: a Create before the
    /// new profile's lists load must not send the old profile's picks.
    private var startFromSelection: Binding<String> {
        Binding(
            get: { draft.cloneFrom },
            set: { source in
                guard source != draft.cloneFrom else { return }
                draft.cloneFrom = source
                capabilitiesSource = nil
                draft.capabilities = nil
                draft.capabilitiesBaseline = nil
                capabilitiesLoadFailed = false
                showKeptStartFrom()
            }
        )
    }

    /// Bots a new one can copy its settings from, besides the main profile.
    private var cloneSources: [BotProfile] {
        appState.orderedBots(appState.botRoster).filter { !BotManagement.isDefaultProfile($0.name) }
    }

    // MARK: State

    private var avatarName: String {
        editedBot?.name ?? appState.newBotSlug(for: draft.name).slug
    }

    /// The face the bot shows: the one picked here, else the bot's own, else,
    /// for a new bot, the first one free on the dashboard it's made on.
    private var shownFace: Int {
        draft.face ?? editedBot?.starterFace ?? appState.nextStarterFace(on: createDashboardID)
    }

    private var avatarLabel: String {
        let typed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return editedBot?.displayLabel ?? "?"
    }

    /// The gateway holds a picture for the bot being edited, loaded or not.
    private var hasStoredAvatar: Bool {
        editedBot?.hasAvatar ?? false
    }

    /// The picture the gateway holds for the bot being edited.
    private var storedImage: UIImage? {
        editedBot.flatMap { appState.botAvatarImage(for: $0) }
    }

    /// The picture plays here as it will on Bots Home: a fresh pick, else
    /// the stored one.
    private var previewPlayback: AnimatedAvatarPlayback? {
        if let png = draft.newAvatarPNG {
            return AnimatedAvatar.isAnimated(png) ? .data(png) : nil
        }
        if draft.removesAvatar { return nil }
        return editedBot.flatMap { appState.botAvatarPlayback(for: $0) }
    }

    private var previewImage: UIImage? {
        if let png = draft.newAvatarPNG { return UIImage(data: png) }
        if draft.removesAvatar { return nil }
        return storedImage
    }

    private var canSave: Bool {
        // A picked GIF or video lands in the draft once it's made.
        guard !isSaving, !isPreparingAnimation else { return false }
        // An edit saves only once the editor snapshot settled: before it,
        // the form still holds placeholders that would overwrite the bot.
        guard isCreating else { return detailsState == .loaded || detailsState == .failed }
        let identity = appState.newBotSlug(for: draft.name, on: createDashboardID)
        return identity.isValid && !identity.isTaken
    }

    /// The editor's first frame: the roster's name, description and color,
    /// and the bot's details as Hermes gave them last time (#1533).
    private func seedShown() {
        guard !seeded else { return }
        seeded = true
        guard let bot = editedBot else { return }
        draft.name = bot.botTitle ?? ""
        draft.description = bot.profileDescription
        draft.color = bot.appearanceColor
        keptDetails = appState.keptBotDetails(bot)
    }

    private func seed() async {
        seedShown()
        guard let bot = editedBot, detailsState == .idle else { return }
        detailsState = .loading
        guard let loaded = await appState.loadBotDetails(bot) else {
            detailsState = .failed
            return
        }
        details = loaded
        // The roster's description is a cached copy; adopt the editor
        // snapshot unless the user already started typing.
        if draft.description == bot.profileDescription {
            draft.description = loaded.description
        }
        draft.soul = loaded.soul
        draft.provider = loaded.provider
        draft.model = loaded.model
        draft.capabilities = loaded.capabilities
        detailsState = .loaded
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        error = nil
        var draft = self.draft
        let target = isCreating ? createDashboardID : nil
        // A new bot keeps the face its preview showed, whatever the roster
        // reads while it's made or the dashboard it switches to lists.
        if isCreating, draft.face == nil { draft.face = shownFace }
        Task {
            let result: BotSaveResult
            var createdName: String?
            // Another dashboard picked: switch there, then make it as on that
            // dashboard. Its model, its Start From and its skills and tools
            // are that dashboard's defaults: what the sheet read was the
            // first one's, and none of it is written to the other. The reset
            // stays on the sheet, so a retry there sends it as well.
            if let target {
                if target != appState.activeDashboardID {
                    guard !appState.refusesCombinedSwitchDuringCall() else { isSaving = false; return }
                    await appState.switchToCombinedDashboardUntilSettled(target)
                    guard appState.activeDashboardID == target, appState.isConnected else {
                        isSaving = false
                        Haptics.warning()
                        error = AppLocalization.string("Connect to Hermes to manage bots.")
                        return
                    }
                }
                if target != (fieldsDashboard ?? target) {
                    draft = draft.readOnAnotherDashboard
                    self.draft = self.draft.readOnAnotherDashboard
                    fieldsDashboard = target
                }
            }
            if let bot = editedBot {
                result = await appState.updateBot(bot, draft: draft, loadedDetails: details)
            } else {
                createdName = appState.newBotSlug(for: draft.name).slug
                result = await appState.createBot(draft)
            }
            isSaving = false
            switch result {
            case .failed(let message):
                Haptics.warning()
                error = message
            case .saved(let warning, let needsModel):
                if warning == nil { Haptics.success() } else { Haptics.warning() }
                dismiss()
                onFinished(createdName, warning, createdName != nil && !needsModel)
            case .confirmModel(let message):
                Haptics.warning()
                // Only Edit Bot asks; a create pins through profiles.create.
                if editedBot == nil { error = message } else { modelConfirmation = message }
            }
        }
    }

    private func confirmModel() {
        guard let bot = editedBot else { return }
        isSaving = true
        error = nil
        let draft = self.draft
        Task {
            let result = await appState.saveBotModel(bot, provider: draft.provider, model: draft.model, confirmed: true)
            isSaving = false
            switch result {
            case .saved(let warning, _):
                if warning == nil { Haptics.success() } else { Haptics.warning() }
                dismiss()
                onFinished(nil, warning, false)
            case .confirmModel, .failed:
                Haptics.warning()
                dismiss()
                onFinished(nil, AppLocalization.string("The model was not saved."), false)
            }
        }
    }
}

/// A bot's face: its picture when it has one, else its starter face
/// (StarterFaces) on its color, else, for what isn't one of your bots (a
/// person, another person's agent), the initial on its color (the explicit
/// pick, else Desktop's name-derived hue).
struct BotAvatarView: View {
    let name: String
    let label: String
    let colorString: String?
    let image: UIImage?
    let size: CGFloat
    /// The moving picture to play over `image`, where the face is the focus
    /// (AnimatedAvatarFrames); nil keeps the still.
    var playback: AnimatedAvatarPlayback? = nil
    /// The bot's starter face, drawn while it has no picture.
    var face: StarterFace? = nil

    var body: some View {
        Group {
            if let image {
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                    if let playback {
                        AnimatedAvatarFrames(playback: playback)
                    }
                }
            } else if let face {
                StarterFaceView(face: face, background: colorString.map { Self.color(for: $0, name: name) })
            } else {
                ZStack {
                    Self.color(for: colorString, name: name)
                    Text(initial)
                        .font(.system(size: max(11, size * 0.42), weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initial: String {
        String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }

    /// Desktop's color strings (`hsl(...)`, hex), the named colors earlier
    /// Conduit builds understood, else the name's own hue.
    static func color(for css: String?, name: String) -> Color {
        if let css, let named = namedColor(css) { return named }
        let rgb = css.flatMap(BotAvatarColor.rgb(from:)) ?? BotAvatarColor.fallbackRGB(for: name)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private static func namedColor(_ name: String) -> Color? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "blue": return .blue
        case "brown": return .brown
        case "cyan": return .cyan
        case "green": return .green
        case "indigo": return .indigo
        case "mint": return .mint
        case "orange": return .orange
        case "pink": return .pink
        case "purple": return .purple
        case "red": return .red
        case "teal": return .teal
        case "yellow": return .yellow
        default: return nil
        }
    }
}
