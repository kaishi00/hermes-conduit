//
//  LiquidOrbView.swift
//  Conduit
//
//  The live call orb: Liquid Orb Editor's "Siri" liquid glass preset
//  (https://github.com/lersent001/orb, MIT, issue #336), recoloured to
//  Conduit's gold accent and blue aura. The shader is LiquidOrb.metal; this
//  file holds the uniform snapshots the editor exported and a small
//  MTKView renderer adapted from its SwiftUI export.
//
//  To retune it, open the editor with these settings, adjust, and re-export
//  the SwiftUI code; the seed arrays below are the only generated part. Idle
//  is this URL's idle state; listening and speaking are its thinking state
//  with colorA-D/glowColor, speed, warp and exposure overridden as noted at
//  each seed:
//  https://lersent001.github.io/orb/#effect=orb-glass-liquid&style=siri&glass=1&state=thinking&activation=0.22&transition=0.65&speed=0.82&idleSpeed=0.246&radius=0.72&contourDeform=0&idleContourDeform=0&zoom=0.36&idleZoom=0.3384&warp=3.2&idleWarp=1.664&ridgeAmt=0.5&idleRidgeAmt=0.24&sharp=2.2&idleSharp=1.98&bandDensity=2&idleBandDensity=2&metalDepth=0.25&idleMetalDepth=0.25&metalRoughness=0.22&idleMetalRoughness=0.22&chromaticShift=0.42&idleChromaticShift=0.42&metalScale=0.77&metalStretch=0.23&idleMetalStretch=0.23&metalAngle=65&metalOffset=0&metalPhase=0&metalEvolution=1&idleMetalEvolution=1&shade=0.12&idleShade=0.12&exposure=2&idleExposure=1.36&sheen=0.28&gloss=0.24&glassOpacity=0.44&shellMidAlpha=0.18&shellEdgeAlpha=0.18&edgeSoftness=0.005&edgeGlow=0&idleEdgeGlow=0&colorA=%23FAD47A&idleColorA=%23B59B6A&colorB=%238FB4FF&idleColorB=%235E7598&colorC=%23E0AB47&idleColorC=%239A8158&colorD=%236194FA&idleColorD=%2356679A&highlightColor=%23FFFFFF&idleHighlightColor=%23C9C4B8&shellInner=%23FFFFFF&shellMid=%23B9CEFF&shellEdge=%23F2D69B&sheenColor=%23FFF4E0&specColor=%23FFF0D6&canvasColor=%230B0D12&glowColor=%23E0AB47&idleGlowColor=%236E6450
//
//  Portions adapted from Liquid Orb Editor's SwiftUI export:
//  Copyright (c) 2026 LerSent001. MIT License; the full notice is in
//  LiquidOrb.metal.
//

import MetalKit
import QuartzCore
import SwiftUI

/// The orb's looks: calm and desaturated at rest, a slow cool blue while it
/// listens, and fast, bright gold while the assistant speaks.
enum LiquidOrbState: Equatable {
    case idle
    case listening
    case speaking
}

// MARK: - Exported uniforms

