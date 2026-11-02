//
//  WatchCallView.swift
//  Conduit Watch
//
//  The call screen in V2's look: captions, level bars and controls on the
//  first page, the conversation so far on the second (scroll down or turn
//  the Digital Crown), a job's approval request over both, and a summary
//  once the call ends.
//

import SwiftUI

struct WatchCallView: View {
    @EnvironmentObject private var call: WatchVoiceCall

    var body: some View {
        Group {
            if case .ended(let reason) = call.phase {
                WatchCallSummary(reason: reason)
                    .background(WatchBackdrop())
            } else {
                // In a NavigationStack so the system lays out the voice's
                // name beside the clock: drawn in the page itself, the
                // header ran under the time.
                NavigationStack {
                    TabView {
                        WatchCallControls()
                        WatchTranscriptPage()
                    }
                    .tabViewStyle(.verticalPage)
                    .containerBackground(for: .tabView) { WatchBackdrop() }
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .sheet(isPresented: approvalShown) {
            if let approval = call.pendingApproval {
                WatchApprovalCard(approval: approval)
                    .environmentObject(call)
            }
        }
    }

    /// The voice's name, or the iPhone's while it has the call.
    private var title: String {
        call.phase == .onPhone ? String(localized: "iPhone") : call.callEngine.title
    }

    /// Up while a job's request waits for an answer; only Approve or Deny
    /// takes it down.
    private var approvalShown: Binding<Bool> {
        Binding(get: { call.pendingApproval != nil && call.isActive }, set: { _ in })
    }
}

// MARK: - Controls

/// V2's call screen, sized for the wrist: the conversation's last lines
/// large at the top, the level bars (a tap interrupts or continues), the
/// state with the jobs and the call's clock, then Mute and End.
struct WatchCallControls: View {
    @EnvironmentObject private var call: WatchVoiceCall

    var body: some View {
        VStack(spacing: 4) {
            WatchCallCaptions(current: currentLine)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            levelButton
            statusLine
            buttons
        }
        .padding(.horizontal, 6)
        // The page's bottom inset left a band of empty space under the
        // buttons; without it they sit in the screen's rounded corners.
        .padding(.bottom, 12)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// The line being said: the call's caption, or else the newest turn.
    /// The lines before it are on the transcript page: on the wrist a
    /// faded previous line left the current one a single line.
    private var currentLine: String? {
        call.caption ?? call.transcript.last?.text
    }

    @ViewBuilder
    private var levelButton: some View {
        let button = Button {
            call.tap()
        } label: {
            WatchLevelBars(mood: mood)
                .frame(height: 26)
                // A full-size tap target around the shorter bars.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tapDoesSomething)
        .accessibilityLabel(Text(levelLabel))
        if #available(watchOS 11, *) {
            // Double tap interrupts, or continues after Siri or an alarm.
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    private var statusLine: some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                Text(status)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let since = call.liveSince {
                    Text(since, style: .timer)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        // A label changing every second keeps VoiceOver
                        // from settling on the line.
                        .accessibilityHidden(true)
                }
                if call.jobsRunning > 0 {
                    Label {
                        Text(verbatim: "\(call.jobsRunning)")
                    } icon: {
                        Image(systemName: "hammer.fill")
                    }
                    .font(.caption2.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .fixedSize()
                    .accessibilityLabel(Text("Jobs running: \(String(call.jobsRunning))"))
                }
            }
            // Fits the 40 mm screen's width at every text size.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(call.phase == .lost || call.phase == .needsTap ? Color.watchAttention : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
        HStack(spacing: 22) {
            Button {
                call.toggleMute()
            } label: {
                Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.body.weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .foregroundStyle(call.isMuted ? Color.black : Color.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(call.isMuted ? Color.white : Color.white.opacity(0.16)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
            .disabled(!call.isActive)
            .opacity(call.isActive ? 1 : 0.4)
            .accessibilityLabel(Text(call.isMuted ? String(localized: "Unmute") : String(localized: "Mute")))
            Button(role: .destructive) {
                call.end()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.body.weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.red))
            }
            .disabled(call.phase == .ending)
            .accessibilityLabel(Text("End call"))
        }
        .buttonStyle(.plain)
    }

    private var mood: WatchLevelBars.Mood {
        switch call.phase {
        case .idle, .preparing, .connecting, .reconnecting: return .working
        case .listening, .onPhone: return call.isMuted ? .muted : .listening
        case .speaking: return .speaking
        case .lost, .needsTap: return .attention
        case .ending, .ended: return .done
        }
    }

    private var tapDoesSomething: Bool {
        call.phase == .speaking || call.phase == .needsTap
    }

    private var levelLabel: String {
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
        case .onPhone: return call.isMuted ? String(localized: "Muted") : String(localized: "On your iPhone")
        case .ending, .ended: return String(localized: "Ending…")
        }
    }

    /// What to do now, under the state; the conversation itself is in
    /// the captions.
    private var hint: String? {
        switch call.phase {
        case .preparing: return String(localized: "Asking your iPhone to set up the call")
        case .speaking: return currentLine == nil ? String(localized: "Tap to interrupt") : nil
        case .lost: return String(localized: "Raise your wrist to reconnect")
        case .needsTap: return String(localized: "Tap to continue")
        case .onPhone: return String(localized: "Talking through your headset")
        default: return nil
        }
    }
}

/// V2's captions on the Watch: the line being said large, cut from the
/// front so the newest words show.
struct WatchCallCaptions: View {
    let current: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let current {
                // The longest cut that fits whole: a 42 mm Watch has room
                // for two lines where an Ultra has three. Head truncation
                // over several lines cuts the middle of the text instead.
                ViewThatFits(in: .vertical) {
                    // No line limit here, so a cut that needs more lines
                    // than fit measures taller and is passed over instead
                    // of losing its newest words to tail truncation.
                    candidate(current, limit: 84)
                    candidate(current, limit: 70)
                    candidate(current, limit: 56)
                    candidate(current, limit: 42)
                    // Past the shortest cut (the largest text), the oldest
                    // words go, and the text may shrink a little.
                    line(Self.newestWords(of: current, limit: Self.shortestBudget))
                        .lineLimit(3)
                        .truncationMode(.head)
                        .minimumScaleFactor(0.75)
                }
                // VoiceOver reads the whole line, not the cut one.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: current))
                .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: current)
    }

    /// The shortest cut. The cuts tried before it, from about three lines
    /// on an Ultra down to two short ones, are a rough guide only: the fit
    /// check picks among them.
    private static let shortestBudget = 28

    private func candidate(_ text: String, limit: Int) -> some View {
        line(Self.newestWords(of: text, limit: limit))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func line(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(.body, weight: .semibold))
            // Three lines of it still leave the controls on screen.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// The last `limit` characters or so, from a word's start.
    static func newestWords(of text: String, limit: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        let start = tail.firstIndex(where: \.isWhitespace).map { tail.index(after: $0) } ?? tail.startIndex
        return "…" + tail[start...]
    }
}

// MARK: - Transcript

struct WatchTranscriptPage: View {
    @EnvironmentObject private var call: WatchVoiceCall
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}

struct WatchTranscriptLine: View {
    let turn: WatchVoiceWire.DirectTurn

    @Environment(\.watchAccent) private var accent

    var body: some View {
        let isUser = turn.role == .user
        HStack {
            if isUser { Spacer(minLength: 16) }
            // As V2's chat: what you said in an accent bubble, Hermes'
            // answer as plain text.
            Text(verbatim: turn.text)
                .font(.footnote)
                .padding(.horizontal, isUser ? 8 : 2)
                .padding(.vertical, isUser ? 5 : 2)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isUser ? accent.opacity(0.32) : Color.clear)
                )
            if !isUser { Spacer(minLength: 16) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: isUser ? String(localized: "You: \(turn.text)") : String(localized: "Hermes: \(turn.text)")))
    }
}

// MARK: - Approval

/// A job, or Hermes in a Local Live call, asks to run a command (Hermes'
/// approval settings decide which need one). Approve allows this one
/// command only.
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
                    Text(verbatim: HermesApprovalText.description(approval.description))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                // All of it: the card scrolls, and the user approves what
                // they read.
                Text(verbatim: HermesApprovalText.command(approval.command))
                    .font(.caption2.monospaced())
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
                if approval.canApproveOnce {
                    Button {
                        call.answerApproval(approval, approve: true)
                    } label: {
                        Label("Approve once", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.green)
                } else {
                    // More requests wait, or the command is too long to show
                    // whole: approving here could approve what wasn't read.
                    Text("To approve it, open the chat in Conduit on your iPhone.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
    @Environment(\.watchAccent) private var accent
    let reason: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: WatchCallEnd.isNormal(reason) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    // The title under it says the same.
                    .accessibilityHidden(true)
                    .foregroundStyle(WatchCallEnd.isNormal(reason) ? accent : Color.watchAttention)
                Text(WatchCallEnd.isNormal(reason) ? String(localized: "Call ended") : String(localized: "Call didn't work"))
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
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(accent)
                if WatchCallEnd.canRetry(reason) {
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
