//
//  ProfilePickerSheet.swift
//  Conduit
//

import SwiftUI

struct ProfilePickerSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var isReordering = false

    private var visibleProfiles: [String] {
        appState.profiles.isEmpty ? [appState.activeProfile] : appState.profiles
    }

    private var photosFootnote: String {
        appState.profilePhotosLiveOnHermes
            ? AppLocalization.string("Sessions and settings follow the active profile. Photos are saved to Hermes, so bots and Hermes Desktop show them too.")
            : AppLocalization.string("Sessions and settings follow the active profile. Photos stay only on this device.")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Shows the active profile's glow, so a picked color is seen
                // as it is picked.
                ConduitBackdrop(glowTint: appState.profileGlowTint(appState.activeProfile))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            Text(isReordering
                                 ? AppLocalization.string("Use the arrows to choose the order profiles appear throughout Conduit.")
                                 : photosFootnote)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button(isReordering ? AppLocalization.string("Done") : AppLocalization.string("Reorder")) {
                                Haptics.selection()
                                withAnimation(ConduitMotion.response) { isReordering.toggle() }
                            }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .conduitGlassControl(cornerRadius: 12, tint: .conduitAccent.opacity(0.08))
                        }
                        .padding(.horizontal, 4)

                        ForEach(Array(visibleProfiles.enumerated()), id: \.element) { index, profile in
                            ProfilePickerRow(
                                profile: profile,
                                isReordering: isReordering,
                                canMoveEarlier: index > 0,
                                canMoveLater: index < visibleProfiles.count - 1,
                                moveEarlier: {
                                    Haptics.selection()
                                    appState.moveProfile(from: index, to: index - 1)
                                },
                                moveLater: {
                                    Haptics.selection()
                                    appState.moveProfile(from: index, to: index + 1)
                                }
                            ) {
                                Haptics.medium()
                                Task { await appState.switchProfile(to: profile); dismiss() }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            // Photos are Hermes pictures: re-read them, since Desktop or
            // another device may have changed one.
            .task { await appState.reloadBotRoster() }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: AppLocalization.string("Profiles"), close: { dismiss() })
            }
        }
    }
}

