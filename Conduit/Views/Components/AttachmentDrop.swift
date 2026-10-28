//
//  AttachmentDrop.swift
//  Conduit
//
//  Files dragged onto a chat or a group room (from Finder on a Mac, Files
//  or another app on an iPad) are staged like files picked with Document:
//  the same size limit, names and JPEG re-encode, and nothing is sent until
//  the user presses Send (#1408). Dragged words and links stay text.
//

import SwiftUI
import UniformTypeIdentifiers

enum AttachmentDrop {
    /// The type a dropped item is staged as: the first (richest) type it
    /// offers that is file content, preferring a specific type over plain
    /// data so the name keeps its extension. A link or a folder offers none.
    static func fileType(registeredTypeIdentifiers identifiers: [String]) -> UTType? {
        let candidates = identifiers
            .compactMap { UTType($0) }
            .filter { $0.conforms(to: .data) && !$0.conforms(to: .url) }
        return candidates.first { $0 != .data } ?? candidates.first
    }

    /// Whether a dropped item is a file to attach. Text counts only when it
    /// comes as a named file (a .txt from Finder); a dragged selection of
    /// words has no name and goes into the draft as text.
    static func isFile(registeredTypeIdentifiers identifiers: [String], suggestedName: String?) -> Bool {
        guard let type = fileType(registeredTypeIdentifiers: identifiers) else { return false }
        guard type.conforms(to: .text) else { return true }
        return !(suggestedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isFile(_ provider: NSItemProvider) -> Bool {
        isFile(registeredTypeIdentifiers: provider.registeredTypeIdentifiers, suggestedName: provider.suggestedName)
    }

    static func files(in providers: [NSItemProvider]) -> [NSItemProvider] {
        providers.filter(isFile)
    }

    /// Whether a drop or paste on the composer's text field is staged as
    /// files. One image alone keeps the image paste it always had; several
    /// items, or a file that isn't an image, go the way a picked file does.
    static func stagesAsFiles(registeredTypeIdentifiers: [[String]], suggestedNames: [String?]) -> Bool {
        let files = zip(registeredTypeIdentifiers, suggestedNames).filter { isFile(registeredTypeIdentifiers: $0, suggestedName: $1) }
        guard let first = files.first else { return false }
        if files.count > 1 || registeredTypeIdentifiers.count > 1 { return true }
        return fileType(registeredTypeIdentifiers: first.0)?.conforms(to: .image) != true
    }

    static func stagesAsFiles(_ providers: [NSItemProvider]) -> Bool {
        stagesAsFiles(
            registeredTypeIdentifiers: providers.map(\.registeredTypeIdentifiers),
            suggestedNames: providers.map(\.suggestedName)
        )
    }

    /// Copies one dropped item into the staging folder under its own name.
    /// The system's copy is only readable inside the load callback, so the
    /// copy happens there.
    static func stage(_ provider: NSItemProvider, ordinal: Int, limitMegabytes: Int) async -> AttachmentStaging.StagedImport {
        let type = fileType(registeredTypeIdentifiers: provider.registeredTypeIdentifiers)
        let fallbackName = AttachmentTypePolicy.filename(suggested: provider.suggestedName, type: type, ordinal: ordinal)
        guard let type else { return .failed(fallbackName) }
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: .failed(fallbackName))
                    return
                }
                let name = AttachmentTypePolicy.filename(
                    suggested: provider.suggestedName ?? url.lastPathComponent,
                    type: type,
                    ordinal: ordinal
                )
                continuation.resume(returning: AttachmentStaging.stageCopy(
                    of: url,
                    name: name,
                    type: type,
                    limitMegabytes: limitMegabytes
                ))
            }
        }
    }

    /// Stages every dropped file in order, one at a time like a picked
    /// selection, so a drop of many large files isn't held at once.
    static func stage(_ providers: [NSItemProvider], limitMegabytes: Int) async -> [AttachmentStaging.StagedImport] {
        var outcomes: [AttachmentStaging.StagedImport] = []
        for (index, provider) in providers.enumerated() {
            outcomes.append(await stage(provider, ordinal: index + 1, limitMegabytes: limitMegabytes))
        }
        return outcomes
    }
}

/// Files dropped on a chat or room, handed to its composer. Equal by
/// identity: each drop is its own request. `owner` is the chat's draft key
/// or the room it was dropped on, so a request never reaches another.
struct AttachmentDropRequest: Equatable {
    let id = UUID()
    let owner: AnyHashable
    let providers: [NSItemProvider]

    static func == (lhs: AttachmentDropRequest, rhs: AttachmentDropRequest) -> Bool {
        lhs.id == rhs.id
    }
}

/// A chat or room that takes dropped files: the whole screen is the
/// target, outlined while something is dragged over it.
struct AttachmentDropTarget: ViewModifier {
    let isEnabled: Bool
    let onDrop: ([NSItemProvider]) -> Void
    @State private var isTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.item], isTargeted: $isTargeted) { providers in
                guard isEnabled else { return false }
                let files = AttachmentDrop.files(in: providers)
                guard !files.isEmpty else { return false }
                onDrop(files)
                return true
            }
            .overlay {
                if isTargeted && isEnabled {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.conduitAccent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.conduitAccent.opacity(0.06))
                        )
                        .overlay {
                            Label(AppLocalization.string("Drop to attach"), systemImage: "paperclip")
                                .font(.headline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .conduitGlassControl(cornerRadius: 20, tint: .conduitAccent.opacity(0.12))
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isTargeted && isEnabled)
    }
}

extension View {
    func attachmentDropTarget(isEnabled: Bool = true, onDrop: @escaping ([NSItemProvider]) -> Void) -> some View {
        modifier(AttachmentDropTarget(isEnabled: isEnabled, onDrop: onDrop))
    }
}
