//
//  Theme.swift
//  Conduit
//
//  Color palette and Liquid Glass styling.
//

import SwiftUI
import UIKit

extension ShapeStyle where Self == Color {
    // Primary accent — amber/gold, matching the RN app's signature look
    static var conduitAccent: Color { .conduitAdaptiveAccent }
    static var conduitAccentSoft: Color { .conduitAdaptiveAccentSoft }
    static var conduitAura: Color { Color(red: 0.38, green: 0.58, blue: 0.98) }
    // V2 status tokens. Each is always paired with an SF Symbol and a word.
    /// Approval waiting (amber shield).
    static var conduitAttention: Color { .conduitAdaptiveAttention }
    /// Finished work (green check).
    static var conduitSuccess: Color { .conduitAdaptiveSuccess }
    /// Scheduled runs (purple clock).
    static var conduitScheduled: Color { .conduitAdaptiveScheduled }
    /// Hermes speaking in a voice call (violet).
    static var conduitVoice: Color { .conduitAdaptiveVoice }
    // Text colors (adapt to light/dark via system colors)
    static var conduitText: Color { Color.primary }
    static var conduitTextSecondary: Color { Color.secondary }
    // Backgrounds
    static var conduitBackground: Color { Color(.systemBackground) }
    static var conduitSurface: Color { Color(.secondarySystemBackground) }
}

/// Quiet information (timestamps, hints, counts) at the tertiary level,
/// raised to secondary under Increase Contrast: tertiary is far below
/// 4.5:1 on the light background (#830).
struct ConduitTertiaryStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> HierarchicalShapeStyle {
        environment.colorSchemeContrast == .increased ? .secondary : .tertiary
    }
}

extension ShapeStyle where Self == ConduitTertiaryStyle {
    static var conduitTertiary: ConduitTertiaryStyle { ConduitTertiaryStyle() }
}

extension Color {
    // Aliases for non-ShapeStyle usage (e.g., UIColor extraction)
    static var conduitAccentColor: Color { .conduitAdaptiveAccent }
    static let conduitBackgroundColor = Color(.systemBackground)
    static let conduitSurfaceColor = Color(.secondarySystemBackground)

    /// The accent picked in Settings (#697), read from the trait the root
    /// view sets, so a new pick redraws every view without rebuilding any.
    static let conduitAdaptiveAccent = Color(uiColor: .conduitAccent)

    static let conduitAdaptiveAttention = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.96, green: 0.65, blue: 0.24, alpha: 1)
            : UIColor(red: 0.74, green: 0.42, blue: 0.04, alpha: 1)
    })

    static let conduitAdaptiveSuccess = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.38, green: 0.80, blue: 0.50, alpha: 1)
            : UIColor(red: 0.13, green: 0.53, blue: 0.27, alpha: 1)
    })

    static let conduitAdaptiveScheduled = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.67, green: 0.56, blue: 0.98, alpha: 1)
            : UIColor(red: 0.44, green: 0.32, blue: 0.80, alpha: 1)
    })

    static let conduitAdaptiveVoice = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.74, green: 0.53, blue: 0.98, alpha: 1)
            : UIColor(red: 0.51, green: 0.31, blue: 0.82, alpha: 1)
    })

    static let conduitAdaptiveAccentSoft = Color(uiColor: UIColor { traits in
        traits.conduitAccent.softColor(dark: traits.userInterfaceStyle == .dark)
    })

    /// A sent bubble's gradient stops, in the picked accent.
    static let conduitUserBubble = Color(uiColor: .conduitUserBubble)
    static let conduitUserBubbleShade = Color(uiColor: .conduitUserBubbleShade)
}

// MARK: - Accent choice

/// The accent colour the user picks in Settings > Appearance (#697): their
/// own message bubbles and Conduit's highlights. Amber is the original look.
enum ConduitAccentChoice: String, CaseIterable, Identifiable, Sendable {
    case amber, blue, green, teal, purple, pink

    static let storageKey = "conduit.accentChoice"
    /// The pick before the user makes one: the original look.
    static let defaultChoice = ConduitAccentChoice.amber

    var id: String { rawValue }

