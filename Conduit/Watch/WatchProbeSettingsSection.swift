//
//  WatchProbeSettingsSection.swift
//  Conduit
//
//  Voice settings > Apple Watch test: the proof of concept's link state,
//  its newest results, and the test log to share
//  (designs/apple-watch-voice.md). A test build's section, so its text
//  is English only.
//

import SwiftUI

@MainActor
struct WatchProbeSettingsSection: View {
    @ObservedObject private var link = WatchVoiceLink.shared
    @ObservedObject private var log = WatchProbePhoneLog.shared

    var body: some View {
        ConduitSettingsSection(title: "Apple Watch test", symbol: "applewatch", tint: .conduitAura) {
            Text(verbatim: statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "Run the tests from Conduit on your Watch. Results land here; share the log when you're done.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(log.summaries.suffix(6).reversed().enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.caption2.monospaced())
                    .lineLimit(4)
            }
            ShareLink(item: log.fileURL) {
                Label {
                    Text(verbatim: "Share the test log")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            Button(role: .destructive) {
                log.clear()
            } label: {
                Text(verbatim: "Clear the test log")
            }
        }
    }

    private var statusLine: String {
        guard link.isActivated else { return "Watch link: not active" }
        guard link.isPaired else { return "Watch link: no Apple Watch paired" }
        guard link.isWatchAppInstalled else { return "Watch link: Conduit isn't on the Watch yet" }
        return link.isReachable ? "Watch link: Watch app reachable" : "Watch link: Watch app not open"
    }
}