private let orbIdleUniformSeed: [Float] = [
    1, 1, 0, 0.2460000067949295, 0.7200000286102295, 0.3384000062942505, 1.6640000343322754, 0.23999999463558197,
    1.9800000190734863, 0.11999999731779099, 0.2800000011920929, 0.23999999463558197, 0.18000000715255737, 0.18000000715255737, 1.3600000143051147, 9,
    0.004999999888241291, 0, 0, 1, 0.4399999976158142, 0, 2, 0.41999998688697815,
    0.7699999809265137, 0.23000000417232513, 65, 0, 0, 1, 0.2199999988079071, 0.25,
    0.7200000286102295, 5, 0.41999998688697815, 1.25, 0.550000011920929, 0.30000001192092896, 1.2000000476837158, 0.699999988079071,
    0.7098039388656616, 0.6078431606292725, 0.4156862795352936, 1, 0.3686274588108063, 0.4588235318660736, 0.5960784554481506, 1,
    0.6039215922355652, 0.5058823823928833, 0.3450980484485626, 1, 0.33725491166114807, 0.40392157435417175, 0.6039215922355652, 1,
    0.7882353067398071, 0.7686274647712708, 0.7215686440467834, 1, 1, 1, 1, 1,
    0.7254902124404907, 0.8078431487083435, 1, 1, 0.9490196108818054, 0.8392156958580017, 0.6078431606292725, 1,
    1, 0.95686274766922, 0.8784313797950745, 1, 1, 0.9411764740943909, 0.8392156958580017, 1,
    0.04313725605607033, 0.05098039284348488, 0.07058823853731155, 1, 0.4313725531101227, 0.3921568691730499, 0.3137255012989044, 1,
    0.9686274528503418, 0.9843137264251709, 1, 1, 0.9372549057006836, 0.9647058844566345, 0.9921568632125854, 1,
    0.8784313797950745, 0.9333333373069763, 0.9764705896377563, 1, 0.8313725590705872, 0.9019607901573181, 0.9686274528503418, 1,
    0.7333333492279053, 0.8352941274642944, 0.9529411792755127, 1, 0.6509804129600525, 0.7803921699523926, 0.9411764740943909, 1,
    0.529411792755127, 0.6901960968971252, 0.9215686321258545, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
]
/// Thinking with colorA #8FB4FF, colorB #6194FA, colorC #C9D8FF,
/// colorD #3F6FD8, glowColor #6194FA, speed 0.55, warp 2.6, exposure 1.8.
private let orbListeningUniformSeed: [Float] = [
    1, 1, 0, 0.550000011920929, 0.7200000286102295, 0.36000001430511475, 2.5999999046325684, 0.5,
    2.200000047683716, 0.11999999731779099, 0.2800000011920929, 0.23999999463558197, 0.18000000715255737, 0.18000000715255737, 1.7999999523162842, 9,
    0.004999999888241291, 0, 0, 1, 0.4399999976158142, 0, 2, 0.41999998688697815,
    0.7699999809265137, 0.23000000417232513, 65, 0, 0, 1, 0.2199999988079071, 0.25,
    0.7200000286102295, 5, 0.41999998688697815, 1.25, 0.550000011920929, 0.30000001192092896, 1.2000000476837158, 0.699999988079071,
    0.5607843399047852, 0.7058823704719543, 1, 1, 0.3803921639919281, 0.5803921818733215, 0.9803921580314636, 1,
    0.7882353067398071, 0.8470588326454163, 1, 1, 0.24705882370471954, 0.43529412150382996, 0.8470588326454163, 1,
    1, 1, 1, 1, 1, 1, 1, 1,
    0.7254902124404907, 0.8078431487083435, 1, 1, 0.9490196108818054, 0.8392156958580017, 0.6078431606292725, 1,
    1, 0.95686274766922, 0.8784313797950745, 1, 1, 0.9411764740943909, 0.8392156958580017, 1,
    0.04313725605607033, 0.05098039284348488, 0.07058823853731155, 1, 0.3803921639919281, 0.5803921818733215, 0.9803921580314636, 1,
    0.9686274528503418, 0.9843137264251709, 1, 1, 0.9372549057006836, 0.9647058844566345, 0.9921568632125854, 1,
    0.8784313797950745, 0.9333333373069763, 0.9764705896377563, 1, 0.8313725590705872, 0.9019607901573181, 0.9686274528503418, 1,
    0.7333333492279053, 0.8352941274642944, 0.9529411792755127, 1, 0.6509804129600525, 0.7803921699523926, 0.9411764740943909, 1,
    0.529411792755127, 0.6901960968971252, 0.9215686321258545, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
]
/// Thinking with colorA #FAD47A, colorB #E0AB47, colorC #FFE3A3,
/// colorD #C98A2E, glowColor #E0AB47, speed 1.2, warp 3.8, exposure 2.2.
private let orbSpeakingUniformSeed: [Float] = [
    1, 1, 0, 1.2000000476837158, 0.7200000286102295, 0.36000001430511475, 3.799999952316284, 0.5,
    2.200000047683716, 0.11999999731779099, 0.2800000011920929, 0.23999999463558197, 0.18000000715255737, 0.18000000715255737, 2.200000047683716, 9,
    0.004999999888241291, 0, 0, 1, 0.4399999976158142, 0, 2, 0.41999998688697815,
    0.7699999809265137, 0.23000000417232513, 65, 0, 0, 1, 0.2199999988079071, 0.25,
    0.7200000286102295, 5, 0.41999998688697815, 1.25, 0.550000011920929, 0.30000001192092896, 1.2000000476837158, 0.699999988079071,
    0.9803921580314636, 0.8313725590705872, 0.47843137383461, 1, 0.8784313797950745, 0.6705882549285889, 0.27843138575553894, 1,
    1, 0.8901960849761963, 0.6392157077789307, 1, 0.7882353067398071, 0.5411764979362488, 0.18039216101169586, 1,
    1, 1, 1, 1, 1, 1, 1, 1,
    0.7254902124404907, 0.8078431487083435, 1, 1, 0.9490196108818054, 0.8392156958580017, 0.6078431606292725, 1,
    1, 0.95686274766922, 0.8784313797950745, 1, 1, 0.9411764740943909, 0.8392156958580017, 1,
    0.04313725605607033, 0.05098039284348488, 0.07058823853731155, 1, 0.8784313797950745, 0.6705882549285889, 0.27843138575553894, 1,
    0.9686274528503418, 0.9843137264251709, 1, 1, 0.9372549057006836, 0.9647058844566345, 0.9921568632125854, 1,
    0.8784313797950745, 0.9333333373069763, 0.9764705896377563, 1, 0.8313725590705872, 0.9019607901573181, 0.9686274528503418, 1,
    0.7333333492279053, 0.8352941274642944, 0.9529411792755127, 1, 0.6509804129600525, 0.7803921699523926, 0.9411764740943909, 1,
    0.529411792755127, 0.6901960968971252, 0.9215686321258545, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
]