    var title: String {
        switch self {
        case .amber: return AppLocalization.string("Amber")
        case .blue: return AppLocalization.string("Blue")
        case .green: return AppLocalization.string("Green")
        case .teal: return AppLocalization.string("Teal")
        case .purple: return AppLocalization.string("Purple")
        case .pink: return AppLocalization.string("Pink")
        }
    }

    /// The accent itself. The light-mode shade is darker so white text on a
    /// sent bubble stays readable. Presets are sRGB literals: the selection
    /// contrast pick reads their components.
    func color(dark: Bool) -> UIColor {
        switch self {
        case .amber: return dark ? UIColor(red: 0.88, green: 0.67, blue: 0.28, alpha: 1) : UIColor(red: 0.55, green: 0.37, blue: 0.13, alpha: 1)
        case .blue: return dark ? UIColor(red: 0.33, green: 0.58, blue: 0.98, alpha: 1) : UIColor(red: 0.12, green: 0.36, blue: 0.80, alpha: 1)
        case .green: return dark ? UIColor(red: 0.30, green: 0.72, blue: 0.47, alpha: 1) : UIColor(red: 0.09, green: 0.47, blue: 0.27, alpha: 1)
        case .teal: return dark ? UIColor(red: 0.22, green: 0.70, blue: 0.75, alpha: 1) : UIColor(red: 0.04, green: 0.45, blue: 0.51, alpha: 1)
        case .purple: return dark ? UIColor(red: 0.62, green: 0.48, blue: 0.96, alpha: 1) : UIColor(red: 0.43, green: 0.28, blue: 0.80, alpha: 1)
        case .pink: return dark ? UIColor(red: 0.93, green: 0.42, blue: 0.64, alpha: 1) : UIColor(red: 0.76, green: 0.19, blue: 0.44, alpha: 1)
        }
    }

    /// The lighter companion shade (`conduitAccentSoft`).
    func softColor(dark: Bool) -> UIColor {
        switch self {
        case .amber: return dark ? UIColor(red: 0.98, green: 0.83, blue: 0.48, alpha: 1) : UIColor(red: 0.67, green: 0.49, blue: 0.28, alpha: 1)
        case .blue: return dark ? UIColor(red: 0.58, green: 0.76, blue: 1.00, alpha: 1) : UIColor(red: 0.27, green: 0.48, blue: 0.85, alpha: 1)
        case .green: return dark ? UIColor(red: 0.54, green: 0.86, blue: 0.64, alpha: 1) : UIColor(red: 0.21, green: 0.56, blue: 0.37, alpha: 1)
        case .teal: return dark ? UIColor(red: 0.50, green: 0.86, blue: 0.89, alpha: 1) : UIColor(red: 0.16, green: 0.55, blue: 0.60, alpha: 1)
        case .purple: return dark ? UIColor(red: 0.79, green: 0.70, blue: 1.00, alpha: 1) : UIColor(red: 0.54, green: 0.41, blue: 0.85, alpha: 1)
        case .pink: return dark ? UIColor(red: 1.00, green: 0.65, blue: 0.79, alpha: 1) : UIColor(red: 0.83, green: 0.35, blue: 0.56, alpha: 1)
        }
    }

    /// Black or white, whichever stands out on `fill`: the one with the
    /// higher WCAG contrast (they cross at a luminance of about 0.179).
    static func markColor(on fill: UIColor) -> UIColor {
        let luminance = fill.conduitRelativeLuminance
        let onBlack = (luminance + 0.05) / 0.05
        let onWhite = 1.05 / (luminance + 0.05)
        return onBlack >= onWhite ? .black : .white
    }
}

/// The accent in force: a preset, or a colour of the user's own. A custom
/// one is stored under the same key as "#RRGGBB" in place of a preset's
/// name, so it syncs and reaches the Watch as the presets do; an app too
/// old to know it reads the default.
enum ConduitAccent: Hashable, Sendable, RawRepresentable {
    case preset(ConduitAccentChoice)
    case custom(CustomAccentColor)

    static let storageKey = ConduitAccentChoice.storageKey
    static let defaultValue = ConduitAccent.preset(ConduitAccentChoice.defaultChoice)

