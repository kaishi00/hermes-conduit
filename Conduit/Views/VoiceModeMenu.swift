//
//  VoiceModeMenu.swift
//  Conduit
//
//  The voice mode menu on the call screens: every mode Voice settings
//  lists, the call's own ticked. Picking another saves it as the profile's
//  mode and moves the call to it, in the same chat.
//

import SwiftUI

struct VoiceModeMenu<Face: View>: View {
    let modeSwitch: VoiceModeSwitch
    @ViewBuilder let face: () -> Face

    var body: some View {
        Menu {
            Section(AppLocalization.string("Voice mode")) {
                ForEach(VoiceModeChoice.allCases) { choice in
                    Button {
                        // The call's own mode carries on as it is.
                        guard modeSwitch.moves(to: choice) else { return }
                        modeSwitch.select(choice)
                    } label: {
                        if choice == modeSwitch.current {
                            Label(choice.title, systemImage: "checkmark")
                        } else {
                            Text(verbatim: choice.title)
                        }
                    }
                    .accessibilityAddTraits(choice == modeSwitch.current ? .isSelected : [])
                }
            }
        } label: {
            face()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityHint(Text(verbatim: AppLocalization.string("Ends this call and starts again in the mode you pick, in the same chat. Voice settings keep the new mode.")))
    }
}

/// The mode menu under a call's title: the mode's name and a chevron in a
/// small glass capsule.
struct VoiceModeCapsule: View {
    let modeSwitch: VoiceModeSwitch

    var body: some View {
        VoiceModeMenu(modeSwitch: modeSwitch) {
            HStack(spacing: 4) {
                Text(verbatim: modeSwitch.current.title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .scaledFont(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            .scaledFont(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .conduitGlassControl(cornerRadius: 14)
            // A 44 pt tap target without moving the header.
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .padding(.vertical, -6)
        }
        .accessibilityLabel(Text(verbatim: AppLocalization.string("Voice mode")))
        .accessibilityValue(Text(verbatim: modeSwitch.current.title))
    }
}
