//
//  ShareDraftSheet.swift
//  ConduitShareExtension
//
//  The share sheet's page: what was shared, what was left out and why, and
//  the chat it goes to (a new chat, or a recent one from the list Conduit
//  keeps for its widgets: titles and ids only).
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ShareDraftSheet: View {
    @ObservedObject var model: ShareDraftModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: "Conduit"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .tint(Self.accent)
        .environment(\.locale, AppLocalization.locale)
    }

    /// Conduit's default accent (amber), so the sheet reads as Conduit's.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.88, green: 0.67, blue: 0.28, alpha: 1)
            : UIColor(red: 0.55, green: 0.37, blue: 0.13, alpha: 1)
    })

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .collecting:
            ProgressView {
                Text("Reading what you shared…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .saving:
            form
        case .saved:
            saved
        case .failed(let message):
            ContentUnavailableView {
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch model.phase {
        case .saved:
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    model.done()
                } label: {
                    Text("Done")
                }
            }
        default:
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .cancel) {
                    model.cancel()
                } label: {
                    Text("Cancel")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    model.save()
                } label: {
                    Text("Add")
                }
                .disabled(model.phase != .ready)
                .accessibilityHint(Text("Saves the draft for Conduit. Nothing is sent."))
            }
        }
    }

    // MARK: The draft

    private var form: some View {
        Form {
            Section {
                if !model.collection.text.isEmpty {
                    Text(verbatim: model.collection.text)
                        .font(.callout)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
                ForEach(model.collection.attachments, id: \.storedName) { attachment in
                    attachmentRow(attachment)
                }
            } header: {
                Text("Draft")
            }

            if !model.collection.problems.isEmpty {
                Section {
                    ForEach(Array(model.collection.problems.enumerated()), id: \.offset) { _, problem in
                        Label {
                            Text(verbatim: problem.message(composerLimitMegabytes: model.composerLimitMegabytes))
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Left out")
                }
            }

            if model.workspaces.count > 1 {
                Section {
                    Picker(selection: Binding(
                        get: { model.workspaceID },
                        set: { if let id = $0 { model.selectWorkspace(id) } }
                    )) {
                        ForEach(model.workspaces, id: \.id) { workspace in
                            Text(verbatim: Self.label(for: workspace)).tag(Optional(workspace.id))
                        }
                    } label: {
                        Text("Workspace")
                    }
                }
            }

            Section {
                chatRow(
                    title: Text("New chat"),
                    systemImage: "square.and.pencil",
                    isSelected: model.target == .newChat
                ) {
                    model.target = .newChat
                }
                ForEach(model.chats, id: \.reference) { choice in
                    chatRow(
                        title: Text(verbatim: choice.title),
                        subtitle: choice.reference.botLabel,
                        systemImage: choice.isPinned ? "pin" : "bubble.left",
                        isSelected: model.target == .conversation(choice.reference)
                    ) {
                        model.target = .conversation(choice.reference)
                    }
                }
            } header: {
                if let workspace = model.workspace, model.workspaces.count == 1 {
                    Text(verbatim: Self.label(for: workspace))
                } else {
                    Text("Chat")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if model.snapshot == nil || model.workspaces.isEmpty {
                        Text("Open Conduit once to see your recent chats here.")
                    }
                    Text("Conduit shows this draft in the chat for you to review. Nothing is sent until you send it.")
                }
            }
        }
        .disabled(model.phase == .saving)
    }

    private func attachmentRow(_ attachment: ShareDraftAttachment) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(for: attachment))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: attachment.displayName)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(verbatim: ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .binary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chatRow(
        title: Text,
        subtitle: String? = nil,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        // Titles in the text colour, not the tint: these are choices.
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Saved

    private var saved: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Draft ready")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Open Conduit to review it and send it. It waits there for a day.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if model.notifiesWhenSaved {
                Text("Tap the notification to go straight there.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: 480, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    // MARK: -

    static func label(for workspace: WidgetWorkspaceSnapshot) -> String {
        workspace.profileLabel.isEmpty ? workspace.dashboardLabel : "\(workspace.dashboardLabel) · \(workspace.profileLabel)"
    }

    static func symbol(for attachment: ShareDraftAttachment) -> String {
        let type = attachment.typeIdentifier.flatMap(UTType.init)
            ?? UTType(filenameExtension: (attachment.displayName as NSString).pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        return "doc"
    }
}