    init?(rawValue: String) {
        if let preset = ConduitAccentChoice(rawValue: rawValue) {
            self = .preset(preset)
        } else if let custom = CustomAccentColor(hex: rawValue) {
            self = .custom(custom)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .preset(let choice): return choice.rawValue
        case .custom(let custom): return custom.hex
        }
    }

    /// The accent itself, as ConduitAccentChoice.color(dark:).
    func color(dark: Bool) -> UIColor {
        switch self {
        case .preset(let choice): return choice.color(dark: dark)
        case .custom(let custom): return UIColor(dark ? custom.darkShade : custom.lightShade)
        }
    }

    /// The lighter companion shade (`conduitAccentSoft`).
    func softColor(dark: Bool) -> UIColor {
        switch self {
        case .preset(let choice): return choice.softColor(dark: dark)
        case .custom(let custom): return UIColor(dark ? custom.softDarkShade : custom.softLightShade)
        }
    }

    /// The fill of the user's own message bubbles, which carry white text:
    /// the light-mode accent, in dark mode too. The dark-mode accent is light
    /// enough to read on the dark backdrop, and so too light under white
    /// text. AccentContrastTests holds both to WCAG AA.
    var bubbleColor: UIColor { color(dark: false) }

    /// The bubble's lower-trailing gradient stop: the same shade, darker and
    /// opaque, so white text keeps its contrast whatever lies behind.
    var bubbleShadeColor: UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        bubbleColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor(red: red * 0.8, green: green * 0.8, blue: blue * 0.8, alpha: 1)
    }

    /// The tint a text selection takes on a sent bubble: the system draws
    /// selections in the accent, which disappears on an accent bubble.
    var selectionColorOnBubble: UIColor { ConduitAccentChoice.markColor(on: bubbleColor) }
}

extension UIColor {
    convenience init(_ rgb: CustomAccentColor.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

extension CustomAccentColor {
    /// The colour as text and tint on the app's backdrop: the shade that
    /// reads in the mode it draws in. A group room draws each bot in its
    /// own colour this way.
    var readableColor: UIColor {
        let light = UIColor(lightShade)
        let dark = UIColor(darkShade)
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
}

extension CustomAccentColor {
    /// The last colour of the user's own, kept on this device while a
    /// preset is picked.
    static let lastPickKey = "conduit.accentLastCustomColor"
    /// The custom swatch's colour before the user's first pick: a coral no
    /// preset has.
    static let firstPick = CustomAccentColor(red: 0.89, green: 0.38, blue: 0.25)
}

/// Carries the accent choice through UIKit traits, so the dynamic accent
/// colours resolve it wherever they draw, SwiftUI and UIKit alike.
struct ConduitAccentTrait: UITraitDefinition {
    static let defaultValue = ConduitAccent.defaultValue
    static let affectsColorAppearance = true
    static let name = "ConduitAccent"
}

extension UITraitCollection {
    var conduitAccent: ConduitAccent { self[ConduitAccentTrait.self] }
}

extension UIMutableTraits {
    var conduitAccent: ConduitAccent {
        get { self[ConduitAccentTrait.self] }
        set { self[ConduitAccentTrait.self] = newValue }
    }
}

private struct ConduitAccentEnvironmentKey: EnvironmentKey {
    static let defaultValue = ConduitAccent.defaultValue
}

extension ConduitAccentEnvironmentKey: UITraitBridgedEnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> ConduitAccent {
        traitCollection.conduitAccent
    }

    static func write(to mutableTraits: inout UIMutableTraits, value: ConduitAccent) {
        mutableTraits.conduitAccent = value
    }
}

extension EnvironmentValues {
    /// Set once at the root from the saved choice.
    var conduitAccent: ConduitAccent {
        get { self[ConduitAccentEnvironmentKey.self] }
        set { self[ConduitAccentEnvironmentKey.self] = newValue }
    }
}

extension UIColor {
    static let conduitAccent = UIColor { traits in
        traits.conduitAccent.color(dark: traits.userInterfaceStyle == .dark)
    }

    /// See ConduitAccent.selectionColorOnBubble.
    static let conduitSelectionOnAccent = UIColor { traits in
        traits.conduitAccent.selectionColorOnBubble
    }

    /// A sent bubble's fill, top-leading and bottom-trailing stops. See
    /// ConduitAccent.bubbleColor.
    static let conduitUserBubble = UIColor { traits in
        traits.conduitAccent.bubbleColor
    }
    static let conduitUserBubbleShade = UIColor { traits in
        traits.conduitAccent.bubbleShadeColor
    }

    /// WCAG relative luminance of an sRGB colour.
    var conduitRelativeLuminance: CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

// MARK: - App identity

/// Uses the real app artwork where Conduit identity matters. The full artwork
/// remains recognizable at this size; compact functional controls should use
/// semantic system symbols instead.
struct ConduitAppIconArtwork: View {
    let assetName: String
    let size: CGFloat

    var body: some View {
        Image(assetName)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Color.conduitAccent.opacity(0.28), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.18), radius: size * 0.10, y: size * 0.04)
            .accessibilityHidden(true)
    }
}

// MARK: - Motion

enum ConduitMotion {
    static let response = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let transition = Animation.spring(response: 0.46, dampingFraction: 0.84)
    static let settle = Animation.easeOut(duration: 0.22)

