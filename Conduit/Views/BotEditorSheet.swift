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
    /// a create) and any best-effort part that did not save.
    let onFinished: (_ createdBotName: String?, _ warning: String?) -> Void

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
        .interactiveDismissDisabled(isSaving)
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
    }

    // MARK: Sections

    private var avatarHeader: some View {
        VStack(spacing: 12) {
            BotAvatarView(
                name: avatarName,
                label: avatarLabel,
                colorString: draft.color,
                image: previewImage,
                size: 88
            )
            HStack(spacing: 12) {
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
                }
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var colorSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 8) {
                swatch(nil, name: AppLocalization.string("Automatic color"))
                ForEach(Array(BotAvatarColor.swatches.enumerated()), id: \.element) { item in
                    swatch(item.element, name: swatchName(item.offset))
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
    /// Resolved per render so a language change applies immediately.
    private func swatchName(_ index: Int) -> String {
        let names = [
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
        return names.indices.contains(index) ? names[index] : AppLocalization.string("Color")
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
            case .saved(let warning):
                Haptics.success()
                dismiss()
                onFinished(createdName, warning)
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
