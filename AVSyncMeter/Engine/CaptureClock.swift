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
/// After both streams are on that common clock, a second fit rate-locks
/// audio vs video unified times. Capture at 30.000 fps against a 29.97 file
/// is exactly 1000 ppm (30 / (30000/1001) = 1.001). Host-map freezes each
/// stream slope at 1.0, so without this relative slope a constant delay
/// still climbs ~1 ms per 1 Hz beep. Freeze the fitted A−V slope after
/// settle (not 1.0 unless they actually match). Do not fit callback hostNow.
///
/// Origins stay in the PTS domain (no callback-latency intercept), so a
/// constant true offset stays a constant. Residual mean sensor delay is a
/// calibration constant, not a walk. The relative intercept is not applied
/// to event timestamps — only the rate — so a ~+6 ms phone residual is not
/// absorbed into the clock.
///
/// Prefer this unified time for pairing. Raw PTS subtraction across streams
/// is how the meter used to walk ~1 ms per 1 Hz beep.
///
/// Do not publish paired offsets until `settled`. Per-stream slope freezes
/// at settle (natural or force after ~2.5 s); the relative A−V slope freezes
/// then too. The first two detector events per stream after the gate opens
/// are dropped so a late/forced settle cannot publish garbage. Discontinuity
/// (PTS going backwards) resets and re-locks.
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

/// Rate-lock between audio and video *unified* times, after each stream is
/// already on the common host-mapped clock.
///
/// Live path: `ptsSeconds == hostSeconds` for every buffer, so each
/// `StreamClockFit` slope freezes at 1.0 and cannot see 30.000 vs 29.97.
/// Pairing last-video with last-audio as if they were simultaneous is
/// biased by one buffer period (~10–33 ms) and cannot recover 1000 ppm
/// in a 1–2.5 s settle. Instead each stream's unified time is fitted
/// against its *observation index*, then divided by a snapped nominal
/// period (integer fps for video, standard audio buffer sizes). That
/// ratio is d(unified)/d(real) without using callback hostNow.
///
/// Video then advances on a running timebase with
/// `slope = rate_audio / rate_video`. Freeze the fitted slope after
/// settle (not 1.0 unless they actually match). The intercept is not
/// applied, so a ~+6 ms phone residual is not hidden.
struct IndexRateFit: Equatable {
    private var index = 0
    private var lastUnified: Double?
    private var firstUnified: Double?
    private var dts: [Double] = []
    private var wSum = 0.0
    private var wX = 0.0
    private var wY = 0.0
    private var wXX = 0.0
    private var wXY = 0.0
    private(set) var slopePerObservation: Double?

    var observationCount: Int { index }
    var spanSeconds: Double {
        guard let first = firstUnified, let last = lastUnified else { return 0 }
        return max(0, last - first)
    }

    mutating func reset() {
        index = 0
        lastUnified = nil
        firstUnified = nil
        dts = []
        wSum = 0
        wX = 0
        wY = 0
        wXX = 0
        wXY = 0
        slopePerObservation = nil
    }

    mutating func observe(_ unified: Double) {
        guard unified.isFinite else { return }
        if firstUnified == nil { firstUnified = unified }
        if let last = lastUnified {
            let dt = unified - last
            if dt > 1e-6 && dt < 1.0 {
                dts.append(dt)
                if dts.count > 64 { dts.removeFirst() }
            }
        }
        lastUnified = unified
        let x = Double(index)
        let y = unified - (firstUnified ?? unified)
        wSum += 1
        wX += x
        wY += y
        wXX += x * x
        wXY += x * y
        index += 1
        let det = wSum * wXX - wX * wX
        if wSum >= 8, det > 1e-6 {
            slopePerObservation = (wSum * wXY - wX * wY) / det
        }
    }

    var medianDt: Double? {
        guard !dts.isEmpty else { return nil }
        let s = dts.sorted()
        return s[s.count / 2]
    }
}

struct RelativeAVFit: Equatable {
    static let lockMinSpanSeconds = 0.6
    static let settleMinSpanSeconds = 1.0
    static let settleMinObservations = 24
    static let settleStableUpdates = 3
    static let forceSettleSpanSeconds = 2.5

    /// d(audioUnified) / d(videoUnified). 1.0 means the two unified clocks match.
    private(set) var slope: Double = 1
    private(set) var observationCount: Int = 0
    private(set) var spanSeconds: Double = 0
    private(set) var locked: Bool = false
    private(set) var settled: Bool = false

