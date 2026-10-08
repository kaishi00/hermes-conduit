//
//  IMAADPCM.swift
//  Conduit and the Conduit Watch app
//
//  IMA ADPCM, 4 bits a sample: 16-bit speech at a quarter of the size, in
//  plain Swift on both devices, so the Watch link needs no codec Apple may
//  not ship on watchOS. Every block carries the coder state it starts
//  from, so a lost packet costs only its own audio.
//
//  Block: predictor (Int16), step index (UInt8), reserved (UInt8),
//  sample count (UInt16), then the samples' nibbles, low nibble first.
//

import Foundation

enum IMAADPCM {
    static let blockHeaderSize = 6
    /// The most samples one block can hold (its count is a UInt16).
    static let maxSamplesPerBlock = Int(UInt16.max)

    static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
        253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
        1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
        3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
        11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
        32767,
    ]

    static let indexTable: [Int32] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

    /// The coder state both sides step through, sample by sample.
    struct State: Equatable {
        var predictor: Int32 = 0
        var index: Int32 = 0

        /// Applies one nibble, exactly as the decoder does.
        mutating func apply(_ nibble: UInt8) -> Int16 {
            let step = IMAADPCM.stepTable[Int(index)]
            var delta = step >> 3
            if nibble & 4 != 0 { delta += step }
            if nibble & 2 != 0 { delta += step >> 1 }
            if nibble & 1 != 0 { delta += step >> 2 }
            predictor += nibble & 8 != 0 ? -delta : delta
            predictor = min(Int32(Int16.max), max(Int32(Int16.min), predictor))
            index = min(88, max(0, index + IMAADPCM.indexTable[Int(nibble)]))
            return Int16(predictor)
        }

        /// The nibble that best approximates `sample` from this state.
        func nibble(for sample: Int16) -> UInt8 {
            var step = IMAADPCM.stepTable[Int(index)]
            var difference = Int32(sample) - predictor
            var nibble: UInt8 = 0
            if difference < 0 {
                nibble = 8
                difference = -difference
            }
            if difference >= step {
                nibble |= 4
                difference -= step
            }
            step >>= 1
            if difference >= step {
                nibble |= 2
                difference -= step
            }
            step >>= 1
            if difference >= step {
                nibble |= 1
            }
            return nibble
        }
    }

    /// Encodes a stream, block by block, carrying the coder state across
    /// blocks so the audio stays continuous.
    struct Encoder {
        private(set) var state = State()

        /// Encodes the samples as one or more self-contained blocks.
        mutating func encode(_ samples: [Int16]) -> Data {
            var data = Data()
            var start = 0
            while start < samples.count {
                let end = min(samples.count, start + IMAADPCM.maxSamplesPerBlock)
                data.append(encodeBlock(samples[start..<end]))
                start = end
            }
            return data
        }

        private mutating func encodeBlock(_ samples: ArraySlice<Int16>) -> Data {
            var block = Data(capacity: IMAADPCM.blockHeaderSize + (samples.count + 1) / 2)
            let predictor = UInt16(bitPattern: Int16(state.predictor))
            block.append(UInt8(truncatingIfNeeded: predictor))
            block.append(UInt8(truncatingIfNeeded: predictor >> 8))
            block.append(UInt8(state.index))
            block.append(0)
            let count = UInt16(samples.count)
            block.append(UInt8(truncatingIfNeeded: count))
            block.append(UInt8(truncatingIfNeeded: count >> 8))
            var pending: UInt8?
            for sample in samples {
                let nibble = state.nibble(for: sample)
                _ = state.apply(nibble)
                if let low = pending {
                    block.append(low | (nibble << 4))
                    pending = nil
                } else {
                    pending = nibble
                }
            }
            if let low = pending { block.append(low) }
            return block
        }

        mutating func reset() { state = State() }
    }

    /// Decodes one or more blocks back to samples. Nil when the data is
    /// cut short or malformed.
    static func decode(_ data: Data) -> [Int16]? {
        var samples: [Int16] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            guard data.endIndex - offset >= blockHeaderSize else { return nil }
            let predictor = Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
            let index = Int32(data[offset + 2])
            let count = Int(UInt16(data[offset + 4]) | UInt16(data[offset + 5]) << 8)
            let byteCount = (count + 1) / 2
            guard index <= 88, data.endIndex - offset - blockHeaderSize >= byteCount else { return nil }
            var state = State(predictor: Int32(predictor), index: index)
            samples.reserveCapacity(samples.count + count)
            var decoded = 0
            var byteOffset = offset + blockHeaderSize
            while decoded < count {
                let byte = data[byteOffset]
                samples.append(state.apply(byte & 0x0F))
                decoded += 1
                if decoded < count {
                    samples.append(state.apply(byte >> 4))
                    decoded += 1
                }
                byteOffset += 1
            }
            offset += blockHeaderSize + byteCount
        }
        return samples
    }
}

/// Little-endian PCM16 helpers shared by both sides of the link.
enum WatchVoicePCM {
    static func samples(_ data: Data) -> [Int16] {
        var samples = [Int16](repeating: 0, count: data.count / 2)
        _ = samples.withUnsafeMutableBufferPointer { data.copyBytes(to: $0) }
        return samples.map { Int16(littleEndian: $0) }
    }

    static func data(_ samples: [Int16]) -> Data {
        samples.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func data(_ samples: ArraySlice<Int16>) -> Data {
        data(Array(samples))
    }
}