/// Seconds to light up, and to settle back to idle.
private let orbActivationDuration: CFTimeInterval = 0.22
private let orbSettleDuration: CFTimeInterval = 0.65
/// Where the colour uniforms start: they blend in sRGB-linear space.
private let orbColorOffset = 40

private func orbUniformSeed(for state: LiquidOrbState) -> [Float] {
    switch state {
    case .idle: return orbIdleUniformSeed
    case .listening: return orbListeningUniformSeed
    case .speaking: return orbSpeakingUniformSeed
    }
}

/// Smoothed 0...1 levels the editor's audio response reads.
struct LiquidOrbAudio: Equatable {
    var low: Float = 0
    var mid: Float = 0
    var high: Float = 0
    var all: Float = 0

    /// A voice-like swell for when the assistant speaks: no engine shares a
    /// playback level feed, so the motion is drawn rather than measured.
    static func speech(intensity: Float, at time: CFTimeInterval) -> LiquidOrbAudio {
        guard intensity > 0 else { return LiquidOrbAudio() }
        // Out-of-step sines per band, so it reads as syllables, not a pulse.
        func wave(_ a: Double, _ b: Double, _ phase: Double) -> Float {
            Float(0.5 + 0.3 * sin(time * a + phase) + 0.2 * sin(time * b + phase * 2.3))
        }
        return LiquidOrbAudio(
            low: intensity * wave(3.1, 5.7, 0.0),
            mid: intensity * wave(5.3, 2.9, 1.2) * 0.85,
            high: intensity * wave(8.7, 6.1, 0.4) * 0.6,
            all: intensity * wave(4.2, 1.9, 0.7)
        )
    }

