import SwiftUI

/// Generate Picture: Hermes' own image generation (`image.generate`) makes
/// a bot's or a group chat's picture, from the user's description or, left
/// empty, from the name. Each Generate adds one picture; the user picks one
/// and taps Use (upstream `avatar-picker.tsx` Generate tab).
struct GeneratePictureSheet: View {
    /// The prompt an empty description uses.
    let defaultPrompt: String
    let forGroup: Bool
    let onUse: (UIImage) -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var description = ""
    @State private var pictures: [GeneratedPicture] = []
    @State private var selection: UUID?
    @State private var generation: Task<Void, Never>?
    @State private var error: String?

    private static let maxPictures = 8

    private struct GeneratedPicture: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private var isGenerating: Bool { generation != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        AppLocalization.string("A friendly fox with a tiny backpack"),
                        text: $description,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                } header: {
                    Text(AppLocalization.string("Describe It (Optional)"))
                } footer: {
                    Text(forGroup
                        ? AppLocalization.string("Leave empty to use the group's name and members.")
                        : AppLocalization.string("Leave empty to use the bot's name and description."))
                }
                Section {
                    Button(action: generate) {
                        HStack(spacing: 8) {
                            if isGenerating {
                                ProgressView()
                            } else {
                                Image(systemName: "sparkles")
                                    .accessibilityHidden(true)
                            }
                            Text(isGenerating
                                ? AppLocalization.string("Generating…")
                                : AppLocalization.string("Generate"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isGenerating)
                } footer: {
                    Text(AppLocalization.string("A picture can take a minute or more. Each tap of Generate adds one; pick one, then tap Use."))
                }
                if let error {
                    Section {
                        Text(error)
                            .scaledFont(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                if !pictures.isEmpty {
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12)], spacing: 12) {
                            ForEach(Array(pictures.enumerated()), id: \.element.id) { index, picture in
                                pictureButton(picture, number: index + 1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(AppLocalization.string("Generate Picture"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Use")) {
                        guard let picked = pictures.first(where: { $0.id == selection }) else { return }
                        Haptics.success()
                        onUse(picked.image)
                        dismiss()
                    }
                    .disabled(selection == nil)
                }
            }
            .onDisappear { generation?.cancel() }
        }
    }

    private func pictureButton(_ picture: GeneratedPicture, number: Int) -> some View {
        let isSelected = picture.id == selection
        return Button {
            Haptics.selection()
            selection = picture.id
        } label: {
            Image(uiImage: picture.image)
                .resizable()
                .scaledToFill()
                .frame(width: 88, height: 88)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(isSelected ? Color.conduitAccent : Color.clear, lineWidth: 3)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(AppLocalization.string("Generated picture \(String(number)) of \(String(pictures.count))")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func generate() {
        guard generation == nil else { return }
        Haptics.light()
        error = nil
        let prompt = PictureGeneration.customPrompt(description, forGroup: forGroup) ?? defaultPrompt
        generation = Task {
            defer { generation = nil }
            do {
                let image = try await appState.generatePicture(prompt: prompt)
                guard !Task.isCancelled else { return }
                let picture = GeneratedPicture(image: image)
                pictures.append(picture)
                // Full-size pictures add up: keep the newest few.
                if pictures.count > Self.maxPictures { pictures.removeFirst(pictures.count - Self.maxPictures) }
                selection = picture.id
                Haptics.success()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                Haptics.warning()
            }
        }
    }
}
