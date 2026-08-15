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

    @State private var pasteboardText = ""

    init() {
        if ProcessInfo.processInfo.environment["CONDUIT_UITEST"] == "1" {
            UIView.setAnimationsEnabled(false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 2)
                        .accessibilityIdentifier("fixture.top")
                    MarkdownText(source: Self.source)
                        .padding(16)
                    Color.clear
                        .frame(height: 2)
                        .accessibilityIdentifier("fixture.bottom")
                }
            }
            Button {
                _ = MarkdownSelectionCoordinator.copyActiveSelectionToPasteboard()
            } label: {
                Label("Copy selection", systemImage: "doc.on.doc")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("fixture.copySelection")
            .tint(.conduitAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            Divider()
            Text(pasteboardText.isEmpty ? "pasteboard:empty" : "pasteboard:\(pasteboardText)")
                .accessibilityIdentifier("fixture.pasteboard")
                .font(.footnote.monospaced())
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
    }
}
#endif
