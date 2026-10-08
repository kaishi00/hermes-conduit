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
    // Text colors (adapt to light/dark via system colors)
    static var conduitText: Color { Color.primary }
    static var conduitTextSecondary: Color { Color.secondary }
    static var conduitTextTertiary: Color { Color(red: 0.5, green: 0.5, blue: 0.55) }
    // Backgrounds
    static var conduitBackground: Color { Color(.systemBackground) }
    static var conduitSurface: Color { Color(.secondarySystemBackground) }
}

extension Color {
    // Aliases for non-ShapeStyle usage (e.g., UIColor extraction)
    static var conduitAccentColor: Color { .conduitAdaptiveAccent }
    static let conduitBackgroundColor = Color(.systemBackground)
    static let conduitSurfaceColor = Color(.secondarySystemBackground)

    static let conduitAdaptiveAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.88, green: 0.67, blue: 0.28, alpha: 1)
            : UIColor(red: 0.55, green: 0.37, blue: 0.13, alpha: 1)
    })

    static let conduitAdaptiveAccentSoft = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.98, green: 0.83, blue: 0.48, alpha: 1)
            : UIColor(red: 0.67, green: 0.49, blue: 0.28, alpha: 1)
    })
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
}

// MARK: - Living canvas

/// The slow background drift is subtle, but the two full-screen blurred
/// circles are expensive to composite continuously. Keep their motion bounded
/// and stop scheduling frames when the app or device should conserve work.
enum ConduitBackdropMotionPolicy {
    static let framesPerSecond = 30
    static let cycleDuration: TimeInterval = 26

    static func shouldAnimate(
        sceneIsActive: Bool,
        reduceMotion: Bool,
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        let thermalStateAllowsMotion = thermalState == .nominal || thermalState == .fair
        return sceneIsActive && !reduceMotion && !lowPowerMode && thermalStateAllowsMotion
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
struct ConduitBackdropMotionClock {
    private var motionOrigin: TimeInterval
    private var pauseStartedAt: TimeInterval?
    private var hasAnimated = false
    private(set) var pausedProgress: CGFloat = 0

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
            } else {
                motionOrigin = now
            }
            hasAnimated = true
        } else {
            guard pauseStartedAt == nil else { return }
            pausedProgress = hasAnimated
                ? ConduitBackdropMotionPolicy.progress(at: now - motionOrigin)
                : 0
            pauseStartedAt = now
        }
    }

    func progress(at now: TimeInterval, isAnimating: Bool) -> CGFloat {
        guard isAnimating, hasAnimated else { return pausedProgress }
        return ConduitBackdropMotionPolicy.progress(at: now - motionOrigin)
    }
}

struct ConduitBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var devicePower = DevicePowerState.shared
    @State private var motionClock = ConduitBackdropMotionClock()

    private var shouldAnimate: Bool {
        ConduitBackdropMotionPolicy.shouldAnimate(
            sceneIsActive: scenePhase == .active,
            reduceMotion: reduceMotion,
            lowPowerMode: devicePower.isLowPowerModeEnabled,
            thermalState: devicePower.thermalState
        )
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / Double(ConduitBackdropMotionPolicy.framesPerSecond),
                paused: !shouldAnimate
            )
        ) { _ in
            GeometryReader { proxy in
                let drift = motionClock.progress(
                    at: ProcessInfo.processInfo.systemUptime,
                    isAnimating: shouldAnimate
                )
                ZStack {
                    base

                    Circle()
                        .fill(Color.conduitAccent.opacity(colorScheme == .dark ? 0.20 : 0.055))
                        .frame(width: proxy.size.width * 0.92)
                        .blur(radius: 72)
                        .offset(
                            x: (-0.18 + 0.48 * drift) * proxy.size.width,
                            y: (-0.24 - 0.10 * drift) * proxy.size.height
                        )

                    Circle()
                        .fill(Color.conduitAura.opacity(colorScheme == .dark ? 0.14 : 0.055))
                        .frame(width: proxy.size.width * 0.84)
                        .blur(radius: 84)
                        .offset(
                            x: (0.26 - 0.58 * drift) * proxy.size.width,
                            y: (0.28 + 0.08 * drift) * proxy.size.height
                        )

                    LinearGradient(
                        colors: [Color.black.opacity(colorScheme == .dark ? 0.18 : 0), .clear],
                        startPoint: .bottom,
                        endPoint: .center
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .onChange(of: shouldAnimate, initial: true) { _, isAnimating in
            motionClock.setAnimating(isAnimating, at: ProcessInfo.processInfo.systemUptime)
        }
        .ignoresSafeArea()
    }

    private var base: Color {
        colorScheme == .dark
            ? Color(red: 0.045, green: 0.052, blue: 0.072)
            : Color(red: 0.94, green: 0.95, blue: 0.98)
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