    private var videoRate = IndexRateFit()
    private var audioRate = IndexRateFit()
    private var lastVideoUnified: Double?
    private var lastVideoRel: Double?
    private var stableUpdateCount = 0
    private var lastEstimate: Double?

    mutating func reset() {
        slope = 1
        observationCount = 0
        spanSeconds = 0
        locked = false
        settled = false
        videoRate.reset()
        audioRate.reset()
        lastVideoUnified = nil
        lastVideoRel = nil
        stableUpdateCount = 0
        lastEstimate = nil
    }

    /// Map a video unified time onto the audio unified rate. Running timebase:
    /// `rel += d(videoUnified) × slope`. Slope-only — no intercept.
    mutating func observeVideo(_ videoUnified: Double, collect: Bool) -> Double {
        guard videoUnified.isFinite else { return videoUnified }
        let corrected: Double
        if let lastV = lastVideoUnified, let lastRel = lastVideoRel {
            corrected = lastRel + (videoUnified - lastV) * slope
        } else {
            corrected = videoUnified
        }
        lastVideoUnified = videoUnified
        lastVideoRel = corrected
        // Collect only after both stream fits are frozen so a still-blending
        // 1000 ppm stream slope cannot be double-counted as relative drift.
        if !settled && collect {
            videoRate.observe(videoUnified)
            refreshEstimate()
        }
        return corrected
    }

    mutating func observeAudio(_ audioUnified: Double, collect: Bool) {
        guard audioUnified.isFinite else { return }
        if !settled && collect {
            audioRate.observe(audioUnified)
            refreshEstimate()
        }
    }

    /// Interpolate video onto the audio-rate timebase without advancing it.
    func correctVideo(_ videoUnified: Double) -> Double {
        guard videoUnified.isFinite else { return videoUnified }
        guard let lastV = lastVideoUnified, let lastRel = lastVideoRel else {
            return videoUnified
        }
        return lastRel + (videoUnified - lastV) * slope
    }

    mutating func refreshSettled(streamSpanSeconds: Double, bothStreamsSettled: Bool) {
        if settled { return }
        observationCount = min(videoRate.observationCount, audioRate.observationCount)
        spanSeconds = min(videoRate.spanSeconds, audioRate.spanSeconds)
        let natural = locked
            && stableUpdateCount >= Self.settleStableUpdates
            && spanSeconds >= Self.settleMinSpanSeconds
            && observationCount >= Self.settleMinObservations
        let haveBoth = videoRate.observationCount >= 8 && audioRate.observationCount >= 8
        // Stream span freezes at stream-settle (~1 s natural), so it cannot
        // be the only force clock. If one stream is not advancing after
        // both fits froze (sequential test warmup), freeze identity.
        let forcedMissing = bothStreamsSettled
            && !haveBoth
            && max(videoRate.spanSeconds, audioRate.spanSeconds) >= 1.0
        let forcedLong = bothStreamsSettled
            && haveBoth
            && spanSeconds >= Self.forceSettleSpanSeconds
        if natural || forcedMissing || forcedLong {
            if let estimated = lastEstimate {
                slope = estimated
            }
            settled = true
            locked = true
        }
    }

