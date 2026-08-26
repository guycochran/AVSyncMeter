import Foundation

/// Pairs visual flash events with audio pulse events and accumulates statistics.
///
/// Fully testable without AVFoundation hardware: inject `VisualFlashEvent` and
/// `AudioPulseEvent` with timestamps already on ONE clock (CaptureClock unified
/// seconds in the live path).
///
/// Pairing: unpaired flashes stay in a short queue (not keep-latest of one).
/// A 60 fps measure queue can ingest the next 1 Hz flash before a beep-like
/// pulse whose onset is still in window of the previous flash — dropping that
/// flash as extra was zero pairs with FLASH+AUDIOPULSE marks. Latest pairable
/// pulse still wins; overlapping speech is never queued. Pair if |audio − video|
/// ≤ maxPairOffsetSeconds (default ±0.80 s, so 500 ms Mitti/LED delay still pairs
/// and a 1001 ms Harkwood neighbor must not). Isolated house hits pair on onset even if the old
/// isBeepLike duration gate was false (Harkwood 1001 ms / 66.7 ms 3 kHz,
/// or a 200–400 ms periodic tone). Overlapping/ongoing speech never pairs, including ±500 ms inside the window.
/// pairingWindowSeconds is how long a lone event waits. Detector 400 ms mask still swallows ring-down.
///
/// Sign: offsetMilliseconds = (audio - video) * 1000. See SyncSignConvention.
final class SyncMeasurementEngine {
    struct Configuration {
        var pairingWindowSeconds: Double = 0.80
        /// Accept a pair only if |audio − video| is inside this window.
        var maxPairOffsetSeconds: Double = 0.80
        var calibrationOffsetMilliseconds: Double = 0
        var stabilityThresholdMilliseconds: Double = 8
        var outlierMADMultiplier: Double = 3.5
        var maxQueueAgeSeconds: Double = 3.0
    }

    var configuration: Configuration {
        didSet { applyConfigurationToStats() }
    }

