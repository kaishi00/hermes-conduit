//
//  VoiceInputLevelMeter.swift
//  Conduit
//

import SwiftUI

/// Pure mapping from linear PCM amplitude to a 0...1 display fraction on a
/// dBFS scale: -60 dBFS renders empty, 0 dBFS renders full. Presentation
/// only — the speech detector never consumes this value.
enum VoiceLevelMeterMath {
    static func displayFraction(forLevel level: Float) -> Double {
        guard level.isFinite, level > 0 else { return 0 }
        let decibels = 20.0 * log10(Double(level))
        return min(1, max(0, (decibels + 60) / 60))
    }
}

/// A compact "the microphone hears me" input meter for voice surfaces.
/// Values are raw linear PCM peaks from the capture service; they are
/// mapped to dBFS so quiet speech (0.01–0.05) is visibly alive instead of
/// barely moving. Presentation only — it must be driven by the raw capture
/// level, never by a VAD decision.
struct VoiceInputLevelMeter: View {
    let level: Float
    let isActive: Bool

    @State private var animatedFraction: Double = 0

    private var targetFraction: Double {
        isActive ? VoiceLevelMeterMath.displayFraction(forLevel: level) : 0
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                bar(index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Microphone input level"))
        .accessibilityValue(Text(accessibilityValue))
        .onAppear { animatedFraction = targetFraction }
        .onChange(of: targetFraction) { _, newValue in
            withAnimation(.easeOut(duration: 0.12)) {
                animatedFraction = newValue
            }
        }
    }

    private func bar(_ index: Int) -> some View {
        let lit = animatedFraction >= Double(index + 1) / 6.0
        return Capsule()
            .fill(lit ? Color.conduitAccent.opacity(0.85) : Color.secondary.opacity(0.25))
            .frame(width: 5, height: lit ? CGFloat(6 + index * 3) : 6)
            .animation(.easeOut(duration: 0.12), value: lit)
    }

    private var accessibilityValue: String {
        guard isActive, targetFraction > 0 else { return "Silent" }
        if targetFraction < 0.3 { return "Low" }
        if targetFraction < 0.65 { return "Medium" }
        return "High"
    }
}
