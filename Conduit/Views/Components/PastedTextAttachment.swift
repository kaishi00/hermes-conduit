//
//  PastedTextAttachment.swift
//  Conduit
//
//  A long paste goes into the composer as a removable text attachment
//  instead of a wall of words in the field, as in Hermes Desktop. It is a
//  plain `.txt` file staged like any other, so it reaches Hermes as an
//  `@file:` reference whose text Hermes puts in the prompt, and a chat
//  reopened anywhere (Desktop included) shows it as pasted content.
//

import SwiftUI
import UniformTypeIdentifiers

enum PastedText {
    /// Past this many UTF-16 units a paste becomes an attachment, Hermes
    /// Desktop's threshold (apps/desktop large-paste.ts), so a paste
    /// behaves the same in both apps.
    static let characterThreshold = 3_000

    static func becomesAttachment(_ text: String) -> Bool {
        text.utf16.count > characterThreshold
    }

    /// Whether a chat composer takes a long paste as an attachment: not
    /// while it's locked, nor while its chat is on its way, whose waiting
    /// message is words only. Otherwise the paste stays in the field.
    static func chatComposerTakesPaste(enabled: Bool, waitsForChat: Bool) -> Bool {
        enabled && !waitsForChat
    }

    /// Whether a room's composer does: only on a plugin that stores the
    /// room's files, and never in a disbanded room.
    static func roomComposerTakesPaste(canStoreFiles: Bool, disbanded: Bool) -> Bool {
        canStoreFiles && !disbanded
    }

    /// Checked before the paste is staged, so one over the limit gets its
    /// notice at once.
    static func fits(_ text: String, limitMegabytes: Int) -> Bool {
        AttachmentSizeLimit.allows(byteCount: Int64(text.utf8.count), megabytes: limitMegabytes)
    }

    /// Desktop's name for a saved paste, `pasted_content_<stamp>_<hex>.txt`,
    /// which its chat reads as pasted content rather than a file.
    static func filename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let random = String(format: "%06x", UInt32.random(in: 0...0xFFFFFF))
        return "pasted_content_\(formatter.string(from: now))_\(random).txt"
    }

    /// Whether a file is a paste, by that exact name, so a file the user
    /// picked isn't taken for one. Hermes may put its own prefix on the
    /// stored name, or `-N` after it.
    static func isPastedText(_ name: String) -> Bool {
        let last = (name as NSString).lastPathComponent
        return last.wholeMatch(of: #/.*pasted_content_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-\d{3}_[0-9a-f]{6}(?:-\d+)?\.txt/#) != nil
    }

    static func isPastedText(_ attachment: Attachment) -> Bool {
        attachment.kind == .document && isPastedText(attachment.name)
    }

    static var displayName: String { AppLocalization.string("Pasted text") }

    /// Stages a paste as a text attachment, checked against the attachment
    /// limit like a picked file.
    static func stage(_ text: String, limitMegabytes: Int) -> AttachmentStaging.StagedImport {
        write(text, name: filename(), id: UUID().uuidString, limitMegabytes: limitMegabytes)
    }

    /// The same attachment holding edited text: a new staged file under the
    /// same id and name, so the strip keeps its place and the chip reloads.
    /// The old file is the caller's to delete once the new one is in.
    static func restage(_ attachment: Attachment, with text: String, limitMegabytes: Int) -> AttachmentStaging.StagedImport {
        write(text, name: attachment.name, id: attachment.id, limitMegabytes: limitMegabytes)
    }

    private static func write(_ text: String, name: String, id: String, limitMegabytes: Int) -> AttachmentStaging.StagedImport {
        let data = Data(text.utf8)
        guard AttachmentSizeLimit.allows(byteCount: Int64(data.count), megabytes: limitMegabytes) else {
            return .tooLarge(displayName)
        }
        guard !data.isEmpty,
              let url = try? AttachmentStaging.destination(for: name),
              (try? data.write(to: url, options: .atomic)) != nil else {
            return .failed(displayName)
        }
        return .staged(Attachment(
            id: id,
            name: name,
            uri: url.absoluteString,
            mimeType: "text/plain",
            kind: .document
        ))
    }

    /// The staged file's text, nil when it can't be read.
    static func text(of attachment: Attachment) -> String? {
        guard let url = URL(string: attachment.uri), url.isFileURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The first `limit` characters of the staged file, reading only the
    /// start of it.
    static func prefix(of attachment: Attachment, limit: Int) -> String? {
        guard let url = URL(string: attachment.uri), url.isFileURL,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Four bytes a character at most, and one more character's worth,
        // so a character cut at the end is past the limit.
        guard let data = try? handle.read(upToCount: (limit + 1) * 4), !data.isEmpty else { return nil }
        return String(String(decoding: data, as: UTF8.self).prefix(limit))
    }

    /// The start of a message's first paste, for Hermes to title a new
    /// chat from (Desktop's `title_preview`, 1,000 characters): without it
    /// a message that is only a paste is titled from its file's name.
    static func titlePreview(in attachments: [Attachment], limit: Int = 1_000) -> String? {
        guard let paste = attachments.first(where: { isPastedText($0) }),
              let preview = prefix(of: paste, limit: limit)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !preview.isEmpty else { return nil }
        return preview
    }

    /// The chip's line: the first words of the paste's first 2,000
    /// characters.
    static func chipPreview(of attachment: Attachment) -> String? {
        prefix(of: attachment, limit: 2_000).map { preview(of: $0) }
    }

    /// The first words of a paste, for its chip.
    static func preview(of text: String, limit: Int = 80) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard firstLine.count > limit else { return firstLine }
        return String(firstLine.prefix(limit)) + "…"
    }

    /// A paste put back into the message: after what was typed, on a line
    /// of its own.
    static func joined(_ draft: String, with pasted: String) -> String {
        guard !pasted.isEmpty else { return draft }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return pasted }
        let separator = draft.hasSuffix("\n") ? "\n" : "\n\n"
        return draft + separator + pasted
    }
}

