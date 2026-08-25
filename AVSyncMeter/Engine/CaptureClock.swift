import Foundation

/// Maps each capture stream onto one timeline so pairing never subtracts
/// timestamps that live on different hardware clocks.
///
/// Common timeline: a running timebase per stream. Each buffer observation
/// advances `unified += (pts − lastPTS) × slope`, where `slope` is
/// d(host)/d(pts) estimated from host-clock arrivals. Audio and video
/// therefore share host seconds even if their PTS clocks run 1000 ppm apart
/// (the NTSC 1000/1001 family, unlocked I/O crystals, frame_index/30 vs wall).
///
/// Origins stay in the PTS domain (no callback-latency intercept), so a
/// constant true offset stays a constant. Residual mean sensor delay is a
/// calibration constant, not a walk.
///
/// Prefer this unified time for pairing. Raw PTS subtraction across streams
/// is how the meter used to walk ~1 ms per 1 Hz beep.
///
/// Do not publish paired offsets until `settled`. While the slope is still
/// blending from 1.0 toward the estimate, unified A−V is garbage even if
/// `locked` has just become true.
struct StreamClockFit: Equatable {
    /// host_seconds per PTS_second. 1.0 means PTS already tracks host.
    private(set) var slope: Double = 1
    private(set) var observationCount: Int = 0
    private(set) var spanSeconds: Double = 0
    private(set) var locked: Bool = false
    /// Locked, enough samples on this stream, and slope no longer jumping.
    private(set) var settled: Bool = false

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
        updateSlope(ptsSeconds: ptsSeconds, hostSeconds: hostSeconds)

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

    private mutating func refreshSettled() {
        settled = locked
            && stableUpdateCount >= 3
            && spanSeconds >= 1.0
            && observationCount >= 24
    }

    private mutating func updateSlope(ptsSeconds: Double, hostSeconds: Double) {
        if firstPTS == nil {
            firstPTS = ptsSeconds
            firstHost = hostSeconds
        }
        guard let firstPTS, let firstHost else { return }

        let dt = max(0, (lastHost.map { hostSeconds - $0 } ?? 0))
        // ~4 s half-life so a 25 s pass can still re-estimate, but not chatter.
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
        guard det > 1e-6, wSum >= 12, spanSeconds >= 0.6 else { return }
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

    /// Live path: do not ingest pairs until both stream fits are settled.
    var allowsPublishedPairs: Bool { snapshot().settled }

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