    private(set) var statistics = MeasurementStatistics()
    private(set) var unpairedRejected = 0
    private(set) var diagnostics: [DiagnosticEvent] = []
    private var pendingFlashes: [VisualFlashEvent] = []
    private var pendingPulse: AudioPulseEvent?
    /// Monotonic media time of the most recently seen event, for aging.
    private var latestMediaTime: Double = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        applyConfigurationToStats()
    }

    func reset() {
        statistics.reset()
        unpairedRejected = 0
        diagnostics.removeAll()
        pendingFlashes.removeAll()
        pendingPulse = nil
        latestMediaTime = 0
    }

    @discardableResult
    func ingestFlash(_ event: VisualFlashEvent) -> SyncSample? {
        latestMediaTime = max(latestMediaTime, event.timestampSeconds)
        appendDiagnostic(DiagnosticEvent(
            id: UUID(),
            kind: .flash,
            message: String(format: "Flash unified %.4f  luma %.3f  thr %.3f", event.timestampSeconds, event.luminance, event.threshold),
            videoPTS: event.timestampSeconds,
            audioPTS: nil,
            offsetMilliseconds: nil,
            luminance: event.luminance,
            visualThreshold: event.threshold,
            audioEnvelope: nil,
            audioThreshold: nil,
            captureFPS: nil
        ))
        pendingFlashes.append(event)
        if pendingFlashes.count > 1 {
            pendingFlashes.sort { $0.timestampSeconds < $1.timestampSeconds }
        }
        while pendingFlashes.count > 8 {
            rejectExtraFlash(pendingFlashes.removeFirst())
        }
        // Pair first so |dt| == window still matches. Expire leftover after.
        let sample = pairReady()
        expireStale(now: event.timestampSeconds)
        return sample
    }

    @discardableResult
    func ingestPulse(_ event: AudioPulseEvent) -> SyncSample? {
        latestMediaTime = max(latestMediaTime, event.timestampSeconds)
        appendDiagnostic(DiagnosticEvent(
            id: UUID(),
            kind: .audioPulse,
            message: String(format: "Audio onset unified %.4f  env %.3f  thr %.3f", event.timestampSeconds, event.envelope, event.threshold),
            videoPTS: nil,
            audioPTS: event.timestampSeconds,
            offsetMilliseconds: nil,
            luminance: nil,
            visualThreshold: nil,
            audioEnvelope: event.envelope,
            audioThreshold: event.threshold,
            captureFPS: nil
        ))
        if !event.isPairable {
            // Extra voice in the window must not steal. Never queue chatter.
            // Isolated 1 Hz / periodic tone still isPairable even if old isBeepLike was false.
            rejectExtraPulse(event)
            expireStale(now: event.timestampSeconds)
            return pairReady()
        }
        if let old = pendingPulse {
            // Latest pairable pulse wins; do not queue a second pulse.
            rejectExtraPulse(old)
        }
        pendingPulse = event
        let sample = pairReady()
        expireStale(now: event.timestampSeconds)
        return sample
    }

    func snapshot() -> MeasurementSnapshot {
        statistics.snapshot(rejectedUnpaired: unpairedRejected)
    }

    /// Future Pro mode: the engine only consumes timed events. A later USB dual-channel
    /// sampler (ch1 photodiode, ch2 mic, shared 48 kHz clock) can feed the same ingest APIs.
    func ingestExternalTimedEvents(flash: VisualFlashEvent?, pulse: AudioPulseEvent?) {
        if let flash { _ = ingestFlash(flash) }
        if let pulse { _ = ingestPulse(pulse) }
    }

    /// Greedy 1:1 in time order. Repeat until the heads are not pairable.
    @discardableResult
    private func pairReady() -> SyncSample? {
        var last: SyncSample?
        while let sample = pairHeadsIfReady() {
            last = sample
        }
        return last
    }

    private func pairHeadsIfReady() -> SyncSample? {
        guard let pulse = pendingPulse else { return nil }
        if !pulse.isPairable {
            pendingPulse = nil
            rejectExtraPulse(pulse)
            return nil
        }
        guard !pendingFlashes.isEmpty else { return nil }

        let window = configuration.maxPairOffsetSeconds
        // 1 ns slack: 13.0+0.80 is 0.8000000000000007 in IEEE, still inclusive 0.80.
        let windowIncl = window + 1e-9
        var bestIndex: Int?
        var bestAbs = Double.infinity
        for (i, flash) in pendingFlashes.enumerated() {
            let dt = abs(pulse.timestampSeconds - flash.timestampSeconds)
            if dt <= windowIncl && dt < bestAbs {
                bestAbs = dt
                bestIndex = i
            }
        }
        if let i = bestIndex {
            let flash = pendingFlashes.remove(at: i)
            pendingPulse = nil
            // Same-beat extras (AE double-pump ~40–150 ms) must not sit around
            // to steal the next 1 Hz pulse. The next 1 Hz flash is ~1 s away.
            let beat = 0.15
            var leftovers: [VisualFlashEvent] = []
            leftovers.reserveCapacity(pendingFlashes.count)
            for extra in pendingFlashes {
                if abs(extra.timestampSeconds - flash.timestampSeconds) < beat {
                    rejectExtraFlash(extra)
                } else {
                    leftovers.append(extra)
                }
            }
            pendingFlashes = leftovers
            return emitPair(flash: flash, pulse: pulse)
        }

        // Not pairable: expire the older head so a ring-down replica cannot steal
        // the next flash (1:1 chronological, extra pulses expire unpaired).
        let oldest = pendingFlashes[0]
        if oldest.timestampSeconds < pulse.timestampSeconds {
            pendingFlashes.removeFirst()
            rejectUnpairedFlash(oldest)
        } else {
            pendingPulse = nil
            rejectUnpairedPulse(pulse)
        }
        return nil
    }

    private func emitPair(flash: VisualFlashEvent, pulse: AudioPulseEvent) -> SyncSample {
        let offsetMs = (pulse.timestampSeconds - flash.timestampSeconds) * 1_000.0
        var sample = SyncSample(
            id: UUID(),
            videoTimestampSeconds: flash.timestampSeconds,
            audioTimestampSeconds: pulse.timestampSeconds,
            offsetMilliseconds: offsetMs,
            videoLuminance: flash.luminance,
            visualThreshold: flash.threshold,
            audioEnvelope: pulse.envelope,
            audioThreshold: pulse.threshold,
            isOutlier: false,
            pairedAt: Date()
        )
        statistics.append(sample)
        statistics.recomputeOutliers()
        if let updated = statistics.rawSamples.last {
            sample = updated
        }
        appendDiagnostic(DiagnosticEvent(
            id: UUID(),
            kind: sample.isOutlier ? .rejectedOutlier : .paired,
            message: String(
                format: "Paired offset %+.2f ms  v %.4f  a %.4f%@",
                offsetMs,
                flash.timestampSeconds,
                pulse.timestampSeconds,
                sample.isOutlier ? "  OUTLIER" : ""
            ),
            videoPTS: flash.timestampSeconds,
            audioPTS: pulse.timestampSeconds,
            offsetMilliseconds: offsetMs,
            luminance: flash.luminance,
            visualThreshold: flash.threshold,
            audioEnvelope: pulse.envelope,
            audioThreshold: pulse.threshold,
            captureFPS: nil
        ))
        return sample
    }

    private func expireStale(now: Double) {
        let window = configuration.pairingWindowSeconds
        let age = configuration.maxQueueAgeSeconds
        let limit = max(window, age)

        var kept: [VisualFlashEvent] = []
        kept.reserveCapacity(pendingFlashes.count)
        for flash in pendingFlashes {
            if now - flash.timestampSeconds > limit {
                rejectUnpairedFlash(flash)
            } else {
                kept.append(flash)
            }
        }
        pendingFlashes = kept
        if let pulse = pendingPulse, now - pulse.timestampSeconds > limit {
            pendingPulse = nil
            rejectUnpairedPulse(pulse)
        }
    }

    private func rejectExtraFlash(_ flash: VisualFlashEvent) {
        unpairedRejected += 1
        appendDiagnostic(DiagnosticEvent(
            id: UUID(),
            kind: .rejectedExtraFlash,
            message: String(format: "Extra flash dropped (same-beat) v %.4f", flash.timestampSeconds),
            videoPTS: flash.timestampSeconds,
            audioPTS: nil,
            offsetMilliseconds: nil,
            luminance: flash.luminance,
            visualThreshold: flash.threshold,
            audioEnvelope: nil,
            audioThreshold: nil,
            captureFPS: nil
        ))
    }

    private func rejectExtraPulse(_ pulse: AudioPulseEvent) {
        unpairedRejected += 1
        appendDiagnostic(DiagnosticEvent(
            id: UUID(),
            kind: .rejectedExtraPulse,
            message: String(format: "Extra audio dropped (keep beep-like) a %.4f  beep %d", pulse.timestampSeconds, pulse.isBeepLike ? 1 : 0),
            videoPTS: nil,
            audioPTS: pulse.timestampSeconds,
            offsetMilliseconds: nil,
            luminance: nil,
            visualThreshold: nil,
            audioEnvelope: pulse.envelope,
            audioThreshold: pulse.threshold,
            captureFPS: nil
        ))
    }

    private func rejectUnpairedFlash(_ flash: VisualFlashEvent) {
        unpairedRejected += 1
        appendDiagnostic(DiagnosticEvent(
            id: UUID(),
            kind: .rejectedUnpaired,
            message: String(format: "Unpaired flash expired v %.4f", flash.timestampSeconds),
            videoPTS: flash.timestampSeconds,
            audioPTS: nil,
            offsetMilliseconds: nil,
            luminance: flash.luminance,
            visualThreshold: flash.threshold,
            audioEnvelope: nil,
            audioThreshold: nil,
            captureFPS: nil
        ))
    }

    private func rejectUnpairedPulse(_ pulse: AudioPulseEvent) {
        unpairedRejected += 1
        appendDiagnostic(DiagnosticEvent(
            id: UUID(),
            kind: .rejectedUnpaired,
            message: String(format: "Unpaired audio expired a %.4f", pulse.timestampSeconds),
            videoPTS: nil,
            audioPTS: pulse.timestampSeconds,
            offsetMilliseconds: nil,
            luminance: nil,
            visualThreshold: nil,
            audioEnvelope: pulse.envelope,
            audioThreshold: pulse.threshold,
            captureFPS: nil
        ))
    }

    /// Flash/pulse seen while CaptureClock is still blending. Logged, not paired.
    func noteHeldForClock(flash: VisualFlashEvent? = nil, pulse: AudioPulseEvent? = nil) {
        if let flash {
            appendDiagnostic(DiagnosticEvent(
                id: UUID(),
                kind: .clockSettling,
                message: String(format: "Clock settling — flash not published  v %.4f  luma %.3f", flash.timestampSeconds, flash.luminance),
                videoPTS: flash.timestampSeconds,
                audioPTS: nil,
                offsetMilliseconds: nil,
                luminance: flash.luminance,
                visualThreshold: flash.threshold,
                audioEnvelope: nil,
                audioThreshold: nil,
                captureFPS: nil
            ))
        }
        if let pulse {
            appendDiagnostic(DiagnosticEvent(
                id: UUID(),
                kind: .clockSettling,
                message: String(format: "Clock settling — audio not published  a %.4f  env %.3f  thr %.3f", pulse.timestampSeconds, pulse.envelope, pulse.threshold),
                videoPTS: nil,
                audioPTS: pulse.timestampSeconds,
                offsetMilliseconds: nil,
                luminance: nil,
                visualThreshold: nil,
                audioEnvelope: pulse.envelope,
                audioThreshold: pulse.threshold,
                captureFPS: nil
            ))
        }
    }

    private func applyConfigurationToStats() {
        statistics.calibrationOffsetMilliseconds = configuration.calibrationOffsetMilliseconds
        statistics.stabilityThresholdMilliseconds = configuration.stabilityThresholdMilliseconds
        statistics.outlierMADMultiplier = configuration.outlierMADMultiplier
    }

    private func appendDiagnostic(_ event: DiagnosticEvent) {
        diagnostics.append(event)
        if diagnostics.count > 400 {
            diagnostics.removeFirst(diagnostics.count - 400)
        }
    }
}
