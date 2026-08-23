import Foundation

/// Pairs visual flash events with audio pulse events and accumulates statistics.
///
/// Fully testable without AVFoundation hardware: inject `VisualFlashEvent` and
/// `AudioPulseEvent` with synthetic media timestamps.
///
/// Pairing: nearest plausible pair inside ±pairingWindowSeconds (default 1 s).
/// Sign: offsetMilliseconds = (audio - video) * 1000. See SyncSignConvention.
final class SyncMeasurementEngine {
    struct Configuration {
        var pairingWindowSeconds: Double = 1.0
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
    private var pendingPulses: [AudioPulseEvent] = []
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
        pendingPulses.removeAll()
        latestMediaTime = 0
    }

    @discardableResult
    func ingestFlash(_ event: VisualFlashEvent) -> SyncSample? {
        latestMediaTime = max(latestMediaTime, event.timestampSeconds)
        appendDiagnostic(DiagnosticEvent(
            id: UUID(),
            kind: .flash,
            message: String(format: "Flash video PTS %.4f  luma %.3f  thr %.3f", event.timestampSeconds, event.luminance, event.threshold),
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
        expireStale(now: event.timestampSeconds)
        return pairBest()
    }

    @discardableResult
    func ingestPulse(_ event: AudioPulseEvent) -> SyncSample? {
        latestMediaTime = max(latestMediaTime, event.timestampSeconds)
        appendDiagnostic(DiagnosticEvent(
            id: UUID(),
            kind: .audioPulse,
            message: String(format: "Audio onset PTS %.4f  env %.3f  thr %.3f", event.timestampSeconds, event.envelope, event.threshold),
            videoPTS: nil,
            audioPTS: event.timestampSeconds,
            offsetMilliseconds: nil,
            luminance: nil,
            visualThreshold: nil,
            audioEnvelope: event.envelope,
            audioThreshold: event.threshold,
            captureFPS: nil
        ))
        pendingPulses.append(event)
        expireStale(now: event.timestampSeconds)
        return pairBest()
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

    private func pairBest() -> SyncSample? {
        guard !pendingFlashes.isEmpty, !pendingPulses.isEmpty else { return nil }
        let window = configuration.pairingWindowSeconds
        var bestFlashIndex: Int?
        var bestPulseIndex: Int?
        var bestAbs = Double.greatestFiniteMagnitude

        for (fi, flash) in pendingFlashes.enumerated() {
            for (pi, pulse) in pendingPulses.enumerated() {
                let dt = pulse.timestampSeconds - flash.timestampSeconds
                if abs(dt) <= window, abs(dt) < bestAbs {
                    bestAbs = abs(dt)
                    bestFlashIndex = fi
                    bestPulseIndex = pi
                }
            }
        }

        guard let fi = bestFlashIndex, let pi = bestPulseIndex else { return nil }
        let flash = pendingFlashes.remove(at: fi)
        let pulse = pendingPulses.remove(at: pi)
        // offset = audio - video, milliseconds
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
                format: "Paired offset %+.2f ms  vPTS %.4f  aPTS %.4f%@",
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
        func keepFlash(_ e: VisualFlashEvent) -> Bool {
            now - e.timestampSeconds <= max(window, age)
        }
        func keepPulse(_ e: AudioPulseEvent) -> Bool {
            now - e.timestampSeconds <= max(window, age)
        }

        let dropF = pendingFlashes.filter { !keepFlash($0) }
        let dropP = pendingPulses.filter { !keepPulse($0) }
        for flash in dropF {
            unpairedRejected += 1
            appendDiagnostic(DiagnosticEvent(
                id: UUID(),
                kind: .rejectedUnpaired,
                message: String(format: "Unpaired flash expired vPTS %.4f", flash.timestampSeconds),
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
        for pulse in dropP {
            unpairedRejected += 1
            appendDiagnostic(DiagnosticEvent(
                id: UUID(),
                kind: .rejectedUnpaired,
                message: String(format: "Unpaired audio expired aPTS %.4f", pulse.timestampSeconds),
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
        pendingFlashes.removeAll { !keepFlash($0) }
        pendingPulses.removeAll { !keepPulse($0) }
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
