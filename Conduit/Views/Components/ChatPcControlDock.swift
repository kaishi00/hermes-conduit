//
//  ChatPcControlDock.swift
//  Conduit
//
//  Control from Hermes on the phone: while the open chat's bot is
//  controlling one of the user's computers, a line above the composer says
//  so ("Atlas is controlling Asuka"), with Stop. Read every few seconds
//  while the chat's turn runs, since a bot only acts in a turn; Stop takes
//  the line away at once and the computer's own bar with it.
//

import SwiftUI

struct ChatPcControlDock: View {
    let appState: AppState
    let openChatID: String?
    /// The chat's turn is running.
    let isBusy: Bool
    /// The chat shows (the app is active, the tab and the chat on screen).
    let isShowing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlling: PcControlling?
    /// Bumped by Stop: a read that started before it can't bring the line back.
    @State private var revision = 0
    /// The computer whose Stop didn't reach the host: its line says so, and
    /// no other computer's line does.
    @State private var stopFailedOn: String?
    /// Counts the chat's turns as they start, so a Stop answered after its
    /// turn ended and another started is left alone (issue 3424).
    @State private var turn = 0

    private var shows: Bool { controlling != nil && isShowing }

    /// Where the line stands now, read from the app rather than this view's
    /// copy, so a Stop answered later sees the chat as it is then.
    private var moment: PcControlling.Moment {
        PcControlling.Moment(chat: appState.activeSessionId, dashboard: appState.activeDashboardID, turn: turn, busy: appState.isBusy)
    }

    var body: some View {
        Group {
            if let controlling, isShowing {
                strip(controlling)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, 12)
        .padding(.bottom, shows ? 6 : 0)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: controlling)
        .onChange(of: openChatID) {
            controlling = nil
            stopFailedOn = nil
        }
        .onChange(of: isBusy) { _, busy in
            if busy { turn += 1 }
        }
        .task(id: "\(openChatID ?? "")|\(isBusy)|\(isShowing)") {
            guard openChatID != nil, isShowing, isBusy else {
                controlling = nil
                stopFailedOn = nil
                return
            }
            let asked = openChatID
            repeat {
                let started = revision
                let now = await appState.loadOpenChatPcControl()
                guard !Task.isCancelled, openChatID == asked else { return }
                if revision == started {
                    controlling = now
                    stopFailedOn = PcControlling.failedStop(stopFailedOn, after: now)
                }
                try? await Task.sleep(for: PcControlling.refreshInterval)
            } while !Task.isCancelled
        }
    }

    private func strip(_ item: PcControlling) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(Color.conduitAura)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppLocalization.string("\(appState.openChatBotName) is controlling \(item.name)", table: .chat))
                    .scaledFont(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if stopFailedOn == item.computer {
                    Text(AppLocalization.string("Couldn't stop it. Try again.", table: .chat))
                        .scaledFont(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button {
                Haptics.medium()
                revision += 1
                controlling = nil
                stopFailedOn = nil
                let pressed = moment
                Task {
                    let stopped = await appState.stopPcControl(item)
                    // Only for the chat Stop was pressed in, still on the same
                    // dashboard and still in its turn: another chat's reads, or
                    // a turn that ended (another one started included), are left alone.
                    let landing = PcControlling.stopLanding(stopped: stopped, computer: item.computer, pressed: pressed, now: moment)
                    guard landing != .ignore else { return }
                    // A read that started while Stop was on its way can't bring the line back.
                    revision += 1
                    if case .failed(let computer) = landing {
                        // Couldn't reach the host: the line comes back, saying so, for another try.
                        controlling = item
                        stopFailedOn = computer
                    } else {
                        controlling = nil
                    }
                }
            } label: {
                Label(AppLocalization.string("Stop"), systemImage: "stop.fill")
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityHint(Text(AppLocalization.string("Stops the bot controlling your computer. Its next action asks you again.", table: .chat)))
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .conduitGlassControl(cornerRadius: 20, tint: .clear)
    }
}
