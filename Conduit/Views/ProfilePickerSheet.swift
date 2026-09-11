//
//  ProfilePickerSheet.swift
//  Conduit
//

import SwiftUI

struct ProfilePickerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var isReordering = false

    private var visibleProfiles: [String] {
        appState.profiles.isEmpty ? [appState.activeProfile] : appState.profiles
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            Text(isReordering
                                 ? "Use the arrows to choose the order profiles appear throughout Conduit."
                                 : "Sessions and settings follow the active profile. Photos stay only on this device.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button(isReordering ? "Done" : "Reorder") {
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
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: String(localized: "Profiles"), close: { dismiss() })
            }
        }
    }
}

private struct ProfilePickerRow: View {
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
    private var isCurrent: Bool { profile == appState.activeProfile }

    var body: some View {
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
                    Image(systemName: "camera.fill").font(.caption2.weight(.bold)).foregroundStyle(Color.conduitBackgroundColor)
                        .frame(width: 20, height: 20).background(Color.conduitAccent, in: Circle())
                        .overlay { Circle().strokeBorder(.background, lineWidth: 1) }
                }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose photo for \(appState.profileDisplayName(profile))")
                }
            }

            Button(action: select) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(appState.profileDisplayName(profile)).font(.headline).foregroundStyle(.primary)
                    Text(profile == "default" ? String(localized: "Primary Hermes profile") : String(localized: "Hermes profile")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(isCurrent || appState.isProfileSwitching || isReordering)

            if isReordering {
                VStack(spacing: 0) {
                    Button(action: moveEarlier) {
                        Image(systemName: "chevron.up").font(.caption.weight(.bold)).frame(width: 34, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveEarlier)
                    .accessibilityLabel("Move \(appState.profileDisplayName(profile)) earlier")
                    Button(action: moveLater) {
                        Image(systemName: "chevron.down").font(.caption.weight(.bold)).frame(width: 34, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveLater)
                    .accessibilityLabel("Move \(appState.profileDisplayName(profile)) later")
                }
            } else if isCurrent {
                Label("Current", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.conduitAccent)
            } else {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if !isReordering, appState.profileAvatarURL(for: profile) != nil {
                Button(role: .destructive) {
                    Haptics.warning()
                    appState.removeProfileAvatar(for: profile)
                } label: {
                    Image(systemName: "trash").font(.caption.weight(.semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove photo for \(appState.profileDisplayName(profile))")
            }
        }
        .padding(12)
        .conduitGlassSurface(cornerRadius: 20, tint: isCurrent ? .conduitAccent.opacity(0.12) : .clear)
        .overlay(alignment: .bottomLeading) {
            if let saveError { Text(saveError).font(.caption2).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 4) }
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(image: $pickedImage)
        }
        .onChange(of: pickedImage) { _, newImage in
            guard let newImage else { return }
            if let data = newImage.pngData() {
                do {
                    try appState.saveProfileAvatar(data, for: profile)
                    saveError = nil
                } catch { saveError = error.localizedDescription }
            }
            pickedImage = nil
        }
    }
}

struct ProfileAvatarView: View {
    let profile: String
    let displayName: String
    let url: URL?
    var size: CGFloat = 30
    private var initials: String {
        let letters = displayName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "H" : String(letters).uppercased()
    }
    var body: some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
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
