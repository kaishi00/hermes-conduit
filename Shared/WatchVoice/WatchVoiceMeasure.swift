//
//  WatchVoiceMeasure.swift
//  Conduit and the Conduit Watch app
//
//  What a Watch call measures and logs: when the user last spoke (a
//  simple level detector), percentiles of timings, and the call log's
//  JSON lines.
//

import Foundation

/// Finds the last moment of speech in a PCM16 stream from 20 ms frame
/// levels against a slowly tracked noise floor.
struct WatchVoiceActivity {
    /// Below this a frame never counts as speech (about -42 dBFS).
    static let minimumSpeechLevel: Float = 0.008
    /// Speech must sit this far above the noise floor (about 12 dB).
    static let speechOverFloor: Float = 4

    private(set) var noiseFloor: Float = 0.003
    private(set) var lastVoicedAt: TimeInterval?
    /// The level of the newest frame, 0...1.
    private(set) var level: Float = 0

    /// `endingAt` is when the chunk's last sample was captured or arrived.
    mutating func process(_ samples: [Int16], sampleRate: Double, endingAt time: TimeInterval) {
        let frameLength = max(1, Int(sampleRate * 0.02))
        let frameCount = samples.count / frameLength
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            var sum: Float = 0
            let start = frame * frameLength
            for sample in samples[start..<(start + frameLength)] {
                let value = Float(sample) / 32_768
                sum += value * value
            }
            let rms = (sum / Float(frameLength)).squareRoot()
            level = rms
            let frameEnd = time - Double(frameCount - frame - 1) * 0.02
            if rms > max(Self.minimumSpeechLevel, noiseFloor * Self.speechOverFloor) {
                lastVoicedAt = frameEnd
            }
            // Down quickly, up slowly: speech never becomes the floor.
            if rms < noiseFloor {
                noiseFloor = noiseFloor * 0.5 + rms * 0.5
            } else {
                noiseFloor = min(0.05, noiseFloor * 1.002)
            }
        }
    }

    mutating func reset() {
        lastVoicedAt = nil
        level = 0
    }
}

enum WatchVoiceStats {
    /// The value below which `fraction` of the values fall (nearest rank).
    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(sorted.count - 1, max(0, rank))]
    }

    static func milliseconds(_ seconds: Double?) -> Int? {
        seconds.map { Int(($0 * 1000).rounded()) }
    }

    /// One JSON line for the test log. Optionals that are nil become null.
    /// Thread-safe, and costly to make for every line.
    private static let timestampFormatter = ISO8601DateFormatter()

    static func jsonLine(_ fields: [String: Any]) -> String {
        var fields = fields.mapValues(jsonValue)
        if fields["at"] == nil {
            fields["at"] = timestampFormatter.string(from: Date())
        }
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return "{\"event\":\"unencodable\"}"
        }
        return line
    }

    /// Unwraps an optional hidden in `Any`, so JSON gets its value or null.
    static func jsonValue(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let wrapped = mirror.children.first?.value else { return NSNull() }
        return jsonValue(wrapped)
    }

    /// Keeps a log file from growing without end: past `maxBytes`, only
    /// its newest half stays, from a line start.
    static func trimLog(at url: URL, maxBytes: Int) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(maxBytes / 2)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try? Data(tail).write(to: url, options: .atomic)
    }
}
