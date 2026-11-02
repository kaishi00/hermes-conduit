#if DEBUG
import SwiftUI
import UIKit

/// DEBUG-only verification surface for cross-block Markdown selection,
/// launched with `-conduitSelectionFixture` (manual simulator passes and the
/// UI test target). Renders one real multi-block response and mirrors the
/// pasteboard so an automated test can assert on what a cross-block Copy
/// actually produced. Never compiled into release builds.
struct SelectionFixtureView: View {
    static let launchArgument = "-conduitSelectionFixture"
    /// With this too, the table draws as the chat draws it: plain cells,
    /// text drawn until touched, inside a row whose tap puts the keyboard
    /// away (TranscriptCellRoot); a link the reply opens shows in
    /// `fixture.openedURL` instead of leaving the app (issue 1585).
    static let chatTableArgument = "-conduitChatTableFixture"

    private let drawsAsChat = ProcessInfo.processInfo.arguments.contains(Self.chatTableArgument)
    @State private var openedURL = ""

    static let source = """
    Before the table paragraph one.

    | Column A | Column B |
    | --- | --- |
    | alpha cell | beta cell |
    | gamma cell | delta cell |

    ```swift
    let fixture = "code block"
    ```

    After the blocks paragraph two.
    """

    static let chatTableSource = """
    Before the table paragraph one.

    | Column A | Column B |
    | --- | --- |
    | alpha cell | beta cell |
    | [skills link](https://example.com/skills) | delta cell |
    """

    @State private var pasteboardText = ""
    @State private var restoredAnimations = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 2)
                        .accessibilityIdentifier("fixture.top")
                    if drawsAsChat {
                        MarkdownText(source: Self.chatTableSource)
                            .padding(16)
                            .environment(\.markdownTablePlainCells, true)
                            .environment(\.selectableTextDrawsUntilTouched, true)
                            .contentShape(Rectangle())
                            .onTapGesture {}
                            .environment(\.openURL, OpenURLAction { url in
                                openedURL = url.absoluteString
                                return .handled
                            })
                    } else {
                        MarkdownText(source: Self.source)
                            .padding(16)
                    }
                    Color.clear
                        .frame(height: 2)
                        .accessibilityIdentifier("fixture.bottom")
                }
            }
            Button {
                _ = MarkdownSelectionCoordinator.copyActiveSelectionToPasteboard()
            } label: {
                Label("Copy selection", systemImage: "doc.on.doc")
                    .scaledFont(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("fixture.copySelection")
            .tint(.conduitAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            Divider()
            if drawsAsChat {
                Text(verbatim: openedURL.isEmpty ? "opened:none" : "opened:\(openedURL)")
                    .accessibilityIdentifier("fixture.openedURL")
                    .scaledFont(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            Text(verbatim: pasteboardText.isEmpty ? "pasteboard:empty" : "pasteboard:\(pasteboardText)")
                .accessibilityIdentifier("fixture.pasteboard")
                .scaledFont(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
                    pasteboardText = UIPasteboard.general.string ?? ""
                }
                .task {
                    pasteboardText = UIPasteboard.general.string ?? ""
                }
        }
        .overlay {
            MarkdownSelectionChromeRoot()
        }
        .onAppear {
            // XCUITest launches only; restored on disappear so a debug
            // session never leaves animations off app-wide.
            if ProcessInfo.processInfo.environment["CONDUIT_UITEST"] == "1", !restoredAnimations {
                UIView.setAnimationsEnabled(false)
            }
        }
        .onDisappear {
            if !restoredAnimations {
                UIView.setAnimationsEnabled(true)
                restoredAnimations = true
            }
        }
    }
}
#endif
