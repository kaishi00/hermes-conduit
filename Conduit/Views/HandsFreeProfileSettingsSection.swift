//
//  HandsFreeProfileSettingsSection.swift
//  Conduit
//
//  Settings > Voice > Watch and Siri calls (#1564): the profile a call
//  started away from the iPhone's screen runs on. Saved on this device for
//  the dashboard in use, whichever profile's voice settings are open.
//

import SwiftUI

@MainActor
struct HandsFreeProfileSettingsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject private var appState = AppStateRuntimeRegistry.shared.appState

    var body: some View {
        // One profile has nothing to choose between.
        if appState.profiles.count > 1 {
            ConduitSettingsSection(title: AppLocalization.string("Watch and Siri calls"), symbol: "applewatch.radiowaves.left.and.right", tint: .conduitAura) {
                ConduitMenuPicker(
                    value: chosen,
                    choices: [(id: "", title: AppLocalization.string("Profile open on iPhone"))]
                        + appState.profiles.map { (id: $0, title: appState.profileDisplayName($0)) },
                    onSelect: { appState.setHandsFreeProfileChoice($0.isEmpty ? nil : $0) }
                ) {
                    Text("Profile").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("voice.handsFreeProfile")
                Text(caption)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The choice as the picker lists it: "" follows the iPhone, as does a
    /// profile this dashboard no longer has.
    private var chosen: String {
        guard let choice = appState.handsFreeProfileChoice else { return "" }
        return appState.profiles.first { AppState.profilesMatch($0, choice) } ?? ""
    }

    private var caption: String {
        if chosen.isEmpty {
            return AppLocalization.string("Calls from your Apple Watch, and from Siri or the Action button when the shortcut names no profile, use the profile open on your iPhone.")
        }
        let name = appState.profileDisplayName(chosen)
        return AppLocalization.string("Calls from your Apple Watch, and from Siri or the Action button when the shortcut names no profile, use \(name). A Watch call doesn't switch your iPhone's profile; a Siri call does. Answering a call from Hermes keeps that call's profile.")
    }
}