/// What a pasted-text chip's sheet can do with the paste besides showing
/// it. Nil actions show it read-only.
struct PastedTextActions {
    /// Keeps edited text as the attachment.
    let save: (String) -> Void
    /// Puts the text into the message and removes the attachment.
    let insertAsText: (String) -> Void
}

/// The paste behind a chip, to read, edit, or put back into the message.
struct PastedTextSheet: View {
    let attachment: Attachment
    let actions: PastedTextActions?

    @Environment(\.dismiss) private var dismiss
    @State private var original: String?
    @State private var text = ""
    @State private var unreadable = false
    /// What the sheet does as it closes, so the chip, which may go with
    /// it, is never asked to act while the sheet is still up.
    @State private var closing: Closing = .keep

    private enum Closing {
        case keep
        case insert
    }

    var body: some View {
        NavigationStack {
            Group {
                if unreadable {
                    ContentUnavailableView {
                        Label(AppLocalization.string("Conduit couldn't read the pasted text."), systemImage: "doc.text")
                    }
                } else if original == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if actions == nil {
                    // Its upload has started: read and select, not edit.
                    ScrollView {
                        Text(text)
                            .scaledFont(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                } else {
                    TextEditor(text: $text)
                        .scaledFont(.body)
                        .padding(.horizontal, 12)
                        .accessibilityIdentifier("composer.pastedText.editor")
                }
            }
            .navigationTitle(Text(PastedText.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if actions != nil, original != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(AppLocalization.string("Paste as text")) {
                            Haptics.selection()
                            closing = .insert
                            dismiss()
                        }
                        .accessibilityIdentifier("composer.pastedText.insert")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: attachment.uri) {
            let attachment = attachment
            let loaded = await Task.detached(priority: .userInitiated) {
                PastedText.text(of: attachment)
            }.value
            guard let loaded else {
                unreadable = true
                return
            }
            original = loaded
            text = loaded
        }
        .onDisappear {
            // Closed by Done, a swipe, or Paste as text: edits are kept
            // either way.
            guard let actions, let original else { return }
            switch closing {
            case .insert:
                actions.insertAsText(text)
            case .keep:
                if text != original { actions.save(text) }
            }
        }
    }
}
