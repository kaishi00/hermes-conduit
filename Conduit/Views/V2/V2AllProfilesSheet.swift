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

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop(glowTint: appState.profileGlowTint(appState.activeProfile))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(AppLocalization.string("All lists these profiles' chats together, newest first. A new chat asks which profile to use."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

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
                                .font(.body)
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
                    .font(.body)
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
