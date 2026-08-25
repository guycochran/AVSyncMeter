import Foundation
import AVFoundation
import Accelerate

/// Detects the onset of a beep against a frozen noise floor.
///
/// Trigger (high, hysteresis) decides *that* a pulse happened. Onset (low,
/// first sample over a noise-floor multiple) is found by walking back from
/// the trigger so AGC / a rising trigger threshold cannot slide the stamp
/// 1 ms per beep. The noise floor is updated only on quiet hops, never
/// during the mask. Onset time = buffer media timestamp + sample offset.
///
/// No pitch detection.
final class AudioPulseDetector {
    struct Configuration {
        var sensitivity: Double = 0.65
        var manualThreshold: Double?
        /// Seconds the detector stays deaf after a hit so tails are not extra events.
        /// Harkwood Sync-One2 is 1 Hz; 300–500 ms dead time is fine.
        var maskSeconds: Double = 0.40
        /// First-sample onset vs noise floor. Independent of the trigger.
        var onsetNoiseMultiple: Double = 4.0
        var triggerNoiseMultiple: Double = 12.0
        var absoluteOnsetFloor: Double = 0.02
        var absoluteTriggerFloor: Double = 0.05
        /// After the mask, stay deaf until envelope falls below this fraction of threshold.
        var rearmQuietFraction: Double = 0.35
        /// Quiet-hop noise-floor half-life. Slow rise, fast fall.
        var noiseHalfLifeSeconds: Double = 0.6
        var confirmationSamples: Int = 6
        var lookbackSeconds: Double = 0.03
    }

