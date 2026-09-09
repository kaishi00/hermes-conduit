import SwiftUI

/// Bots home: pin-able bot and group shelf.
struct MessagingInboxView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: MessagingStore
    @Binding var requestedAction: String?
    let openMessaging: (MessagingDestination) -> Void
    var showFeatureCard: Bool = false
    var onOpenFeatureCard: () -> Void = {}
    var pinnedSize: CGFloat = ConduitInboxMetrics.profileRailSizePhone
    var unpinnedSize: CGFloat = ConduitInboxMetrics.profileShelfUnpinnedSize
    @State private var newGroup = false
    @State private var chooseBot = false
    @State private var pendingDestination: MessagingDestination?

    private var pinnedItems: [MessagingShelfItem] { store.pinnedShelfItems }
    private var unpinnedItems: [MessagingShelfItem] { store.unpinnedShelfItems }

    private var pinnedColumns: [GridItem] {
        [GridItem(.adaptive(minimum: pinnedSize + 12, maximum: pinnedSize + 28), spacing: 16)]
    }

    var body: some View {
        VStack(spacing: 12) {
            if showFeatureCard {
                MessagingFeatureCard(open: onOpenFeatureCard, dismiss: store.dismissCard)
                    .padding(.horizontal, 16)
            }
            if !store.isReady {
                Text(store.availability.explanation)
                    .font(.footnote)
                    .foregroundStyle(Color.conduitSecondaryText)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !pinnedItems.isEmpty {
                        LazyVGrid(columns: pinnedColumns, alignment: .leading, spacing: 16) {
                            ForEach(pinnedItems) { item in
                                pinnedCell(item)
                            }
                        }
                    }

                    if !unpinnedItems.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if !pinnedItems.isEmpty {
                                Text("More")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.conduitSecondaryText)
                                    .padding(.bottom, 4)
                            }
                            ForEach(unpinnedItems) { item in
                                unpinnedRow(item)
                            }
                        }
                    } else if store.isReady && store.profiles.isEmpty && store.unarchivedGroups.isEmpty {
                        Text("No bots are available for messaging yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await store.refresh() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: requestedAction) { _, action in
            if action == "message" { chooseBot = true }
            if action == "group" { newGroup = true }
            requestedAction = nil
        }
        .sheet(isPresented: $chooseBot, onDismiss: {
            if let pendingDestination {
                openMessaging(pendingDestination)
            }
            pendingDestination = nil
        }) {
            NavigationStack {
                List(store.profiles) { profile in
                    Button(profile.displayName) {
                        pendingDestination = MessagingDestination(conversationID: nil, profileID: profile.id)
                        chooseBot = false
                    }
                }.navigationTitle("Message a bot")
            }
        }
        .sheet(isPresented: $newGroup, onDismiss: {
            if let pendingDestination {
                openMessaging(pendingDestination)
            }
            pendingDestination = nil
        }) {
            NewMessagingGroupSheet(store: store) { conversation in
                pendingDestination = MessagingDestination(conversationID: conversation.id, profileID: nil)
            }
        }
    }

    private func pinnedCell(_ item: MessagingShelfItem) -> some View {
        Button {
            open(item)
        } label: {
            VStack(spacing: 8) {
                shelfArtwork(item, size: pinnedSize)
                Text(item.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.conduitPrimaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: pinnedSize + 8)
            }
        }
        .buttonStyle(.plain)
        .disabled(!store.isReady)
        .contextMenu { pinMenu(for: item) }
        .accessibilityLabel(item.title)
        .accessibilityHint(accessibilityHint(for: item))
    }

    private func unpinnedRow(_ item: MessagingShelfItem) -> some View {
        Button {
            open(item)
        } label: {
            HStack(spacing: 14) {
                shelfArtwork(item, size: unpinnedSize)
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.conduitPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.conduitSecondaryText)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!store.isReady)
        .contextMenu { pinMenu(for: item) }
        .accessibilityLabel(item.title)
        .accessibilityHint(accessibilityHint(for: item))
    }

    @ViewBuilder
    private func shelfArtwork(_ item: MessagingShelfItem, size: CGFloat) -> some View {
        switch item {
        case .bot(let profile):
            AgentAvatar(
                profileID: profile.name,
                displayName: profile.displayName,
                photoURL: appState.profileAvatarURL(for: profile.name),
                size: size,
                state: appState.avatarState(for: profile.name)
            )
        case .group:
            Image(systemName: "person.2.circle.fill")
                .font(.system(size: size - 4))
                .foregroundStyle(Color.conduitAccent)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func pinMenu(for item: MessagingShelfItem) -> some View {
        let pinned: Bool = {
            switch item {
            case .bot(let profile): return store.isBotPinned(profile.id)
            case .group(let conversation): return store.isGroupPinned(conversation.id)
            }
        }()
        Button {
            Haptics.light()
            withAnimation(ConduitMotion.response) {
                switch item {
                case .bot(let profile): store.toggleBotPinned(profile.id)
                case .group(let conversation): store.toggleGroupPinned(conversation.id)
                }
            }
        } label: {
            Label(
                pinned ? "Unpin" : "Pin",
                systemImage: pinned ? "pin.slash" : "pin"
            )
        }
    }

    private func open(_ item: MessagingShelfItem) {
        switch item {
        case .bot(let profile):
            openMessaging(MessagingDestination(conversationID: nil, profileID: profile.id))
        case .group(let conversation):
            openMessaging(MessagingDestination(conversationID: conversation.id, profileID: nil))
        }
    }

    private func accessibilityHint(for item: MessagingShelfItem) -> String {
        switch item {
        case .bot: return "Opens a direct message with this bot"
        case .group: return "Opens this group conversation"
        }
    }
}

struct NewMessagingGroupSheet: View {
    @ObservedObject var store: MessagingStore
    let created: (MessagingConversation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: Set<String> = []
    @State private var responder = ""
    @State private var saving = false
    @State private var error: String?
    @State private var requestID = UUID().uuidString
    @State private var result: MessagingConversation?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Group name", text: $name)
                Section("Bots") {
                    ForEach(store.profiles) { profile in
                        Toggle(profile.displayName, isOn: Binding(get: { members.contains(profile.id) }, set: { value in
                            if value { members.insert(profile.id); if responder.isEmpty { responder = profile.id } }
                            else { members.remove(profile.id); if responder == profile.id { responder = members.sorted().first ?? "" } }
                        }))
                    }
                }
                Picker("Default responder", selection: $responder) {
                    Text("Choose a bot").tag("")
                    ForEach(store.profiles.filter { members.contains($0.id) }) { Text($0.displayName).tag($0.id) }
                }
                Text("Every member can read this group's shared messages. Leave To: on Auto to let turn-taking choose who speaks; the default responder is only used if that call fails. Use the To: menu to address specific bots.").font(.footnote)
                if let error { Text(error).foregroundStyle(.red) }
            }.disabled(saving)
                .navigationTitle("New group")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            saving = true
                            Task {
                                do { let value = try await store.createGroup(name: name, members: members.sorted(), responder: responder, requestID: requestID); result = value; created(value); dismiss() }
                                catch { self.error = error.localizedDescription }
                                saving = false
                            }
                        }.disabled(saving || members.count < 2 || responder.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }

    }
}
