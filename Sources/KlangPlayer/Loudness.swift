import AVFoundation
import Foundation

/// Loudness normalization (EBU R128 / ITU-R BS.1770): measures a track's integrated loudness and
/// writes a copy with the gain that brings it to the target, without clipping.
enum Loudness {
    static let target = -16.0          // LUFS
    static let peakLimit = -1.0        // dBFS
    static let maxBoost = 9.0, maxCut = -15.0

    struct Result { let lufs: Double; let peak: Float; let gainDB: Double }

    /// Integrated loudness and sample peak of an audio file (any format Core Audio reads, e.g. FLAC).
    static func measure(_ url: URL) throws -> Result {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat            // float32, deinterleaved
        let fs = fmt.sampleRate
        let channels = Int(fmt.channelCount)
        var filters = (0..<channels).map { _ in KWeighting(sampleRate: fs) }
        let segment = Int(fs / 10)                 // 100 ms
        var segmentSums: [[Double]] = []           // per 100 ms: sum of squares per channel
        var acc = [Double](repeating: 0, count: channels)
        var inSegment = 0
        var peak: Float = 0

        let chunk: AVAudioFrameCount = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { throw PlayerError.http(0) }
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: chunk)
            let n = Int(buf.frameLength)
            guard n > 0, let data = buf.floatChannelData else { break }
            for i in 0..<n {
                for c in 0..<channels {
                    let x = data[c][i]
                    peak = max(peak, abs(x))
                    let y = filters[c].process(Double(x))
                    acc[c] += y * y
                }
                inSegment += 1
                if inSegment == segment {
                    segmentSums.append(acc)
                    acc = [Double](repeating: 0, count: channels)
                    inSegment = 0
                }
            }
        }
        // 400 ms blocks, 75 % overlap = 4 consecutive segments.
        var blocks: [Double] = []                  // mean square summed over channels
        if segmentSums.count >= 4 {
            for b in 0...(segmentSums.count - 4) {
                var z = 0.0
                for c in 0..<min(channels, 2) {    // L and R weigh 1.0; more channels are rare here
                    z += (segmentSums[b][c] + segmentSums[b + 1][c] + segmentSums[b + 2][c] + segmentSums[b + 3][c]) / Double(4 * segment)
                }
                blocks.append(z)
            }
        }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-12)) }
        let absGated = blocks.filter { lufs($0) > -70 }
        guard !absGated.isEmpty else { return Result(lufs: -70, peak: peak, gainDB: 0) }
        let relGate = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
        let gated = absGated.filter { lufs($0) > relGate }
        let integrated = lufs(gated.reduce(0, +) / Double(max(1, gated.count)))

        var gain = target - integrated
        let peakDB = 20 * log10(Double(max(peak, 1e-6)))
        gain = min(gain, peakLimit - peakDB)       // don't clip
        gain = min(max(gain, maxCut), maxBoost)
        return Result(lufs: integrated, peak: peak, gainDB: gain)
    }

    /// Writes `src` × gain to a float WAV at `dest`.
    static func apply(_ gainDB: Double, from src: URL, to dest: URL) throws {
        let input = try AVAudioFile(forReading: src)
        let fmt = input.processingFormat
        let output = try AVAudioFile(forWriting: dest, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let g = Float(pow(10, gainDB / 20))
        let chunk: AVAudioFrameCount = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { throw PlayerError.http(0) }
        while input.framePosition < input.length {
            try input.read(into: buf, frameCount: chunk)
            guard buf.frameLength > 0, let data = buf.floatChannelData else { break }
            for c in 0..<Int(fmt.channelCount) {
                let p = data[c]
                for i in 0..<Int(buf.frameLength) { p[i] *= g }
            }
            try output.write(from: buf)
        }
    }

    /// BS.1770 K-weighting: high shelf + high-pass, coefficients for any sample rate.
    struct KWeighting {
        private var s1: Biquad, s2: Biquad
        init(sampleRate fs: Double) {
            // Stage 1: high shelf (+4 dB above ~1.7 kHz).
            var f0 = 1681.974450955533, q = 0.7071752369554196
            let gainDB = 3.999843853973347
            var k = tan(.pi * f0 / fs)
            let vh = pow(10, gainDB / 20), vb = pow(vh, 0.4996667741545416)
            var a0 = 1 + k / q + k * k
            s1 = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                        a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
            // Stage 2: high-pass at ~38 Hz.
            f0 = 38.13547087602444; q = 0.5003270373238773
            k = tan(.pi * f0 / fs)
            a0 = 1 + k / q + k * k
            s2 = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        }
        mutating func process(_ x: Double) -> Double { s2.process(s1.process(x)) }
    }

    struct Biquad {
        let b0, b1, b2, a1, a2: Double
        private var z1 = 0.0, z2 = 0.0
        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
        }
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
}
