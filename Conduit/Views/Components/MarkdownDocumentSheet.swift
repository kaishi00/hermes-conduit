//
//  MarkdownDocumentSheet.swift
//  Conduit
//
//  A Markdown artifact, drawn by the same renderer as the Folder's reader:
//  formatted by default, its source a tap away, and a system handoff to
//  another reader (MDReader on the user's iPad) from the toolbar.
//

import SwiftUI
import UIKit

/// The small decisions a Markdown artifact makes before it is drawn, kept
/// apart from the view so they can be tested without a window.
enum MarkdownArtifact {
    /// True for the names the Folder's reader draws as Markdown, on a
    /// Windows or a Mac host: the path's last component is the same.
    static func isMarkdown(_ name: String) -> Bool {
        let withoutQuery = name.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? name
        return WorkspaceFileKind(name: withoutQuery) == .markdown
    }

    /// The file's UTF-8 text from the dashboard's data URL, or nil when it
    /// is empty, not UTF-8, or larger than the reader's ceiling.
    static func text(from dataURL: String, maxBytes: Int = DataURLLimits.maxDecodedBytes) -> String? {
        guard let comma = dataURL.firstIndex(of: ","),
              dataURL[dataURL.index(after: comma)...].utf8.count <= ((maxBytes + 2) / 3) * 4,
              let data = DataURLLimits.decodeBase64DataURL(dataURL),
              data.count <= maxBytes,
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// A Markdown file from Artifacts. The reader is `MarkdownText`, so the
/// file gets the chat's headings, tables, code, task lists and callouts
/// rather than Quick Look's plain text. The staged copy in the toolbar is
/// what `Open` hands to another app and `Share` sends on.
struct MarkdownDocumentSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.dismiss) private var dismiss

    let name: String
    let text: String
    let resolver: GatewayMediaDataURLResolver

    @State private var showsSource = false
    @State private var shareURL: URL?
    @State private var shareDirectory: URL?

    var body: some View {
        NavigationStack {
            Group {
                if showsSource {
                    source
                } else {
                    reader
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle(Text(verbatim: name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .task { await stageForSharing() }
        .onDisappear { removeShareDirectory() }
    }

    private var reader: some View {
        ScrollView {
            MarkdownText(
                source: text,
                gatewayMediaDataURL: { path in await resolver.dataURL(for: path) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var source: some View {
        ScrollView([.vertical]) {
            WorkspaceCodeText(text: text, highlight: nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(AppLocalization.string("Done")) { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showsSource.toggle()
            } label: {
                Image(systemName: showsSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityLabel(showsSource ? AppLocalization.string("Show Formatted") : AppLocalization.string("Show Source"))
            if let shareURL {
                Menu {
                    // The system's Open In menu lists the apps that read
                    // Markdown, MDReader among them. Share is the fallback
                    // for a reader that only registers a Share extension.
                    Button {
                        if !MediaPreviewPresenter.shared.presentOpenIn(fileURL: shareURL) {
                            _ = MediaPreviewPresenter.shared.presentShare(fileURL: shareURL)
                        }
                    } label: {
                        Label(AppLocalization.string("Open"), systemImage: "arrow.up.forward.app")
                    }
                    ShareLink(item: shareURL) {
                        Label(AppLocalization.string("Share"), systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(AppLocalization.string("Share"))
            }
        }
    }

    /// Writes the text to a temporary `.md` so Open and Share hand over a
    /// real file, named as the artifact was, rather than a bare string.
    @MainActor
    private func stageForSharing() async {
        // Touch the presenter first: its one-time sweep clears a previous
        // run's preview directories before this sheet adds one.
        _ = MediaPreviewPresenter.shared.stagingDirectory
        let name = name
        let text = text
        let staged = await Task.detached(priority: .utility) {
            MediaPreviewPresenter.stage(text: text, filename: name)
        }.value
        guard !Task.isCancelled else {
            if let staged { MediaPreviewPresenter.removeDirectory(staged.directory) }
            return
        }
        guard let staged else { return }
        shareDirectory = staged.directory
        shareURL = staged.file
    }

    private func removeShareDirectory() {
        if let shareDirectory {
            try? FileManager.default.removeItem(at: shareDirectory)
        }
        shareDirectory = nil
        shareURL = nil
    }
}