    /// The editor's mapping for the Siri style (strength 0.8): `all` lifts
    /// speed and exposure, `mid` the warp, `low` the contour, `high` the sheen.
    func apply(to values: inout [Float]) {
        let strength: Float = 0.8
        func level(_ value: Float) -> Float { value.isFinite ? max(0, min(1, value)) * strength : 0 }
        func modulate(_ index: Int, _ band: Float, additive: Float, proportional: Float, ceiling: Float) {
            let amount = level(band)
            guard amount > 0 else { return }
            values[index] = min(max(ceiling, values[index]), values[index] * (1 + proportional * amount) + additive * amount)
        }
        modulate(3, all, additive: 0, proportional: 0.7, ceiling: 5)
        modulate(6, mid, additive: 0.85, proportional: 0, ceiling: 7)
        modulate(21, low, additive: 0.075, proportional: 0, ceiling: 1)
        modulate(10, high, additive: 0.16, proportional: 0, ceiling: 2)
        modulate(14, all, additive: 0, proportional: 0.12, ceiling: 4)
    }

    /// Conduit's addition: the sphere itself breathes with speech, up to 8%.
    /// It deliberately skips the editor's 0.8 style strength.
    func applyPulse(to values: inout [Float]) {
        let level = all.isFinite ? max(0, min(1, all)) : 0
        values[4] *= 1 + 0.08 * level
    }
}

// MARK: - Renderer

/// The compiled shader, built once and shared by every orb on screen. Nil
/// where Metal is unavailable; the call sheet then draws its gradient orb.
final class LiquidOrbPipeline {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let state: MTLRenderPipelineState

    static let shared = LiquidOrbPipeline()

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "vs_main"),
              let fragment = library.makeFunction(name: "fs_main"),
              let queue = device.makeCommandQueue()
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Liquid orb"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // The shader writes premultiplied colour over a clear background.
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.commandQueue = queue
        self.state = state
    }
}

/// Main-thread only: SwiftUI updates it and MTKView calls its delegate on
/// the main thread, so its state needs no lock.
final class LiquidOrbRenderer: NSObject, MTKViewDelegate {
    private let pipeline: LiquidOrbPipeline
    private var currentState: LiquidOrbState
    private var fromUniforms: [Float]
    private var targetUniforms: [Float]
    private var displayedUniforms: [Float]
    private var transitionStartedAt: CFTimeInterval = 0
    private var transitionDuration: CFTimeInterval = 0
    private var lastFrameAt = CACurrentMediaTime()
    private var motionPhase: CFTimeInterval = 0
    private var speechTarget: Float = 0
    private var speechLevel: Float = 0
    /// Off under Reduce Motion: frames are drawn on demand and hold still.
    private(set) var animates: Bool

    init(pipeline: LiquidOrbPipeline, state: LiquidOrbState, animates: Bool) {
        self.pipeline = pipeline
        let seed = orbUniformSeed(for: state)
        currentState = state
        fromUniforms = seed
        targetUniforms = seed
        displayedUniforms = seed
        self.animates = animates
        super.init()
    }

    func update(state: LiquidOrbState, speech: Float, animates: Bool) {
        self.animates = animates
        speechTarget = max(0, min(1, speech))
        if !animates {
            speechLevel = 0
            // A still orb never sits partway through a transition.
            if transitionDuration > 0 {
                fromUniforms = targetUniforms
                transitionDuration = 0
            }
        }
        guard state != currentState else { return }
        let now = CACurrentMediaTime()
        fromUniforms = sampleTransition(at: now)
        targetUniforms = orbUniformSeed(for: state)
        transitionStartedAt = now
        // A still orb jumps straight to its new look.
        transitionDuration = animates ? (state == .idle ? orbSettleDuration : orbActivationDuration) : 0
        currentState = state
    }

