import SwiftUI

struct MessagingGroupSettingsSheet: View {
    @ObservedObject var model: MessagingConversationStore
    @ObservedObject var owner: MessagingStore
    let conversation: MessagingConversation
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var members: Set<String>
    @State private var responder: String
    @State private var saving = false
    @State private var error: String?

    init(model: MessagingConversationStore, owner: MessagingStore, conversation: MessagingConversation) {
        self.model = model; self.owner = owner; self.conversation = conversation
        _title = State(initialValue: conversation.title)
        _members = State(initialValue: Set(conversation.profiles))
        _responder = State(initialValue: conversation.defaultResponder)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Group name", text: $title)
                Section("Members") {
                    ForEach(owner.profiles) { profile in
                        Toggle(profile.displayName, isOn: Binding(get: { members.contains(profile.id) }, set: { value in
                            if value { members.insert(profile.id) }
                            else { members.remove(profile.id); if responder == profile.id { responder = members.sorted().first ?? "" } }
                        }))
                    }
                    Text("Added bots can read all prior shared messages. Removing a bot cancels its queued or active work and prevents further replies.").font(.footnote)
                }
                Picker("Default responder", selection: $responder) {
                    ForEach(owner.profiles.filter { members.contains($0.id) }) { Text($0.displayName).tag($0.id) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.disabled(saving)
                .navigationTitle("Group settings")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saving = true
                            Task {
                                do {
                                    try await model.updateGroup(title: title, profiles: members.sorted(), responder: responder, revision: conversation.revision)
                                    dismiss()
                                } catch { self.error = error.localizedDescription }
                                saving = false
                            }
                        }.disabled(saving || members.count < 2 || !members.contains(responder) || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
