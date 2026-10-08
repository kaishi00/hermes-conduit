//
//  WatchTheme.swift
//  Conduit Watch
//
//  The Watch app's colours and the voice orb, in Conduit's palette: the
//  iPhone's aura blue while it listens, violet while Hermes speaks, amber
//  when the call needs the user.
//

import SwiftUI

extension Color {
    /// Conduit's accent (Theme.swift on the iPhone).
    static let watchAura = Color(red: 0.38, green: 0.58, blue: 0.98)
    static let watchVoice = Color(red: 0.62, green: 0.45, blue: 0.98)
    static let watchAttention = Color(red: 1.0, green: 0.66, blue: 0.24)
}

/// The call's orb: what the call is doing, at a glance, and the control a
/// tap reaches (start, interrupt, continue).
struct WatchVoiceOrb: View {
    enum Mood: Equatable {
        case ready
        case working
        case listening
        case muted
        case speaking
        case attention
        case done
    }

    let mood: Mood
    var size: CGFloat = 96

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ZStack {
            if mood == .speaking, animates {
                ripples
            }
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: tint.opacity(isLuminanceReduced ? 0 : 0.45), radius: breathing ? 12 : 6)
                .scaleEffect(breathing ? 1.04 : 0.98)
            if mood == .working, !isLuminanceReduced {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.3)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: mood == .speaking && animates)
                    // A new image per symbol: one changed in place under an
                    // indefinite effect can keep drawing the old symbol.
                    .id(symbol)
            }
        }
        .frame(width: size, height: size)
        .onAppear { updateBreathing() }
        .onChange(of: mood) { _, _ in updateBreathing() }
        .onChange(of: isLuminanceReduced) { _, _ in updateBreathing() }
        .onChange(of: reduceMotion) { _, _ in updateBreathing() }
    }

    /// Nothing moves in always-on, or with Reduce Motion on.
    private var animates: Bool { !isLuminanceReduced && !reduceMotion }

    /// Listening breathes slowly.
    private func updateBreathing() {
        let wanted = mood == .listening && animates
        guard wanted != breathing else { return }
        if wanted {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathing = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { breathing = false }
        }
    }

    private var ripples: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let progress = (t / 1.8 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(tint.opacity(0.5 * (1 - progress)), lineWidth: 2)
                        .scaleEffect(1 + 0.32 * progress)
                }
            }
        }
    }

    private var tint: Color {
        switch mood {
        case .ready, .working, .listening: return .watchAura
        case .muted, .done: return .gray
        case .speaking: return .watchVoice
        case .attention: return .watchAttention
        }
    }

    private var fill: LinearGradient {
        LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var symbol: String {
        switch mood {
        case .ready: return "mic.fill"
        case .working: return "ellipsis"
        case .listening: return "mic.fill"
        case .muted: return "mic.slash.fill"
        case .speaking: return "waveform"
        case .attention: return "hand.tap.fill"
        case .done: return "checkmark"
        }
    }
}
