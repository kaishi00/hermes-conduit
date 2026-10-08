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
    @AppStorage(WatchPhoneKeepAlive.key) private var keepAlive: WatchPhoneKeepAlive = .off
    @AppStorage(WatchJobSettings.jobsPerCallKey) private var jobsPerCall = WatchJobSettings.defaultJobsPerCall
    @AppStorage(WatchJobSettings.voiceApprovalsKey) private var voiceApprovals = false

    var body: some View {
        ConduitSettingsSection(title: "Apple Watch test", symbol: "applewatch", tint: .conduitAura) {
            Text(verbatim: statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "Run the tests from Conduit on your Watch. Results land here; share the log when you're done.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(selection: $keepAlive) {
                ForEach(WatchPhoneKeepAlive.allCases, id: \.self) { option in
                    Text(verbatim: option.title).tag(option)
                }
            } label: {
                Text(verbatim: "Keep the iPhone running")
            }
            Text(verbatim: keepAlive.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(value: $jobsPerCall, in: 0...WatchJobSettings.maximumJobsPerCall) {
                Text(verbatim: "Jobs per Watch call: \(WatchJobSettings.jobsPerCallTitle(jobsPerCall))")
            }
            Text(verbatim: "Jobs a Gemini call on the Watch can start on Hermes through the push relay, wrist up or down. Each runs as a normal Hermes chat under Voice Jobs, and Hermes' own approval settings apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(selection: $voiceApprovals) {
                Text(verbatim: "Tap").tag(false)
                Text(verbatim: "Tap or voice").tag(true)
            } label: {
                Text(verbatim: "Approve from the Watch")
            }
            .disabled(jobsPerCall == 0)
            Text(verbatim: voiceApprovals
                ? "A job's approval request shows on the Watch, and you can also answer it by voice. Voice only ever approves once. Text in a web page or a job's output could try to talk Gemini into approving."
                : "A job's approval request shows on the Watch with Approve and Deny buttons; Gemini can't answer it.")
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

    // The Watch app is reachable only while it's in front with the
    // screen awake, so a dimmed Watch reads as unreachable. Reachability
    // comes first: `isWatchAppInstalled` has read false at launch with
    // the Watch app installed.
    private var statusLine: String {
        if link.isReachable { return "Watch link: Watch app reachable" }
        guard link.isActivated else { return "Watch link: not active" }
        guard link.isPaired else { return "Watch link: no Apple Watch paired" }
        return "Watch link: open Conduit on the Watch and tap its screen to wake it"
    }
}
