import Foundation

/// Maps each capture stream onto one timeline so pairing never subtracts
/// timestamps that live on different hardware clocks.
///
/// Common timeline: a running timebase per stream. Each buffer observation
/// advances `unified += (pts − lastPTS) × slope`, where `slope` is
/// d(host)/d(pts) estimated from a *stable* host clock — never from
/// `CaptureManager.hostNowSeconds()` (callback arrival). The live path
/// already has session-mapped PTS on the host clock via `CMSyncConvertTime`;
/// that mapped PTS is both `ptsSeconds` and `hostSeconds`. Fitting it against
/// callback hostNow is a double map: jitter keeps the slope from settling
/// and can walk a constant delay.
///
/// Origins stay in the PTS domain (no callback-latency intercept), so a
/// constant true offset stays a constant. Residual mean sensor delay is a
/// calibration constant, not a walk.
///
/// Prefer this unified time for pairing. Raw PTS subtraction across streams
/// is how the meter used to walk ~1 ms per 1 Hz beep.
///
/// Do not publish paired offsets until `settled`. Slope freezes at settle
/// (natural or force after ~2.5 s). The first two detector events per stream
/// after the gate opens are dropped so a late/forced settle cannot publish
/// garbage. Discontinuity (PTS going backwards) resets and re-locks.
struct StreamClockFit: Equatable {
    static let lockMinSpanSeconds = 0.6
    static let settleMinSpanSeconds = 1.0
    static let settleMinObservations = 24
    static let settleStableUpdates = 3
    static let forceSettleSpanSeconds = 2.5
    static let forceSettleMinObservations = 8
    static let postSettleDrops = 2

    /// host_seconds per PTS_second. 1.0 means PTS already tracks host.
    private(set) var slope: Double = 1
    private(set) var observationCount: Int = 0
    private(set) var spanSeconds: Double = 0
    private(set) var locked: Bool = false
    /// Locked, enough samples on this stream, and slope no longer jumping
    /// — or force-settled after `forceSettleSpanSeconds`. Slope is frozen.
    private(set) var settled: Bool = false
    /// Detector events still to drop after the gate opens (per stream).
    private(set) var warmupDropsRemaining: Int = 0

    private var lastPTS: Double?
    private var lastUnified: Double?
    private var firstPTS: Double?
    private var firstHost: Double?
    private var lastHost: Double?

    private var wSum = 0.0
    private var wX = 0.0
    private var wY = 0.0
    private var wXX = 0.0
    private var wXY = 0.0
    private var stableUpdateCount = 0

    mutating func reset() {
        slope = 1
        observationCount = 0
        spanSeconds = 0
        locked = false
        settled = false
        warmupDropsRemaining = 0
        lastPTS = nil
        lastUnified = nil
        firstPTS = nil
        firstHost = nil
        lastHost = nil
        wSum = 0
        wX = 0
        wY = 0
        wXX = 0
        wXY = 0
        stableUpdateCount = 0
    }

    /// Observe a buffer/frame. Returns unified seconds for this PTS.
    @discardableResult
    mutating func observe(ptsSeconds: Double, hostSeconds: Double) -> Double {
        guard ptsSeconds.isFinite, hostSeconds.isFinite else {
            return ptsSeconds
        }
        if let lastPTS, ptsSeconds + 0.000_5 < lastPTS {
            // Discontinuity (session restart, device clock jump). Re-lock.
            reset()
        }
        // Freeze the slope once settled. A 4 s half-life blend after lock is
        // how a 15–25 beep pass still walked. HostSeconds after freeze is
        // ignored so callback jitter cannot walk a frozen fit.
        if !settled {
            updateSlope(ptsSeconds: ptsSeconds, hostSeconds: hostSeconds)
        }

        let unified: Double
        if let lastPTS, let lastUnified {
            unified = lastUnified + (ptsSeconds - lastPTS) * slope
            self.lastPTS = ptsSeconds
            self.lastUnified = unified
            self.lastHost = hostSeconds
            observationCount += 1
        } else {
            lastPTS = ptsSeconds
            lastUnified = ptsSeconds
            lastHost = hostSeconds
            firstPTS = ptsSeconds
            firstHost = hostSeconds
            observationCount = 1
            unified = ptsSeconds
        }
        refreshSettled()
        return unified
    }

    /// Interpolate an onset that sits inside the last observed buffer.
    func unified(ptsSeconds: Double) -> Double {
        guard let lastPTS, let lastUnified, ptsSeconds.isFinite else {
            return ptsSeconds
        }
        return lastUnified + (ptsSeconds - lastPTS) * slope
    }

    /// Audio-sample rate relative to host, in ppm. Positive = PTS running fast.
    var ptsRatePpmVersusHost: Double {
        guard slope > 1e-9 else { return 0 }
        return (1.0 / slope - 1.0) * 1_000_000.0
    }

    /// Live path: after both streams are settled, drop the first couple of
    /// detector events so a just-opened (or force-opened) gate cannot publish
    /// the first garbage pair. Settling-period events are never queued.
    mutating func acceptDetectedEvent() -> Bool {
        guard settled else { return false }
        if warmupDropsRemaining > 0 {
            warmupDropsRemaining -= 1
            return false
        }
        return true
    }

