//
//  LivingPortrait.swift
//  Conduit
//
//  Bring to Life (Eric 2026-11-05): a still bot or profile picture made
//  into a moving one on the phone. Vision lifts the subject out of the
//  picture; the subject breathes and sways over a softened copy of the
//  picture, a 3-second seamless loop written as the same looping APNG a
//  picked GIF becomes (AnimatedAvatar), so it's stored, synced and played
//  like one. Nothing inside the subject moves: no blinking, no talking.
//

import CoreImage
import Foundation
import UIKit
import Vision

enum LivingPortrait {
    enum Failure: Error, Equatable {
        /// Vision found nothing to lift out (or can't run here).
        case noSubject
        case unreadable
        case tooLarge
    }

    /// One loop, and every motion's period divides it, so it never jumps.
    static let loopDuration: Double = 3
    static let frameCount = 36
    static let edge = Int(BotManagement.avatarEdge)

    /// Where the subject is in a frame, as a share of the picture's edge.
    struct Pose: Equatable {
        var scale: Double
        var rotation: Double
        var dx: Double
        var dy: Double
    }

    /// The subject's pose `t` seconds into the loop: a breath once a loop,
    /// a slow sway, a little drift. The subject stays a little larger than
    /// where it sits in the picture, so it covers its own place in the
    /// softened background.
    static func pose(at t: Double) -> Pose {
        let phase = 2 * Double.pi * t / loopDuration
        return Pose(
            scale: 1.035 + 0.02 * sin(phase),
            rotation: 0.02 * sin(phase + .pi / 2),
            dx: 0.012 * sin(phase),
            dy: 0.008 * sin(2 * phase)
        )
    }

    /// The moving picture for a still, made off the main thread.
    static func picture(from image: UIImage) async -> Result<Data, Failure> {
        await Task.detached(priority: .userInitiated) {
            guard let square = square(image) else { return .failure(.unreadable) }
            guard let subject = subject(of: square) else { return .failure(.noSubject) }
            guard let background = softened(square) else { return .failure(.unreadable) }
            switch AnimatedAvatar.encode(frames(background: background, subject: subject)) {
            case .success(let data): return .success(data)
            case .failure(.tooLarge): return .failure(.tooLarge)
            case .failure(.unreadable): return .failure(.unreadable)
            }
        }.value
    }

    static func message(for failure: Failure) -> String {
        switch failure {
        case .noSubject: return AppLocalization.string("No subject was found in that picture to bring to life.")
        // Too large has no clip to shorten here, and a still's loop fits
        // even the first size tried, so it says only that it failed.
        case .unreadable, .tooLarge: return AppLocalization.string("That picture could not be used.")
        }
    }

    // MARK: Frames

    /// The loop's frames: the background drifting slightly against the
    /// subject, the subject posed over it.
    static func frames(background: CGImage, subject: CGImage) -> [AnimatedAvatar.Frame] {
        let delay = loopDuration / Double(frameCount)
        return (0..<frameCount).compactMap { index in
            frame(background: background, subject: subject, pose: pose(at: Double(index) * delay))
                .map { AnimatedAvatar.Frame(image: $0, delay: delay) }
        }
    }

    static func frame(background: CGImage, subject: CGImage, pose: Pose) -> CGImage? {
        let side = CGFloat(edge)
        guard let context = CGContext(
            data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let full = CGRect(x: 0, y: 0, width: side, height: side)
        // The background a touch larger, moving a little the other way.
        context.saveGState()
        context.translateBy(x: side / 2 - CGFloat(pose.dx) * side * 0.4, y: side / 2)
        context.scaleBy(x: 1.06, y: 1.06)
        context.translateBy(x: -side / 2, y: -side / 2)
        context.draw(background, in: full)
        context.restoreGState()
        // The subject turns about a point below the middle, as a body
        // sways from its base. Core Graphics' y runs up.
        let pivot = CGPoint(x: side / 2, y: side * 0.3)
        context.translateBy(x: pivot.x + CGFloat(pose.dx) * side, y: pivot.y - CGFloat(pose.dy) * side)
        context.rotate(by: CGFloat(-pose.rotation))
        context.scaleBy(x: CGFloat(pose.scale), y: CGFloat(pose.scale))
        context.translateBy(x: -pivot.x, y: -pivot.y)
        context.draw(subject, in: full)
        return context.makeImage()
    }

    // MARK: Pictures

    /// The picture as the stored square, upright.
    static func square(_ image: UIImage) -> CGImage? {
        guard let png = BotAvatarImage.normalizedPNG(from: image, edge: CGFloat(edge)) else { return nil }
        return UIImage(data: png)?.cgImage
    }

    private static let ciContext = CIContext()

    /// The picture blurred a little, so the background reads as further
    /// away and the subject's own place in it doesn't show as an edge.
    static func softened(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 2.5).cropped(to: input.extent)
        return ciContext.createCGImage(blurred, from: input.extent)
    }

    /// Every subject Vision finds, with the rest transparent; nil when it
    /// finds none or can't run (no Neural Engine).
    static func subject(of image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
            let buffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false
            )
            let masked = CIImage(cvPixelBuffer: buffer)
            return ciContext.createCGImage(masked, from: masked.extent)
        } catch {
            return nil
        }
    }
}