    var configuration: Configuration
    private(set) var lastEnvelope: Double = 0
    /// Noise floor. Named `baseline` so DiagnosticsView keeps working.
    private(set) var baseline: Double = 0
    private(set) var lastThreshold: Double = 0.08
    private var hasBaseline = false
    private var maskUntilSeconds: Double = -1
    private var awaitingRearm = false
    private var previousEnvelope: Double = 0
    private var tail: [Float] = []
    private var tailStartSeconds: Double = 0
    private var tailRate: Double = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func reset() {
        lastEnvelope = 0
        baseline = 0
        hasBaseline = false
        maskUntilSeconds = -1
        awaitingRearm = false
        previousEnvelope = 0
        lastThreshold = 0.08
        tail.removeAll()
        tailStartSeconds = 0
        tailRate = 0
    }

    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, bufferStartOverride: Double? = nil) -> AudioPulseEvent? {
        guard let parsed = Self.parseMono(sampleBuffer) else { return nil }
        let start = bufferStartOverride ?? parsed.startSeconds
        guard start.isFinite else { return nil }
        return processMonoSamples(parsed.samples, bufferStartSeconds: start, sampleRate: parsed.sampleRate)
    }

    /// Testable path: inject a mono PCM buffer with its media start time.
    func processMonoSamples(_ samples: [Float], bufferStartSeconds: Double, sampleRate: Double) -> AudioPulseEvent? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }

        var combined: [Float]
        var combinedStart: Double
        var newRegionStart: Int
        if !tail.isEmpty,
           abs(tailRate - sampleRate) < 1,
           abs((tailStartSeconds + Double(tail.count) / tailRate) - bufferStartSeconds) < 0.003 {
            combined = tail + samples
            combinedStart = tailStartSeconds
            newRegionStart = tail.count
        } else {
            combined = samples
            combinedStart = bufferStartSeconds
            newRegionStart = 0
        }

        let hop = max(32, min(64, samples.count / 16))
        var event: AudioPulseEvent?
        var i = newRegionStart
        while i < combined.count {
            let end = min(combined.count, i + hop)
            let slice = combined[i..<end]
            let rms = Self.rms(slice)
            let t = combinedStart + Double(i) / sampleRate
            let dt = Double(end - i) / sampleRate

            lastEnvelope = rms
            lastThreshold = effectiveThreshold(relativeToBaseline: baseline)

            if !hasBaseline {
                baseline = max(rms, 1e-5)
                hasBaseline = true
                previousEnvelope = rms
                i = end
                continue
            }

            if t < maskUntilSeconds {
                previousEnvelope = rms
                i = end
                continue
            }

            if awaitingRearm {
                let rearmQuiet = rms < max(lastThreshold * configuration.rearmQuietFraction, baseline * 3, 0.02)
                previousEnvelope = rms
                if rearmQuiet {
                    awaitingRearm = false
                    updateNoiseFloor(rms: rms, dt: dt)
                }
                i = end
                continue
            }

            let quiet = rms < max(lastThreshold * 0.35, baseline * 3)
            if quiet {
                updateNoiseFloor(rms: rms, dt: dt)
            }

            // Must clear threshold with real headroom so a 0.001 gap above env cannot fire.
            let trigger = rms > lastThreshold * 1.12
                && rms > previousEnvelope + lastThreshold * 0.25
                && rms > baseline * configuration.triggerNoiseMultiple * 0.5

            if trigger {
                let onsetThr = onsetThreshold()
                let searchStart = max(0, i - Int(configuration.lookbackSeconds * sampleRate))
                let onsetIndex = refineOnset(
                    samples: combined,
                    searchStart: searchStart,
                    hopEnd: end,
                    threshold: onsetThr
                )
                let onset = combinedStart + Double(onsetIndex) / sampleRate
                maskUntilSeconds = onset + configuration.maskSeconds
                awaitingRearm = true
                event = AudioPulseEvent(timestampSeconds: onset, envelope: rms, threshold: lastThreshold)
                previousEnvelope = rms
                break
            }

            previousEnvelope = rms
            i = end
        }

        let keep = max(32, Int(configuration.lookbackSeconds * sampleRate))
        if samples.count >= keep {
            tail = Array(samples.suffix(keep))
            tailStartSeconds = bufferStartSeconds + Double(samples.count - keep) / sampleRate
        } else {
            tail = samples
            tailStartSeconds = bufferStartSeconds
        }
        tailRate = sampleRate
        return event
    }

    /// Envelope-only hook used by older tests. Prefer `processMonoSamples` for onset.
    @discardableResult
    func processEnvelope(_ envelope: Double, timestampSeconds: Double, sampleOffset: Double = 0) -> AudioPulseEvent? {
        _ = sampleOffset
        lastEnvelope = envelope
        lastThreshold = effectiveThreshold(relativeToBaseline: baseline)
        if !hasBaseline {
            baseline = max(envelope, 1e-5)
            hasBaseline = true
            previousEnvelope = envelope
            return nil
        }
        if timestampSeconds < maskUntilSeconds {
            previousEnvelope = envelope
            return nil
        }
        if awaitingRearm {
            let rearmQuiet = envelope < max(lastThreshold * configuration.rearmQuietFraction, baseline * 3, 0.02)
            previousEnvelope = envelope
            if rearmQuiet { awaitingRearm = false }
            return nil
        }
        if envelope < max(lastThreshold * 0.35, baseline * 3) {
            updateNoiseFloor(rms: envelope, dt: 0.005)
        }
        let trigger = envelope > lastThreshold * 1.12
            && envelope > previousEnvelope + lastThreshold * 0.25
        previousEnvelope = envelope
        if trigger {
            maskUntilSeconds = timestampSeconds + configuration.maskSeconds
            awaitingRearm = true
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
        let floor = configuration.absoluteTriggerFloor - configuration.sensitivity * 0.03
        // Quiet-only floor already; never let threshold sit a mill above the noise.
        let noiseFloor = max(base, 0.004)
        let fromNoise = noiseFloor * configuration.triggerNoiseMultiple
        let raw = max(floor, fromNoise)
        return max(0.05, raw * (1.4 - configuration.sensitivity * 0.4))
    }

    private func onsetThreshold() -> Double {
        if let manual = configuration.manualThreshold {
            return max(configuration.absoluteOnsetFloor * 0.5, manual * 0.35)
        }
        let fromNoise = baseline * configuration.onsetNoiseMultiple
        return max(configuration.absoluteOnsetFloor, fromNoise)
    }

    private func updateNoiseFloor(rms: Double, dt: Double) {
        // Fast fall, slow rise — minimum statistics, AGC cannot haul the floor up.
        if rms < baseline {
            baseline = max(rms, 1e-6)
            return
        }
        let tau = max(0.05, configuration.noiseHalfLifeSeconds)
        let a = 1 - exp(-max(dt, 1e-4) / tau)
        baseline = baseline + (rms - baseline) * a
    }

    private func refineOnset(samples: [Float], searchStart: Int, hopEnd: Int, threshold: Double) -> Int {
        let ampThresh = Float(max(threshold, 0.005))
        var i = searchStart
        let confirm = max(1, configuration.confirmationSamples)
        while i < hopEnd {
            if abs(samples[i]) >= ampThresh {
                var ok = true
                let end = min(samples.count, i + confirm)
                var hits = 0
                var k = i
                while k < end {
                    if abs(samples[k]) >= ampThresh * 0.5 { hits += 1 }
                    k += 1
                }
                if hits < max(1, confirm / 3) { ok = false }
                if ok { return i }
            }
            i += 1
        }
        return searchStart
    }

    static func rms(_ slice: ArraySlice<Float>) -> Double {
        guard !slice.isEmpty else { return 0 }
        var sum: Float = 0
        slice.withUnsafeBufferPointer { buf in
            vDSP_svesq(buf.baseAddress!, 1, &sum, vDSP_Length(buf.count))
        }
        return sqrt(Double(sum) / Double(slice.count))
    }

    struct ParsedBuffer {
        var samples: [Float]
        var startSeconds: Double
        var sampleRate: Double
    }

    static func parseMono(_ sampleBuffer: CMSampleBuffer) -> ParsedBuffer? {
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
        let isNonInterleaved = (asbd?.mFormatFlags ?? 0) & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerSample = max(1, bits / 8)
        let frameCount: Int
        if isNonInterleaved {
            frameCount = length / bytesPerSample
        } else {
            frameCount = length / max(1, bytesPerSample * max(channels, 1))
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let bufferStart = CMTimeGetSeconds(pts)
        guard bufferStart.isFinite, frameCount > 0 else { return nil }

        var samples = [Float](repeating: 0, count: frameCount)
        if isFloat && bits == 32 {
            dataPointer.withMemoryRebound(to: Float.self, capacity: frameCount * max(channels, 1)) { src in
                if channels <= 1 || isNonInterleaved {
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
                if channels <= 1 || isNonInterleaved {
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
        return ParsedBuffer(samples: samples, startSeconds: bufferStart, sampleRate: sampleRate)
    }
}