/// One profile card. Selection covers the whole card — see the selection
/// surface on the body for why, and for the accessibility split between the
/// card and its nested controls.
///
/// Covered by `ConduitUITests/ProfilePickerUITests`: the picker is reached with
/// the DEBUG-only `-CONDUIT_UI_TEST_CONNECTED_DASHBOARD` stub plus the
/// `-CONDUIT_UI_TEST_PROFILES` roster seam in `AppState.uiTestSeededProfiles()`,
/// which seeds through the same `orderedProfiles` a real `/api/profiles`
/// discovery uses.
private struct ProfilePickerRow: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let profile: String
    let isReordering: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let moveEarlier: () -> Void
    let moveLater: () -> Void
    let select: () -> Void
    @State private var showingImagePicker = false
    @State private var pickedImage: UIImage?
    @State private var saveError: String?
    @State private var isSavingPhoto = false
    private var isCurrent: Bool { profile == appState.activeProfile }
    /// One rule for both selection paths: the text column's button and the
    /// card-sized selection surface behind the row must agree on when a
    /// profile can be selected.
    private var canSelect: Bool {
        !isCurrent && !appState.isProfileSwitching && !isReordering
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            profileLine
            if !isReordering { glowLine }
            if let saveError {
                Text(saveError).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(12)
        // The card's empty area selects the profile. The selection surface has
        // to be a card-sized button BEHIND the row, not a container
        // `.onTapGesture`: a gesture on an ancestor also recognizes taps that
        // land on the nested controls, so tapping the avatar or the
        // photo-removal button would switch profiles (and dismiss the sheet)
        // as well as running its own action. As a sibling behind the row it is
        // reached only where nothing interactive sits above it — the padding,
        // the trailing accessory column, and the space beside the name — and
        // the nested controls keep every tap that lands on them.
        //
        // Accessibility stays on the inner select button, which VoiceOver
        // already exposes with the profile name and the `canSelect` disabled
        // state; this surface is hidden to avoid a duplicate target. The
        // Kanban card's `.accessibilityElement(children: .combine)` treatment
        // is wrong here for the same reason the gesture is — this row carries
        // further controls (photo, removal, glow color) that combining would
        // fold into the card.
        .background {
            Button(action: select) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.clear)
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSelect)
            .accessibilityHidden(true)
        }
        .conduitGlassSurface(cornerRadius: 20, tint: isCurrent ? .conduitAccent.opacity(0.12) : .clear)
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(image: $pickedImage)
        }
        .onChange(of: pickedImage) { _, newImage in
            guard let newImage else { return }
            pickedImage = nil
            savePhoto(newImage)
        }
    }

    private var profileLine: some View {
        HStack(spacing: 12) {
            Group {
                if isReordering {
                    ProfileAvatarView(profile: profile, displayName: appState.profileDisplayName(profile), url: appState.profileAvatarURL(for: profile), size: 48)
                } else {
                    Button {
                        Haptics.selection()
                        showingImagePicker = true
                    } label: {
                ZStack(alignment: .bottomTrailing) {
                    ProfileAvatarView(profile: profile, displayName: appState.profileDisplayName(profile), url: appState.profileAvatarURL(for: profile), size: 48)
                        .overlay {
                            if isSavingPhoto {
                                ProgressView().frame(width: 48, height: 48).background(.ultraThinMaterial, in: Circle())
                            }
                        }
                    Image(systemName: "camera.fill").font(.caption2.weight(.bold)).foregroundStyle(Color.conduitBackgroundColor)
                        .frame(width: 20, height: 20).background(Color.conduitAccent, in: Circle())
                        .overlay { Circle().strokeBorder(.background, lineWidth: 1) }
                }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSavingPhoto)
                    .accessibilityLabel("Choose photo for \(appState.profileDisplayName(profile))")
                    .accessibilityValue(isSavingPhoto ? AppLocalization.string("Saving…") : "")
                }
            }

            Button(action: select) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(appState.profileDisplayName(profile)).font(.headline).foregroundStyle(.primary)
                    Text(profile == "default" ? AppLocalization.string("Primary Hermes profile") : AppLocalization.string("Hermes profile")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!canSelect)

            if isReordering {
                HStack(spacing: 2) {
                    reorderArrow("chevron.up", enabled: canMoveEarlier, action: moveEarlier)
                        .accessibilityLabel("Move \(appState.profileDisplayName(profile)) earlier")
                    reorderArrow("chevron.down", enabled: canMoveLater, action: moveLater)
                        .accessibilityLabel("Move \(appState.profileDisplayName(profile)) later")
                }
            } else if isCurrent {
                Label("Current", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.conduitAccent)
            } else {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.conduitTertiary)
            }
            if !isReordering, appState.profileAvatarURL(for: profile) != nil {
                Button(role: .destructive) {
                    Haptics.warning()
                    savePhoto(nil)
                } label: {
                    Image(systemName: "trash").font(.caption.weight(.semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(isSavingPhoto)
                .accessibilityLabel("Remove photo for \(appState.profileDisplayName(profile))")
            }
        }
    }

    /// The backdrop glow for this profile: drawn from its photo until a
    /// color is picked here; Automatic goes back to the photo's color.
    private var glowLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(AppLocalization.string("Background glow"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            if appState.profileGlowPicks[profile] != nil {
                Button(AppLocalization.string("Automatic")) {
                    Haptics.selection()
                    appState.setProfileGlowColor(nil, for: profile)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.conduitAccent)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Automatic background glow for \(appState.profileDisplayName(profile))")
            }
            ColorPicker(selection: glowColor, supportsOpacity: false) {
                Text(AppLocalization.string("Background glow"))
            }
            .labelsHidden()
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Background glow for \(appState.profileDisplayName(profile))")
            .accessibilityIdentifier("profile-glow-color-\(profile)")
        }
        // Lines up with the name, past the 48 pt avatar.
        .padding(.leading, 60)
    }

    private var glowColor: Binding<Color> {
        Binding(
            get: { appState.profileGlowTint(profile) ?? Color.conduitAccent },
            set: { color in
                guard let picked = ProfileGlowRGB(UIColor(color)) else { return }
                appState.setProfileGlowColor(picked, for: profile)
            }
        )
    }

    /// Nil removes the photo.
    private func savePhoto(_ image: UIImage?) {
        isSavingPhoto = true
        saveError = nil
        Task {
            saveError = await appState.setProfilePhoto(image, for: profile)
            isSavingPhoto = false
            if let saveError {
                UIAccessibility.post(notification: .announcement, argument: saveError)
            }
        }
    }

    /// A reorder arrow with a full 44 pt tap target (#552). A `.plain` button
    /// hit-tests only its label's drawn content, so without the content shape
    /// just the small chevron glyph took taps; the space around it fell to the
    /// disabled text button and the disabled selection surface behind the row,
    /// which swallow taps, and the arrows looked dead on device.
    private func reorderArrow(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.conduitAccent)
                .frame(width: 34, height: 34)
                .background(Color.conduitAccent.opacity(0.12), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

struct ProfileAvatarView: View {
    let profile: String
    let displayName: String
    let url: URL?
    /// The one face size every identity mark in a transcript draws at; the
    /// transcript's bot face sizes itself to it.
    static let defaultSize: CGFloat = 30
    var size: CGFloat = ProfileAvatarView.defaultSize
    private var initials: String {
        let letters = displayName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "H" : String(letters).uppercased()
    }
    var body: some View {
        Group {
            if let url, let image = ProfileAvatarImageCache.image(at: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
                    // Always beside the profile's name, or inside a labelled button.
                    .accessibilityHidden(true)
            } else {
                Text(initials).font(.system(size: max(10, size * 0.36), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.conduitAccent).frame(width: size, height: size)
                    .background(Color.conduitAccent.opacity(0.17))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(Color.conduitAccent.opacity(0.28), lineWidth: 1) }
    }
}