    private func sampleTransition(at now: CFTimeInterval) -> [Float] {
        let raw = transitionDuration == 0 ? 1 : min(1, max(0, (now - transitionStartedAt) / transitionDuration))
        // Lights up fast and eases out; settles with a smoothstep.
        let eased = currentState != .idle ? 1 - pow(1 - raw, 3) : raw * raw * (3 - 2 * raw)
        let progress = Float(eased)
        for index in 3..<displayedUniforms.count {
            let isColorComponent = index >= orbColorOffset && (index - orbColorOffset) % 4 < 3
            displayedUniforms[index] = isColorComponent
                ? mixSrgb(fromUniforms[index], targetUniforms[index], progress)
                : fromUniforms[index] + (targetUniforms[index] - fromUniforms[index]) * progress
        }
        return displayedUniforms
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // A paused orb's first request can land before it has a size.
        if !animates { view.setNeedsDisplay() }
    }

    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = pipeline.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let now = CACurrentMediaTime()
        let frameDelta = min(0.1, max(0, now - lastFrameAt))
        lastFrameAt = now
        var uniforms = sampleTransition(at: now)
        if animates {
            // Eases speech in and out over roughly a quarter second.
            speechLevel += (speechTarget - speechLevel) * Float(min(1, frameDelta * 4))
            let speech = LiquidOrbAudio.speech(intensity: speechLevel, at: now)
            speech.apply(to: &uniforms)
            speech.applyPulse(to: &uniforms)
            motionPhase += frameDelta * CFTimeInterval(max(uniforms[3], 0))
        }
        uniforms[0] = Float(view.drawableSize.width)
        uniforms[1] = Float(view.drawableSize.height)
        // Phase over speed, so a change of speed never jumps the motion.
        uniforms[2] = Float(motionPhase / CFTimeInterval(max(uniforms[3], 0.001)))

        encoder.setRenderPipelineState(pipeline.state)
        uniforms.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

private func srgbToLinear(_ value: Float) -> Float {
    value <= 0.04045 ? value / 12.92 : Float(pow(Double((value + 0.055) / 1.055), 2.4))
}

private func linearToSrgb(_ value: Float) -> Float {
    value <= 0.0031308 ? value * 12.92 : 1.055 * Float(pow(Double(value), 1.0 / 2.4)) - 0.055
}

private func mixSrgb(_ from: Float, _ to: Float, _ progress: Float) -> Float {
    linearToSrgb(srgbToLinear(from) + (srgbToLinear(to) - srgbToLinear(from)) * progress)
}

// MARK: - Device power

/// The phone's thermal state and Low Power Mode, published on the main
/// thread so the call orb can slow down or hold still (#432). Main thread
/// only: its observers run on the main queue and only views read it.
final class DevicePowerState: ObservableObject {
    static let shared = DevicePowerState()

    @Published private(set) var thermalState: ProcessInfo.ThermalState
    @Published private(set) var isLowPowerModeEnabled: Bool
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(processInfo: ProcessInfo = .processInfo, notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        thermalState = processInfo.thermalState
        isLowPowerModeEnabled = processInfo.isLowPowerModeEnabled
        // Both are posted on whichever thread noticed the change.
        observers.append(notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: processInfo, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // An unchanged value would still publish and redraw the orb.
            let value = processInfo.thermalState
            if thermalState != value { thermalState = value }
        })
        observers.append(notificationCenter.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: processInfo, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let value = processInfo.isLowPowerModeEnabled
            if isLowPowerModeEnabled != value { isLowPowerModeEnabled = value }
        })
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }
}

// MARK: - View

/// The Metal orb as a SwiftUI view. Check `LiquidOrbPipeline.shared` first:
/// without Metal there is nothing to draw.
struct LiquidOrbView: UIViewRepresentable {
    let pipeline: LiquidOrbPipeline
    var state: LiquidOrbState
    /// 0...1: how strongly the orb swells as if speaking.
    var speech: Float = 0
    var animates = true
    /// See LiveVoiceOrbPower: 60 only while speaking, unless in Low Power Mode.
    var framesPerSecond = 30

    func makeCoordinator() -> LiquidOrbRenderer {
        LiquidOrbRenderer(pipeline: pipeline, state: state, animates: animates)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: pipeline.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // The shader is soft-edged: 2x is indistinguishable from 3x here and
        // shades less than half the pixels.
        view.contentScaleFactor = 2
        view.delegate = context.coordinator
        view.isAccessibilityElement = false
        configure(view, renderer: context.coordinator)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(state: state, speech: speech, animates: animates)
        configure(view, renderer: context.coordinator)
    }

    private func configure(_ view: MTKView, renderer: LiquidOrbRenderer) {
        view.preferredFramesPerSecond = framesPerSecond
        view.isPaused = !animates
        view.enableSetNeedsDisplay = !animates
        if !animates { view.setNeedsDisplay() }
    }
}
