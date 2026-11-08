//
//  V2AllProfilesSheet.swift
//  Conduit
//
//  Which profiles the Chats list's All view shows, and whether it groups
//  them. Opened by tapping the selected All chip, the way the selected
//  profile's chip opens Profiles.
//

import SwiftUI

struct V2AllProfilesSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// Profiles: Current only hides the chips, so this sheet is the only
    /// control the bar has left and needs its own way back to one profile.
    @AppStorage(V2SessionsBarPreferences.Profiles.key) private var profilesPreference = V2SessionsBarPreferences.Profiles.defaultValue

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop(glowTint: appState.profileGlowTint(appState.activeProfile))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(AppLocalization.string("All lists these profiles' chats together, newest first. A new chat asks which profile to use."))
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        if profilesPreference == .currentOnly {
                            showOnlyProfileButton
                        }

                        VStack(spacing: 0) {
                            ForEach(appState.profiles, id: \.self) { profile in
                                profileToggle(profile)
                                if profile != appState.profiles.last {
                                    Divider().padding(.leading, 56)
                                }
                            }
                        }
                        .settingsCard()

                        Toggle(isOn: Binding(
                            get: { appState.allProfilesChats.groupsByProfile },
                            set: { grouped in
                                Haptics.selection()
                                appState.setAllProfilesGroupsByProfile(grouped)
                            }
                        )) {
                            Label(AppLocalization.string("Group by profile"), systemImage: "rectangle.stack")
                                .scaledFont(.body)
                        }
                        .tint(.conduitAccent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 52)
                        .settingsCard()
                    }
                    .padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: AppLocalization.string("Show in All"), close: { dismiss() })
            }
        }
    }

    /// Current only leaves one chip, and while All is on it opens this sheet:
    /// the way back to a single profile has to be here, or only the
    /// Appearance preference could leave All. With the chips drawn they do
    /// this themselves, so the row stays out of the default sheet.
    private var showOnlyProfileButton: some View {
        let name = appState.profileDisplayName(appState.activeProfile)
        return Button {
            Haptics.selection()
            appState.setAllProfilesChatsOn(false)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22))
                    .conduitFixedGlyph()
                    .foregroundStyle(Color.conduitAccent)
                    .frame(width: 30, height: 30)
                Text(AppLocalization.string("Show only \(name)"))
                    .scaledFont(.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .settingsCard()
    }

    /// The last profile left in can't be turned off: All never lists
    /// nothing.
    private func profileToggle(_ profile: String) -> some View {
        let included = appState.allProfilesIncluded
        let isIncluded = included.contains(profile)
        let name = appState.profileDisplayName(profile)
        return Toggle(isOn: Binding(
            get: { isIncluded },
            set: { on in
                Haptics.selection()
                appState.setProfile(profile, includedInAll: on)
            }
        )) {
            HStack(spacing: 12) {
                ProfileAvatarView(
                    profile: profile,
                    displayName: name,
                    url: appState.profileAvatarURL(for: profile),
                    size: 30
                )
                Text(name)
                    .scaledFont(.body)
                    .lineLimit(1)
            }
        }
        .tint(.conduitAccent)
        .disabled(isIncluded && included.count == 1)
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .accessibilityLabel(AppLocalization.string("\(name) profile"))
    }
}
