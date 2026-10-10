//
//  CarPlayVoiceArtwork.swift
//  Conduit
//
//  The state icons the CarPlay voice screen shows above its title: the
//  Conduit orb, in the live call orb's colours (LiquidOrbView), with the
//  state's mark on it. A mic at Ready, a pulsing ring while listening,
//  cycling dots while thinking, moving bars while responding, and a warning
//  at Error. The orb is calm grey-gold at rest, cool blue while it listens,
//  bright gold while Hermes works and talks, and red at Error. Drawn once
//  per car scale and cached. Pure state feedback: no user or assistant
//  content is ever drawn.
//

import UIKit

@MainActor
enum CarPlayVoiceArtwork {
    /// The template accepts images up to 150 pt square. The icon uses all
    /// of it, and its marks fill the orb rather than sit in its middle:
    /// with dots a seventh of the width and bars about half its height, the
    /// Thinking and Responding icons still looked tiny in the car (#378).
    static let side: CGFloat = 150
    /// The system clamps an animated image's cycle to 0.3 to 5 seconds.
    static let cycleDuration: TimeInterval = 1.2
    static let frameCount = 12
    /// The scale icons are drawn at when the car doesn't say. CarPlay
    /// screens are 2x or 3x; the guide's limit is 450 px at 3x.
    static let defaultScale: CGFloat = 2

    private struct CacheKey: Hashable {
        let state: CarPlayVoiceState
        let scale: CGFloat
    }

    private static var cache: [CacheKey: UIImage] = [:]

    /// Ready and Error are still; the in-conversation states animate.
    static func isAnimated(_ state: CarPlayVoiceState) -> Bool {
        switch state {
        case .ready, .error: return false
        case .listening, .processing, .responding: return true
        }
    }

