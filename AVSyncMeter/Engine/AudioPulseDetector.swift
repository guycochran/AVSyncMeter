import Foundation
import AVFoundation
import Accelerate

/// Detects a sharp amplitude pulse against an ambient baseline.
/// Onset time is buffer media timestamp + sample offset — not the whole-buffer time.
/// Reverb is suppressed with hysteresis and a post-hit mask. No pitch detection.
final class AudioPulseDetector {
    struct Configuration {
        var sensitivity: Double = 0.65
        var manualThreshold: Double?
        /// Seconds the detector stays deaf after a hit so tails are not extra events.
        var maskSeconds: Double = 0.22
        var baselineAlpha: Double = 0.05
        var attackWindows: Int = 4
    }

    var configuration: Configuration
    private(set) var lastEnvelope: Double = 0
    private(set) var baseline: Double = 0
    private(set) var lastThreshold: Double = 0.08
    private var hasBaseline = false
    private var armed = true
    private var maskUntilSeconds: Double = -1
    private var recentEnvelopes: [Double] = []

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func reset() {
        lastEnvelope = 0
        baseline = 0
        hasBaseline = false
        armed = true
        maskUntilSeconds = -1
        recentEnvelopes.removeAll()
    }

    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> AudioPulseEvent? {
        guard let block = sampleBuffer.dataBuffer else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer, length > 0 else { return nil }

        let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        let asbd = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = asbd?.mSampleRate ?? 48_000
        let channels = Int(asbd?.mChannelsPerFrame ?? 1)
        let bits = Int(asbd?.mBitsPerChannel ?? 16)
        let isFloat = (asbd?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat != 0
        let frameCount = length / max(1, (bits / 8) * max(channels, 1))

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let bufferStart = CMTimeGetSeconds(pts)
        guard bufferStart.isFinite else { return nil }

        var samples = [Float](repeating: 0, count: frameCount)
        if isFloat && bits == 32 {
            dataPointer.withMemoryRebound(to: Float.self, capacity: frameCount * max(channels, 1)) { src in
                if channels <= 1 {
                    samples.withUnsafeMutableBufferPointer { dst in
                        dst.baseAddress!.update(from: src, count: frameCount)
                    }
                } else {
                    for i in 0..<frameCount {
                        var acc: Float = 0
                        for c in 0..<channels { acc += src[i * channels + c] }
                        samples[i] = acc / Float(channels)
                    }
                }
            }
        } else {
            dataPointer.withMemoryRebound(to: Int16.self, capacity: frameCount * max(channels, 1)) { src in
                let scale: Float = 1.0 / 32768.0
                if channels <= 1 {
                    for i in 0..<frameCount { samples[i] = Float(src[i]) * scale }
                } else {
                    for i in 0..<frameCount {
                        var acc: Float = 0
                        for c in 0..<channels { acc += Float(src[i * channels + c]) }
                        samples[i] = (acc / Float(channels)) * scale
                    }
                }
            }
        }

        return processMonoSamples(samples, bufferStartSeconds: bufferStart, sampleRate: sampleRate)
    }

    /// Testable path: inject a mono PCM buffer with its media start time.
    func processMonoSamples(_ samples: [Float], bufferStartSeconds: Double, sampleRate: Double) -> AudioPulseEvent? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        let hop = max(32, samples.count / 16)
        var event: AudioPulseEvent?
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + hop)
            let slice = samples[i..<end]
            let rms = Self.rms(slice)
            let t = bufferStartSeconds + Double(i) / sampleRate
            if let hit = processEnvelope(rms, timestampSeconds: t, sampleOffset: Double(i) / sampleRate) {
                // Refine onset inside this hop: first sample whose |amp| exceeds threshold.
                let local = refineOnset(samples: samples, hopStart: i, hopEnd: end, threshold: hit.threshold)
                let onset = bufferStartSeconds + Double(local) / sampleRate
                event = AudioPulseEvent(timestampSeconds: onset, envelope: hit.envelope, threshold: hit.threshold)
                break
            }
            i += hop
        }
        return event
    }

    @discardableResult
    func processEnvelope(_ envelope: Double, timestampSeconds: Double, sampleOffset: Double = 0) -> AudioPulseEvent? {
        lastEnvelope = envelope
        lastThreshold = effectiveThreshold(relativeToBaseline: baseline)

        if !hasBaseline {
            baseline = envelope
            hasBaseline = true
            return nil
        }

        if timestampSeconds < maskUntilSeconds {
            baseline = baseline * (1 - configuration.baselineAlpha) + envelope * configuration.baselineAlpha
            return nil
        }
        armed = true

        recentEnvelopes.append(envelope)
        if recentEnvelopes.count > configuration.attackWindows {
            recentEnvelopes.removeFirst()
        }
        let rise = envelope - (recentEnvelopes.first ?? baseline)
        let above = envelope - baseline
        let hit = armed && envelope > lastThreshold && above > lastThreshold * 0.5 && rise > lastThreshold * 0.35

        baseline = min(baseline * (1 - configuration.baselineAlpha) + envelope * configuration.baselineAlpha, envelope)
        // Keep baseline from riding up onto the pulse itself when we hit.
        if hit {
            armed = false
            maskUntilSeconds = timestampSeconds + configuration.maskSeconds
            return AudioPulseEvent(
                timestampSeconds: timestampSeconds,
                envelope: envelope,
                threshold: lastThreshold
            )
        }
        return nil
    }

    func effectiveThreshold(relativeToBaseline base: Double) -> Double {
        if let manual = configuration.manualThreshold { return max(0.002, manual) }
        // Floor rises a little with ambient. Sensitivity 0 → harder, 1 → easier.
        let floor = 0.12 - configuration.sensitivity * 0.10
        return max(0.01, floor + base * (1.8 - configuration.sensitivity))
    }

    private func refineOnset(samples: [Float], hopStart: Int, hopEnd: Int, threshold: Double) -> Int {
        let ampThresh = Float(max(threshold, 0.02))
        var i = hopStart
        while i < hopEnd {
            if abs(samples[i]) >= ampThresh { return i }
            i += 1
        }
        return hopStart
    }

    static func rms(_ slice: ArraySlice<Float>) -> Double {
        guard !slice.isEmpty else { return 0 }
        var sum: Float = 0
        slice.withUnsafeBufferPointer { buf in
            vDSP_svesq(buf.baseAddress!, 1, &sum, vDSP_Length(buf.count))
        }
        return sqrt(Double(sum) / Double(slice.count))
    }
}
