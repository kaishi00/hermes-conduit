//
//  CarPlayVoiceArtwork.swift
//  Conduit
//
//  The state icons the CarPlay voice screen shows above its title: a mic at
//  Ready, a pulsing ring while listening, cycling dots while thinking,
//  moving bars while responding, and a warning at Error. Drawn once and
//  cached. Pure state feedback: no user or assistant content is ever drawn.
//

import UIKit

@MainActor
enum CarPlayVoiceArtwork {
    /// The template accepts images up to 150 pt square. The icon uses all
    /// of it, and its marks fill the disc rather than sit in its middle:
    /// with dots a seventh of the width and bars about half its height, the
    /// Thinking and Responding icons still looked tiny in the car (#378).
    static let side: CGFloat = 150
    /// The system clamps an animated image's cycle to 0.3 to 5 seconds.
    static let cycleDuration: TimeInterval = 1.2
    static let frameCount = 12

    private static var cache: [CarPlayVoiceState: UIImage] = [:]

    /// Ready and Error are still; the in-conversation states animate.
    static func isAnimated(_ state: CarPlayVoiceState) -> Bool {
        switch state {
        case .ready, .error: return false
        case .listening, .processing, .responding: return true
        }
    }

    static func image(for state: CarPlayVoiceState) -> UIImage? {
        if let cached = cache[state] { return cached }
        let image: UIImage?
        switch state {
        case .ready:
            image = still { drawGlyph("mic.fill", color: accent, in: $0) }
        case .listening:
            image = animated { context, phase in
                drawPulse(phase: phase, in: context)
                drawGlyph("mic.fill", color: accent, in: context)
            }
        case .processing:
            image = animated { context, phase in drawDots(phase: phase, in: context) }
        case .responding:
            image = animated { context, phase in drawBars(phase: phase, in: context) }
        case .error:
            image = still { drawGlyph("exclamationmark.triangle.fill", color: warning, in: $0) }
        }
        cache[state] = image
        return image
    }

    // MARK: - Drawing

    /// The app's dark-mode accent: CarPlay screens are dark nearly always,
    /// and a baked bitmap cannot follow the car's appearance.
    private static let accent = UIColor(red: 0.88, green: 0.67, blue: 0.28, alpha: 1)
    private static let warning = UIColor(red: 1.0, green: 0.45, blue: 0.4, alpha: 1)

    private static var bounds: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }

    private static func renderer() -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        return UIGraphicsImageRenderer(size: bounds.size, format: format)
    }

    private static func still(_ draw: (CGContext) -> Void) -> UIImage {
        renderer().image { context in
            drawDisc(in: context.cgContext)
            draw(context.cgContext)
        }
    }

    /// `phase` runs from 0 up to (not including) 1 across the cycle.
    private static func animated(_ draw: (CGContext, CGFloat) -> Void) -> UIImage? {
        let renderer = renderer()
        let frames = (0..<frameCount).map { index in
            renderer.image { context in
                drawDisc(in: context.cgContext)
                draw(context.cgContext, CGFloat(index) / CGFloat(frameCount))
            }
        }
        return UIImage.animatedImage(with: frames, duration: cycleDuration)
    }

    /// The disc's margin inside the canvas: nearly none, so the disc (and
    /// every mark inside it) is as large as the template allows.
    private static let discInset: CGFloat = 0.02
    /// The disc's radius as a fraction of the side.
    static let discRadius: CGFloat = 0.5 - discInset
    /// The glyphs (the mic, the warning) fit a square this fraction of the
    /// side, whatever the symbol's own proportions.
    static let glyphBox: CGFloat = 0.6

    private static func drawDisc(in context: CGContext) {
        context.setFillColor(accent.withAlphaComponent(0.3).cgColor)
        context.fillEllipse(in: bounds.insetBy(dx: side * discInset, dy: side * discInset))
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

    /// A ring that grows from around the mic out to the disc's edge and
    /// fades.
    private static func drawPulse(phase: CGFloat, in context: CGContext) {
        let lineWidth = side * 0.05
        let minRadius = side * glyphBox / 2 + lineWidth
        let maxRadius = side * discRadius - lineWidth / 2
        let radius = minRadius + (maxRadius - minRadius) * phase
        context.setStrokeColor(accent.withAlphaComponent(0.85 * (1 - phase)).cgColor)
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
    /// stay inside the disc.
    static let dotSpacing: CGFloat = 0.31
    static let dotRadius: CGFloat = 0.115
    static let dotGrowth: CGFloat = 0.25

    /// Three dots that brighten and grow one after another.
    private static func drawDots(phase: CGFloat, in context: CGContext) {
        let spacing = side * dotSpacing
        let baseRadius = side * dotRadius
        for index in 0..<3 {
            let offset = phase - CGFloat(index) / 3
            let wave = (sin(offset * 2 * .pi) + 1) / 2
            let radius = baseRadius * (1 + dotGrowth * wave)
            let center = CGPoint(x: side / 2 + CGFloat(index - 1) * spacing, y: side / 2)
            context.setFillColor(accent.withAlphaComponent(0.4 + 0.6 * wave).cgColor)
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
    /// so the outer bars' corners stay inside the disc.
    static let barWidth: CGFloat = 0.125
    static let barSpacing: CGFloat = 0.18
    static let barMaxHeight: CGFloat = 0.84
    static let barMinHeight: CGFloat = 0.22
    static let barEnvelope: [CGFloat] = [0.52, 0.8, 1, 0.8, 0.52]

    /// Five rounded bars rising and falling out of step, like a voice level.
    private static func drawBars(phase: CGFloat, in context: CGContext) {
        let count = barEnvelope.count
        let width = side * barWidth
        let spacing = side * barSpacing
        context.setFillColor(accent.cgColor)
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