    /// The car's scale, kept to the 2x and 3x screens CarPlay has: a
    /// bitmap baked at the phone's or a guessed scale looked soft.
    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return defaultScale }
        return min(max(scale.rounded(.up), 2), 3)
    }

    /// The state's icon at `scale`. `includesOrb: false` draws the mark
    /// alone, so tests can measure it against a clear background.
    static func image(
        for state: CarPlayVoiceState,
        scale: CGFloat = defaultScale,
        includesOrb: Bool = true
    ) -> UIImage? {
        let scale = clampedScale(scale)
        let key = CacheKey(state: state, scale: scale)
        if includesOrb, let cached = cache[key] { return cached }
        let palette = OrbPalette.for(state)
        let orb: ((CGContext, CGFloat) -> Void)? = includesOrb
            ? { context, phase in drawOrb(palette, breathing: state == .listening ? phase : nil, in: context) }
            : nil
        let mark = palette.mark
        let image: UIImage?
        switch state {
        case .ready:
            image = still(scale: scale, orb: orb) { drawGlyph("mic.fill", color: mark, in: $0) }
        case .listening:
            image = animated(scale: scale, orb: orb) { context, phase in
                drawPulse(phase: phase, color: mark, in: context)
                drawGlyph("mic.fill", color: mark, in: context)
            }
        case .processing:
            image = animated(scale: scale, orb: orb) { context, phase in drawDots(phase: phase, color: mark, in: context) }
        case .responding:
            image = animated(scale: scale, orb: orb) { context, phase in drawBars(phase: phase, color: mark, in: context) }
        case .error:
            image = still(scale: scale, orb: orb) { drawGlyph("exclamationmark.triangle.fill", color: mark, in: $0) }
        }
        if includesOrb { cache[key] = image }
        return image
    }

    // MARK: - Colours

    /// The orb's colours for one state, from the live call orb's seeds:
    /// gold #FAD47A/#E0AB47 and aura blue #8FB4FF/#6194FA, with their
    /// desaturated idle versions. Baked bitmaps can't follow the car's
    /// appearance, and CarPlay screens are dark nearly always.
    struct OrbPalette {
        /// The lit side of the body, its far side, and the second colour
        /// swirling in from the top left.
        let light: UIColor
        let deep: UIColor
        let swirl: UIColor
        let glow: UIColor
        let mark: UIColor

        static func `for`(_ state: CarPlayVoiceState) -> OrbPalette {
            switch state {
            case .ready:
                return OrbPalette(light: rgb(0xB59B6A), deep: rgb(0x6E5B3A), swirl: rgb(0x5E7598), glow: rgb(0x6E6450), mark: ink)
            case .listening:
                return OrbPalette(light: rgb(0x8FB4FF), deep: rgb(0x3A64C8), swirl: rgb(0xFAD47A), glow: rgb(0x6194FA), mark: .white)
            case .processing, .responding:
                return OrbPalette(light: rgb(0xFAD47A), deep: rgb(0xB07D24), swirl: rgb(0x8FB4FF), glow: rgb(0xE0AB47), mark: ink)
            case .error:
                return OrbPalette(light: rgb(0xFF9A8F), deep: rgb(0xB8362E), swirl: rgb(0xFFC9A8), glow: rgb(0xE5534B), mark: .white)
            }
        }

        /// The marks on a gold orb: the orb editor's canvas colour.
        static let ink = rgb(0x0B0D12)

        static func rgb(_ hex: Int) -> UIColor {
            UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    // MARK: - Drawing

    private static var bounds: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }

    private static func renderer(scale: CGFloat) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: bounds.size, format: format)
    }

    private static func still(
        scale: CGFloat,
        orb: ((CGContext, CGFloat) -> Void)?,
        _ draw: (CGContext) -> Void
    ) -> UIImage {
        renderer(scale: scale).image { context in
            orb?(context.cgContext, 0)
            draw(context.cgContext)
        }
    }

    /// `phase` runs from 0 up to (not including) 1 across the cycle.
    private static func animated(
        scale: CGFloat,
        orb: ((CGContext, CGFloat) -> Void)?,
        _ draw: (CGContext, CGFloat) -> Void
    ) -> UIImage? {
        let renderer = renderer(scale: scale)
        let frames = (0..<frameCount).map { index in
            renderer.image { context in
                let phase = CGFloat(index) / CGFloat(frameCount)
                orb?(context.cgContext, phase)
                draw(context.cgContext, phase)
            }
        }
        return UIImage.animatedImage(with: frames, duration: cycleDuration)
    }

    /// The orb's margin inside the canvas, left for its glow.
    private static let discInset: CGFloat = 0.02
    /// The orb's radius as a fraction of the side.
    static let discRadius: CGFloat = 0.5 - discInset
    /// The glyphs (the mic, the warning) fit a square this fraction of the
    /// side, whatever the symbol's own proportions.
    static let glyphBox: CGFloat = 0.6

    /// A glass orb: a soft glow, a body lit from the top left with the
    /// second colour swirling in, a specular highlight and a fine rim.
    /// `breathing` swells the glow while the orb listens.
    private static func drawOrb(_ palette: OrbPalette, breathing: CGFloat?, in context: CGContext) {
        let center = CGPoint(x: side / 2, y: side / 2)
        let radius = side * discRadius
        let space = CGColorSpaceCreateDeviceRGB()
        let pulse = breathing.map { (sin($0 * 2 * .pi) + 1) / 2 } ?? 0.5

        // Glow just outside the body.
        if let glow = CGGradient(
            colorsSpace: space,
            colors: [palette.glow.withAlphaComponent(0.25 + 0.3 * pulse).cgColor, palette.glow.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawRadialGradient(
                glow, startCenter: center, startRadius: radius * 0.9,
                endCenter: center, endRadius: side / 2, options: []
            )
        }

        context.saveGState()
        context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.clip()
        // Body: lit from the top left, falling off to the deep colour.
        if let body = CGGradient(
            colorsSpace: space,
            colors: [palette.light.cgColor, palette.deep.cgColor] as CFArray,
            locations: [0.15, 1]
        ) {
            context.drawRadialGradient(
                body,
                startCenter: CGPoint(x: side * 0.38, y: side * 0.34), startRadius: 0,
                endCenter: center, endRadius: radius * 1.05,
                options: [.drawsAfterEndLocation]
            )
        }
        // The second colour, swirling in from the top left.
        if let swirl = CGGradient(
            colorsSpace: space,
            colors: [palette.swirl.withAlphaComponent(0.55).cgColor, palette.swirl.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawRadialGradient(
                swirl,
                startCenter: CGPoint(x: side * 0.24, y: side * 0.3), startRadius: 0,
                endCenter: CGPoint(x: side * 0.24, y: side * 0.3), endRadius: radius * 0.75,
                options: []
            )
        }
        // Specular highlight.
        if let shine = CGGradient(
            colorsSpace: space,
            colors: [UIColor.white.withAlphaComponent(0.45).cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawRadialGradient(
                shine,
                startCenter: CGPoint(x: side * 0.36, y: side * 0.26), startRadius: 0,
                endCenter: CGPoint(x: side * 0.36, y: side * 0.26), endRadius: radius * 0.42,
                options: []
            )
        }
        context.restoreGState()

        // Rim.
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(side * 0.012)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            .insetBy(dx: side * 0.006, dy: side * 0.006))
    }

    private static func drawGlyph(_ name: String, color: UIColor, in context: CGContext) {
        let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.5, weight: .bold)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let size = symbol.size
        guard size.width > 0, size.height > 0 else { return }
        // Scaled to fill the box: the symbol's point size alone left the
        // mic narrow and short.
        let scale = side * glyphBox / max(size.width, size.height)
        let width = size.width * scale
        let height = size.height * scale
        symbol.draw(in: CGRect(
            x: (side - width) / 2,
            y: (side - height) / 2,
            width: width,
            height: height
        ))
    }

    /// A ring that grows from around the mic out to the orb's edge and
    /// fades.
    private static func drawPulse(phase: CGFloat, color: UIColor, in context: CGContext) {
        let lineWidth = side * 0.05
        let minRadius = side * glyphBox / 2 + lineWidth
        let maxRadius = side * discRadius - lineWidth / 2
        let radius = minRadius + (maxRadius - minRadius) * phase
        context.setStrokeColor(color.withAlphaComponent(0.85 * (1 - phase)).cgColor)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: CGRect(
            x: side / 2 - radius,
            y: side / 2 - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    /// The thinking dots: their spacing and their radius at rest and at
    /// their largest, as fractions of the side. The outer dots' far edges
    /// stay inside the orb.
    static let dotSpacing: CGFloat = 0.31
    static let dotRadius: CGFloat = 0.115
    static let dotGrowth: CGFloat = 0.25

    /// Three dots that brighten and grow one after another.
    private static func drawDots(phase: CGFloat, color: UIColor, in context: CGContext) {
        let spacing = side * dotSpacing
        let baseRadius = side * dotRadius
        for index in 0..<3 {
            let offset = phase - CGFloat(index) / 3
            let wave = (sin(offset * 2 * .pi) + 1) / 2
            let radius = baseRadius * (1 + dotGrowth * wave)
            let center = CGPoint(x: side / 2 + CGFloat(index - 1) * spacing, y: side / 2)
            context.setFillColor(color.withAlphaComponent(0.4 + 0.6 * wave).cgColor)
            context.fillEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
    }

    /// The responding bars: width, centre spacing, and the tallest and
    /// shortest middle bar, as fractions of the side. Each bar's reach is
    /// scaled by `barEnvelope`, highest in the middle like a voice level,
    /// so the outer bars' corners stay inside the orb.
    static let barWidth: CGFloat = 0.125
    static let barSpacing: CGFloat = 0.18
    static let barMaxHeight: CGFloat = 0.84
    static let barMinHeight: CGFloat = 0.22
    static let barEnvelope: [CGFloat] = [0.52, 0.8, 1, 0.8, 0.52]

    /// Five rounded bars rising and falling out of step, like a voice level.
    private static func drawBars(phase: CGFloat, color: UIColor, in context: CGContext) {
        let count = barEnvelope.count
        let width = side * barWidth
        let spacing = side * barSpacing
        context.setFillColor(color.cgColor)
        for index in 0..<count {
            let offset = phase + CGFloat(index) * 0.27
            let wave = (sin(offset * 2 * .pi) + 1) / 2
            let reach = side * barEnvelope[index]
            let height = reach * (barMinHeight + (barMaxHeight - barMinHeight) * wave)
            let x = side / 2 + CGFloat(index - count / 2) * spacing - width / 2
            let rect = CGRect(x: x, y: (side - height) / 2, width: width, height: height)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: width / 2).cgPath)
            context.fillPath()
        }
    }
}