    private mutating func refreshSettled() {
        if settled { return }
        let natural = locked
            && stableUpdateCount >= Self.settleStableUpdates
            && spanSeconds >= Self.settleMinSpanSeconds
            && observationCount >= Self.settleMinObservations
        let forced = spanSeconds >= Self.forceSettleSpanSeconds
            && observationCount >= Self.forceSettleMinObservations
        if natural || forced {
            settled = true
            locked = true
            warmupDropsRemaining = Self.postSettleDrops
        }
    }

    private mutating func updateSlope(ptsSeconds: Double, hostSeconds: Double) {
        if firstPTS == nil {
            firstPTS = ptsSeconds
            firstHost = hostSeconds
        }
        guard let firstPTS, let firstHost else { return }

        let dt = max(0, (lastHost.map { hostSeconds - $0 } ?? 0))
        // ~4 s half-life while blending toward lock. Frozen after settle.
        let decay = dt > 0 ? pow(0.5, dt / 4.0) : 1.0
        wSum *= decay
        wX *= decay
        wY *= decay
        wXX *= decay
        wXY *= decay

        wSum += 1
        wX += ptsSeconds
        wY += hostSeconds
        wXX += ptsSeconds * ptsSeconds
        wXY += ptsSeconds * hostSeconds

        spanSeconds = max(spanSeconds, hostSeconds - firstHost, ptsSeconds - firstPTS)

        let det = wSum * wXX - wX * wX
        // Need real span so a burst of same-time samples cannot invent a rate.
        guard det > 1e-6, wSum >= 12, spanSeconds >= Self.lockMinSpanSeconds else { return }
        let estimated = (wSum * wXY - wX * wY) / det
        guard estimated > 0.95, estimated < 1.05 else { return }
        // Blend so lock does not jump a 25 s origin in one shot.
        let previous = slope
        let alpha = locked ? 0.15 : 0.35
        slope = slope * (1 - alpha) + estimated * alpha
        locked = true
        let denom = max(abs(slope), 1e-9)
        let ppm = abs(slope - previous) / denom * 1_000_000.0
        if ppm < 80 {
            stableUpdateCount += 1
        } else {
            stableUpdateCount = 0
        }
    }
}

struct ClockSnapshot: Equatable {
    var videoSlope: Double = 1
    var audioSlope: Double = 1
    var videoObservations: Int = 0
    var audioObservations: Int = 0
    var videoSpanSeconds: Double = 0
    var audioSpanSeconds: Double = 0
    var videoPpmVersusHost: Double = 0
    var audioPpmVersusHost: Double = 0
    /// (audio PTS rate / video PTS rate − 1) × 1e6. Positive: audio PTS runs fast vs video.
    var relativeDriftPPM: Double = 0
    var locked: Bool = false
    var settled: Bool = false

    static let empty = ClockSnapshot()
}

/// Two independent stream fits. Pairing uses `observe`/`unified` results, never raw cross-stream PTS.
final class CaptureClock {
    enum Stream: Equatable {
        case video
        case audio
    }

    private var videoFit = StreamClockFit()
    private var audioFit = StreamClockFit()

    func reset() {
        videoFit.reset()
        audioFit.reset()
    }

    @discardableResult
    func observe(stream: Stream, ptsSeconds: Double, hostSeconds: Double) -> Double {
        switch stream {
        case .video:
            return videoFit.observe(ptsSeconds: ptsSeconds, hostSeconds: hostSeconds)
        case .audio:
            return audioFit.observe(ptsSeconds: ptsSeconds, hostSeconds: hostSeconds)
        }
    }

    func unified(stream: Stream, ptsSeconds: Double) -> Double {
        switch stream {
        case .video:
            return videoFit.unified(ptsSeconds: ptsSeconds)
        case .audio:
            return audioFit.unified(ptsSeconds: ptsSeconds)
        }
    }

    /// Live path: both fits settled. Detector events still go through
    /// `acceptDetectedEvent` so the first two per stream after the gate are dropped.
    var allowsPublishedPairs: Bool { snapshot().settled }

    /// Call when a detector fired. Returns whether to ingest. Requires both
    /// streams settled; decrements that stream's post-settle drop count.
    func acceptDetectedEvent(stream: Stream) -> Bool {
        guard snapshot().settled else { return false }
        switch stream {
        case .video:
            return videoFit.acceptDetectedEvent()
        case .audio:
            return audioFit.acceptDetectedEvent()
        }
    }

    func snapshot() -> ClockSnapshot {
        let vs = videoFit.slope
        let asl = audioFit.slope
        let rel: Double
        if asl > 1e-9 {
            rel = (vs / asl - 1.0) * 1_000_000.0
        } else {
            rel = 0
        }
        return ClockSnapshot(
            videoSlope: vs,
            audioSlope: asl,
            videoObservations: videoFit.observationCount,
            audioObservations: audioFit.observationCount,
            videoSpanSeconds: videoFit.spanSeconds,
            audioSpanSeconds: audioFit.spanSeconds,
            videoPpmVersusHost: videoFit.ptsRatePpmVersusHost,
            audioPpmVersusHost: audioFit.ptsRatePpmVersusHost,
            relativeDriftPPM: rel,
            locked: videoFit.locked && audioFit.locked,
            settled: videoFit.settled && audioFit.settled
        )
    }
}
