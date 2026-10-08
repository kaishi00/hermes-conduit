//
//  WatchCallView.swift
//  Conduit Watch
//
//  The call screen: the orb and controls on the first page, the
//  conversation so far on the second (scroll down or turn the Digital
//  Crown), a job's approval request over both, and a summary once the
//  call ends.
//

import SwiftUI

struct WatchCallView: View {
    @EnvironmentObject private var call: WatchVoiceCall

    var body: some View {
        Group {
            if case .ended(let reason) = call.phase {
                WatchCallSummary(reason: reason)
            } else {
                TabView {
                    WatchCallControls()
                    WatchTranscriptPage()
                }
                .tabViewStyle(.verticalPage)
            }
        }
        .sheet(isPresented: approvalShown) {
            if let approval = call.pendingApproval {
                WatchApprovalCard(approval: approval)
            }
        }
    }

    /// Up while a job's request waits for an answer; only Approve or Deny
    /// takes it down.
    private var approvalShown: Binding<Bool> {
        Binding(get: { call.pendingApproval != nil && call.isActive }, set: { _ in })
    }
}

// MARK: - Controls

struct WatchCallControls: View {
    @EnvironmentObject private var call: WatchVoiceCall

    var body: some View {
        VStack(spacing: 4) {
            header
            Spacer(minLength: 0)
            orb
            VStack(spacing: 1) {
                Text(status)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            buttons
        }
        .padding(.horizontal, 4)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(call.callEngine.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.watchAura)
            Spacer(minLength: 0)
            if call.jobsRunning > 0 {
                Label {
                    Text(verbatim: "\(call.jobsRunning)")
                } icon: {
                    Image(systemName: "hammer.fill")
                }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.watchVoice.opacity(0.3)))
                .accessibilityLabel(Text("Jobs running: \(String(call.jobsRunning))"))
            }
            if let since = call.liveSince {
                Text(since, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var orb: some View {
        let button = Button {
            call.tap()
        } label: {
            WatchVoiceOrb(mood: mood, size: 88)
        }
        .buttonStyle(.plain)
        .disabled(!tapDoesSomething)
        .accessibilityLabel(Text(orbLabel))
        if #available(watchOS 11, *) {
            // Double tap interrupts, or continues after Siri or an alarm.
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button {
                call.toggleMute()
            } label: {
                Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .tint(call.isMuted ? .watchAttention : .gray)
            .disabled(!call.isActive)
            .accessibilityLabel(Text(call.isMuted ? "Unmute" : "Mute"))
            Button(role: .destructive) {
                call.end()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
            .disabled(call.phase == .ending)
            .accessibilityLabel(Text("End call"))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }

    private var mood: WatchVoiceOrb.Mood {
        switch call.phase {
        case .idle, .preparing, .connecting, .reconnecting: return .working
        case .listening: return call.isMuted ? .muted : .listening
        case .speaking: return .speaking
        case .lost, .needsTap: return .attention
        case .ending, .ended: return .done
        }
    }

    private var tapDoesSomething: Bool {
        call.phase == .speaking || call.phase == .needsTap
    }

    private var orbLabel: String {
        switch call.phase {
        case .speaking: return String(localized: "Interrupt")
        case .needsTap: return String(localized: "Continue")
        default: return status
        }
    }

    private var status: String {
        switch call.phase {
        case .idle, .preparing: return String(localized: "Starting…")
        case .connecting: return String(localized: "Connecting…")
        case .listening: return call.isMuted ? String(localized: "Muted") : String(localized: "Listening")
        case .speaking: return String(localized: "Speaking")
        case .reconnecting: return String(localized: "Reconnecting…")
        case .lost: return String(localized: "Connection lost")
        case .needsTap: return String(localized: "Paused")
        case .ending, .ended: return String(localized: "Ending…")
        }
    }

    /// A hint under the status, or the newest line of the conversation.
    private var detail: String? {
        switch call.phase {
        case .preparing: return String(localized: "Asking your iPhone to set up the call")
        case .speaking: return call.caption ?? String(localized: "Tap to interrupt")
        case .lost: return String(localized: "Raise your wrist to reconnect")
        case .needsTap: return String(localized: "Tap to continue")
        case .listening: return call.caption
        default: return nil
        }
    }
}

// MARK: - Transcript

struct WatchTranscriptPage: View {
    @EnvironmentObject private var call: WatchVoiceCall

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if call.transcript.isEmpty {
                        Text("What you and Hermes say shows here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 20)
                    }
                    ForEach(Array(call.transcript.enumerated()), id: \.offset) { index, turn in
                        WatchTranscriptLine(turn: turn)
                            .id(index)
                    }
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: call.transcript.count) { _, count in
                guard count > 0 else { return }
                withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}

struct WatchTranscriptLine: View {
    let turn: WatchVoiceWire.DirectTurn

    var body: some View {
        let isUser = turn.role == .user
        HStack {
            if isUser { Spacer(minLength: 16) }
            Text(verbatim: turn.text)
                .font(.footnote)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isUser ? Color.watchAura.opacity(0.35) : Color.white.opacity(0.12))
                )
            if !isUser { Spacer(minLength: 16) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: isUser ? String(localized: "You: \(turn.text)") : String(localized: "Hermes: \(turn.text)")))
    }
}

// MARK: - Approval

/// A job asks to run a command (Hermes' approval settings decide which
/// need one). Approve allows this one command only.
struct WatchApprovalCard: View {
    @EnvironmentObject private var call: WatchVoiceCall
    let approval: WatchJobAnswer.Approval

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Label("Approve this command?", systemImage: "exclamationmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(Color.watchAttention)
                Text(verbatim: approval.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(3)
                if !approval.description.isEmpty {
                    Text(verbatim: approval.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                // All of it: the card scrolls, and the user approves what
                // they read.
                Text(verbatim: approval.command)
                    .font(.caption2.monospaced())
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
                Button {
                    call.answerApproval(approval, approve: true)
                } label: {
                    Label("Approve once", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)
                Button(role: .destructive) {
                    call.answerApproval(approval, approve: false)
                } label: {
                    Label("Deny", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

// MARK: - Summary

struct WatchCallSummary: View {
    @EnvironmentObject private var call: WatchVoiceCall
    let reason: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: WatchCallEnd.isNormal(reason) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(WatchCallEnd.isNormal(reason) ? Color.watchAura : Color.watchAttention)
                Text(WatchCallEnd.isNormal(reason) ? "Call ended" : "Call didn't work")
                    .font(.headline)
                if let reason, !WatchCallEnd.isNormal(reason) {
                    Text(verbatim: reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let duration {
                    Text(duration)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    call.dismissEnded()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .tint(.watchAura)
                if !WatchCallEnd.isNormal(reason) {
                    Button {
                        call.dismissEnded()
                        call.start()
                    } label: {
                        Text("Try again")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var duration: String? {
        guard let since = call.liveSince, let ended = call.endedAt else { return nil }
        return Self.durationFormatter.string(from: max(0, ended.timeIntervalSince(since)))
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()
}
