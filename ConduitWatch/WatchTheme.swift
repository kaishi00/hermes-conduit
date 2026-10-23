//
//  WatchTheme.swift
//  Conduit Watch
//
//  The Watch app in the iPhone's V2 look: the accent picked in Conduit on
//  the iPhone (gold unless changed), the dark backdrop with its soft glow,
//  the gold voice button with its five bars, and the call's level bars
//  (blue while it listens, the accent while Hermes speaks, amber when the
//  call needs the user).
//

import SwiftUI

extension Color {
    /// Conduit's listening blue (`conduitAura` on the iPhone).
    static let watchAura = Color(red: 0.38, green: 0.58, blue: 0.98)
    /// V2's approval amber (`conduitAttention`, dark).
    static let watchAttention = Color(red: 0.96, green: 0.65, blue: 0.24)
}

/// The iPhone's accent presets (ConduitAccentChoice in Theme.swift), in
/// their dark shades: the Watch is always dark. The iPhone shares the pick
/// in its WatchPhoneContext as ConduitAccentChoice's raw value; an older
/// iPhone app shares none, and a choice this Watch app doesn't know yet
/// (a newer iPhone app's) draws gold too. A new preset goes in both lists.
/// A colour of the user's own comes as "#RRGGBB" and draws in the dark
/// shade the iPhone works out from it.
enum WatchAccent {
    static func color(_ choice: String?) -> Color {
        if let choice, let custom = CustomAccentColor(hex: choice) {
            let shade = custom.darkShade
            return Color(red: shade.red, green: shade.green, blue: shade.blue)
        }
        switch choice {
        case "blue": return Color(red: 0.33, green: 0.58, blue: 0.98)
        case "green": return Color(red: 0.30, green: 0.72, blue: 0.47)
        case "teal": return Color(red: 0.22, green: 0.70, blue: 0.75)
        case "purple": return Color(red: 0.62, green: 0.48, blue: 0.96)
        case "pink": return Color(red: 0.93, green: 0.42, blue: 0.64)
        default: return Color(red: 0.88, green: 0.67, blue: 0.28)
        }
    }
}

private struct WatchAccentKey: EnvironmentKey {
    static let defaultValue = WatchAccent.color(nil)
}

extension EnvironmentValues {
    /// The accent, set once at the root from the iPhone's pick.
    var watchAccent: Color {
        get { self[WatchAccentKey.self] }
        set { self[WatchAccentKey.self] = newValue }
    }
}

// MARK: - Backdrop

/// V2's backdrop on the Watch: near black, the accent's glow up top and a
/// faint blue one low down, still (nothing drifts on the wrist).
struct WatchBackdrop: View {
    @Environment(\.watchAccent) private var accent
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.052, blue: 0.072)
            if !isLuminanceReduced {
                RadialGradient(
                    colors: [accent.opacity(0.30), .clear],
                    center: UnitPoint(x: 0.2, y: 0),
                    startRadius: 0,
                    endRadius: 170
                )
                RadialGradient(
                    colors: [Color.watchAura.opacity(0.16), .clear],
                    center: UnitPoint(x: 0.9, y: 1),
                    startRadius: 0,
                    endRadius: 150
                )
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Draws the V2 backdrop behind a screen in a NavigationStack.
    func watchBackdrop() -> some View {
        containerBackground(for: .navigation) { WatchBackdrop() }
    }
}

// MARK: - Card

/// V2's card on the Watch: a soft raised panel over the backdrop.
struct WatchCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

// MARK: - Voice button

/// The iPhone's V2 voice button: an accent circle with five dark bars.
struct WatchVoiceButtonFace: View {
    var size: CGFloat = 76

    @Environment(\.watchAccent) private var accent
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private static let heights: [CGFloat] = [0.34, 0.62, 0.9, 0.62, 0.34]

    var body: some View {
        HStack(spacing: size * 0.055) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(Color.black.opacity(0.82))
                    .frame(width: size * 0.065, height: size * 0.4 * Self.heights[index])
            }
        }
        .frame(width: size, height: size)
        .background(accent, in: Circle())
        .shadow(color: accent.opacity(isLuminanceReduced ? 0 : 0.35), radius: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - Call level

/// V2's call level on the Watch: thin bars in an arch over a soft glow,
/// coloured and moving by what the call is doing. No engine feeds a common
/// audio level, so the bars move with the phase, as on the iPhone. Nothing
/// moves in always-on, with Reduce Motion on, in Low Power Mode or when hot.
struct WatchLevelBars: View {
    enum Mood: Equatable {
        case working
        case listening
        case muted
        case speaking
        case attention
        case done
    }

    let mood: Mood
    var barCount = 15

    @Environment(\.watchAccent) private var accent
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch mood {
        case .working, .listening: return .watchAura
        case .speaking: return accent
        case .muted, .done: return .gray
        case .attention: return .watchAttention
        }
    }

    /// Scale swing and speed, as the iPhone's orb motion.
    private var motion: (amplitude: Double, speed: Double, opacity: Double) {
        switch mood {
        case .working: return (0.05, 1.4, 0.65)
        case .listening: return (0.035, 1.9, 1)
        case .speaking: return (0.06, 4.6, 1)
        case .attention: return (0.02, 1, 1)
        case .muted: return (0, 0, 0.8)
        case .done: return (0, 0, 0.6)
        }
    }

    /// Also still in Low Power Mode or when the Watch runs hot, as the
    /// iPhone's bars are: a call already works the battery hard.
    private var moves: Bool {
        let process = ProcessInfo.processInfo
        return motion.amplitude > 0 && !isLuminanceReduced && !reduceMotion
            && !process.isLowPowerModeEnabled && process.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moves)) { context in
            let t = moves ? context.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { proxy in
                ZStack {
                    if !isLuminanceReduced {
                        Ellipse()
                            .fill(tint.opacity(0.22))
                            .blur(radius: 14)
                            .frame(width: proxy.size.width * 0.9, height: proxy.size.height * 0.8)
                    }
                    HStack(alignment: .center, spacing: 3) {
                        ForEach(0..<barCount, id: \.self) { index in
                            Capsule()
                                .fill(tint)
                                .frame(height: max(3, proxy.size.height * level(index, time: t)))
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .opacity(motion.opacity)
        .animation(.easeInOut(duration: 0.4), value: mood)
        .accessibilityHidden(true)
    }

    /// A bar's height, 0...1: taller in the middle, rippling faster and
    /// higher while Hermes speaks.
    private func level(_ index: Int, time: TimeInterval) -> CGFloat {
        let position = Double(index) / Double(max(1, barCount - 1))
        let arch = 0.25 + 0.5 * sin(position * .pi)
        guard moves else { return CGFloat(mood == .muted || mood == .done ? 0.08 : arch * 0.6) }
        let swing = motion.amplitude * 8
        let ripple = 0.6 * sin(time * motion.speed * 2 + position * 9) + 0.4 * sin(time * motion.speed * 3.1 + position * 23)
        return CGFloat(max(0.06, min(1, arch + ripple * swing * arch)))
    }
}