    private mutating func refreshEstimate() {
        observationCount = min(videoRate.observationCount, audioRate.observationCount)
        spanSeconds = min(videoRate.spanSeconds, audioRate.spanSeconds)
        guard !settled else { return }
        guard spanSeconds >= Self.lockMinSpanSeconds else { return }
        guard let estimated = currentRelativeSlope() else { return }
        guard estimated > 0.95, estimated < 1.05 else { return }
        lastEstimate = estimated
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

    private func currentRelativeSlope() -> Double? {
        guard let vPer = videoRate.slopePerObservation,
              let aPer = audioRate.slopePerObservation,
              let vDt = videoRate.medianDt,
              let aDt = audioRate.medianDt else { return nil }
        let vNom = Self.snapVideoPeriod(vDt)
        let aNom = Self.snapAudioPeriod(aDt)
        guard vNom > 1e-9, aNom > 1e-9 else { return nil }
        let rateV = vPer / vNom
        let rateA = aPer / aNom
        guard rateV > 1e-9 else { return nil }
        return rateA / rateV
    }

    /// Integer fps only — 23.976 / 29.97 / 59.94 must *not* be candidates
    /// or the 1000 ppm vs 30.000 would snap away.
    static func snapVideoPeriod(_ dt: Double) -> Double {
        let candidates = [1.0 / 24.0, 1.0 / 25.0, 1.0 / 30.0, 1.0 / 48.0, 1.0 / 50.0, 1.0 / 60.0]
        var best = candidates[0]
        var bestErr = abs(dt - best)
        for c in candidates {
            let e = abs(dt - c)
            if e < bestErr {
                bestErr = e
                best = c
            }
        }
        return best
    }

    /// Nearest standard audio buffer. 10 ms (480 @ 48 kHz) is the harness
    /// hop; 1024 is typical iOS capture. Snapping to *arbitrary* integer
    /// sample counts would absorb 1000 ppm (1024 × 1.001 ≈ 1025).
    static func snapAudioPeriod(_ dt: Double) -> Double {
        let sr = 48_000.0
        let candidates = [64, 128, 160, 192, 256, 320, 384, 480, 512, 768, 960, 1024, 1536, 1920, 2048, 4096]
        let samples = dt * sr
        var best = candidates[0]
        var bestErr = abs(samples - Double(best))
        for c in candidates {
            let e = abs(samples - Double(c))
            if e < bestErr {
                bestErr = e
                best = c
            }
        }
        return Double(best) / sr
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
    /// (d(audioUnified)/d(videoUnified) − 1) × 1e6. Positive: audio unified runs fast vs video.
    var relativeDriftPPM: Double = 0
    var relativeSlope: Double = 1
    var locked: Bool = false
    var settled: Bool = false

    static let empty = ClockSnapshot()
}

/// Two independent stream fits plus a relative A−V rate lock. Pairing uses
/// `observe`/`unified` results, never raw cross-stream PTS.
final class CaptureClock {
    enum Stream: Equatable {
        case video
        case audio
    }

    private var videoFit = StreamClockFit()
    private var audioFit = StreamClockFit()
    private var relativeFit = RelativeAVFit()

    func reset() {
        videoFit.reset()
        audioFit.reset()
        relativeFit.reset()
        lastVideoCount = 0
        lastAudioCount = 0
    }

    private var lastVideoCount = 0
    private var lastAudioCount = 0

    @discardableResult
    func observe(stream: Stream, ptsSeconds: Double, hostSeconds: Double) -> Double {
        switch stream {
        case .video:
            let raw = videoFit.observe(ptsSeconds: ptsSeconds, hostSeconds: hostSeconds)
            if videoFit.observationCount < lastVideoCount {
                relativeFit.reset()
            }
            lastVideoCount = videoFit.observationCount
            let collect = videoFit.settled && audioFit.settled
            let corrected = relativeFit.observeVideo(raw, collect: collect)
            refreshRelative()
            return corrected
        case .audio:
            let raw = audioFit.observe(ptsSeconds: ptsSeconds, hostSeconds: hostSeconds)
            if audioFit.observationCount < lastAudioCount {
                relativeFit.reset()
            }
            lastAudioCount = audioFit.observationCount
            let collect = videoFit.settled && audioFit.settled
            relativeFit.observeAudio(raw, collect: collect)
            refreshRelative()
            return raw
        }
    }

    func unified(stream: Stream, ptsSeconds: Double) -> Double {
        switch stream {
        case .video:
            return relativeFit.correctVideo(videoFit.unified(ptsSeconds: ptsSeconds))
        case .audio:
            return audioFit.unified(ptsSeconds: ptsSeconds)
        }
    }

    /// Live path: both stream fits and the relative A−V fit settled.
    /// Detector events still go through `acceptDetectedEvent` so the first
    /// two per stream after the gate are dropped.
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
        let relSlope = relativeFit.slope
        return ClockSnapshot(
            videoSlope: vs,
            audioSlope: asl,
            videoObservations: videoFit.observationCount,
            audioObservations: audioFit.observationCount,
            videoSpanSeconds: videoFit.spanSeconds,
            audioSpanSeconds: audioFit.spanSeconds,
            videoPpmVersusHost: videoFit.ptsRatePpmVersusHost,
            audioPpmVersusHost: audioFit.ptsRatePpmVersusHost,
            relativeDriftPPM: (relSlope - 1.0) * 1_000_000.0,
            relativeSlope: relSlope,
            locked: videoFit.locked && audioFit.locked && relativeFit.locked,
            settled: videoFit.settled && audioFit.settled && relativeFit.settled
        )
    }

    private func refreshRelative() {
        let streamSpan = max(videoFit.spanSeconds, audioFit.spanSeconds)
        relativeFit.refreshSettled(
            streamSpanSeconds: streamSpan,
            bothStreamsSettled: videoFit.settled && audioFit.settled
        )
    }
}
