import SwiftUI

struct ProfileAvatarPickerSheet: View {
    let profile: String
    let displayName: String
    let photoURL: URL?
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentAvatarSelection
    @State private var pickedImage: UIImage?
    @State private var showsPhotos = false
    @State private var previewState: AgentAvatarState = .idle
    @State private var showsAnimations = false
    @State private var saveError: String?

    init(profile: String, displayName: String, photoURL: URL?) {
        self.profile = profile
        self.displayName = displayName
        self.photoURL = photoURL
        _draft = State(initialValue: AgentAvatarSelectionStore.load(for: profile)
                       ?? AgentAvatarSelection(character: nil, usesPhoto: photoURL != nil))
    }

    private var appearance: AgentAvatarAppearance {
        draft.character ?? .generated(for: profile)
    }
    private var palette: AgentAvatarIdentity.Palette {
        AgentAvatarIdentity.palette(for: appearance.color.paletteSeed)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(spacing: 12) {
                        AgentAvatar(profileID: profile, displayName: displayName, photoURL: photoURL,
                                    size: 132, state: previewState, selection: draft, previewImage: pickedImage)
                            .accessibilityIdentifier("avatar.preview")
                        Text(displayName).font(.title3.weight(.semibold))
                        Text("A familiar face, made yours.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(24)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))

                    Picker("Avatar style", selection: $draft.usesPhoto) {
                        Text("Character").tag(false)
                        Text("Photo").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("avatar.style")

                    if draft.usesPhoto {
                        VStack(alignment: .leading, spacing: 12) {
                            Button { showsPhotos = true } label: {
                                Label(pickedImage != nil || photoURL != nil ? "Change photo" : "Choose a photo", systemImage: "photo.on.rectangle.angled")
                                    .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(16)
                            }
                            .buttonStyle(.bordered).accessibilityIdentifier("avatar.photo")
                            Text("Choose and crop a photo from your library. It stays on this device.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        characterOptions
                        colorOptions
                        accessoryOptions
                    }

                    DisclosureGroup("Preview animations", isExpanded: $showsAnimations) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                            ForEach(AgentAvatarState.allCases, id: \.self) { state in
                                option(state.label, selected: previewState == state) { previewState = state }
                                    .accessibilityIdentifier("avatar.state.\(state.rawValue)")
                            }
                        }.padding(.top, 12)
                        Text("Your bot’s activity controls these expressions in the app.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("avatar.animations")

                    Button("Reset to default") {
                        draft = AgentAvatarSelection(character: nil, usesPhoto: false)
                        pickedImage = nil
                        previewState = .idle
                    }
                    .font(.subheadline).accessibilityIdentifier("avatar.reset")
                    Text("Avatar choices stay on this device. Changes apply when you save.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Choose avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("avatar.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold)
                        .disabled(draft.usesPhoto && pickedImage == nil && photoURL == nil)
                        .accessibilityIdentifier("avatar.save")
                }
            }
            .sheet(isPresented: $showsPhotos) { ImagePicker(image: $pickedImage) }
            .alert("Couldn’t save avatar", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "Please try again.") }
        }
    }

    private var characterOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Character")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                ForEach(AgentCharacterKind.allCases, id: \.self) { shape in
                    let choice = AgentAvatarAppearance(shape: shape, color: appearance.color, accessory: appearance.accessory)
                    Button { draft.character = choice } label: {
                        VStack(spacing: 7) {
                            AgentAvatar(profileID: profile, displayName: shape.label, photoURL: nil, size: 56,
                                        animates: false, selection: AgentAvatarSelection(character: choice))
                                .accessibilityHidden(true)
                            Text(shape.label).font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(appearance.shape == shape ? palette.fill : .clear, lineWidth: 2) }
                    }
                    .buttonStyle(.plain).accessibilityLabel(shape.label)
                    .accessibilityAddTraits(appearance.shape == shape ? .isSelected : [])
                    .accessibilityIdentifier("avatar.shape.\(shape.rawValue)")
                }
            }
        }
    }

    private var colorOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Color")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                ForEach(AgentAvatarColor.allCases, id: \.self) { color in
                    Button {
                        var next = appearance; next.color = color; draft.character = next
                    } label: {
                        Circle().fill(AgentAvatarIdentity.palette(for: color.paletteSeed).fill.gradient)
                            .frame(width: 38, height: 38)
                            .overlay {
                                if appearance.color == color {
                                    Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(color.label)
                    .accessibilityAddTraits(appearance.color == color ? .isSelected : [])
                    .accessibilityIdentifier("avatar.color.\(color.rawValue)")
                }
            }
        }
    }

    private var accessoryOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Accessory")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
                ForEach(AgentCharacterAccessoryKind.allCases, id: \.self) { accessory in
                    option(accessory.label, selected: appearance.accessory == accessory) {
                        var next = appearance; next.accessory = accessory; draft.character = next
                    }.accessibilityIdentifier("avatar.accessory.\(accessory.rawValue)")
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
            }
            .font(.caption.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? palette.fill : Color.primary.opacity(0.06), in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        do {
            if draft.usesPhoto, let pickedImage {
                guard let data = pickedImage.jpegData(compressionQuality: 0.9) else { throw ProfileAppearanceError.invalidImage }
                try appState.saveProfileAvatar(data, for: profile)
                draft.photoRevision = UUID()
            }
            try AgentAvatarSelectionStore.save(draft, for: profile)
            Haptics.selection()
            dismiss()
        } catch { saveError = error.localizedDescription }
    }
}

extension AgentCharacterKind {
    var label: String {
        switch self {
        case .roundBlob: return "Blob"
        case .tallOval: return "Oval"
        case .softSquare: return "Pebble"
        case .diamond: return "Kite"
        case .bean: return "Bean"
        case .petal: return "Petal"
        }
    }
}

extension AgentCharacterAccessoryKind {
    var label: String {
        switch self {
        case .none: return "None"
        case .ear: return "Ear"
        case .hat: return "Hat"
        case .cheekDot: return "Blush"
        }
    }
}
