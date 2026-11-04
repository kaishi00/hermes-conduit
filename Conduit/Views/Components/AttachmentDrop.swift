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
        // A web link stays a link, even when a browser also offers its page
        // as HTML or a picture under a name (#1695).
        if isWebLink(registeredTypeIdentifiers: identifiers) { return false }
        guard let type = fileType(registeredTypeIdentifiers: identifiers) else { return false }
        guard type.conforms(to: .text) else { return true }
        return !(suggestedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether an item is a link to somewhere other than a file, offered
    /// at most with its page or title as text. A picture dragged from a
    /// page, which also carries its address, is still a file.
    static func isWebLink(registeredTypeIdentifiers identifiers: [String]) -> Bool {
        let types = identifiers.compactMap { UTType($0) }
        let isLink = types.contains { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }
        let hasFile = types.contains { type in
            type.conforms(to: .fileURL)
                || (type.conforms(to: .data) && !type.conforms(to: .url) && !type.conforms(to: .text) && type != .data)
        }
        return isLink && !hasFile
    }

    static func isFile(_ provider: NSItemProvider) -> Bool {
        isFile(registeredTypeIdentifiers: provider.registeredTypeIdentifiers, suggestedName: provider.suggestedName)
    }

    /// Whether a dropped item is a folder (from Finder or Files). A folder
    /// isn't attached, but the drop is taken so the composer can say why.
    static func isFolder(registeredTypeIdentifiers identifiers: [String]) -> Bool {
        fileType(registeredTypeIdentifiers: identifiers) == nil
            && identifiers.contains { UTType($0)?.conforms(to: .directory) == true }
    }

    static func isFolder(_ provider: NSItemProvider) -> Bool {
        isFolder(registeredTypeIdentifiers: provider.registeredTypeIdentifiers)
    }

    /// Whether a drop takes the item: a file to attach, or a folder to
    /// name in the composer's notice.
    static func takes(registeredTypeIdentifiers identifiers: [String], suggestedName: String?) -> Bool {
        isFile(registeredTypeIdentifiers: identifiers, suggestedName: suggestedName)
            || isFolder(registeredTypeIdentifiers: identifiers)
    }

    static func takes(_ provider: NSItemProvider) -> Bool {
        takes(registeredTypeIdentifiers: provider.registeredTypeIdentifiers, suggestedName: provider.suggestedName)
    }

    /// The files and folders in a drop; words and links are left out.
    static func files(in providers: [NSItemProvider]) -> [NSItemProvider] {
        providers.filter(takes)
    }

    /// The names of the folders in a drop, for the composer's notice.
    static func folderNames(in providers: [NSItemProvider]) -> [String] {
        providers.filter(isFolder).compactMap { provider in
            let name = (provider.suggestedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
    }

    /// Why a dropped folder wasn't attached, and what to do instead.
    static func folderMessage(names: [String]) -> String {
        if names.count == 1, let name = names.first {
            return AppLocalization.string("\(name) is a folder, so it wasn't attached. Drop the files inside it instead.")
        }
        if names.isEmpty {
            return AppLocalization.string("Folders can't be attached. Drop the files inside them instead.")
        }
        let list = names.joined(separator: ", ")
        return AppLocalization.string("These folders weren't attached: \(list). Drop the files inside them instead.")
    }

    /// Whether a drop or paste on the composer's text field is staged as
    /// files. One image alone keeps the image paste it always had; several
    /// items, or a file that isn't an image, go the way a picked file does.
    static func stagesAsFiles(registeredTypeIdentifiers: [[String]], suggestedNames: [String?]) -> Bool {
        let files = zip(registeredTypeIdentifiers, suggestedNames).filter { takes(registeredTypeIdentifiers: $0, suggestedName: $1) }
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

extension Notification.Name {
    /// A drag that reached a composer field has ended, dropped or not.
    /// The drop target around the field clears its outline on it: a drag
    /// that ends on the field never tells the target it left (issue 1689).
    static let attachmentDragEnded = Notification.Name("ConduitAttachmentDragEnded")
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
            // The outline is this target's own state, not SwiftUI's
            // `isTargeted`: a drag that moves onto the composer field and
            // is dropped there never reaches this target again, so the
            // outline stayed up until a restart (issue 1689). The drop, the
            // drag leaving, and the field's drag ending each clear it.
            .onDrop(of: [.item], delegate: AttachmentDropDelegate(
                isEnabled: isEnabled,
                isTargeted: $isTargeted,
                onDrop: onDrop
            ))
            .onReceive(NotificationCenter.default.publisher(for: .attachmentDragEnded)) { _ in
                isTargeted = false
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
                                .scaledFont(.headline)
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

/// The chat's or room's drop: files go to `onDrop`; words and links are
/// turned down.
struct AttachmentDropDelegate: DropDelegate {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let onDrop: ([NSItemProvider]) -> Void

    /// A drag came over the chat or room: the outline goes up.
    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    /// The drag left (or moved onto a field that took it): outline down.
    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    /// Dropped here: the outline goes down whether or not files are taken.
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        return take(info.itemProviders(for: [.item]))
    }

    /// Hands the drop's files to `onDrop`; whether the drop was taken.
    func take(_ providers: [NSItemProvider]) -> Bool {
        guard isEnabled else { return false }
        let files = AttachmentDrop.files(in: providers)
        guard !files.isEmpty else { return false }
        onDrop(files)
        return true
    }
}

extension View {
    func attachmentDropTarget(isEnabled: Bool = true, onDrop: @escaping ([NSItemProvider]) -> Void) -> some View {
        modifier(AttachmentDropTarget(isEnabled: isEnabled, onDrop: onDrop))
    }
}