    // V2 motion: the prototype's two curves as springs.
    /// The prototype's `cubic-bezier(.32,.72,0,1)` ease: pushes, resizes,
    /// list expand and collapse.
    static let easeSpring = Animation.spring(response: 0.5, dampingFraction: 0.9)
    /// The prototype's overshoot curve: tab highlight, menus, toggles, presses.
    static let overshootSpring = Animation.spring(response: 0.45, dampingFraction: 0.72)
    /// How long the fade-out before a profile switch takes; the switch
    /// waits this long before moving content out of sight.
    static let fadeOutDuration: TimeInterval = 0.17
    /// The quick fade-out before a profile switch.
    static let fadeOut = Animation.easeOut(duration: fadeOutDuration)

    /// Under Reduce Motion every spring becomes the plain settle fade.
    static func ease(reduceMotion: Bool) -> Animation {
        reduceMotion ? settle : easeSpring
    }

    static func overshoot(reduceMotion: Bool) -> Animation {
        reduceMotion ? settle : overshootSpring
    }
}

/// V2's shared press feedback: every tappable control scales to 0.95 on the
/// overshoot spring, and holds still under Reduce Motion.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableButtonLabel(configuration: configuration)
    }
}

private struct PressableButtonLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(ConduitMotion.overshoot(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

// MARK: - Living canvas

/// The slow background drift is subtle, but every tick redraws the backdrop
/// and the glass sampling it. Keep the motion bounded and stop scheduling
/// frames when the app or device should conserve work.
enum ConduitBackdropMotionPolicy {
    /// Every frame also redraws each glass surface on top, which samples the
    /// backdrop. The glows are 72-84 pt soft and drift slowly, so a 10 fps
    /// step (about 3 pt on a phone) can't be seen.
    static let framesPerSecond = 10
    static let cycleDuration: TimeInterval = 26

    /// `drifts` is false for sheets (the sidebar drawer included) and pushed
    /// detail screens: they hold the static composition so only the main chat,
    /// the persistent sidebar column and sign-in run a timeline, rather than
    /// one per stacked layer while a sheet is open.
    ///
    /// `idle` is `InteractionIdleState.isIdle`: nothing touched, typed or
    /// running for a couple of minutes. An iPad that never auto-locks would
    /// otherwise draw the drift all night with nobody watching.
    static func shouldAnimate(
        drifts: Bool,
        sceneIsActive: Bool,
        reduceMotion: Bool,
        lowPowerMode: Bool,
        idle: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        let thermalStateAllowsMotion = thermalState == .nominal || thermalState == .fair
        return drifts && sceneIsActive && !reduceMotion && !lowPowerMode && !idle && thermalStateAllowsMotion
    }

    /// One smooth out-and-back drift over 26 seconds, matching the previous
    /// 13-second ease-in/ease-out animation with autoreverse.
    static func progress(at activeTime: TimeInterval) -> CGFloat {
        let remainder = activeTime.truncatingRemainder(dividingBy: cycleDuration)
        let normalized = (remainder < 0 ? remainder + cycleDuration : remainder) / cycleDuration
        return CGFloat((1 - cos(2 * .pi * normalized)) / 2)
    }
}

/// Tracks only active monotonic time so a paused backdrop freezes in place and
/// resumes at the same phase. Reduce Motion from launch keeps the original
/// static composition until the user enables motion.
///
/// The view renders before `onChange` reports a pause or resume, so the phase
/// is derived from the clock's own state rather than the caller's current
/// `shouldAnimate`: it stays live until the pause is recorded and stays frozen
/// until the resume is recorded, which avoids a one-frame jump either way.
/// A repeated resume while already live is a no-op, so it never resets the phase.
struct ConduitBackdropMotionClock {
    private var motionOrigin: TimeInterval
    private var pauseStartedAt: TimeInterval?
    private var hasAnimated = false

    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        motionOrigin = now
    }

    mutating func setAnimating(_ isAnimating: Bool, at now: TimeInterval) {
        if isAnimating {
            if let pauseStartedAt {
                if hasAnimated {
                    motionOrigin += now - pauseStartedAt
                } else {
                    motionOrigin = now
                }
                self.pauseStartedAt = nil
            } else if !hasAnimated {
                motionOrigin = now
            }
            hasAnimated = true
        } else {
            guard pauseStartedAt == nil else { return }
            pauseStartedAt = now
        }
    }

    func progress(at now: TimeInterval) -> CGFloat {
        guard hasAnimated else { return 0 }
        return ConduitBackdropMotionPolicy.progress(at: (pauseStartedAt ?? now) - motionOrigin)
    }
}

struct ConduitBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var devicePower = DevicePowerState.shared
    /// Publishes only when Conduit goes idle or wakes, never per touch.
    @ObservedObject private var interactionIdle = InteractionIdleState.shared
    @State private var motionClock = ConduitBackdropMotionClock()
    private let drifts: Bool
    /// The warm glow's color. V2 tints it with the active profile's color;
    /// nil keeps the gold accent.
    private let glowTint: Color?

    /// Pass `drifts: true` only for the app's main surfaces (chat, persistent
    /// sidebar column, sign-in). Sheets and pushed screens keep the still
    /// composition.
    init(drifts: Bool = false, glowTint: Color? = nil) {
        self.drifts = drifts
        self.glowTint = glowTint
    }

    private var shouldAnimate: Bool {
        ConduitBackdropMotionPolicy.shouldAnimate(
            drifts: drifts,
            sceneIsActive: scenePhase == .active,
            reduceMotion: reduceMotion,
            lowPowerMode: devicePower.isLowPowerModeEnabled,
            idle: interactionIdle.isIdle,
            thermalState: devicePower.thermalState
        )
    }

    var body: some View {
        // Only the two drifting circles live inside the timeline; the base
        // colour and bottom shade never change between ticks.
        ZStack {
            base
            // Light mode: a faint wash of the glow color over the whole
            // screen, so the profile's color reads beyond the glow itself
            // and the page isn't plain white.
            if colorScheme != .dark {
                glowColor.opacity(0.05)
            }

            TimelineView(
                .animation(
                    minimumInterval: 1.0 / Double(ConduitBackdropMotionPolicy.framesPerSecond),
                    paused: !shouldAnimate
                )
            ) { _ in
                GeometryReader { proxy in
                    let drift = motionClock.progress(at: ProcessInfo.processInfo.systemUptime)
                    ZStack {
                        ConduitGlow(
                            // On the light base a dark-mode-strength glow
                            // washes out, so light mode draws it stronger.
                            color: glowColor.opacity(colorScheme == .dark ? 0.20 : 0.24),
                            diameter: min(proxy.size.width * 0.92, proxy.size.height),
                            blur: 72
                        )
                        .offset(
                            x: (-0.18 + 0.48 * drift) * proxy.size.width,
                            y: (-0.24 - 0.10 * drift) * proxy.size.height
                        )

                        ConduitGlow(
                            color: Color.conduitAura.opacity(colorScheme == .dark ? 0.14 : 0.10),
                            diameter: min(proxy.size.width * 0.84, proxy.size.height),
                            blur: 84
                        )
                        .offset(
                            x: (0.26 - 0.58 * drift) * proxy.size.width,
                            y: (0.28 + 0.08 * drift) * proxy.size.height
                        )
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }

            LinearGradient(
                colors: [Color.black.opacity(colorScheme == .dark ? 0.18 : 0), .clear],
                startPoint: .bottom,
                endPoint: .center
            )
        }
        // Flattened into one opaque image, drawn again only when the glow
        // moves (10 fps at most) or changes color, so nothing scrolling over
        // it redraws it.
        .drawingGroup(opaque: true)
        .animation(.easeInOut(duration: 0.6), value: glowTint)
        .onChange(of: shouldAnimate, initial: true) { _, isAnimating in
            motionClock.setAnimating(isAnimating, at: ProcessInfo.processInfo.systemUptime)
        }
        .ignoresSafeArea()
        // The glows reach well past the backdrop's frame, and clipping only
        // hides them: still hit-testable, the chat column's took touches
        // (and accessibility's hit tests) meant for the list beside it on an
        // iPad. Nothing on a backdrop takes a tap.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var glowColor: Color { glowTint ?? Color.conduitAccent }

    private var base: Color {
        colorScheme == .dark
            ? Color(red: 0.045, green: 0.052, blue: 0.072)
            : Color(red: 0.94, green: 0.95, blue: 0.98)
    }
}

/// A soft glow: a disc as it looks blurred, drawn as a radial gradient. The
/// backdrop's glows were blurred circles, and a 72-84 pt Gaussian blur over
/// most of the screen was redone on every drift tick, ten times a second,
/// on the GPU the scrolling chat shares. A gradient costs almost nothing to
/// draw and looks the same.
struct ConduitGlow: View {
    let color: Color
    let diameter: CGFloat
    /// The blur the glow imitates (a Gaussian's standard deviation, as
    /// `.blur(radius:)` takes it).
    let blur: CGFloat

    var body: some View {
        let reach = diameter / 2 + ConduitGlowProfile.reachInBlurs * blur
        let intensities = ConduitGlowProfile.intensities(radius: diameter / 2, blur: blur)
        let last = Double(max(intensities.count - 1, 1))
        Circle()
            .fill(RadialGradient(
                stops: intensities.enumerated().map { index, intensity in
                    Gradient.Stop(color: color.opacity(intensity), location: Double(index) / last)
                },
                center: .center,
                startRadius: 0,
                endRadius: reach
            ))
            .frame(width: 2 * reach, height: 2 * reach)
    }
}

/// How bright a blurred disc is from its centre outwards.
@MainActor
enum ConduitGlowProfile {
    /// The gradient runs out to the disc's edge plus three blurs, where a
    /// Gaussian has all but faded.
    static let reachInBlurs: CGFloat = 3
    static let stopCount = 20

    private struct Key: Hashable { let radius: Int; let blur: Int }
    private static var cache: [Key: [Double]] = [:]

    /// The brightness (0...1) at `stopCount` evenly spaced distances from
    /// the centre out to the reach: the disc convolved with the Gaussian,
    /// integrated over the disc. Cached per whole-point size, so a drift
    /// tick only looks it up.
    static func intensities(radius: CGFloat, blur: CGFloat) -> [Double] {
        let key = Key(radius: Int(radius.rounded()), blur: Int(blur.rounded()))
        if let cached = cache[key] { return cached }
        let values = computeIntensities(radius: Double(key.radius), blur: Double(key.blur))
        cache[key] = values
        return values
    }

    nonisolated static func computeIntensities(radius: Double, blur: Double) -> [Double] {
        guard radius > 0, blur > 0 else {
            return Array(repeating: radius > 0 ? 1 : 0, count: stopCount)
        }
        let reach = radius + Double(reachInBlurs) * blur
        let rings = 40, angles = 40
        let ringStep = radius / Double(rings)
        let angleStep = Double.pi / Double(angles)
        let twoSigmaSquared = 2 * blur * blur
        // Half the disc by symmetry, then doubled.
        let scale = 2 * ringStep * angleStep / (Double.pi * twoSigmaSquared)
        return (0..<stopCount).map { index in
            let distance = reach * Double(index) / Double(stopCount - 1)
            var total = 0.0
            for ring in 0..<rings {
                let rho = (Double(ring) + 0.5) * ringStep
                for angle in 0..<angles {
                    let theta = (Double(angle) + 0.5) * angleStep
                    let squared = distance * distance + rho * rho - 2 * distance * rho * cos(theta)
                    total += exp(-squared / twoSigmaSquared) * rho
                }
            }
            return min(max(total * scale, 0), 1)
        }
    }
}

/// Keeps adjacent glass controls composited as a group on iOS 26 while
/// retaining the same layout on earlier OS versions.
struct ConduitGlassGroup<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - Liquid Glass compatibility

extension View {
    /// Uses the native iOS 26 glass compositor when it is available. The
    /// fallback intentionally stays material-based rather than attempting to
    /// imitate glass with custom blur stacks.
    ///
    /// Both branches of both helpers in this section — this one and
    /// `conduitGlassControl` — must keep the same corner radius and the same
    /// covered area, so the two OS paths render the same card geometry. A
    /// branch that drew a smaller surface would render a clipped card on that
    /// path. The fallback cannot be exercised by any simulator runtime this
    /// project has available (iOS 26.5 only, locally and in CI), which is why
    /// this note stands in for a test of it: verify by inspection when changing
    /// either branch.
    @ViewBuilder
    func conduitGlassSurface(
        cornerRadius: CGFloat,
        tint: Color = .clear,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func conduitGlassControl(
        cornerRadius: CGFloat = 18,
        tint: Color = .clear,
        prominent: Bool = false,
        interactive: Bool = true
    ) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(
                    .regular.tint(prominent ? tint.opacity(0.88) : tint).interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
            } else {
                self.glassEffect(
                    .regular.tint(prominent ? tint.opacity(0.88) : tint),
                    in: .rect(cornerRadius: cornerRadius)
                )
            }
        } else {
            self
                .background(
                    prominent ? tint.opacity(0.92) : Color.conduitSurface.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func conduitGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(.plain)
        }
    }
}

extension View {
    /// For the photo picker, which runs in another process and is handed the
    /// tint of the view presenting it. The app-wide `.conduitAccent` resolves the choice from a
    /// trait that process never sees, so it falls back to amber there (#748):
    /// hand it the plain colour of the current pick instead.
    func conduitOutOfProcessAccentTint() -> some View {
        modifier(OutOfProcessAccentTint())
    }
}

private struct OutOfProcessAccentTint: ViewModifier {
    @Environment(\.conduitAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.tint(Color(uiColor: accent.color(dark: colorScheme == .dark)))
    }
}

/// Gives the window the chosen accent as its tint, for system screens Conduit
/// presents but doesn't draw, and as its accent trait, for the sheets it does. The colour is resolved, not dynamic: a dynamic
/// one sent to another process loses the pick (#748). It is set again when
/// the window turns light or dark: the window's own trait change, since the
/// tinting view is never laid out again and its changes can arrive late.
struct WindowAccentTint: UIViewRepresentable {
    let choice: ConduitAccent

    func makeUIView(context: Context) -> TintingView {
        let view = TintingView()
        view.isUserInteractionEnabled = false
        view.choice = choice
        return view
    }

    func updateUIView(_ view: TintingView, context: Context) {
        view.choice = choice
    }

    final class TintingView: UIView {
        var choice = ConduitAccent.defaultValue {
            didSet { if choice != oldValue { applyTint() } }
        }

        private weak var observedWindow: UIWindow?
        private var styleRegistration: (any UITraitChangeRegistration)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if observedWindow !== window {
                if let styleRegistration { observedWindow?.unregisterForTraitChanges(styleRegistration) }
                styleRegistration = window?.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UIWindow, _: UITraitCollection) in
                    self?.applyTint()
                }
                observedWindow = window
            }
            applyTint()
        }

        private func applyTint() {
            guard let window else { return }
            // Screens presented over the root (sheets: the full message
            // editor) inherit their traits from the window, not from the
            // root's environment, so without this their accent colours
            // resolve the default amber (#920).
            // Reading an override that was never set throws, so ask first.
            let overrides = window.traitOverrides
            if !overrides.contains(ConduitAccentTrait.self) || overrides.conduitAccent != choice {
                window.traitOverrides.conduitAccent = choice
            }
            window.tintColor = choice.color(dark: window.traitCollection.userInterfaceStyle == .dark)
        }
    }
}
