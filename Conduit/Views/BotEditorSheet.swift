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
    @State private var error: String?
    @State private var showingImagePicker = false
    @State private var pickedImage: UIImage?
    @State private var seeded = false
    @State private var showsAdvanced = false
    /// The gateway's message for a model pick it wants confirmed.
    @State private var modelConfirmation: String?
    @State private var capabilitiesLoadFailed = false
    /// The Start From profile the staged lists were read from.
    @State private var capabilitiesSource: String?

    private enum DetailsState {
        case idle, loading, loaded, failed
    }

    private var editedBot: BotProfile? {
        if case .edit(let bot) = mode { return bot }
        return nil
    }

    private var isCreating: Bool { editedBot == nil }

    var body: some View {
        NavigationStack {
            Form {
                if let error, !error.isEmpty {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    avatarHeader
                }
                .listRowBackground(Color.clear)
                colorSection
                nameSection
                Section {
                    TextField(
                        AppLocalization.string("What this bot is for"),
                        text: $draft.description,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                } header: {
                    Text(AppLocalization.string("Description"))
                }
                personalitySection
                advancedSection
            }
            .navigationTitle(isCreating ? AppLocalization.string("New Bot") : AppLocalization.string("Edit Bot"))
            .navigationBarTitleDisplayMode(.inline)
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
            AppLocalization.string("Use This Model?"),
            isPresented: Binding(
                get: { modelConfirmation != nil },
                set: { if !$0 { modelConfirmation = nil } }
            ),
            presenting: modelConfirmation
        ) { _ in
            Button(AppLocalization.string("Use Anyway")) { confirmModel() }
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
        .onChange(of: pickedImage) { _, image in
            guard let image else { return }
            if let png = BotAvatarImage.normalizedPNG(from: image) {
                draft.newAvatarPNG = png
                draft.removesAvatar = false
                error = nil
            } else {
                error = AppLocalization.string("That picture could not be used.")
            }
            pickedImage = nil
        }
        .task { await seed() }
        .task(id: capabilitySource) { await loadStartFromCapabilities() }
        .task {
            // The stored picture, independent of whether the roster row's
            // fetch succeeded.
            if let bot = editedBot { await appState.loadBotAvatarRetrying(bot) }
        }
    }

    // MARK: Sections

    private var avatarHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                BotAvatarView(
                    name: avatarName,
                    label: avatarLabel,
                    colorString: draft.color,
                    image: previewImage,
                    size: 88
                )
            }
            // The avatar itself is decorative everywhere else; here it is the
            // only sign of whether the bot will have a picture.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(AppLocalization.string("Picture")))
            .accessibilityValue(Text(pictureStateDescription))
            AdaptiveStack(spacing: 12) {
                Button {
                    Haptics.light()
                    showingImagePicker = true
                } label: {
                    Label(AppLocalization.string("Choose Photo"), systemImage: "photo")
                }
                .buttonStyle(.bordered)
                if previewImage != nil || (hasStoredAvatar && !draft.removesAvatar) {
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
                    .buttonStyle(.bordered)
                } else if draft.removesAvatar {
                    Button {
                        Haptics.light()
                        draft.removesAvatar = false
                    } label: {
                        Label(AppLocalization.string("Keep Photo"), systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var pictureStateDescription: String {
        if draft.newAvatarPNG != nil {
            return AppLocalization.string("New photo chosen")
        }
        if draft.removesAvatar {
            return AppLocalization.string("Photo will be removed")
        }
        return hasStoredAvatar ? AppLocalization.string("Photo set") : AppLocalization.string("No photo")
    }

    private var colorSection: some View {
        let names = swatchNames
        return Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 8) {
                swatch(nil, name: AppLocalization.string("Automatic color"))
                ForEach(Array(BotAvatarColor.swatches.enumerated()), id: \.element) { item in
                    swatch(
                        item.element,
                        name: names.indices.contains(item.offset) ? names[item.offset] : AppLocalization.string("Color")
                    )
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(AppLocalization.string("Color"))
        } footer: {
            Text(AppLocalization.string("Shown behind the bot's initial when it has no picture."))
        }
    }

    /// VoiceOver names for `BotAvatarColor.swatches`, in hue order (0°, 30°, …).
    /// Resolved once per render of the grid so a language change applies
    /// immediately.
    private var swatchNames: [String] {
        [
            AppLocalization.string("Red"),
            AppLocalization.string("Orange"),
            AppLocalization.string("Yellow"),
            AppLocalization.string("Lime"),
            AppLocalization.string("Green"),
            AppLocalization.string("Mint"),
            AppLocalization.string("Cyan"),
            AppLocalization.string("Sky Blue"),
            AppLocalization.string("Blue"),
            AppLocalization.string("Purple"),
            AppLocalization.string("Magenta"),
            AppLocalization.string("Pink")
        ]
    }

    private func swatch(_ value: String?, name: String) -> some View {
        let isSelected = draft.color == value
        return Button {
            Haptics.light()
            draft.color = value
        } label: {
            ZStack {
                Circle()
                    .fill(BotAvatarView.color(for: value, name: avatarName))
                if value == nil {
                    // Fixed size: it fills a fixed-size colour swatch.
                    Text(AppLocalization.string("Auto"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 32, height: 32)
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
            Section {
                TextField(bot.displayName.isEmpty ? bot.name : bot.displayName, text: $draft.name)
                    .textInputAutocapitalization(.words)
            } header: {
                Text(AppLocalization.string("Display Name"))
            } footer: {
                Text(AppLocalization.string("Profile ID: \(bot.name)"))
            }
        } else {
            Section {
                TextField(AppLocalization.string("Name"), text: $draft.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            } header: {
                Text(AppLocalization.string("Name"))
            } footer: {
                createNameFooter
            }
        }
    }

    @ViewBuilder
    private var createNameFooter: some View {
        let identity = appState.newBotSlug(for: draft.name)
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(AppLocalization.string("The bot gets its own Hermes profile, chat, memory and skills."))
        } else if !identity.isValid {
            Text(AppLocalization.string("Use at least one letter or number."))
                .foregroundStyle(.red)
        } else if identity.isTaken {
            Text(AppLocalization.string("A profile named \(identity.slug) already exists."))
                .foregroundStyle(.red)
        } else {
            Text(AppLocalization.string("Profile ID: \(identity.slug)"))
        }
    }

    @ViewBuilder
    private var personalitySection: some View {
        Section {
            if isCreating || detailsState == .loaded {
                TextEditor(text: $draft.soul)
                    .frame(minHeight: 160)
                    .font(.callout.monospaced())
            } else if detailsState == .failed {
                Text(AppLocalization.string("Could not load this bot's personality."))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text(AppLocalization.string("Personality"))
        } footer: {
            Text(isCreating
                ? AppLocalization.string("Optional. Leave empty to start from a short identity built from the name and description.")
                : AppLocalization.string("Saved as the bot's SOUL.md."))
        }
    }

    /// Desktop's Advanced disclosure. Creating: where the profile starts
    /// from, its model, skills, tools and MCP, shared keys and bundled
    /// skills. Editing: its model, skills, tools and MCP, once the bot's
    /// details have loaded.
    @ViewBuilder
    private var advancedSection: some View {
        if isCreating || detailsState == .loaded {
            Section {
                Button {
                    Haptics.light()
                    withAnimation { showsAdvanced.toggle() }
                } label: {
                    HStack {
                        Text(AppLocalization.string("Advanced"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityValue(Text(showsAdvanced ? AppLocalization.string("Shown") : AppLocalization.string("Hidden")))
                if showsAdvanced {
                    if isCreating {
                        Picker(AppLocalization.string("Start From"), selection: $draft.cloneFrom) {
                            Text(AppLocalization.string("Main Profile")).tag(BotCreateRequest.mainProfile)
                            ForEach(cloneSources, id: \.name) { bot in
                                Text(verbatim: bot.displayLabel).tag(bot.name)
                            }
                            Text(AppLocalization.string("Fresh Profile")).tag("")
                        }
                    }
                    NavigationLink {
                        BotModelPicker(provider: $draft.provider, model: $draft.model, allowsInherit: isCreating)
                    } label: {
                        LabeledContent(AppLocalization.string("Model")) {
                            Text(verbatim: BotModelPicker.summary(model: draft.model, allowsInherit: isCreating))
                        }
                    }
                    capabilitiesRow
                    if isCreating {
                        Toggle(AppLocalization.string("Share Keys and Accounts"), isOn: $draft.shareAuth)
                        Toggle(AppLocalization.string("Skip Bundled Skills"), isOn: $draft.noSkills)
                    }
                }
            } footer: {
                if showsAdvanced, isCreating {
                    Text(AppLocalization.string("Shared keys and accounts stay one set with the main profile, so a sign-in refresh in one never signs the other out. Turn it off for a separate copy."))
                }
            }
        }
    }

    @ViewBuilder
    private var capabilitiesRow: some View {
        if draft.capabilities != nil {
            NavigationLink {
                BotCapabilitiesView(
                    capabilities: Binding(
                        get: { draft.capabilities ?? BotCapabilities() },
                        set: { draft.capabilities = $0 }
                    ),
                    skillsSkipped: isCreating && draft.noSkills,
                    sourceLabel: isCreating ? startFromLabel : nil
                )
            } label: {
                Text(AppLocalization.string("Skills, Tools and MCP"))
            }
        } else if capabilitiesLoadFailed {
            Text(AppLocalization.string("Could not load skills, tools or MCP servers."))
                .foregroundStyle(.secondary)
        } else {
            LabeledContent(AppLocalization.string("Skills, Tools and MCP")) {
                ProgressView()
            }
        }
    }

    /// The profile a new bot's skills, tools and MCP lists are read from
    /// while Advanced is open: its Start From profile (the main profile for
    /// a fresh start, as on Desktop). Nil when nothing should load.
    private var capabilitySource: String? {
        guard isCreating, showsAdvanced else { return nil }
        return draft.cloneFrom.isEmpty ? BotCreateRequest.mainProfile : draft.cloneFrom
    }

    private var startFromLabel: String {
        let source = capabilitySource ?? BotCreateRequest.mainProfile
        if BotManagement.isDefaultProfile(source) { return AppLocalization.string("Main Profile") }
        return appState.botRoster.first { $0.name == source }?.displayLabel ?? source
    }

    /// A new Start From pick replaces the staged lists: picks made against
    /// another profile's set don't carry over.
    private func loadStartFromCapabilities() async {
        guard let source = capabilitySource,
              source != capabilitiesSource || draft.capabilities == nil else { return }
        capabilitiesSource = source
        draft.capabilities = nil
        draft.capabilitiesBaseline = nil
        capabilitiesLoadFailed = false
        let loaded = await appState.loadBotCapabilities(startingFrom: source)
        guard !Task.isCancelled else { return }
        if let loaded {
            draft.capabilities = loaded
            draft.capabilitiesBaseline = loaded
        } else {
            capabilitiesSource = nil
            capabilitiesLoadFailed = true
        }
    }

    /// Bots a new one can copy its settings from, besides the main profile.
    private var cloneSources: [BotProfile] {
        appState.botRoster.filter { !BotManagement.isDefaultProfile($0.name) }
    }

    // MARK: State

    private var avatarName: String {
        editedBot?.name ?? appState.newBotSlug(for: draft.name).slug
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

    private var previewImage: UIImage? {
        if let png = draft.newAvatarPNG { return UIImage(data: png) }
        if draft.removesAvatar { return nil }
        return storedImage
    }

    private var canSave: Bool {
        guard !isSaving else { return false }
        // An edit saves only once the editor snapshot settled: before it,
        // the form still holds placeholders that would overwrite the bot.
        guard isCreating else { return detailsState == .loaded || detailsState == .failed }
        let identity = appState.newBotSlug(for: draft.name)
        return identity.isValid && !identity.isTaken
    }

    private func seed() async {
        guard !seeded else { return }
        seeded = true
        guard let bot = editedBot else { return }
        draft.name = bot.botTitle ?? ""
        draft.description = bot.profileDescription
        draft.color = bot.appearanceColor
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
        let draft = self.draft
        Task {
            let result: BotSaveResult
            var createdName: String?
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

/// A bot's face: its picture when it has one, else its initial on its color
/// (the explicit pick, else Desktop's name-derived hue).
struct BotAvatarView: View {
    let name: String
    let label: String
    let colorString: String?
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
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
