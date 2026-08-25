import Foundation

/// Pairs visual flash events with audio pulse events and accumulates statistics.
///
/// Fully testable without AVFoundation hardware: inject `VisualFlashEvent` and
/// `AudioPulseEvent` with timestamps already on ONE clock (CaptureClock unified
/// seconds in the live path).
///
/// Pairing: at most one pending flash and one pending pulse. Latest beep-like
/// pulse wins; voice/chatter is never queued. They pair only if both are present
/// and |audio − video| ≤ maxPairOffsetSeconds (default ±400 ms, enough for
/// monitor+PA+Mitti and a +164 ms step, tight enough that a 220–350 ms ring-down
/// replica cannot steal the next 1 Hz flash). Voice-like pulses never pair, so
/// extra speech in the window cannot steal. pairingWindowSeconds is how long a
/// lone event waits.
///
/// Sign: offsetMilliseconds = (audio - video) * 1000. See SyncSignConvention.
final class SyncMeasurementEngine {
    struct Configuration {
        var pairingWindowSeconds: Double = 0.40
        /// Accept a pair only if |audio − video| is inside this window.
        var maxPairOffsetSeconds: Double = 0.40
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
    private var pendingFlash: VisualFlashEvent?
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
        pendingFlash = nil
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
        if let old = pendingFlash {
            rejectExtraFlash(old)
        }
        pendingFlash = event
        expireStale(now: event.timestampSeconds)
        return pairReady()
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
        if !event.isBeepLike {
            // Extra voice in the window must not steal. Never queue chatter.
            rejectExtraPulse(event)
            expireStale(now: event.timestampSeconds)
            return pairReady()
        }
        if let old = pendingPulse {
            // Latest beep-like wins; do not queue a second pulse.
            rejectExtraPulse(old)
        }
        pendingPulse = event
        expireStale(now: event.timestampSeconds)
        return pairReady()
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
        guard let flash = pendingFlash, let pulse = pendingPulse else {
            return nil
        }
        if !pulse.isBeepLike {
            pendingPulse = nil
            rejectExtraPulse(pulse)
            return nil
        }
        let dt = pulse.timestampSeconds - flash.timestampSeconds
        if abs(dt) <= configuration.maxPairOffsetSeconds {
            pendingFlash = nil
            pendingPulse = nil
            return emitPair(flash: flash, pulse: pulse)
        }
        // Not pairable: expire the older head so a ring-down replica cannot steal
        // the next flash (1:1 chronological, extra pulses expire unpaired).
        if flash.timestampSeconds < pulse.timestampSeconds {
            pendingFlash = nil
            rejectUnpairedFlash(flash)
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

        if let flash = pendingFlash, now - flash.timestampSeconds > limit {
            pendingFlash = nil
            rejectUnpairedFlash(flash)
        }
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
            message: String(format: "Extra flash dropped (keep latest) v %.4f", flash.timestampSeconds),
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
