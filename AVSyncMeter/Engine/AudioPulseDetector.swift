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
/// Stage-noise: only *beep-like* pulses are emitted — an isolated transient
/// then quiet, not sustained voice. A PA-smeared 1 Hz Harkwood/PCM beep
/// (15–80 ms, even quiet) must still event. Speech stays loud so quiet
/// re-arm cannot fire on the next syllable. A 1 kHz overlay can still win
/// while voice is held. 400 ms mask after a real beep.
///
/// No pitch detection (high-band energy / duration / isolation).
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
        var absoluteOnsetFloor: Double = 0.008
        var absoluteTriggerFloor: Double = 0.016
        /// After the mask, stay deaf until envelope falls below this fraction of threshold.
        var rearmQuietFraction: Double = 0.35
        /// Quiet-hop noise-floor half-life. Slow rise, fast fall.
        var noiseHalfLifeSeconds: Double = 0.6
        var confirmationSamples: Int = 6
        var lookbackSeconds: Double = 0.03
        /// Isolated pulses up to this duration are still a beep (PA smear).
        /// Ongoing energy past this is voice/walkie, not a 1 Hz house beep.
        var beepMaxDurationSeconds: Double = 0.085
        /// High-band (mean abs-diff) jump that can overlay a 1 kHz beep on speech.
        var highBandJump: Double = 0.035
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
    private var candidate: Candidate?
    private var previousHighBand: Double = 0
    private var previousZCR: Double = 0
    /// After dropping a voice-like hold, ignore broadband onsets until quiet
    /// so the next syllable cannot re-arm. A high-band beep overlay still can.
    private var ignoreSustainedUntilQuiet = false

    private struct Candidate {
        var onsetSeconds: Double
        var envelope: Double
        var threshold: Double
        var sharpness: Double
        var highBand: Double
        var lastLoudSeconds: Double
        var peakEnvelope: Double
    }

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
        candidate = nil
        previousHighBand = 0
        previousZCR = 0
        ignoreSustainedUntilQuiet = false
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
            let highBand = Self.meanAbsDiff(slice)
            let zcr = Self.zeroCrossingRate(slice)
            let sharp = Self.sharpness(zcr: zcr, mad: highBand, rms: rms)
            let t = combinedStart + Double(i) / sampleRate
            let dt = Double(end - i) / sampleRate

            lastEnvelope = rms
            lastThreshold = effectiveThreshold(relativeToBaseline: baseline)

            if !hasBaseline {
                baseline = max(rms, 1e-5)
                hasBaseline = true
                previousEnvelope = rms
                previousHighBand = highBand; previousZCR = zcr
                i = end
                continue
            }

            if t < maskUntilSeconds {
                previousEnvelope = rms
                previousHighBand = highBand; previousZCR = zcr
                i = end
                continue
            }

            if awaitingRearm {
                // No hard 0.02 floor: after DSP is off a loud room sits above 0.02
                // and would never re-arm (pairing dies after the first beep).
                let rearmQuiet = rms < max(lastThreshold * configuration.rearmQuietFraction, baseline * 3)
                previousEnvelope = rms
                previousHighBand = highBand; previousZCR = zcr
                if rearmQuiet {
                    awaitingRearm = false
                    ignoreSustainedUntilQuiet = false
                    updateNoiseFloor(rms: rms, dt: dt)
                }
                i = end
                continue
            }

            let quiet = rms < max(lastThreshold * 0.35, baseline * 3)
            if quiet {
                updateNoiseFloor(rms: rms, dt: dt)
                ignoreSustainedUntilQuiet = false
            }

            // Quiet-to-loud isolated pulse (smeared PA) may ramp across hops
            // without a 0.25-threshold jump. Do not require a click edge.
            let wasQuiet = previousEnvelope < max(lastThreshold * 0.40, baseline * 3, 0.004)
            let rmsTrigger = rms > lastThreshold * 1.08
                && (wasQuiet || rms > previousEnvelope + lastThreshold * 0.18)
                && rms > baseline * configuration.triggerNoiseMultiple * 0.5
            // 1 kHz overlay on already-loud speech: broadband RMS may not jump.
            // Entering ~1 kHz territory (zcr ~0.042 at 48 kHz), not a hop-delta —
            // a ramped beep can raise ZCR across several hops without a 0.010 jump.
            let zcrTrigger = zcr > 0.030 && previousZCR < 0.024
            let highTrigger = rms > lastThreshold * 0.8 && (
                (highBand > previousHighBand + configuration.highBandJump && highBand > 0.025)
                || zcrTrigger
            )

            if let c = candidate {
                // Beep duration is high-band for a sharp/high candidate so
                // following speech cannot stretch a 16 ms 1 kHz burst into "voice".
                // Dull onsets still use RMS so a DC click stays short-then-quiet.
                let zcrStill = zcr > 0.022
                let stillThisBurst = c.sharpness >= 0.40 ? zcrStill : (!quiet || zcrStill)
                if stillThisBurst {
                    candidate?.lastLoudSeconds = t + dt
                    if rms > c.peakEnvelope {
                        candidate?.peakEnvelope = rms
                        candidate?.envelope = rms
                    }
                    if sharp > c.sharpness {
                        candidate?.sharpness = sharp
                        candidate?.highBand = max(c.highBand, highBand)
                    }
                }
                if zcr > 0.030 && c.sharpness < 0.45 {
                    // Overlay beep: walk back to the ZCR rise. Amplitude walk-back
                    // would land on the syllable; stamping this hop is a buffer late.
                    let searchStart = max(0, i - Int(configuration.lookbackSeconds * sampleRate))
                    let onset = refineZCROnset(
                        samples: combined,
                        searchStart: searchStart,
                        hopEnd: end,
                        hop: hop,
                        combinedStart: combinedStart,
                        sampleRate: sampleRate
                    )
                    candidate = Candidate(
                        onsetSeconds: onset,
                        envelope: rms,
                        threshold: lastThreshold,
                        sharpness: max(sharp, 0.55),
                        highBand: highBand,
                        lastLoudSeconds: t + dt,
                        peakEnvelope: rms
                    )
                }
                if event == nil, let ev = finishCandidateIfReady(now: t + dt) {
                    event = ev
                    previousEnvelope = rms
                    previousHighBand = highBand; previousZCR = zcr
                    i = end
                    continue
                }
            } else {
                let allowBroadband = !ignoreSustainedUntilQuiet
                let trigger = (allowBroadband && rmsTrigger) || highTrigger
                if trigger {
                    let onset: Double
                    if highTrigger && !rmsTrigger {
                        let searchStart = max(0, i - Int(configuration.lookbackSeconds * sampleRate))
                        onset = refineZCROnset(
                            samples: combined,
                            searchStart: searchStart,
                            hopEnd: end,
                            hop: hop,
                            combinedStart: combinedStart,
                            sampleRate: sampleRate
                        )
                    } else {
                        let onsetThr = onsetThreshold()
                        let searchStart = max(0, i - Int(configuration.lookbackSeconds * sampleRate))
                        let onsetIndex = refineOnset(
                            samples: combined,
                            searchStart: searchStart,
                            hopEnd: end,
                            threshold: onsetThr
                        )
                        onset = combinedStart + Double(onsetIndex) / sampleRate
                    }
                    candidate = Candidate(
                        onsetSeconds: onset,
                        envelope: rms,
                        threshold: lastThreshold,
                        sharpness: highTrigger ? max(sharp, 0.55) : sharp,
                        highBand: highBand,
                        lastLoudSeconds: t + dt,
                        peakEnvelope: rms
                    )
                }
            }

            previousEnvelope = rms
            previousHighBand = highBand; previousZCR = zcr
            i = end
        }

        if event == nil {
            let now = combinedStart + Double(combined.count) / sampleRate
            event = finishCandidateIfReady(now: now)
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


    /// First hop where ZCR enters beep territory (~1 kHz). Amplitude walk-back
    /// would land on already-loud speech.
    private func refineZCROnset(samples: [Float], searchStart: Int, hopEnd: Int, hop: Int, combinedStart: Double, sampleRate: Double) -> Double {
        let win = max(32, min(hop, 64))
        var i = searchStart
        while i < hopEnd {
            let end = min(samples.count, min(hopEnd, i + win))
            guard end > i + 4 else { break }
            let z = Self.zeroCrossingRate(samples[i..<end])
            if z > 0.030 {
                return combinedStart + Double(i) / sampleRate
            }
            i += win
        }
        return combinedStart + Double(max(searchStart, hopEnd - win)) / sampleRate
    }

    /// Commit an isolated pulse as beep-like, or drop sustained voice.
    /// A ~1 Hz PA-smeared beep (15–80 ms, quiet after) must event even if it
    /// is longer than 20 ms or low amplitude — isolated 1 Hz is not speech.
    /// Speech is overlapping/ongoing energy (no quiet gap), not a once-per-
    /// second spike. A sharp 1 kHz smear may run a bit past 85 ms and still
    /// event; a dull 100 ms syllable that returns to quiet does not.
    private func finishCandidateIfReady(now: Double) -> AudioPulseEvent? {
        guard let c = candidate else { return nil }
        let duration = max(0, c.lastLoudSeconds - c.onsetSeconds)
        let seen = now - c.onsetSeconds
        let quietFor = now - c.lastLoudSeconds
        let maxDur = configuration.beepMaxDurationSeconds

        if quietFor >= 0.004 && duration >= 0.001 && seen >= duration {
            // Isolated: energy returned to quiet. Do not drop a 1 Hz house
            // beep as speech just because smear > 20 ms or the old isBeepLike
            // gate would have been false.
            let isolatedBeep = duration <= maxDur || (duration <= 0.20 && c.sharpness >= 0.40)
            if isolatedBeep {
                candidate = nil
                ignoreSustainedUntilQuiet = false
                maskUntilSeconds = c.onsetSeconds + configuration.maskSeconds
                awaitingRearm = true
                return AudioPulseEvent(
                    timestampSeconds: c.onsetSeconds,
                    envelope: c.peakEnvelope,
                    threshold: c.threshold,
                    durationSeconds: duration,
                    sharpness: c.sharpness,
                    isBeepLike: true
                )
            }
            // Isolated but voice-like (syllable then quiet). Not a 1 Hz beep.
            candidate = nil
            ignoreSustainedUntilQuiet = true
            return nil
        }
        if seen >= maxDur + 0.012 && duration > maxDur && quietFor < 0.004 {
            // Sustained voice/walkie: still loud, no isolated quiet gap.
            // Do not 400 ms-mask (a 1 kHz beep overlay still has to win).
            candidate = nil
            ignoreSustainedUntilQuiet = true
            return nil
        }
        if seen >= 0.20 + 0.012 && duration > 0.20 && quietFor < 0.004 {
            candidate = nil
            ignoreSustainedUntilQuiet = true
            return nil
        }
        return nil
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
            let rearmQuiet = envelope < max(lastThreshold * configuration.rearmQuietFraction, baseline * 3)
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
                threshold: lastThreshold,
                durationSeconds: 0.016,
                sharpness: 1.0,
                isBeepLike: true
            )
        }
        return nil
    }

    func effectiveThreshold(relativeToBaseline base: Double) -> Double {
        if let manual = configuration.manualThreshold { return max(0.002, manual) }
        // 89% must hear a distant smeared PA (env 0.005–0.03). A 0.008 clamp
        // with live env 0.001 is the upstairs miss (thr 0.009, 26/26 reject).
        // Crushed 0.001 noise still must not trigger (fromNoise ≥ ~0.005).
        let floor = max(0.0025, configuration.absoluteTriggerFloor - configuration.sensitivity * 0.015)
        let noiseFloor = max(base, 0.0008)
        let fromNoise = min(0.10, noiseFloor * max(5.0, configuration.triggerNoiseMultiple * 0.45))
        return max(floor, fromNoise)
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

    static func meanAbsDiff(_ slice: ArraySlice<Float>) -> Double {
        guard slice.count >= 2 else { return 0 }
        var sum: Double = 0
        var prev = slice[slice.startIndex]
        var n = 0
        var i = slice.index(after: slice.startIndex)
        while i < slice.endIndex {
            let x = slice[i]
            sum += Double(abs(x - prev))
            prev = x
            n += 1
            i = slice.index(after: i)
        }
        return n == 0 ? 0 : sum / Double(n)
    }

    static func zeroCrossingRate(_ slice: ArraySlice<Float>) -> Double {
        guard slice.count >= 2 else { return 0 }
        var c = 0
        var prev = slice[slice.startIndex]
        var i = slice.index(after: slice.startIndex)
        while i < slice.endIndex {
            let x = slice[i]
            if (prev >= 0 && x < 0) || (prev < 0 && x >= 0) { c += 1 }
            prev = x
            i = slice.index(after: i)
        }
        return Double(c) / Double(slice.count - 1)
    }

    static func sharpness(zcr: Double, mad: Double, rms: Double) -> Double {
        let z = min(1.0, zcr / 0.05)
        let click = rms > 1e-6 ? min(1.0, (mad / max(rms, 1e-6)) / 0.55) : 0
        return max(z, click)
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
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let bufferStart = CMTimeGetSeconds(pts)
        guard bufferStart.isFinite else { return nil }

        let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        let asbd = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = asbd?.mSampleRate ?? 48_000
        let channels = max(1, Int(asbd?.mChannelsPerFrame ?? 1))
        let flags = asbd?.mFormatFlags ?? 0
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        var bits = Int(asbd?.mBitsPerChannel ?? 0)
        if bits == 0 {
            let bpf = Int(asbd?.mBytesPerFrame ?? 0)
            if bpf > 0 {
                bits = isNonInterleaved ? bpf * 8 : max(16, (bpf / channels) * 8)
            } else {
                bits = 16
            }
        }
        if bits == 24 { bits = 32 }

        if let mixed = parseAudioBufferList(sampleBuffer, bits: bits, isFloat: isFloat), !mixed.isEmpty {
            return ParsedBuffer(samples: mixed, startSeconds: bufferStart, sampleRate: sampleRate)
        }

        guard let block = sampleBuffer.dataBuffer else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer, length > 0 else { return nil }
        let samples = decodeAndMixMono(
            bytes: UnsafeRawPointer(dataPointer),
            byteCount: length,
            channels: channels,
            bitsPerChannel: bits,
            isFloat: isFloat,
            isNonInterleaved: isNonInterleaved
        )
        guard !samples.isEmpty else { return nil }
        return ParsedBuffer(samples: samples, startSeconds: bufferStart, sampleRate: sampleRate)
    }

    /// AudioBufferList so non-interleaved dual-mic is not first-channel-only.
    private static func parseAudioBufferList(_ sampleBuffer: CMSampleBuffer, bits: Int, isFloat: Bool) -> [Float]? {
        let maxBuffers = 8
        let byteSize = AudioBufferList.sizeInBytes(maximumBuffers: maxBuffers)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteSize)
        let listPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        listPtr.pointee.mNumberBuffers = UInt32(maxBuffers)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPtr,
            bufferListSize: byteSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return nil }

        let abl = UnsafeMutableAudioBufferListPointer(listPtr)
        var planes: [[Float]] = []
        for buf in abl {
            guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
            let chInBuf = max(1, Int(buf.mNumberChannels))
            let plane = decodeAndMixMono(
                bytes: data,
                byteCount: Int(buf.mDataByteSize),
                channels: chInBuf,
                bitsPerChannel: bits,
                isFloat: isFloat,
                isNonInterleaved: false
            )
            if !plane.isEmpty { planes.append(plane) }
        }
        guard !planes.isEmpty else { return nil }
        return mixLoudestChannel(planes)
    }

    /// Pick the plane with the most energy. Averaging a silent (or voice-processed)
    /// channel with the PA channel, or taking only channel 0 of non-interleaved
    /// dual-mic, is how a loud house reads as env 0.001.
    static func mixLoudestChannel(_ planes: [[Float]]) -> [Float] {
        guard let first = planes.first else { return [] }
        if planes.count == 1 { return first }
        let n = planes.map(\.count).min() ?? 0
        guard n > 0 else { return [] }
        var bestIdx = 0
        var bestEnergy: Double = -1
        for (idx, plane) in planes.enumerated() {
            var e: Double = 0
            let m = min(n, plane.count)
            var i = 0
            while i < m {
                let x = Double(plane[i])
                e += x * x
                i += 1
            }
            if e > bestEnergy {
                bestEnergy = e
                bestIdx = idx
            }
        }
        let best = planes[bestIdx]
        return best.count == n ? best : Array(best.prefix(n))
    }

    /// Testable PCM → mono. HostHarness uses this to catch silent-ch0 / int32-as-int16.
    static func decodeAndMixMono(
        bytes: UnsafeRawPointer,
        byteCount: Int,
        channels: Int,
        bitsPerChannel: Int,
        isFloat: Bool,
        isNonInterleaved: Bool
    ) -> [Float] {
        let ch = max(1, channels)
        var bits = bitsPerChannel
        if bits == 24 { bits = 32 }
        let bytesPerSample = bits / 8
        guard bytesPerSample == 2 || bytesPerSample == 4, byteCount >= bytesPerSample else { return [] }

        var planes: [[Float]] = []
        if isNonInterleaved {
            let planeBytes = byteCount / ch
            let frames = planeBytes / bytesPerSample
            guard frames > 0 else { return [] }
            for c in 0..<ch {
                let off = c * planeBytes
                planes.append(decodeContiguous(bytes: bytes + off, frames: frames, bytesPerSample: bytesPerSample, isFloat: isFloat))
            }
        } else if ch == 1 {
            let frames = byteCount / bytesPerSample
            planes.append(decodeContiguous(bytes: bytes, frames: frames, bytesPerSample: bytesPerSample, isFloat: isFloat))
        } else {
            let frames = byteCount / (bytesPerSample * ch)
            guard frames > 0 else { return [] }
            for c in 0..<ch {
                planes.append(decodeStrided(
                    bytes: bytes,
                    frames: frames,
                    bytesPerSample: bytesPerSample,
                    channel: c,
                    channels: ch,
                    isFloat: isFloat
                ))
            }
        }
        return mixLoudestChannel(planes)
    }

    static func decodeAndMixMono(bytes: [UInt8], channels: Int, bitsPerChannel: Int, isFloat: Bool, isNonInterleaved: Bool) -> [Float] {
        guard !bytes.isEmpty else { return [] }
        return bytes.withUnsafeBytes { raw in
            decodeAndMixMono(
                bytes: raw.baseAddress!,
                byteCount: bytes.count,
                channels: channels,
                bitsPerChannel: bitsPerChannel,
                isFloat: isFloat,
                isNonInterleaved: isNonInterleaved
            )
        }
    }

    private static func decodeContiguous(bytes: UnsafeRawPointer, frames: Int, bytesPerSample: Int, isFloat: Bool) -> [Float] {
        guard frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames)
        if isFloat && bytesPerSample == 4 {
            let src = bytes.bindMemory(to: Float.self, capacity: frames)
            for i in 0..<frames {
                let x = src[i]
                out[i] = x.isFinite ? x : 0
            }
        } else if bytesPerSample == 4 {
            let src = bytes.bindMemory(to: Int32.self, capacity: frames)
            let scale: Float = 1.0 / 2_147_483_648.0
            for i in 0..<frames { out[i] = Float(src[i]) * scale }
        } else {
            let src = bytes.bindMemory(to: Int16.self, capacity: frames)
            let scale: Float = 1.0 / 32_768.0
            for i in 0..<frames { out[i] = Float(src[i]) * scale }
        }
        return out
    }

    private static func decodeStrided(bytes: UnsafeRawPointer, frames: Int, bytesPerSample: Int, channel: Int, channels: Int, isFloat: Bool) -> [Float] {
        guard frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames)
        if isFloat && bytesPerSample == 4 {
            let src = bytes.bindMemory(to: Float.self, capacity: frames * channels)
            for i in 0..<frames {
                let x = src[i * channels + channel]
                out[i] = x.isFinite ? x : 0
            }
        } else if bytesPerSample == 4 {
            let src = bytes.bindMemory(to: Int32.self, capacity: frames * channels)
            let scale: Float = 1.0 / 2_147_483_648.0
            for i in 0..<frames { out[i] = Float(src[i * channels + channel]) * scale }
        } else {
            let src = bytes.bindMemory(to: Int16.self, capacity: frames * channels)
            let scale: Float = 1.0 / 32_768.0
            for i in 0..<frames { out[i] = Float(src[i * channels + channel]) * scale }
        }
        return out
    }
}
