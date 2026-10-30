//
//  OfflineChatBanner.swift
//  Conduit
//
//  The banner over a saved copy (#99) while Hermes can't be reached. The
//  copy's rows draw in the chat's own scroll view (ChatView), as the chat's.
//

import SwiftUI

/// Up only while Hermes can't be reached: Retry and Sign In are what it
/// offers.
struct OfflineChatBanner: View {
    let savedAt: Date?
    /// A saved conversation is on screen. Without one (a chat picked in the
    /// saved list that has no copy) the banner says Hermes can't be reached.
    let showsCopy: Bool
    @EnvironmentObject var appState: AppState

    private var title: String {
        showsCopy
            ? AppLocalization.string("Showing a saved copy")
            : AppLocalization.string("Can't reach Hermes")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "icloud.slash")
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(.footnote.weight(.semibold))
                if let savedAt {
                    Text(AppLocalization.string("Saved \(savedAt.formatted(.relative(presentation: .named).locale(AppLocalization.formattingLocale)))"))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(AppLocalization.string("Retry")) { appState.retryFromOfflineChat() }
                .scaledFont(.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.conduitAccent)
            if appState.connection == nil {
                Button(AppLocalization.string("Sign In")) { appState.signInFromOfflineChat() }
                    .scaledFont(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.conduitAccent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline-chat-banner")
    }
}
