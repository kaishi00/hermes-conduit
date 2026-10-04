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
    /// of it, and its marks fill most of that: at 120 pt with a faint disc
    /// and a glyph a third of the width, drivers saw a tiny, unreadable
    /// mark (#378).
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

    /// The disc's margin inside the canvas, leaving room for the pulse ring.
    private static let discInset: CGFloat = 0.06

    private static func drawDisc(in context: CGContext) {
        context.setFillColor(accent.withAlphaComponent(0.24).cgColor)
        context.fillEllipse(in: bounds.insetBy(dx: side * discInset, dy: side * discInset))
    }

    private static func drawGlyph(_ name: String, color: UIColor, in context: CGContext) {
        let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.42, weight: .bold)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let size = symbol.size
        symbol.draw(in: CGRect(
            x: (side - size.width) / 2,
            y: (side - size.height) / 2,
            width: size.width,
            height: size.height
        ))
    }

    /// A ring that grows from the disc's edge outward and fades.
    private static func drawPulse(phase: CGFloat, in context: CGContext) {
        let minRadius = side * (0.5 - discInset)
        let maxRadius = side * 0.49
        let radius = minRadius + (maxRadius - minRadius) * phase
        context.setStrokeColor(accent.withAlphaComponent(0.8 * (1 - phase)).cgColor)
        context.setLineWidth(side * 0.04)
        context.strokeEllipse(in: CGRect(
            x: side / 2 - radius,
            y: side / 2 - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    /// Three dots that brighten and grow one after another.
    private static func drawDots(phase: CGFloat, in context: CGContext) {
        let spacing = side * 0.22
        let baseRadius = side * 0.07
        for index in 0..<3 {
            let offset = phase - CGFloat(index) / 3
            let wave = (sin(offset * 2 * .pi) + 1) / 2
            let radius = baseRadius * (1 + 0.45 * wave)
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

    /// Five rounded bars rising and falling out of step, like a voice level.
    private static func drawBars(phase: CGFloat, in context: CGContext) {
        let count = 5
        let width = side * 0.09
        let spacing = side * 0.14
        let minHeight = side * 0.14
        let maxHeight = side * 0.56
        context.setFillColor(accent.cgColor)
        for index in 0..<count {
            let offset = phase + CGFloat(index) * 0.27
            let wave = (sin(offset * 2 * .pi) + 1) / 2
            let height = minHeight + (maxHeight - minHeight) * wave
            let x = side / 2 + CGFloat(index - count / 2) * spacing - width / 2
            let rect = CGRect(x: x, y: (side - height) / 2, width: width, height: height)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: width / 2).cgPath)
            context.fillPath()
        }
    }
}
