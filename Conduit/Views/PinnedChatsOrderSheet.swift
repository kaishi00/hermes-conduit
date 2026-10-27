//
//  PinnedChatsOrderSheet.swift
//  Conduit
//
//  Reorder pinned chats (issue 1354): a profile's pinned chats with drag
//  handles, from a pinned chat's touch-and-hold menu or the Pinned header.
//  It moves nothing else, so it can't catch a swipe or the menu, and it is
//  the way to reorder with VoiceOver and in the classic drawer.
//

import SwiftUI

/// Which profile's pinned chats the sheet orders.
struct PinnedChatsOrderTarget: Identifiable, Equatable {
    let profile: String
    var id: String { profile }
}

struct PinnedChatsOrderSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .active
    let profile: String

    var body: some View {
        let chats = appState.pinnedChatsForOrdering(profile: profile)
        NavigationStack {
            List {
                Section {
                    ForEach(Array(chats.enumerated()), id: \.element.id) { index, session in
                        Label(session.title, systemImage: appState.sessionCategory(for: session).iconName)
                            .lineLimit(2)
                            .accessibilityActions {
                                if index > 0 {
                                    Button(AppLocalization.string("Move up")) {
                                        appState.movePinnedChats(chats, fromOffsets: [index], toOffset: index - 1)
                                    }
                                }
                                if index < chats.count - 1 {
                                    Button(AppLocalization.string("Move down")) {
                                        appState.movePinnedChats(chats, fromOffsets: [index], toOffset: index + 2)
                                    }
                                }
                            }
                    }
                    .onMove { source, destination in
                        appState.movePinnedChats(chats, fromOffsets: source, toOffset: destination)
                    }
                } footer: {
                    Text(AppLocalization.string("Drag chats into the order you want. A chat you pin next goes on top."))
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(AppLocalization.string("Reorder pinned chats"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

extension View {
    /// A Pinned header's touch-and-hold menu and VoiceOver action, which
    /// open Reorder pinned chats while there are pins to put in order.
    @ViewBuilder
    func reorderPinnedChatsMenu(isOn: Bool, open: @escaping () -> Void) -> some View {
        if isOn {
            contextMenu {
                Button {
                    Haptics.selection()
                    // Next turn, as Rename: the sheet waits for the menu to close.
                    DispatchQueue.main.async { open() }
                } label: {
                    Label(AppLocalization.string("Reorder pinned chats"), systemImage: "arrow.up.arrow.down")
                }
            }
            .accessibilityAction(named: Text(AppLocalization.string("Reorder pinned chats")), open)
        } else {
            self
        }
    }
}
