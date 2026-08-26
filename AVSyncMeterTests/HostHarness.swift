import Foundation

@main
struct HostHarness {
    static func main() {
        var failed = 0
        func expect(_ cond: Bool, _ name: String, _ detail: String = "") {
            if cond {
                print("PASS  \(name)")
            } else {
                failed += 1
                print("FAIL  \(name) \(detail)")
            }
        }

        func engine() -> SyncMeasurementEngine {
            SyncMeasurementEngine(configuration: .init(pairingWindowSeconds: 1.0))
        }
        func pair(_ e: SyncMeasurementEngine, tVideo: Double, tAudio: Double) -> SyncSample? {
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: tVideo, luminance: 0.8, threshold: 0.1))
            return e.ingestPulse(AudioPulseEvent(timestampSeconds: tAudio, envelope: 0.4, threshold: 0.1))
        }

        do {
            let e = engine()
            let s = pair(e, tVideo: 10.0, tAudio: 10.0)
            expect(s != nil && abs(s!.offsetMilliseconds) < 0.0001, "exact sync")
        }
        do {
            let e = engine()
            let s = pair(e, tVideo: 5.0, tAudio: 5.200)
            expect(s != nil && abs(s!.offsetMilliseconds - 200) < 0.001 && s!.direction == .audioEarly, "audio 200 ms early")
        }
        do {
            let e = engine()
            let s = pair(e, tVideo: 5.0, tAudio: 4.800)
            expect(s != nil && abs(s!.offsetMilliseconds + 200) < 0.001 && s!.direction == .audioLate, "audio 200 ms late")
        }
        do {
            let e = engine()
            for i in 0..<8 {
                let t = Double(i)
                _ = pair(e, tVideo: t, tAudio: t + 0.193)
            }
            let snap = e.snapshot()
            expect(snap.validCount == 8 && abs(snap.medianMilliseconds - 193) < 0.01, "repeated events every second")
        }
        do {
            let e = engine()
            let offsets = [198.0, 201.0, 199.5, 202.0, 197.0, 200.5, 199.0]
            for (i, ms) in offsets.enumerated() {
                _ = pair(e, tVideo: Double(i), tAudio: Double(i) + ms / 1000.0)
            }
            let snap = e.snapshot()
            expect(snap.validCount == offsets.count && snap.standardDeviationMilliseconds < 5 && snap.isStable, "small random jitter")
            expect(abs(snap.spanMilliseconds - (snap.maxMilliseconds - snap.minMilliseconds)) < 0.0001 && snap.spanMilliseconds > 0, "span is max-min")
        }
        do {
            let e = engine()
            _ = pair(e, tVideo: 0, tAudio: 0.200)
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.0, luminance: 0.8, threshold: 0.1))
            _ = pair(e, tVideo: 5.0, tAudio: 5.200)
            let snap = e.snapshot()
            expect(snap.validCount == 2 && snap.rejectedCount >= 1, "one missing audio")
        }
        do {
            let e = engine()
            _ = pair(e, tVideo: 0, tAudio: 0.200)
            _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 1.0, envelope: 0.4, threshold: 0.1))
            _ = pair(e, tVideo: 5.0, tAudio: 5.200)
            let snap = e.snapshot()
            expect(snap.validCount == 2 && snap.rejectedCount >= 1, "one missing flash")
        }
        do {
            let e = engine()
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 2.0, luminance: 0.8, threshold: 0.1))
            _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 2.200, envelope: 0.4, threshold: 0.1))
            _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 2.260, envelope: 0.2, threshold: 0.1))
            _ = pair(e, tVideo: 6.0, tAudio: 6.200)
            expect(e.snapshot().validCount == 2 && e.snapshot().rejectedCount >= 1, "false extra audio pulse")
        }
        do {
            let e = engine()
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 2.0, luminance: 0.8, threshold: 0.1))
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 2.04, luminance: 0.9, threshold: 0.1))
            _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 2.200, envelope: 0.4, threshold: 0.1))
            _ = pair(e, tVideo: 6.0, tAudio: 6.200)
            expect(e.snapshot().validCount == 2 && e.snapshot().rejectedCount >= 1, "false extra video flash")
        }
        do {
            let e = engine()
            for i in 0..<6 { _ = pair(e, tVideo: Double(i), tAudio: Double(i) + 0.200) }
            _ = pair(e, tVideo: 10.0, tAudio: 10.0 + 0.240)
            let snap = e.snapshot()
            expect(snap.validCount == 6 && snap.outlierCount == 1 && abs(snap.medianMilliseconds - 200) < 0.1, "extreme outlier")
        }
        do {
            let frames = FrameRate.fps2997.frames(forMilliseconds: 193)
            expect(abs(FrameRate.fps2997.framesPerSecond - 30_000.0 / 1_001.0) < 1e-12, "29.97 fps exact")
            expect(abs(frames - 5.79) < 0.01, "29.97 frame conversion 193ms")
        }
        do {
            let frames = FrameRate.fps5994.frames(forMilliseconds: 193)
            expect(abs(FrameRate.fps5994.framesPerSecond - 60_000.0 / 1_001.0) < 1e-12, "59.94 fps exact")
            expect(abs(frames - (193.0 / 1000.0 * 60_000.0 / 1_001.0)) < 1e-10, "59.94 frame conversion")
        }
        do {
            let e = SyncMeasurementEngine(configuration: .init(calibrationOffsetMilliseconds: 12))
            _ = pair(e, tVideo: 1, tAudio: 1.200)
            expect(abs((e.snapshot().correctedCurrentMilliseconds ?? 0) - 188) < 0.001, "calibration subtracts")
        }
        do {
            let e = engine()
            _ = pair(e, tVideo: 1, tAudio: 1.193)
            let snap = e.snapshot()
            let measured = CalibrationMath.measuredOffsetForZero(
                validCount: snap.validCount,
                medianMilliseconds: snap.medianMilliseconds,
                currentOffsetMilliseconds: snap.currentOffsetMilliseconds
            )
            expect(measured != nil && abs(measured! - 193) < 0.001, "zero uses +193 raw pair")
            let stored = CalibrationMath.calibrationOffset(measuredOffset: measured ?? 0, knownTrueOffset: 0)
            expect(abs(stored - 193) < 0.001, "zero stores cal +193")
            e.configuration.calibrationOffsetMilliseconds = stored
            let zeroed = e.snapshot()
            expect(abs((zeroed.correctedCurrentMilliseconds ?? -1)) < 0.001, "zero displays 0")
            expect(abs(zeroed.calibrationOffsetMilliseconds - 193) < 0.001 && zeroed.calibrationApplied, "zero persists stored cal")
            e.configuration.calibrationOffsetMilliseconds = 0
            let cleared = e.snapshot()
            expect(abs((cleared.correctedCurrentMilliseconds ?? 0) - 193) < 0.001, "clear restores raw +193")
            expect(!cleared.calibrationApplied, "clear is none applied")
            expect(CalibrationMath.measuredOffsetForZero(validCount: 0, medianMilliseconds: 0, currentOffsetMilliseconds: nil) == nil, "no pair cannot zero")
        }
        do {
            let d = VideoFlashDetector()
            var hits = 0
            for i in 0..<10 {
                if d.processLuminance(0.05, timestampSeconds: Double(i) * 0.016) != nil { hits += 1 }
            }
            if d.processLuminance(0.85, timestampSeconds: 0.20) != nil { hits += 1 }
            for i in 0..<12 {
                if d.processLuminance(0.80, timestampSeconds: 0.22 + Double(i) * 0.016) != nil { hits += 1 }
            }
            expect(hits == 1, "flash detector single event")
        }
        do {
            let d = AudioPulseDetector()
            let rate = 48_000.0
            let quiet = [Float](repeating: 0.001, count: 2048)
            _ = d.processMonoSamples(quiet, bufferStartSeconds: 0, sampleRate: rate)
            var loud = [Float](repeating: 0.001, count: 2048)
            for i in 512..<700 { loud[i] = 0.9 }
            let event = d.processMonoSamples(loud, bufferStartSeconds: 1.0, sampleRate: rate)
            let expected = 1.0 + 512.0 / rate
            expect(event != nil && abs(event!.timestampSeconds - expected) < 32.0 / rate, "audio onset sample offset", event.map { String($0.timestampSeconds) } ?? "nil")
        }

        do {
            let e = engine()
            for i in 0..<28 {
                _ = pair(e, tVideo: Double(i), tAudio: Double(i) + 0.200)
            }
            _ = pair(e, tVideo: 40.0, tAudio: 40.0 + 0.240)
            let snap = e.snapshot()
            expect(snap.validCount == 28 && snap.outlierCount == 1 && snap.recentValidSamples.count == 25, "recent table size")
            expect(!(snap.recentValidSamples.contains { $0.isOutlier }), "recent table omits outliers")
            expect(abs((snap.recentValidSamples.first?.videoTimestampSeconds ?? -1) - 27.0) < 0.001, "recent newest first")
            expect(abs((snap.recentValidSamples.last?.videoTimestampSeconds ?? -1) - 3.0) < 0.001, "recent oldest of 25")
            e.reset()
            expect(e.snapshot().recentValidSamples.isEmpty && e.snapshot().validCount == 0, "reset clears recent table")
            expect(e.snapshot().correctedMedianMilliseconds == nil, "no pairs: headline median is nil")
        }
        do {
            let e = engine()
            expect(e.snapshot().correctedMedianMilliseconds == nil, "empty snapshot median nil")
            _ = pair(e, tVideo: 0, tAudio: 0.100)
            _ = pair(e, tVideo: 1, tAudio: 1.160)
            _ = pair(e, tVideo: 2, tAudio: 2.220)
            let snap = e.snapshot()
            expect(abs((snap.currentOffsetMilliseconds ?? 0) - 220) < 0.01, "last pair is 220")
            expect(abs(snap.medianMilliseconds - 160) < 0.01, "median of 100/160/220 is 160")
            expect(abs((snap.correctedMedianMilliseconds ?? 0) - 160) < 0.01, "headline uses median not last")
            e.configuration.calibrationOffsetMilliseconds = 10
            expect(abs((e.snapshot().correctedMedianMilliseconds ?? 0) - 150) < 0.01, "headline median minus cal")
        }

        // MARK: - Constant offset must not climb (the walking-number tests)

        func runSyntheticPass(trueOffsetMs: Double, events: Int = 36, agcDecayPerSecond: Double = 0) -> [Double] {
            SyntheticRig.run(trueOffsetMs: trueOffsetMs, events: events, agcDecayPerSecond: agcDecayPerSecond)
        }

        for trueMs in [0.0, 50.0, -80.0] {
            let offsets = runSyntheticPass(trueOffsetMs: trueMs)
            let n = offsets.count
            let med = n == 0 ? 0 : MeasurementStatistics.median(offsets)
            let walk = MeasurementStatistics.walkMsPerEvent(offsets) ?? 999
            let span = (offsets.max() ?? 0) - (offsets.min() ?? 0)
            expect(n >= 30, "constant \(Int(trueMs)) ms: enough events", "n=\(n)")
            expect(abs(med - trueMs) < 3.0, "constant \(Int(trueMs)) ms: median near true", String(format: "median %.3f walk %.4f n=%d", med, walk, n))
            expect(abs(walk) < 0.15, "constant \(Int(trueMs)) ms: walk ≪ 1 ms/event", String(format: "walk %.4f ms/event span %.3f", walk, span))
            expect(span < 5.0, "constant \(Int(trueMs)) ms: span small", String(format: "span %.3f", span))
        }

        do {
            let pre = runSyntheticPass(trueOffsetMs: 0, events: 10)
            let post = runSyntheticPass(trueOffsetMs: 164, events: 30)
            let medPre = MeasurementStatistics.median(pre)
            let medPost = MeasurementStatistics.median(post)
            expect(pre.count >= 8 && abs(medPre) < 3, "step pre: ~0 ms", String(format: "n=%d med=%.3f", pre.count, medPre))
            expect(post.count >= 20 && abs(medPost - 164) < 3, "step post: ~164 ms", String(format: "n=%d med=%.3f", post.count, medPost))
            expect(abs((medPost - medPre) - 164) < 4, "step: median jumps by ~164 ms", String(format: "delta %.3f", medPost - medPre))
        }

        do {
            // Same 36-event pass, audio amplitude decays 3%/s (AGC). Onset must not walk 1 ms/beep.
            let offsets = runSyntheticPass(trueOffsetMs: 50, events: 36, agcDecayPerSecond: 0.03)
            let walk = MeasurementStatistics.walkMsPerEvent(offsets) ?? 999
            expect(offsets.count >= 20, "AGC pass produced events", "n=\(offsets.count)")
            expect(abs(walk) < 0.25, "AGC cannot walk 1 ms/event", String(format: "walk %.4f n=%d", walk, offsets.count))
            expect(abs(MeasurementStatistics.median(offsets) - 50) < 5, "AGC median still ~50", String(format: "med %.3f", MeasurementStatistics.median(offsets)))
        }

        do {
            // Document the old bug: raw PTS subtraction with 1000 ppm audio-fast walks ~1 ms/s.
            var raw: [Double] = []
            for i in 0..<30 {
                let hostV = Double(i)
                let hostA = Double(i) + 0.011
                let audioPTS = hostA * 1.001
                raw.append((audioPTS - hostV) * 1000)
            }
            let rawWalk = MeasurementStatistics.walkMsPerEvent(raw) ?? 0
            expect(abs(rawWalk - 1.0) < 0.05, "raw 1000 ppm walk is ~1 ms/event (the old bug)", String(format: "walk %.4f first %.3f last %.3f", rawWalk, raw.first ?? 0, raw.last ?? 0))

            let clock = CaptureClock()
            // Warm up both fits with 60 fps video + 100 Hz audio buffers over 8 s.
            var t = 0.0
            while t <= 8.0 {
                _ = clock.observe(stream: .video, ptsSeconds: t, hostSeconds: t)
                t += 1.0 / 60.0
            }
            t = 0.0
            while t <= 8.0 {
                let audioPTS = t * 1.001
                _ = clock.observe(stream: .audio, ptsSeconds: audioPTS, hostSeconds: t)
                t += 0.01
            }
            var unified: [Double] = []
            for i in 8..<40 {
                let hostV = Double(i)
                let hostA = Double(i) + 0.050
                // Keep feeding the timebase so interpolation stays local.
                _ = clock.observe(stream: .video, ptsSeconds: hostV, hostSeconds: hostV)
                _ = clock.observe(stream: .audio, ptsSeconds: hostA * 1.001, hostSeconds: hostA)
                let vU = clock.unified(stream: .video, ptsSeconds: hostV)
                let aU = clock.unified(stream: .audio, ptsSeconds: hostA * 1.001)
                unified.append((aU - vU) * 1000)
            }
            let uWalk = MeasurementStatistics.walkMsPerEvent(unified) ?? 999
            let uMed = MeasurementStatistics.median(unified)
            expect(abs(uWalk) < 0.15, "CaptureClock flattens 1000 ppm walk", String(format: "walk %.4f med %.3f first %.3f last %.3f", uWalk, uMed, unified.first ?? 0, unified.last ?? 0))
            expect(abs(uMed - 50) < 3, "CaptureClock preserves +50 ms true offset", String(format: "med %.3f", uMed))
        }

        do {
            let e = engine()
            for i in 0..<20 {
                _ = pair(e, tVideo: Double(i), tAudio: Double(i) + 0.050)
            }
            let walk = e.snapshot().walkMsPerEvent ?? 999
            expect(abs(walk) < 0.001, "engine walk on constant injected pairs is 0", String(format: "walk %.6f", walk))
        }

        // MARK: - Clock must settle before pairs are published

        func warmupClock(_ clock: CaptureClock, seconds: Double, audioPpm: Double = 0) {
            // Interleave like live capture so the relative A−V fit sees both
            // streams. Sequential video-then-audio never produces A-vs-V samples.
            let audioRate = 1.0 + audioPpm / 1_000_000.0
            var tV = 0.0
            var tA = 0.0
            while tV <= seconds || tA <= seconds {
                if tA > seconds || (tV <= seconds && tV <= tA) {
                    _ = clock.observe(stream: .video, ptsSeconds: tV, hostSeconds: tV)
                    tV += 1.0 / 60.0
                } else {
                    _ = clock.observe(stream: .audio, ptsSeconds: tA * audioRate, hostSeconds: tA)
                    tA += 0.01
                }
            }
        }

        func publishIfSettled(_ clock: CaptureClock, _ e: SyncMeasurementEngine, tVideo: Double, tAudio: Double) -> SyncSample? {
            guard clock.allowsPublishedPairs else { return nil }
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: tVideo, luminance: 0.8, threshold: 0.1))
            return e.ingestPulse(AudioPulseEvent(timestampSeconds: tAudio, envelope: 0.4, threshold: 0.1))
        }

        do {
            let clock = CaptureClock()
            let e = engine()
            var t = 0.0
            while t <= 0.25 {
                _ = clock.observe(stream: .video, ptsSeconds: t, hostSeconds: t)
                _ = clock.observe(stream: .audio, ptsSeconds: t, hostSeconds: t)
                t += 1.0 / 60.0
            }
            expect(!clock.snapshot().settled && !clock.allowsPublishedPairs, "clock not settled after 0.25 s")
            let held = publishIfSettled(clock, e, tVideo: 0.20, tAudio: 0.206)
            expect(held == nil && e.snapshot().validCount == 0, "clock not settled → no published pairs")
            e.noteHeldForClock(
                flash: VisualFlashEvent(timestampSeconds: 0.20, luminance: 0.8, threshold: 0.1),
                pulse: AudioPulseEvent(timestampSeconds: 0.206, envelope: 0.4, threshold: 0.1)
            )
            expect(e.diagnostics.contains(where: { $0.kind == .clockSettling }), "settling events are logged, not paired")
        }

        do {
            // One beep plus ring-down replicas 200–400 ms later must be one onset.
            let d = AudioPulseDetector()
            let rate = 48_000.0
            let buf = 1024
            func feed(from t0: Double, until t1: Double, paint: (Double) -> Float) -> [AudioPulseEvent] {
                var hits: [AudioPulseEvent] = []
                var t = t0
                while t < t1 {
                    let n = buf
                    var samples = [Float](repeating: 0, count: n)
                    for i in 0..<n {
                        samples[i] = paint(t + Double(i) / rate)
                    }
                    if let ev = d.processMonoSamples(samples, bufferStartSeconds: t, sampleRate: rate) {
                        hits.append(ev)
                    }
                    t += Double(n) / rate
                }
                return hits
            }
            func sample(at t: Double) -> Float {
                func burst(_ start: Double, amp: Float, dur: Double) -> Float {
                    guard t >= start && t < start + dur else { return 0 }
                    return amp
                }
                var x: Float = 0.001
                x = max(x, burst(1.000, amp: 0.80, dur: 0.010))
                x = max(x, burst(1.220, amp: 0.12, dur: 0.008))
                x = max(x, burst(1.350, amp: 0.08, dur: 0.008))
                x = max(x, burst(1.400, amp: 0.06, dur: 0.008))
                return x
            }
            _ = feed(from: 0.0, until: 0.8, paint: { _ in 0.001 })
            let first = feed(from: 0.8, until: 1.7, paint: sample)
            expect(first.count == 1, "one beep with ring-down replicas → one onset", "hits=\(first.count)")
            if let onset = first.first {
                expect(abs(onset.timestampSeconds - 1.0) < 0.005, "onset walks back to the real attack", String(format: "onset %.4f", onset.timestampSeconds))
            }
        }

        do {
            // Extra 300 ms replica expires unpaired instead of stealing the next flash.
            let e = engine()
            _ = pair(e, tVideo: 1.0, tAudio: 1.006)
            _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 1.300, envelope: 0.12, threshold: 0.05))
            _ = pair(e, tVideo: 2.0, tAudio: 2.006)
            let snap = e.snapshot()
            expect(snap.validCount == 2, "replica does not steal next flash", "n=\(snap.validCount)")
            expect(snap.rejectedCount >= 1, "replica expires unpaired")
            let offsets = snap.recentValidSamples.map(\.offsetMilliseconds)
            expect(offsets.allSatisfy { abs($0 - 6) < 0.5 }, "both pairs stay ~+6 ms", "\(offsets)")
        }

        do {
            // Constant +6 ms over 15 events after lock stays flat.
            let clock = CaptureClock()
            warmupClock(clock, seconds: 2.5, audioPpm: 1000)
            expect(clock.allowsPublishedPairs, "clock settled after 2.5 s warmup")
            let e = engine()
            var offsets: [Double] = []
            for i in 0..<15 {
                let hostV = 3.0 + Double(i)
                let hostA = hostV + 0.006
                _ = clock.observe(stream: .video, ptsSeconds: hostV, hostSeconds: hostV)
                _ = clock.observe(stream: .audio, ptsSeconds: hostA * 1.001, hostSeconds: hostA)
                let vU = clock.unified(stream: .video, ptsSeconds: hostV)
                let aU = clock.unified(stream: .audio, ptsSeconds: hostA * 1.001)
                guard clock.allowsPublishedPairs else { continue }
                _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: vU, luminance: 0.8, threshold: 0.1))
                if let s = e.ingestPulse(AudioPulseEvent(timestampSeconds: aU, envelope: 0.4, threshold: 0.1)) {
                    offsets.append(s.offsetMilliseconds)
                }
            }
            let med = MeasurementStatistics.median(offsets)
            let walk = MeasurementStatistics.walkMsPerEvent(offsets) ?? 999
            let span = (offsets.max() ?? 0) - (offsets.min() ?? 0)
            expect(offsets.count == 15, "15 events after lock", "n=\(offsets.count)")
            expect(abs(med - 6) < 3.0, "after lock median ~+6 ms", String(format: "med %.3f", med))
            expect(abs(walk) < 0.15, "after lock +6 ms stays flat", String(format: "walk %.4f span %.3f", walk, span))
            expect(span < 5.0, "after lock span tight", String(format: "span %.3f", span))
        }

        // MARK: - Build 7: freeze, holdoff, discontinuity, force-settle

        do {
            // Session-mapped PTS is already host time. Callback hostNow jitter
            // must not be the slope-fit target; after freeze it also must not
            // walk a constant offset even if someone still passes it.
            let clock = CaptureClock()
            var t = 0.0
            while t <= 3.0 {
                _ = clock.observe(stream: .video, ptsSeconds: t, hostSeconds: t)
                t += 1.0 / 60.0
            }
            t = 0.0
            while t <= 3.0 {
                _ = clock.observe(stream: .audio, ptsSeconds: t, hostSeconds: t)
                t += 0.01
            }
            expect(clock.allowsPublishedPairs, "jitter test: settled before freeze window")
            var offsets: [Double] = []
            for i in 0..<25 {
                let hostV = 3.0 + Double(i)
                let hostA = hostV + 0.006
                let jitterV = 0.012 * sin(Double(i) * 2.7 + 0.3)
                let jitterA = 0.010 * sin(Double(i) * 3.1 + 1.1)
                _ = clock.observe(stream: .video, ptsSeconds: hostV, hostSeconds: hostV + jitterV)
                _ = clock.observe(stream: .audio, ptsSeconds: hostA, hostSeconds: hostA + jitterA)
                let vU = clock.unified(stream: .video, ptsSeconds: hostV)
                let aU = clock.unified(stream: .audio, ptsSeconds: hostA)
                offsets.append((aU - vU) * 1000)
            }
            let med = MeasurementStatistics.median(offsets)
            let walk = MeasurementStatistics.walkMsPerEvent(offsets) ?? 999
            let span = (offsets.max() ?? 0) - (offsets.min() ?? 0)
            expect(offsets.count == 25, "callback-jitter: 25 events", "n=\(offsets.count)")
            expect(abs(med - 6) < 3.0, "callback-jitter hostNow does not walk unified offset", String(format: "med %.3f walk %.4f span %.3f", med, walk, span))
            expect(abs(walk) < 0.15, "callback-jitter walk ≪ 1 ms/event", String(format: "walk %.4f", walk))
            expect(span < 5.0, "callback-jitter span tight", String(format: "span %.3f", span))
        }

        do {
            let d = VideoFlashDetector()
            var hits = 0
            for i in 0..<30 {
                if d.processLuminance(0.05, timestampSeconds: Double(i) / 60.0) != nil { hits += 1 }
            }
            for f in 0..<20 {
                let t = 1.0 + Double(f) / 60.0
                if d.processLuminance(0.90, timestampSeconds: t) != nil { hits += 1 }
            }
            expect(hits == 1, "long video flash (20 frames at 60 fps) is one event", "hits=\(hits)")
        }

        do {
            let d = VideoFlashDetector()
            let e = engine()
            let fps = 60.0
            func luma(_ t: Double) -> Double {
                for p in [1.0, 1.15, 2.0] {
                    if abs(t - p) < 0.5 / fps { return 0.90 }
                }
                return 0.05
            }
            var events: [VisualFlashEvent] = []
            var t = 0.0
            while t < 2.6 {
                if let ev = d.processLuminance(luma(t), timestampSeconds: t) {
                    events.append(ev)
                }
                t += 1.0 / fps
            }
            expect(events.count == 2, "extra flash ~150 ms later is not a second event", "n=\(events.count) times=\(events.map { String(format: "%.3f", $0.timestampSeconds) })")
            if events.count == 2 {
                expect(abs(events[0].timestampSeconds - 1.0) < 0.02, "first flash at 1.0 s", String(format: "%.4f", events[0].timestampSeconds))
                expect(abs(events[1].timestampSeconds - 2.0) < 0.02, "second flash at 2.0 s not 1.15", String(format: "%.4f", events[1].timestampSeconds))
                _ = e.ingestFlash(events[0])
                _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 1.006, envelope: 0.4, threshold: 0.1))
                _ = e.ingestFlash(events[1])
                _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 2.006, envelope: 0.4, threshold: 0.1))
                let snap = e.snapshot()
                expect(snap.validCount == 2, "extra flash ~150 ms later does not steal the next pulse", "n=\(snap.validCount)")
                let offs = snap.recentValidSamples.map(\.offsetMilliseconds)
                expect(offs.allSatisfy { abs($0 - 6) < 1.0 }, "stolen-pulse pairs stay ~+6 ms", "\(offs)")
            }
        }

        // MARK: - Build 8: flash must fire at 1 Hz even with lock-style flattened luma

        do {
            // Zero-flash regression: dark floor then 1 Hz white flashes must
            // produce one event per flash. Reintroducing a dead detector fails here.
            let d = VideoFlashDetector()
            let fps = 60.0
            func luma(_ t: Double) -> Double {
                let phase = t.truncatingRemainder(dividingBy: 1.0)
                // ~2 frames of white at each integer second, otherwise dark.
                if t >= 1.0 && phase < 2.0 / fps { return 0.87 }
                return 0.05
            }
            var times: [Double] = []
            var t = 0.0
            while t < 9.0 {
                if let ev = d.processLuminance(luma(t), timestampSeconds: t) {
                    times.append(ev.timestampSeconds)
                }
                t += 1.0 / fps
            }
            expect(times.count == 8, "1 Hz white flash on dark field is one event each (zero-flash regression)", "n=\(times.count) times=\(times.map { String(format: "%.3f", $0) })")
            if times.count == 8 {
                for i in 0..<8 {
                    expect(abs(times[i] - Double(i + 1)) < 0.03, "1 Hz flash \(i + 1) on the second", String(format: "%.4f", times[i]))
                }
            }
        }

        do {
            // Bright first frame must not hide later flashes (asymmetric floor).
            let d = VideoFlashDetector()
            var hits = 0
            if d.processLuminance(0.90, timestampSeconds: 0.0) != nil { hits += 1 }
            for i in 1..<30 {
                if d.processLuminance(0.05, timestampSeconds: Double(i) / 60.0) != nil { hits += 1 }
            }
            if d.processLuminance(0.87, timestampSeconds: 1.0) != nil { hits += 1 }
            expect(hits == 1, "bright first frame then dark then flash still fires", "hits=\(hits)")
        }

        do {
            // After holdoff, still-bright field must not re-arm / re-fire.
            let d = VideoFlashDetector()
            var hits = 0
            for i in 0..<30 {
                if d.processLuminance(0.05, timestampSeconds: Double(i) / 60.0) != nil { hits += 1 }
            }
            if d.processLuminance(0.87, timestampSeconds: 1.0) != nil { hits += 1 }
            var t = 1.0 + 1.0 / 60.0
            while t < 2.2 {
                if d.processLuminance(0.80, timestampSeconds: t) != nil { hits += 1 }
                t += 1.0 / 60.0
            }
            expect(hits == 1, "stuck-bright after 400 ms holdoff does not re-fire", "hits=\(hits)")
        }

        do {
            // Lock-style elevated floor: after the first flash, luma never
            // returns to the original dark (AE pumped). Re-arm on relative
            // drop from peak, then 1 Hz flashes with remaining contrast still
            // fire. Completely crushed (flat) luma is a capture problem, not
            // something the detector can invent — see the next case.
            let d = VideoFlashDetector()
            let fps = 60.0
            func luma(_ t: Double) -> Double {
                let phase = t.truncatingRemainder(dividingBy: 1.0)
                let flashing = t >= 1.0 && phase < 2.0 / fps
                if flashing { return t < 1.5 ? 0.87 : 0.70 }
                if t < 1.0 { return 0.05 }
                return 0.22
            }
            var times: [Double] = []
            var t = 0.0
            while t < 6.0 {
                if let ev = d.processLuminance(luma(t), timestampSeconds: t) {
                    times.append(ev.timestampSeconds)
                }
                t += 1.0 / fps
            }
            expect(times.count == 5, "elevated post-flash floor still yields 1 Hz events", "n=\(times.count) times=\(times.map { String(format: "%.3f", $0) })")
        }

        do {
            // Honest limit: AE-crushed flat luma (no rise) cannot be recovered
            // in software. CaptureManager must not lock AE. This documents the
            // zero-flash failure mode; it is not a detector pass.
            let d = VideoFlashDetector()
            var hits = 0
            var t = 0.0
            while t < 5.0 {
                if d.processLuminance(0.15, timestampSeconds: t) != nil { hits += 1 }
                t += 1.0 / 60.0
            }
            expect(hits == 0, "flat luma after crushed AE produces no invented flashes", "hits=\(hits)")
        }

        do {
            let clock = CaptureClock()
            warmupClock(clock, seconds: 3.0)
            expect(clock.allowsPublishedPairs, "discontinuity: settled before jump")
            var before: [Double] = []
            for i in 0..<4 {
                let hostV = 3.0 + Double(i)
                let hostA = hostV + 0.006
                _ = clock.observe(stream: .video, ptsSeconds: hostV, hostSeconds: hostV)
                _ = clock.observe(stream: .audio, ptsSeconds: hostA, hostSeconds: hostA)
                let vU = clock.unified(stream: .video, ptsSeconds: hostV)
                let aU = clock.unified(stream: .audio, ptsSeconds: hostA)
                before.append((aU - vU) * 1000)
            }
            expect(before.allSatisfy { abs($0 - 6) < 1 }, "discontinuity: pre-jump +6 ms")

            // PTS goes backwards mid-pass → reset, drop until re-settled.
            _ = clock.observe(stream: .video, ptsSeconds: 0.05, hostSeconds: 0.05)
            _ = clock.observe(stream: .audio, ptsSeconds: 0.05, hostSeconds: 0.05)
            expect(!clock.snapshot().settled && !clock.allowsPublishedPairs, "PTS discontinuity mid-pass: not settled")
            let e = engine()
            let held = publishIfSettled(clock, e, tVideo: 0.20, tAudio: 0.206)
            expect(held == nil && e.snapshot().validCount == 0, "PTS discontinuity: drop until re-settled")

            warmupClock(clock, seconds: 3.0)
            expect(clock.allowsPublishedPairs, "PTS discontinuity: re-settled after warmup")
            var after: [Double] = []
            for i in 0..<12 {
                let hostV = 3.0 + Double(i)
                let hostA = hostV + 0.006
                _ = clock.observe(stream: .video, ptsSeconds: hostV, hostSeconds: hostV)
                _ = clock.observe(stream: .audio, ptsSeconds: hostA, hostSeconds: hostA)
                let vU = clock.unified(stream: .video, ptsSeconds: hostV)
                let aU = clock.unified(stream: .audio, ptsSeconds: hostA)
                after.append((aU - vU) * 1000)
            }
            let med = MeasurementStatistics.median(after)
            let walk = MeasurementStatistics.walkMsPerEvent(after) ?? 999
            expect(after.count == 12, "discontinuity: post re-settle events", "n=\(after.count)")
            expect(abs(med - 6) < 3.0, "PTS discontinuity then flat +6 ms", String(format: "med %.3f walk %.4f", med, walk))
            expect(abs(walk) < 0.15, "PTS discontinuity re-settle walk flat", String(format: "walk %.4f", walk))
        }

        do {
            let clock = CaptureClock()
            warmupClock(clock, seconds: 3.0)
            expect(clock.allowsPublishedPairs, "25 s freeze: settled")
            var offsets: [Double] = []
            for i in 0..<25 {
                let hostV = 3.0 + Double(i)
                let hostA = hostV + 0.006
                _ = clock.observe(stream: .video, ptsSeconds: hostV, hostSeconds: hostV)
                _ = clock.observe(stream: .audio, ptsSeconds: hostA, hostSeconds: hostA)
                let vU = clock.unified(stream: .video, ptsSeconds: hostV)
                let aU = clock.unified(stream: .audio, ptsSeconds: hostA)
                offsets.append((aU - vU) * 1000)
            }
            let med = MeasurementStatistics.median(offsets)
            let walk = MeasurementStatistics.walkMsPerEvent(offsets) ?? 999
            let span = (offsets.max() ?? 0) - (offsets.min() ?? 0)
            expect(offsets.count == 25, "25 s constant +6 ms event count", "n=\(offsets.count)")
            expect(abs(med - 6) < 3.0, "25 s constant +6 ms stays flat after freeze", String(format: "med %.3f walk %.4f span %.3f", med, walk, span))
            expect(abs(walk) < 0.15, "25 s freeze walk ≪ 1 ms/event", String(format: "walk %.4f", walk))
            expect(span < 5.0, "25 s freeze span tight", String(format: "span %.3f", span))
        }

        do {
            // Slope chatter must not stay CLOCK SETTLING forever.
            let clock = CaptureClock()
            var t = 0.0
            while t <= 2.7 {
                let jv = 0.008 * sin(t * 47.0)
                let ja = 0.007 * sin(t * 53.0 + 0.8)
                _ = clock.observe(stream: .video, ptsSeconds: t, hostSeconds: t + jv)
                _ = clock.observe(stream: .audio, ptsSeconds: t, hostSeconds: t + ja)
                t += 1.0 / 60.0
            }
            expect(clock.snapshot().settled && clock.allowsPublishedPairs, "force-settle after ~2.5 s of chatter")
        }

        do {
            let clock = CaptureClock()
            warmupClock(clock, seconds: 3.0)
            expect(clock.allowsPublishedPairs, "post-settle drop: settled")
            let e = engine()
            var published = 0
            for i in 0..<6 {
                let tV = 3.0 + Double(i)
                let tA = tV + 0.006
                let takeV = clock.acceptDetectedEvent(stream: .video)
                let takeA = clock.acceptDetectedEvent(stream: .audio)
                if takeV {
                    _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: tV, luminance: 0.8, threshold: 0.1))
                } else {
                    e.noteHeldForClock(flash: VisualFlashEvent(timestampSeconds: tV, luminance: 0.8, threshold: 0.1), pulse: nil)
                }
                if takeA {
                    if e.ingestPulse(AudioPulseEvent(timestampSeconds: tA, envelope: 0.4, threshold: 0.1)) != nil {
                        published += 1
                    }
                } else {
                    e.noteHeldForClock(flash: nil, pulse: AudioPulseEvent(timestampSeconds: tA, envelope: 0.4, threshold: 0.1))
                }
            }
            expect(e.snapshot().validCount == 4, "drop 2 pairs after gate opens", "valid=\(e.snapshot().validCount) published=\(published)")
            expect(e.diagnostics.contains(where: { $0.kind == .clockSettling }), "dropped post-settle events are logged, not queued")
        }

        // MARK: - Build 9: already-mapped 30.000 vs 29.97 (1000 ppm)

        /// Live path after CMSyncConvertTime: pts == host for each stream.
        /// Video timestamps advance at 30.000 fps; audio at the 29.97/1.001
        /// family (exactly 1000 ppm: 30 / (30000/1001) = 1.001). StreamClockFit
        /// freezes each slope at 1.0 because x == y. The relative A−V lock
        /// has to flatten the walk. True offset is applied to *events only*,
        /// never to every buffer (that would hide the residual in intercept).
        func runAlreadyMappedNTSC(trueOffsetMs: Double, events: Int, warmupSeconds: Double = 3.0) -> [Double] {
            let clock = CaptureClock()
            let ntsc = 1001.0 / 1000.0
            let videoFps = 30.0
            let audioDt = 0.01
            let trueOffset = trueOffsetMs / 1000.0
            let total = warmupSeconds + Double(events) + 0.5
            var offsets: [Double] = []
            var tV = 0.0
            var tA = 0.0
            var nextEvent = warmupSeconds

            while tV <= total || tA <= total {
                if tA > total || (tV <= total && tV <= tA) {
                    let real = tV
                    let vPTS = tV
                    _ = clock.observe(stream: .video, ptsSeconds: vPTS, hostSeconds: vPTS)
                    tV += 1.0 / videoFps
                    if clock.allowsPublishedPairs,
                       real + 1e-9 >= nextEvent,
                       nextEvent < warmupSeconds + Double(events) {
                        let i = nextEvent
                        let evV = i
                        let evA = (i + trueOffset) * ntsc
                        let vU = clock.unified(stream: .video, ptsSeconds: evV)
                        let aU = clock.unified(stream: .audio, ptsSeconds: evA)
                        offsets.append((aU - vU) * 1000)
                        nextEvent += 1.0
                    }
                } else {
                    let aPTS = tA * ntsc
                    _ = clock.observe(stream: .audio, ptsSeconds: aPTS, hostSeconds: aPTS)
                    tA += audioDt
                }
            }
            return offsets
        }

        for trueMs in [6.0, -43.0] {
            let offsets = runAlreadyMappedNTSC(trueOffsetMs: trueMs, events: 25)
            let n = offsets.count
            let med = n == 0 ? 0 : MeasurementStatistics.median(offsets)
            let walk = MeasurementStatistics.walkMsPerEvent(offsets) ?? 999
            let span = n == 0 ? 999 : (offsets.max()! - offsets.min()!)
            expect(n >= 25, "already-mapped 30 vs 29.97 \(Int(trueMs)) ms: ≥25 s of events", "n=\(n)")
            expect(abs(med - trueMs) < 3.0, "already-mapped 30 vs 29.97 \(Int(trueMs)) ms: median near true (do not hide residual)", String(format: "median %.3f walk %.4f n=%d first %.3f last %.3f", med, walk, n, offsets.first ?? 0, offsets.last ?? 0))
            expect(abs(walk) < 0.15, "already-mapped 30 vs 29.97 \(Int(trueMs)) ms: walk ≪ 1 ms/event", String(format: "walk %.4f span %.3f n=%d", walk, span, n))
            expect(span < 5.0, "already-mapped 30 vs 29.97 \(Int(trueMs)) ms: span tight", String(format: "span %.3f", span))
        }

        do {
            // Same already-mapped 30 vs 29.97 clock. A real +164 ms step must
            // still move the median — the relative lock is a rate, not a delay sponge.
            let clock = CaptureClock()
            let ntsc = 1001.0 / 1000.0
            let videoFps = 30.0
            let warmup = 3.0
            let total = warmup + 30.5
            var tV = 0.0
            var tA = 0.0
            var nextEvent = warmup
            var pre: [Double] = []
            var post: [Double] = []
            while tV <= total || tA <= total {
                if tA > total || (tV <= total && tV <= tA) {
                    let real = tV
                    _ = clock.observe(stream: .video, ptsSeconds: tV, hostSeconds: tV)
                    tV += 1.0 / videoFps
                    if clock.allowsPublishedPairs,
                       real + 1e-9 >= nextEvent,
                       nextEvent < warmup + 30.0 {
                        let i = nextEvent
                        let trueOffset = i < warmup + 10.0 ? 0.0 : 0.164
                        let evV = i
                        let evA = (i + trueOffset) * ntsc
                        let vU = clock.unified(stream: .video, ptsSeconds: evV)
                        let aU = clock.unified(stream: .audio, ptsSeconds: evA)
                        let ms = (aU - vU) * 1000
                        if i < warmup + 10.0 { pre.append(ms) } else { post.append(ms) }
                        nextEvent += 1.0
                    }
                } else {
                    let aPTS = tA * ntsc
                    _ = clock.observe(stream: .audio, ptsSeconds: aPTS, hostSeconds: aPTS)
                    tA += 0.01
                }
            }
            let medPre = MeasurementStatistics.median(pre)
            let medPost = MeasurementStatistics.median(post)
            expect(pre.count >= 8 && abs(medPre) < 3, "already-mapped 30 vs 29.97 step pre: ~0 ms", String(format: "n=%d med=%.3f", pre.count, medPre))
            expect(post.count >= 16 && abs(medPost - 164) < 3, "already-mapped 30 vs 29.97 step post: ~164 ms", String(format: "n=%d med=%.3f", post.count, medPost))
            expect(abs((medPost - medPre) - 164) < 4, "already-mapped 30 vs 29.97: +164 ms still moves median", String(format: "delta %.3f", medPost - medPre))
        }

        do {
            // Raw already-mapped 30 vs 29.97 still walks ~1 ms/event (the on-device bug).
            var raw: [Double] = []
            let ntsc = 1001.0 / 1000.0
            for i in 0..<25 {
                let v = Double(i)
                let a = (Double(i) + 0.006) * ntsc
                raw.append((a - v) * 1000)
            }
            let rawWalk = MeasurementStatistics.walkMsPerEvent(raw) ?? 0
            expect(abs(rawWalk - 1.001) < 0.05, "raw already-mapped 30 vs 29.97 walk is ~1 ms/event", String(format: "walk %.4f first %.3f last %.3f", rawWalk, raw.first ?? 0, raw.last ?? 0))
        }

        // MARK: - Build 10: lock capture to NTSC 1001 family

        do {
            let d60 = FrameRate.preferredCaptureDuration(program: .fps2997, maxFrameRate: 60)
            expect(d60.value == 1001 && d60.timescale == 60_000, "29.97 picker + 59+ format → 60_000/1001", "\(d60.value)/\(d60.timescale)")
            let d30 = FrameRate.preferredCaptureDuration(program: .fps2997, maxFrameRate: 30)
            expect(d30.value == 1001 && d30.timescale == 30_000, "29.97 picker without 60 → 30_000/1001", "\(d30.value)/\(d30.timescale)")
            let d5994 = FrameRate.preferredCaptureDuration(program: .fps5994, maxFrameRate: 60)
            expect(d5994.value == 1001 && d5994.timescale == 60_000, "59.94 picker + 59+ format → 60_000/1001", "\(d5994.value)/\(d5994.timescale)")
            let d5994_30 = FrameRate.preferredCaptureDuration(program: .fps5994, maxFrameRate: 30)
            expect(d5994_30.value == 1001 && d5994_30.timescale == 30_000, "59.94 picker without 60 → 30_000/1001", "\(d5994_30.value)/\(d5994_30.timescale)")
            let i60 = FrameRate.preferredCaptureDuration(program: .fps30, maxFrameRate: 60)
            expect(i60.value == 1 && i60.timescale == 60, "integer 30 picker + 59+ → 1/60", "\(i60.value)/\(i60.timescale)")
            let i30 = FrameRate.preferredCaptureDuration(program: .fps30, maxFrameRate: 30)
            expect(i30.value == 1 && i30.timescale == 30, "integer 30 picker without 60 → 1/30", "\(i30.value)/\(i30.timescale)")
            let i60p = FrameRate.preferredCaptureDuration(program: .fps60, maxFrameRate: 60)
            expect(i60p.value == 1 && i60p.timescale == 60, "integer 60 picker → 1/60", "\(i60p.value)/\(i60p.timescale)")
        }

        /// Both stream clocks are true host (pts == host). Relative A−V stays 1.0,
        /// so build (9) cannot flatten this. Video event stamps are capture-frame
        /// index / captureFps; audio events sit on 29.97 file wall + constant delay.
        /// Integer 30 walks ~1 ms/beep. 30_000/1001 or 60_000/1001 goes FLAT.
        func runTrueHostCaptureVsNTSCFile(
            captureFps: Double,
            trueOffsetMs: Double,
            events: Int,
            warmupSeconds: Double = 4.2
        ) -> (offsets: [Double], relativeSlope: Double) {
            let clock = CaptureClock()
            let fileFps = 30_000.0 / 1_001.0
            let eventPeriod = 30.0 / fileFps
            let trueOffset = trueOffsetMs / 1000.0
            let firstK = Int((warmupSeconds / eventPeriod).rounded(.up))
            let lastK = firstK + events - 1
            let total = Double(lastK) * eventPeriod + 0.5
            var offsets: [Double] = []
            var tV = 0.0
            var tA = 0.0
            var nextK = firstK
            while tV <= total || tA <= total {
                if tA > total || (tV <= total && tV <= tA) {
                    _ = clock.observe(stream: .video, ptsSeconds: tV, hostSeconds: tV)
                    tV += 1.0 / captureFps
                    if clock.allowsPublishedPairs, nextK <= lastK {
                        let fileWall = Double(nextK) * eventPeriod
                        if tV + 1e-9 >= fileWall {
                            let vPTS = CaptureFrameDuration.videoPTS(fileWallSeconds: fileWall, captureFps: captureFps)
                            let aPTS = fileWall + trueOffset
                            let vU = clock.unified(stream: .video, ptsSeconds: vPTS)
                            let aU = clock.unified(stream: .audio, ptsSeconds: aPTS)
                            offsets.append((aU - vU) * 1000)
                            nextK += 1
                        }
                    }
                } else {
                    _ = clock.observe(stream: .audio, ptsSeconds: tA, hostSeconds: tA)
                    tA += 0.01
                }
            }
            return (offsets, clock.snapshot().relativeSlope)
        }

        do {
            let ntsc30 = 30_000.0 / 1_001.0
            let ntsc60 = 60_000.0 / 1_001.0
            let (walkOff, walkSlope) = runTrueHostCaptureVsNTSCFile(captureFps: 30.0, trueOffsetMs: 6, events: 25)
            let n = walkOff.count
            let med = n == 0 ? 0 : MeasurementStatistics.median(walkOff)
            let walk = MeasurementStatistics.walkMsPerEvent(walkOff) ?? 0
            expect(n >= 25, "integer-30 capture vs 29.97 events: ≥25 s", "n=\(n)")
            expect(abs(walkSlope - 1.0) < 0.0008, "integer-30 vs 29.97: relative A−V stays 1.0 (9 cannot flatten)", String(format: "slope %.6f", walkSlope))
            expect(abs(walk - 1.001) < 0.08, "integer-30 capture vs 29.97 events walks ~1 ms/beep until NTSC lock", String(format: "walk %.4f med %.3f first %.3f last %.3f n=%d", walk, med, walkOff.first ?? 0, walkOff.last ?? 0, n))

            for (fps, label) in [(ntsc30, "30_000/1001"), (ntsc60, "60_000/1001")] {
                let (off, slope) = runTrueHostCaptureVsNTSCFile(captureFps: fps, trueOffsetMs: 6, events: 25)
                let nn = off.count
                let m = nn == 0 ? 0 : MeasurementStatistics.median(off)
                let w = MeasurementStatistics.walkMsPerEvent(off) ?? 999
                let span = nn == 0 ? 999 : (off.max()! - off.min()!)
                expect(nn >= 25, "NTSC \(label) capture vs 29.97 events: ≥25 s", "n=\(nn)")
                expect(abs(slope - 1.0) < 0.0008, "NTSC \(label): relative A−V stays 1.0 (lock is capture, not (9))", String(format: "slope %.6f", slope))
                expect(abs(m - 6) < 3.0, "NTSC \(label) median ~+6 ms (do not hide residual)", String(format: "med %.3f walk %.4f n=%d first %.3f last %.3f", m, w, nn, off.first ?? 0, off.last ?? 0))
                expect(abs(w) < 0.15, "NTSC \(label) capture vs 29.97 events goes FLAT", String(format: "walk %.4f span %.3f n=%d", w, span, nn))
                expect(span < 5.0, "NTSC \(label) span tight", String(format: "span %.3f", span))
            }
        }

        do {
            // NTSC lock is a rate, not a delay sponge. +164 ms still moves the median.
            let ntsc60 = 60_000.0 / 1_001.0
            let pre = runTrueHostCaptureVsNTSCFile(captureFps: ntsc60, trueOffsetMs: 0, events: 10).offsets
            let post = runTrueHostCaptureVsNTSCFile(captureFps: ntsc60, trueOffsetMs: 164, events: 20).offsets
            let medPre = MeasurementStatistics.median(pre)
            let medPost = MeasurementStatistics.median(post)
            expect(pre.count >= 8 && abs(medPre) < 3, "NTSC lock step pre: ~0 ms", String(format: "n=%d med=%.3f", pre.count, medPre))
            expect(post.count >= 16 && abs(medPost - 164) < 3, "NTSC lock step post: ~164 ms", String(format: "n=%d med=%.3f", post.count, medPost))
            expect(abs((medPost - medPre) - 164) < 4, "NTSC lock: +164 ms still moves median", String(format: "delta %.3f", medPost - medPre))
        }


        // MARK: - Build 11: 400 ms pair window, beep PCM, WALK span, fps footer

        do {
            expect(abs(SyncMeasurementEngine.Configuration().maxPairOffsetSeconds - 0.40) < 1e-9, "pair window default is 400 ms")
            let e = SyncMeasurementEngine()
            let s = pair(e, tVideo: 1.0, tAudio: 1.164)
            expect(s != nil && abs(s!.offsetMilliseconds - 164) < 0.001, "+164 ms still pairs inside 400 ms window")
        }

        do {
            // Ring-down 220–350 ms must expire unpaired vs the next 1 Hz flash.
            for replicaDelay in [0.220, 0.280, 0.350] {
                let e = SyncMeasurementEngine()
                _ = pair(e, tVideo: 1.0, tAudio: 1.006)
                _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 1.0 + replicaDelay, envelope: 0.12, threshold: 0.05))
                _ = pair(e, tVideo: 2.0, tAudio: 2.006)
                let snap = e.snapshot()
                let ms = Int(replicaDelay * 1000)
                expect(snap.validCount == 2, "400 ms window: \(ms) ms replica does not steal next flash", "n=\(snap.validCount)")
                expect(snap.rejectedCount >= 1, "400 ms window: \(ms) ms replica expires unpaired")
                let offsets = snap.recentValidSamples.map(\.offsetMilliseconds)
                expect(offsets.allSatisfy { abs($0 - 6) < 0.5 }, "400 ms window: pairs stay ~+6 ms after \(ms) ms replica", "\(offsets)")
            }
        }

        do {
            let samples = TestSignalBeep.pcmSamples()
            let peak = samples.map { abs($0) }.max() ?? 0
            let wav = TestSignalBeep.wavData()
            let riff = String(bytes: wav.prefix(4), encoding: .ascii) ?? ""
            let wave = String(bytes: wav.dropFirst(8).prefix(4), encoding: .ascii) ?? ""
            expect(TestSignalBeep.durationSeconds >= 0.010 && TestSignalBeep.durationSeconds <= 0.020, "beep duration 10–20 ms", String(format: "%.4f", TestSignalBeep.durationSeconds))
            expect(abs(TestSignalBeep.frequencyHz - 1000) < 1, "beep ~1 kHz")
            expect(samples.count >= 441 && samples.count <= 882, "beep sample count ~10–20 ms at 44.1 kHz", "n=\(samples.count)")
            expect(Double(peak) > 0.7, "beep is loud", String(format: "peak %.3f", Double(peak)))
            expect(wav.count > 44 && riff == "RIFF" && wave == "WAVE", "beep WAV exists", "\(riff)\(wave) bytes=\(wav.count)")
            expect(TestSignalBeep.sessionMixWithOthers && TestSignalBeep.sessionDefaultToSpeaker, "SIG session mixes with capture and defaults to speaker")
            expect(TestSignalBeep.sessionCategory == "playAndRecord" || TestSignalBeep.sessionCategory == "playback", "SIG category plays with ringer off")
            expect(TestSignalBeep.sessionMode == "measurement", "SIG/capture mode is measurement not voiceChat")
            expect(TestSignalBeep.sessionMode != "voiceChat" && TestSignalBeep.sessionMode != "videoChat", "mic path is not voice-chat DSP")
            expect(!TestSignalBeep.sessionAllowBluetooth, "no HFP Bluetooth (AEC + 8 kHz)")
            expect(!TestSignalBeep.sessionPrefersEchoCancelledInput, "echo cancellation is off")
            expect(TestSignalBeep.sessionPreferredMicrophoneMode == "wideSpectrum", "preferred mic mode is wide spectrum")
            expect(!TestSignalBeep.usedAsMeasurementTimestamp, "SIG beep is not a measurement timestamp")
        }

        do {
            // Guy's on-device (8): WALK +0.06 with SPAN 32 from a −23 to −55 step.
            // Palindrome of -23/-55: OLS walk ~0, SPAN 32 (Guy's step that cancelled WALK).
            let half: [Double] = [-55, -23, -55, -23, -55, -23, -55, -23]
            let offsets = half + half.reversed()
            let e = engine()
            for (i, ms) in offsets.enumerated() {
                _ = pair(e, tVideo: Double(i), tAudio: Double(i) + ms / 1000.0)
            }
            let snap = e.snapshot()
            let walk = snap.walkMsPerEvent ?? 999
            expect(abs(walk) < 0.2, "stepped clusters can cancel to |walk|<0.2", String(format: "walk %.4f span %.3f", walk, snap.spanMilliseconds))
            expect(snap.spanMilliseconds > 20, "SPAN is huge (not a few ms)", String(format: "span %.3f", snap.spanMilliseconds))
            expect(!snap.walkLooksStable, "WALK not green when SPAN is huge even if |walk|<0.2")
        }

        do {
            let e = engine()
            for i in 0..<12 {
                _ = pair(e, tVideo: Double(i), tAudio: Double(i) + 0.006 + Double(i % 3) * 0.0002)
            }
            expect(e.snapshot().walkLooksStable, "WALK green when walk flat AND span tight", String(format: "walk %.4f span %.3f", e.snapshot().walkMsPerEvent ?? 999, e.snapshot().spanMilliseconds))
        }

        do {
            let ntsc = FrameRate.captureFooter(observedFPS: 30_000.0 / 1_001.0, picker: .fps2997)
            let integer = FrameRate.captureFooter(observedFPS: 30.0, picker: .fps2997)
            expect(ntsc.contains("29.97") && !ntsc.contains("30.0 fps") && !ntsc.contains("30.00"), "29.97 footer is 29.97 not 30.0", ntsc)
            expect(ntsc.contains("NTSC"), "29.97 footer labeled NTSC", ntsc)
            expect(integer.contains("30.00") && integer.contains("integer"), "integer-30 footer is 30.00 integer", integer)
            expect(integer.contains("MISS"), "picker 29.97 + integer 30.00 footer says NTSC lock MISS", integer)
            let intPicker = FrameRate.captureFooter(observedFPS: 30.0, picker: .fps30)
            expect(intPicker.contains("30.00") && intPicker.contains("integer") && !intPicker.contains("MISS"), "integer picker 30 does not say NTSC lock MISS", intPicker)
            expect(FrameRate.captureFamily(observedFPS: 30_000.0 / 1_001.0) == "NTSC", "classify 29.97 as NTSC")
            expect(FrameRate.captureFamily(observedFPS: 30.0) == "integer", "classify 30.00 as integer")
            expect(FrameRate.captureFamily(observedFPS: 60_000.0 / 1_001.0) == "NTSC", "classify 59.94 as NTSC")
            expect(FrameRate.captureFamily(observedFPS: 60.0) == "integer", "classify 60.00 as integer")
            // 16:52 59.94 NTSC vs 16:55 IDLE 60.00 integer MISS — do not silently flap.
            let jitter5994 = FrameRate.captureFooter(observedFPS: 59.98, picker: .fps5994)
            expect(jitter5994.contains("59.94") && jitter5994.contains("NTSC") && !jitter5994.contains("MISS"), "59.98 with picker 59.94 stays 59.94 NTSC (not 60.00 MISS)", jitter5994)
            expect(FrameRate.captureFamily(observedFPS: 59.98, picker: .fps5994) == "NTSC", "picker 59.94: 59.98 is NTSC not integer")
            let true60 = FrameRate.captureFooter(observedFPS: 60.0, picker: .fps5994)
            expect(true60.contains("60.00") && true60.contains("MISS"), "true 60.00 with picker 59.94 is NTSC lock MISS", true60)
            let idleFlap = FrameRate.captureFooter(observedFPS: 60.0, picker: .fps2997)
            expect(idleFlap.contains("MISS") && idleFlap.contains("integer"), "true 60.00 with picker 29.97 is MISS, never silent integer", idleFlap)
            let ntsc5994 = FrameRate.captureFooter(observedFPS: 60_000.0 / 1_001.0, picker: .fps5994)
            expect(ntsc5994.contains("59.94") && ntsc5994.contains("NTSC") && !ntsc5994.contains("MISS"), "59.94 lock footer is 59.94 NTSC", ntsc5994)
            expect(!ntsc5994.contains("60.00") && !ntsc5994.contains("60.0 fps"), "59.94 footer never prints integer 60", ntsc5994)
        }



        // MARK: - Build 12: stage-noise (beep-like vs voice, one pending, no chase)

        do {
            // Voice-like onsets 50/150/250 ms after a flash plus a real beep at +80 ms.
            // Pair MUST be the beep (~+80), not the first syllable.
            let e = SyncMeasurementEngine()
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.0, luminance: 0.8, threshold: 0.1))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: 1.050))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: 1.150))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: 1.250))
            let s = e.ingestPulse(.beepLike(timestampSeconds: 1.080, envelope: 0.85))
            expect(s != nil && abs(s!.offsetMilliseconds - 80) < 0.5, "voice onsets must not steal; pair is the +80 ms beep", s.map { String(format: "%+.2f n=%d", $0.offsetMilliseconds, e.snapshot().validCount) } ?? "nil")
            expect(e.snapshot().validCount == 1, "one pair from the beep not the syllables", "n=\(e.snapshot().validCount)")
        }

        do {
            let e = SyncMeasurementEngine()
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 2.0, luminance: 0.8, threshold: 0.1))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: 2.050))
            let s = e.ingestPulse(.beepLike(timestampSeconds: 2.080))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: 2.150))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: 2.250))
            expect(s != nil && abs(s!.offsetMilliseconds - 80) < 0.5, "time-ordered syllable then beep pairs +80", s.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
            expect(e.snapshot().validCount == 1, "later syllables do not create extra pairs", "n=\(e.snapshot().validCount)")
        }

        do {
            // Chatter between 1 Hz flashes must not create pairs.
            let e = SyncMeasurementEngine()
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.0, luminance: 0.8, threshold: 0.1))
            _ = e.ingestPulse(.beepLike(timestampSeconds: 1.006))
            for t in [1.22, 1.35, 1.48, 1.61, 1.75, 1.88] {
                _ = e.ingestPulse(.voiceLike(timestampSeconds: t))
            }
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 2.0, luminance: 0.8, threshold: 0.1))
            _ = e.ingestPulse(.beepLike(timestampSeconds: 2.006))
            let snap = e.snapshot()
            expect(snap.validCount == 2, "chatter between 1 Hz flashes does not create pairs", "n=\(snap.validCount) rejected=\(snap.rejectedCount)")
            let offs = snap.recentValidSamples.map(\.offsetMilliseconds)
            expect(offs.allSatisfy { abs($0 - 6) < 0.5 }, "chatter pairs stay ~+6 ms", "\(offs)")
        }

        do {
            // At most one pending pulse: latest beep-like wins, no queued chatter.
            let e = SyncMeasurementEngine()
            _ = e.ingestPulse(.beepLike(timestampSeconds: 1.000, envelope: 0.4))
            _ = e.ingestPulse(.beepLike(timestampSeconds: 1.080, envelope: 0.9))
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.000, luminance: 0.8, threshold: 0.1))
            let snap = e.snapshot()
            expect(snap.validCount == 1 && abs((snap.currentOffsetMilliseconds ?? 0) - 80) < 0.5, "latest beep-like wins (not the first noise hit)", String(format: "n=%d off=%.2f", snap.validCount, snap.currentOffsetMilliseconds ?? -1))
        }

        do {
            // Detector: voice-like onsets 50/150/250 ms plus a 1 kHz 16 ms beep at +80.
            let d = AudioPulseDetector()
            let rate = 48_000.0
            let buf = 1024
            func feed(from t0: Double, until t1: Double, paint: (Double) -> Float) -> [AudioPulseEvent] {
                var hits: [AudioPulseEvent] = []
                var t = t0
                while t < t1 {
                    let n = buf
                    var samples = [Float](repeating: 0, count: n)
                    for i in 0..<n {
                        samples[i] = paint(t + Double(i) / rate)
                    }
                    if let ev = d.processMonoSamples(samples, bufferStartSeconds: t, sampleRate: rate) {
                        hits.append(ev)
                    }
                    t += Double(n) / rate
                }
                return hits
            }
            func sample(_ t: Double) -> Float {
                func syl(_ start: Double, f0: Double) -> Float {
                    let dur = 0.10
                    guard t >= start && t < start + dur else { return 0 }
                    let local = t - start
                    let env: Float
                    if local < 0.012 { env = Float(local / 0.012) }
                    else if local > dur - 0.02 { env = Float(max(0, (dur - local) / 0.02)) }
                    else { env = 1 }
                    return env * 0.32 * Float(sin(2 * Double.pi * f0 * t) + 0.35 * sin(2 * Double.pi * 2 * f0 * t))
                }
                func beep(_ start: Double) -> Float {
                    let dur = 0.016
                    guard t >= start && t < start + dur else { return 0 }
                    let local = t - start
                    let fade = 0.0015
                    let env: Float
                    if local < fade { env = Float(local / fade) }
                    else if local > dur - fade { env = Float(max(0, (dur - local) / fade)) }
                    else { env = 1 }
                    return env * 0.75 * Float(sin(2 * Double.pi * 1_000 * t))
                }
                let mixed = 0.001 + syl(1.050, f0: 180) + beep(1.080) + syl(1.150, f0: 200) + syl(1.250, f0: 170)
                return max(-1, min(1, mixed))
            }
            _ = feed(from: 0.0, until: 0.9, paint: { _ in 0.001 })
            let hits = feed(from: 0.9, until: 1.70, paint: sample)
            expect(hits.count == 1, "detector: beep not syllables (50/150/250 + beep +80)", "n=\(hits.count) times=\(hits.map { String(format: "%.3f beep=%d", $0.timestampSeconds, $0.isBeepLike ? 1 : 0) })")
            if let onset = hits.first {
                expect(abs(onset.timestampSeconds - 1.080) < 0.010, "detector onset is the +80 ms beep", String(format: "%.4f", onset.timestampSeconds))
                expect(onset.isBeepLike, "emitted pulse is beep-like")
            }
        }

        do {
            // Chatter-only (no beep) between 1 Hz windows → no detector events.
            let d = AudioPulseDetector()
            let rate = 48_000.0
            let buf = 1024
            func feed(from t0: Double, until t1: Double, paint: (Double) -> Float) -> [AudioPulseEvent] {
                var hits: [AudioPulseEvent] = []
                var t = t0
                while t < t1 {
                    var samples = [Float](repeating: 0, count: buf)
                    for i in 0..<buf { samples[i] = paint(t + Double(i) / rate) }
                    if let ev = d.processMonoSamples(samples, bufferStartSeconds: t, sampleRate: rate) {
                        hits.append(ev)
                    }
                    t += Double(buf) / rate
                }
                return hits
            }
            func chatter(_ t: Double) -> Float {
                for start in [1.22, 1.40, 1.58, 1.75] {
                    let dur = 0.10
                    if t >= start && t < start + dur {
                        let local = t - start
                        let env: Float = local < 0.015 ? Float(local / 0.015) : 1
                        return env * 0.48 * Float(sin(2 * Double.pi * 190 * t))
                    }
                }
                return 0.001
            }
            _ = feed(from: 0.0, until: 0.9, paint: { _ in 0.001 })
            let hits = feed(from: 0.9, until: 2.1, paint: chatter)
            expect(hits.isEmpty, "detector: voice chatter between flashes emits no beep", "n=\(hits.count) times=\(hits.map { String(format: "%.3f", $0.timestampSeconds) })")
        }

        do {
            // After a real beep, speech stays loud: quiet re-arm must not fire on the next syllable.
            let d = AudioPulseDetector()
            let rate = 48_000.0
            let buf = 1024
            func feed(from t0: Double, until t1: Double, paint: (Double) -> Float) -> [AudioPulseEvent] {
                var hits: [AudioPulseEvent] = []
                var t = t0
                while t < t1 {
                    var samples = [Float](repeating: 0, count: buf)
                    for i in 0..<buf { samples[i] = paint(t + Double(i) / rate) }
                    if let ev = d.processMonoSamples(samples, bufferStartSeconds: t, sampleRate: rate) {
                        hits.append(ev)
                    }
                    t += Double(buf) / rate
                }
                return hits
            }
            func sample(_ t: Double) -> Float {
                var x: Float = 0.001
                if t >= 1.000 && t < 1.016 {
                    let local = t - 1.000
                    let env: Float = local < 0.001 ? Float(local / 0.001) : 1
                    x = max(x, env * 0.90 * Float(sin(2 * Double.pi * 1_000 * t)))
                }
                if t >= 1.020 && t < 1.380 {
                    x = max(x, 0.45 * Float(sin(2 * Double.pi * 180 * t)))
                }
                return x
            }
            _ = feed(from: 0.0, until: 0.8, paint: { _ in 0.001 })
            let hits = feed(from: 0.8, until: 1.55, paint: sample)
            expect(hits.count == 1, "quiet re-arm does not fire on the next syllable after a beep", "n=\(hits.count) times=\(hits.map { String(format: "%.3f", $0.timestampSeconds) })")
        }

        do {
            // Moving luma (work lights / people) must not fire; a real white flash still does.
            let d = VideoFlashDetector()
            var hits: [Double] = []
            var t = 0.0
            let fps = 60.0
            while t < 2.0 {
                // Slow walk 0.05 → 0.32 over 2 s, plus a 0.16 one-frame bump at 0.8 s.
                var luma = 0.05 + 0.27 * (t / 2.0)
                if abs(t - 0.80) < 0.5 / fps { luma += 0.16 }
                if let ev = d.processLuminance(luma, timestampSeconds: t) {
                    hits.append(ev.timestampSeconds)
                }
                t += 1.0 / fps
            }
            expect(hits.isEmpty, "moving luma / people do not fire FLASH", "n=\(hits.count) times=\(hits)")
            if d.processLuminance(0.05, timestampSeconds: 2.05) != nil { hits.append(2.05) }
            if let ev = d.processLuminance(0.87, timestampSeconds: 2.20) { hits.append(ev.timestampSeconds) }
            expect(hits.count == 1 && abs((hits.first ?? 0) - 2.20) < 0.03, "white flash still fires after luma walk", "hits=\(hits)")
        }

        do {
            // +164 / +200 house delay still pairs inside 400 ms after stage-noise path.
            let e = SyncMeasurementEngine()
            let a = pair(e, tVideo: 1.0, tAudio: 1.164)
            let b = pair(e, tVideo: 2.0, tAudio: 2.200)
            expect(a != nil && abs(a!.offsetMilliseconds - 164) < 0.001, "stage-noise path: +164 still pairs")
            expect(b != nil && abs(b!.offsetMilliseconds - 200) < 0.001, "stage-noise path: +200 still pairs")
        }



        // MARK: - Build 13: probe NTSC lock (never silent 1/30); PA-smeared 1 Hz beep

        do {
            let locked30 = CaptureFormatProbe(
                width: 1920, height: 1080,
                ranges: [CaptureFrameDurationRange(minDuration: .integer30, maxDuration: .integer30)]
            )
            let miss = CaptureFrameDuration.selectLock(program: .fps2997, formats: [locked30])
            expect(miss == nil, "picker 29.97 + only 1/30 format does not silently select 1/30", miss.map { "\($0.duration.value)/\($0.duration.timescale)" } ?? "nil")

            let wide30 = CaptureFormatProbe(
                width: 1920, height: 1080,
                ranges: [CaptureFrameDurationRange(minDuration: .integer30, maxDuration: CaptureFrameDuration(value: 1, timescale: 1))]
            )
            let d30 = CaptureFrameDuration.selectLock(program: .fps2997, formats: [wide30])
            expect(d30 != nil && d30!.duration.value == 1001 && d30!.duration.timescale == 30_000, "picker 29.97 on 1/30…1/1 range selects 30_000/1001 not 1/30", d30.map { "\($0.duration.value)/\($0.duration.timescale)" } ?? "nil")

            let native60 = CaptureFormatProbe(
                width: 1280, height: 720,
                ranges: [CaptureFrameDurationRange(minDuration: .ntsc60, maxDuration: CaptureFrameDuration(value: 1, timescale: 1))]
            )
            let integer60fmt = CaptureFormatProbe(
                width: 1920, height: 1080,
                ranges: [CaptureFrameDurationRange(minDuration: .integer60, maxDuration: CaptureFrameDuration(value: 1, timescale: 1))]
            )
            let d60 = CaptureFrameDuration.selectLock(program: .fps2997, formats: [integer60fmt, native60])
            expect(d60 != nil && d60!.duration.value == 1001 && d60!.duration.timescale == 60_000, "picker 29.97 prefers 60_000/1001 from the format list", d60.map { "idx=\($0.formatIndex) \($0.duration.value)/\($0.duration.timescale)" } ?? "nil")
            expect(d60?.formatIndex == 1, "prefer the format that natively lists 1001/60000", d60.map { "idx=\($0.formatIndex)" } ?? "nil")

            let listedOnly = CaptureFormatProbe(
                width: 1920, height: 1080,
                ranges: [CaptureFrameDurationRange(minDuration: .ntsc30, maxDuration: .ntsc30)]
            )
            let closest = CaptureFrameDuration.selectLock(program: .fps2997, formats: [listedOnly])
            expect(closest != nil && closest!.duration.isNTSCFamily && closest!.duration.timescale == 30_000, "closest listed 1001-family is 30_000/1001", closest.map { "\($0.duration.value)/\($0.duration.timescale)" } ?? "nil")

            let i30 = CaptureFrameDuration.selectLock(program: .fps30, formats: [wide30])
            expect(i30 != nil && i30!.duration.value == 1 && i30!.duration.timescale == 30, "integer 30 picker still selects 1/30", i30.map { "\($0.duration.value)/\($0.duration.timescale)" } ?? "nil")
        }

        do {
            // Isolated 1 Hz PA-smeared 40–60 ms pulse, quiet MIC. Must onset.
            let d = AudioPulseDetector()
            let rate = 48_000.0
            let buf = 1024
            func feed(from t0: Double, until t1: Double, paint: (Double) -> Float) -> [AudioPulseEvent] {
                var hits: [AudioPulseEvent] = []
                var t = t0
                while t < t1 {
                    var samples = [Float](repeating: 0, count: buf)
                    for i in 0..<buf { samples[i] = paint(t + Double(i) / rate) }
                    if let ev = d.processMonoSamples(samples, bufferStartSeconds: t, sampleRate: rate) {
                        hits.append(ev)
                    }
                    t += Double(buf) / rate
                }
                return hits
            }
            func smear(_ t: Double, start: Double, dur: Double, amp: Float) -> Float {
                guard t >= start && t < start + dur else { return 0 }
                let local = t - start
                let fade = min(0.008, dur / 4)
                let env: Float
                if local < fade { env = Float(local / fade) }
                else if local > dur - fade { env = Float(max(0, (dur - local) / fade)) }
                else { env = 1 }
                return env * amp * Float(sin(2 * Double.pi * 1_000 * t))
            }
            _ = feed(from: 0.0, until: 0.8, paint: { _ in 0.001 })
            let hits = feed(from: 0.8, until: 2.7, paint: { t in
                0.001 + smear(t, start: 1.0, dur: 0.050, amp: 0.055) + smear(t, start: 2.0, dur: 0.060, amp: 0.040)
            })
            expect(hits.count == 2, "smeared 50/60 ms 1 Hz PA pulse still onsets", "n=\(hits.count) times=\(hits.map { String(format: "%.3f dur=%.3f", $0.timestampSeconds, $0.durationSeconds) })")
            if hits.count >= 1 {
                expect(abs(hits[0].timestampSeconds - 1.0) < 0.012, "first smeared onset ~1.000", String(format: "%.4f", hits[0].timestampSeconds))
                expect(hits[0].isBeepLike, "smeared 50 ms isolated pulse is beep-like")
            }
            if hits.count >= 2 {
                expect(abs(hits[1].timestampSeconds - 2.0) < 0.012, "second 1 Hz smeared onset ~2.000", String(format: "%.4f", hits[1].timestampSeconds))
            }
        }

        do {
            // Voice 50/150/250 + smeared 30 ms beep at +80 must still pair ~+80.
            let d = AudioPulseDetector()
            let rate = 48_000.0
            let buf = 1024
            func feed(from t0: Double, until t1: Double, paint: (Double) -> Float) -> [AudioPulseEvent] {
                var hits: [AudioPulseEvent] = []
                var t = t0
                while t < t1 {
                    var samples = [Float](repeating: 0, count: buf)
                    for i in 0..<buf { samples[i] = paint(t + Double(i) / rate) }
                    if let ev = d.processMonoSamples(samples, bufferStartSeconds: t, sampleRate: rate) {
                        hits.append(ev)
                    }
                    t += Double(buf) / rate
                }
                return hits
            }
            func sample(_ t: Double) -> Float {
                func syl(_ start: Double, f0: Double) -> Float {
                    let dur = 0.10
                    guard t >= start && t < start + dur else { return 0 }
                    let local = t - start
                    let env: Float
                    if local < 0.012 { env = Float(local / 0.012) }
                    else if local > dur - 0.02 { env = Float(max(0, (dur - local) / 0.02)) }
                    else { env = 1 }
                    return env * 0.32 * Float(sin(2 * Double.pi * f0 * t) + 0.35 * sin(2 * Double.pi * 2 * f0 * t))
                }
                func beep(_ start: Double) -> Float {
                    let dur = 0.030
                    guard t >= start && t < start + dur else { return 0 }
                    let local = t - start
                    let fade = 0.004
                    let env: Float
                    if local < fade { env = Float(local / fade) }
                    else if local > dur - fade { env = Float(max(0, (dur - local) / fade)) }
                    else { env = 1 }
                    return env * 0.70 * Float(sin(2 * Double.pi * 1_000 * t))
                }
                let mixed = 0.001 + syl(1.050, f0: 180) + beep(1.080) + syl(1.150, f0: 200) + syl(1.250, f0: 170)
                return max(-1, min(1, mixed))
            }
            _ = feed(from: 0.0, until: 0.9, paint: { _ in 0.001 })
            let hits = feed(from: 0.9, until: 1.70, paint: sample)
            expect(hits.count == 1, "detector: 30 ms smeared beep not syllables (50/150/250 + beep +80)", "n=\(hits.count) times=\(hits.map { String(format: "%.3f beep=%d", $0.timestampSeconds, $0.isBeepLike ? 1 : 0) })")
            if let onset = hits.first {
                expect(abs(onset.timestampSeconds - 1.080) < 0.012, "smeared +80 ms beep onset", String(format: "%.4f", onset.timestampSeconds))
                expect(onset.isBeepLike, "smeared overlay pulse is beep-like")
            }
            let e = SyncMeasurementEngine()
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.0, luminance: 0.8, threshold: 0.1))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: 1.050))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: 1.150))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: 1.250))
            if let onset = hits.first {
                let s = e.ingestPulse(onset)
                expect(s != nil && abs(s!.offsetMilliseconds - 80) < 15, "voice 50/150/250 does not steal; smeared beep +80 still pairs", s.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
            }
        }


        // MARK: - Build 14: mic path — loud PA must onset at 89%, not env 0.001

        do {
            // Non-interleaved stereo: silent/processed ch0 at 0.001, PA beep on ch1.
            // Old parse copied channel 0 (env 0.001). Loudest-channel mix must keep the PA.
            let n = 4096
            let ch0 = [Float](repeating: 0.001, count: n)
            var ch1 = [Float](repeating: 0.001, count: n)
            for i in 512..<1400 {
                let t = Double(i) / 48_000.0
                ch1[i] = 0.22 * Float(sin(2 * Double.pi * 1_000 * t))
            }
            func pack(_ xs: [Float]) -> [UInt8] {
                var b: [UInt8] = []
                b.reserveCapacity(xs.count * 4)
                for x in xs {
                    var f = x
                    withUnsafeBytes(of: &f) { b.append(contentsOf: $0) }
                }
                return b
            }
            let bytes = pack(ch0) + pack(ch1)
            let mixed = AudioPulseDetector.decodeAndMixMono(
                bytes: bytes, channels: 2, bitsPerChannel: 32, isFloat: true, isNonInterleaved: true
            )
            let peak = mixed.dropFirst(512).prefix(800).map { abs($0) }.max() ?? 0
            let firstPlanePeak = ch0.map { abs($0) }.max() ?? 0
            expect(mixed.count == n, "stereo silent-ch0 mix keeps frame count", "n=\(mixed.count)")
            expect(Double(firstPlanePeak) < 0.002, "channel 0 is the crushed 0.001 plane")
            expect(Double(peak) > 0.15, "loudest-channel mix recovers PA-scale peak, not env 0.001", String(format: "peak %.4f", Double(peak)))
            let slice = mixed[512..<1400]
            let rms = AudioPulseDetector.rms(slice)
            expect(rms > 0.10, "mixed RMS is PA-scale not 0.001", String(format: "rms %.4f", rms))
        }

        do {
            // Interleaved int16: silent L, loud R. Must not average down to a sliver.
            let n = 2048
            var bytes = [UInt8](repeating: 0, count: n * 4)
            for i in 400..<900 {
                let t = Double(i) / 48_000.0
                let s = Int16((0.40 * sin(2 * Double.pi * 1_000 * t) * 32767.0).rounded())
                let le = s.littleEndian
                bytes[i * 4 + 2] = UInt8(truncatingIfNeeded: le)
                bytes[i * 4 + 3] = UInt8(truncatingIfNeeded: le >> 8)
            }
            let mixed = AudioPulseDetector.decodeAndMixMono(
                bytes: bytes, channels: 2, bitsPerChannel: 16, isFloat: false, isNonInterleaved: false
            )
            let rms = AudioPulseDetector.rms(mixed[400..<900])
            expect(rms > 0.20, "interleaved silent-L/loud-R mix is PA-scale", String(format: "rms %.4f", rms))
        }

        do {
            // Int32 full-scale 0.25 sine must decode as ~0.25, not as int16-low-half ~0.001.
            let n = 1024
            var bytes = [UInt8](repeating: 0, count: n * 4)
            for i in 0..<n {
                let t = Double(i) / 48_000.0
                let v = Int32((0.25 * sin(2 * Double.pi * 1_000 * t) * 2_147_483_647.0).rounded())
                let le = v.littleEndian
                bytes[i * 4 + 0] = UInt8(truncatingIfNeeded: le)
                bytes[i * 4 + 1] = UInt8(truncatingIfNeeded: le >> 8)
                bytes[i * 4 + 2] = UInt8(truncatingIfNeeded: le >> 16)
                bytes[i * 4 + 3] = UInt8(truncatingIfNeeded: le >> 24)
            }
            let mixed = AudioPulseDetector.decodeAndMixMono(
                bytes: bytes, channels: 1, bitsPerChannel: 32, isFloat: false, isNonInterleaved: false
            )
            let rms = AudioPulseDetector.rms(mixed[...])
            expect(rms > 0.10 && rms < 0.30, "int32 PCM decodes at true scale not 0.001", String(format: "rms %.4f", rms))
        }

        func feedPulse(_ d: AudioPulseDetector, from t0: Double, until t1: Double, rate: Double = 48_000, buf: Int = 1024, paint: (Double) -> Float) -> [AudioPulseEvent] {
            var hits: [AudioPulseEvent] = []
            var t = t0
            while t < t1 {
                var samples = [Float](repeating: 0, count: buf)
                for i in 0..<buf { samples[i] = paint(t + Double(i) / rate) }
                if let ev = d.processMonoSamples(samples, bufferStartSeconds: t, sampleRate: rate) {
                    hits.append(ev)
                }
                t += Double(buf) / rate
            }
            return hits
        }

        do {
            // 89% sensitivity: PA-scale buffers that used to look like env 0.001 still onset.
            var cfg = AudioPulseDetector.Configuration()
            cfg.sensitivity = 0.89
            let d = AudioPulseDetector(configuration: cfg)
            _ = feedPulse(d, from: 0.0, until: 0.8, paint: { _ in 0.001 })
            let thr = d.effectiveThreshold(relativeToBaseline: d.baseline)
            expect(thr < 0.008 && thr > 0.002, "89% threshold sits below a distant PA, above crushed 0.001", String(format: "thr %.4f env %.4f", thr, d.lastEnvelope))
            func smear(_ t: Double, start: Double, dur: Double, amp: Float) -> Float {
                guard t >= start && t < start + dur else { return 0 }
                let local = t - start
                let fade = min(0.006, dur / 4)
                let env: Float
                if local < fade { env = Float(local / fade) }
                else if local > dur - fade { env = Float(max(0, (dur - local) / fade)) }
                else { env = 1 }
                return env * amp * Float(sin(2 * Double.pi * 1_000 * t))
            }
            let hits = feedPulse(d, from: 0.8, until: 3.4, paint: { t in
                0.001 + smear(t, start: 1.0, dur: 0.050, amp: 0.18) + smear(t, start: 2.0, dur: 0.050, amp: 0.18)
            })
            expect(hits.count == 2, "89%: loud PA-scale 50 ms beeps onset (not env 0.001 reject)", "n=\(hits.count) times=\(hits.map { String(format: "%.3f env=%.3f", $0.timestampSeconds, $0.envelope) })")
            if hits.count >= 1 {
                expect(hits[0].envelope > 0.05, "onset envelope is PA-scale not 0.001", String(format: "env %.4f", hits[0].envelope))
                expect(hits[0].isBeepLike, "PA-scale isolated pulse is beep-like")
            }
        }

        do {
            // Crushed 0.001 live env at 89% must still NOT fire (noise floor, not a beep).
            var cfg = AudioPulseDetector.Configuration()
            cfg.sensitivity = 0.89
            let d = AudioPulseDetector(configuration: cfg)
            let hits = feedPulse(d, from: 0.0, until: 2.5, paint: { _ in 0.001 })
            expect(hits.isEmpty, "89%: constant env 0.001 (crushed mic) does not onset", "n=\(hits.count)")
        }

        do {
            // Smeared 15–80 ms 1 Hz PA still pairs with flashes at 89%.
            var cfg = AudioPulseDetector.Configuration()
            cfg.sensitivity = 0.89
            let d = AudioPulseDetector(configuration: cfg)
            _ = feedPulse(d, from: 0.0, until: 0.8, paint: { _ in 0.001 })
            func smear(_ t: Double, start: Double, dur: Double, amp: Float) -> Float {
                guard t >= start && t < start + dur else { return 0 }
                let local = t - start
                let fade = min(0.005, dur / 4)
                let env: Float
                if local < fade { env = Float(local / fade) }
                else if local > dur - fade { env = Float(max(0, (dur - local) / fade)) }
                else { env = 1 }
                return env * amp * Float(sin(2 * Double.pi * 1_000 * t))
            }
            let hits = feedPulse(d, from: 0.8, until: 3.5, paint: { t in
                0.001 + smear(t, start: 1.0, dur: 0.015, amp: 0.16) + smear(t, start: 2.0, dur: 0.080, amp: 0.14)
            })
            expect(hits.count == 2, "smeared 15/80 ms 1 Hz PA still onsets at 89%", "n=\(hits.count) times=\(hits.map { String(format: "%.3f dur=%.3f", $0.timestampSeconds, $0.durationSeconds) })")
            let e = SyncMeasurementEngine()
            if hits.count >= 2 {
                expect(hits.allSatisfy(\.isBeepLike), "15–80 ms isolated PA pulses are beep-like")
                _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.0, luminance: 0.8, threshold: 0.1))
                let a = e.ingestPulse(hits[0])
                _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 2.0, luminance: 0.8, threshold: 0.1))
                let b = e.ingestPulse(hits[1])
                expect(a != nil && abs(a!.offsetMilliseconds) < 20, "15 ms smeared beep pairs with flash", a.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
                expect(b != nil && abs(b!.offsetMilliseconds) < 20, "80 ms smeared beep pairs with flash", b.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
            }
        }

        do {
            // Sustained speech still rejected at 89%.
            var cfg = AudioPulseDetector.Configuration()
            cfg.sensitivity = 0.89
            let d = AudioPulseDetector(configuration: cfg)
            _ = feedPulse(d, from: 0.0, until: 0.8, paint: { _ in 0.001 })
            func speech(_ t: Double) -> Float {
                if t >= 1.0 && t < 1.45 {
                    return 0.35 * Float(sin(2 * Double.pi * 180 * t) + 0.3 * sin(2 * Double.pi * 360 * t))
                }
                return 0.001
            }
            let hits = feedPulse(d, from: 0.8, until: 2.0, paint: speech)
            expect(hits.isEmpty, "89%: sustained speech still rejected", "n=\(hits.count) times=\(hits.map { String(format: "%.3f", $0.timestampSeconds) })")
        }


        // MARK: - Build 15: scrolling LUMA+MIC VU of the last 1–90 s (pair-independent + event marks)

        do {
            expect(abs(MeterHistory.defaultWindowSeconds - 90) < 1e-9, "VU default window is 90 s")
            expect(abs(MeterHistory.clampedWindow(0) - 1) < 1e-9, "VU window floor 1 s")
            expect(abs(MeterHistory.clampedWindow(90) - 90) < 1e-9, "VU window ceiling 90 s")
            expect(abs(MeterHistory.clampedWindow(91) - 90) < 1e-9, "VU window clamps above 90")
            expect(abs(MeterHistory.clampedWindow(0.5) - 1) < 1e-9, "VU window clamps below 1")
            expect(abs(MeterHistory.clampedWindow(MeterHistory.defaultWindowSeconds) - 90) < 1e-9, "default 90 is in 1-90")
        }

        do {
            let h = MeterHistory()
            for i in 0..<30 {
                h.appendLuma(t: Double(i), value: 0.05)
                h.appendMic(t: Double(i), value: 0.02)
            }
            h.appendLuma(t: 29.0, value: 0.98)
            h.appendLuma(t: 29.016, value: 0.90)
            h.appendMic(t: 29.05, value: 0.80)
            let n = 30
            let luma = h.lumaColumns(now: 30.0, windowSeconds: 30, count: n)
            let mic = h.micColumns(now: 30.0, windowSeconds: 30, count: n)
            expect(luma.count == n && mic.count == n, "VU columns match count")
            expect(luma[29] > 0.8, "1-frame luma flash peak-holds at the right (NOW)", String(format: "col29=%.3f", luma[29]))
            expect(luma[0] < 0.2 && luma[10] < 0.2, "dark floor stays low on the left", String(format: "col0=%.3f col10=%.3f", luma[0], luma[10]))
            expect(mic[29] > 0.5, "mic pulse peak-holds at the right (NOW)", String(format: "col29=%.3f", mic[29]))
            expect(mic[0] < 0.1, "mic floor stays low on the left", String(format: "col0=%.3f", mic[0]))
        }

        do {
            let h = MeterHistory()
            h.appendLuma(t: 0.0, value: 0.9)
            h.appendLuma(t: 100.0, value: 0.1)
            let cols = h.lumaColumns(now: 100.0, windowSeconds: 30, count: 30)
            expect(cols[0] < 0.2 && !cols.contains(where: { $0 > 0.5 }), "samples older than the window do not appear")
            expect(cols[29] > 0.05 && cols[29] < 0.2, "newest column is the live 0.1 sample", String(format: "col29=%.3f", cols[29]))
        }

        do {
            // Default 90 s window still shows a flash from ~90 s ago (spike-then-pair glance).
            let h = MeterHistory()
            h.appendLuma(t: 10.0, value: 0.95)
            h.appendMic(t: 10.08, value: 0.85)
            h.appendLuma(t: 100.0, value: 0.08)
            h.appendMic(t: 100.0, value: 0.02)
            let luma90 = h.lumaColumns(now: 100.0, windowSeconds: 90, count: 90)
            let mic90 = h.micColumns(now: 100.0, windowSeconds: 90, count: 90)
            expect(luma90[0] > 0.8, "90 s window keeps a luma flash from 90 s ago at the left", String(format: "col0=%.3f", luma90[0]))
            expect(mic90[0] > 0.5, "90 s window keeps a mic spike from 90 s ago at the left", String(format: "col0=%.3f", mic90[0]))
            expect(luma90[89] < 0.2 && mic90[89] < 0.1, "NOW column is the live floor, not the old spike")
            let luma30 = h.lumaColumns(now: 100.0, windowSeconds: 30, count: 30)
            expect(!luma30.contains(where: { $0 > 0.5 }), "30 s window drops the 90 s old flash")
        }

        do {
            let h = MeterHistory()
            h.appendLuma(t: 1, value: 0.8)
            h.appendMic(t: 1, value: 0.7)
            h.reset()
            expect(h.lumaCount == 0 && h.micCount == 0 && h.lastTimestamp == 0, "RESET clears VU history")
        }

        do {
            // Independent traces: a luma flash must not invent a mic pulse.
            let h = MeterHistory()
            h.appendLuma(t: 5.0, value: 0.95)
            h.appendMic(t: 5.0, value: 0.02)
            let luma = h.lumaColumns(now: 6.0, windowSeconds: 6, count: 6)
            let mic = h.micColumns(now: 6.0, windowSeconds: 6, count: 6)
            expect(luma[5] > 0.8, "luma trace shows the flash", String(format: "luma5=%.3f", luma[5]))
            expect(mic[5] < 0.1, "mic trace stays independent of luma", String(format: "mic5=%.3f", mic[5]))
        }

        do {
            // Pair-independent: live luma/mic fill the strip with ZERO pairs.
            let h = MeterHistory()
            let e = engine()
            for i in 0..<20 {
                let t = Double(i) * 0.05
                h.appendLuma(t: t, value: i == 10 ? 0.95 : 0.08)
                h.appendMic(t: t, value: i == 12 ? 0.90 : 0.03)
            }
            expect(e.snapshot().validCount == 0, "engine has zero pairs")
            expect(h.markCount == 0, "no PAIR/FLASH/AUDIOPULSE marks appended")
            let luma = h.lumaColumns(now: 1.0, windowSeconds: 1, count: 20)
            let mic = h.micColumns(now: 1.0, windowSeconds: 1, count: 20)
            expect(luma.contains(where: { $0 > 0.8 }), "luma strip records a flash-level sample with zero pairs")
            expect(mic.contains(where: { $0 > 0.8 }), "mic strip records a beep-level sample with zero pairs")
            expect(h.marks(now: 1.0, windowSeconds: 90).isEmpty, "marks stay empty when only live levels are recorded")
        }

        do {
            // FLASH + AUDIOPULSE can exist without PAIR (full-green beep that did not pair).
            let h = MeterHistory()
            h.appendLuma(t: 10.0, value: 0.95)
            h.appendMic(t: 10.08, value: 0.85)
            h.appendMark(t: 10.0, kind: .flash)
            h.appendMark(t: 10.08, kind: .audioPulse)
            let ms = h.marks(now: 11.0, windowSeconds: 90)
            expect(ms.contains(where: { $0.kind == .flash }), "FLASH mark without pair")
            expect(ms.contains(where: { $0.kind == .audioPulse }), "AUDIOPULSE mark without pair")
            expect(!ms.contains(where: { $0.kind == .pair }), "no PAIR mark when unpaired")
            let kinds = h.markKindsByColumn(now: 11.0, windowSeconds: 2, count: 20).flatMap { $0 }
            expect(kinds.contains(.flash) && kinds.contains(.audioPulse) && !kinds.contains(.pair), "column overlay has FLASH+AUDIOPULSE, no PAIR")
            expect(abs(MeterHistory.defaultWindowSeconds - 90) < 1e-9, "90 s default asserted with unpaired marks")
        }

        do {
            // A PAIR mark only appears when paired.
            let h = MeterHistory()
            h.appendLuma(t: 5.0, value: 0.92)
            h.appendMic(t: 5.08, value: 0.80)
            h.appendMark(t: 5.0, kind: .flash)
            h.appendMark(t: 5.08, kind: .audioPulse)
            expect(!h.marks(now: 6, windowSeconds: 5).contains(where: { $0.kind == .pair }), "still no PAIR before pairing")
            h.appendMark(t: 5.08, kind: .pair)
            let ms = h.marks(now: 6, windowSeconds: 5)
            expect(ms.contains(where: { $0.kind == .pair }), "PAIR mark only after paired")
            expect(ms.contains(where: { $0.kind == .flash }) && ms.contains(where: { $0.kind == .audioPulse }), "FLASH+AUDIOPULSE remain after pair")
            let cols = h.markKindsByColumn(now: 6, windowSeconds: 5, count: 5)
            expect(cols.flatMap { $0 }.contains(.pair), "PAIR paints a column")
        }

        do {
            let h = MeterHistory()
            h.appendLuma(t: 1, value: 0.8)
            h.appendMic(t: 1, value: 0.7)
            h.appendMark(t: 1, kind: .flash)
            h.appendMark(t: 1.02, kind: .audioPulse)
            h.appendMark(t: 1.02, kind: .pair)
            h.reset()
            expect(h.lumaCount == 0 && h.micCount == 0 && h.markCount == 0 && h.lastTimestamp == 0, "RESET clears VU samples and marks")
        }

        // MARK: - Build 16: 1 Hz FLASH + delayed AUDIOPULSE must PAIR (keep-latest was the bug)

        do {
            // Live 60 fps measure queue: next 1 Hz flash is ingested before the
            // beep-like pulse whose onset is still inside ±400 ms of the previous
            // flash. Keep-latest of one pending flash dropped that match → MEAS 0
            // with FLASH+AUDIOPULSE marks and REJECTEDEXTRAFLASH every ~1 s.
            let e = SyncMeasurementEngine()
            var paired = 0
            for i in 0..<8 {
                let t = Double(i)
                _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: t, luminance: 0.58, threshold: 0.124))
                if i > 0 {
                    if e.ingestPulse(.beepLike(timestampSeconds: Double(i - 1) + 0.080)) != nil {
                        paired += 1
                    }
                }
            }
            if e.ingestPulse(.beepLike(timestampSeconds: 7.080)) != nil { paired += 1 }
            let snap = e.snapshot()
            expect(snap.validCount == 8, "1 Hz FLASH + delayed 1 Hz AUDIOPULSE within ±400 ms must PAIR (not zero pairs)", "valid=\(snap.validCount) paired=\(paired) rejected=\(snap.rejectedCount)")
            expect(abs(snap.medianMilliseconds - 80) < 1.0, "delayed-pulse pairs stay ~+80 ms", String(format: "med %.3f", snap.medianMilliseconds))
            let kinds = Set(e.diagnostics.map(\.kind))
            expect(kinds.contains(.flash) && kinds.contains(.audioPulse) && kinds.contains(.paired), "FLASH+AUDIOPULSE ingest produces PAIR diagnostics", "\(kinds)")
            expect(!kinds.contains(.clockSettling), "this case is pairing, not clock hold")
        }

        do {
            // Same 1 Hz train ingested in timestamp order still pairs (no lag).
            let e = SyncMeasurementEngine()
            for i in 0..<8 {
                let t = Double(i)
                _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: t, luminance: 0.58, threshold: 0.124))
                _ = e.ingestPulse(.beepLike(timestampSeconds: t + 0.080))
            }
            expect(e.snapshot().validCount == 8, "in-order 1 Hz FLASH+PULSE still pairs", "n=\(e.snapshot().validCount)")
            expect(abs(e.snapshot().medianMilliseconds - 80) < 0.5, "in-order pairs stay +80 ms")
        }

        do {
            expect(MeterHistory.displayMicLevel(0.02) > 0.25, "display MIC at env 0.02 is not a sliver", String(format: "%.3f", MeterHistory.displayMicLevel(0.02)))
            expect(MeterHistory.displayMicLevel(0.02) < 1, "display MIC at env 0.02 is not pegged")
            expect(abs(MeterHistory.displayMicLevel(0.001) - 0.016) < 1e-9, "display MIC *16 does not change detector math")
            expect(MeterHistory.displayMicLevel(0.20) == 1, "display MIC clamps at 1")
        }

        // MARK: - Build 17: isolated 1 Hz must PAIR; EVT=ingest; unified VU domain

        do {
            // 1 Hz flash + pulse +80 ms MUST PAIR even if smear/isBeepLike was
            // false under the old gate (dull, 70 ms PA smear).
            let e = SyncMeasurementEngine()
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.0, luminance: 0.8, threshold: 0.1))
            let smeared = AudioPulseEvent(
                timestampSeconds: 1.080,
                envelope: 0.22,
                threshold: 0.05,
                durationSeconds: 0.070,
                sharpness: 0.22,
                isBeepLike: false
            )
            expect(smeared.isPairable, "isolated 70 ms 1 Hz smear is pairable even if old isBeepLike was false")
            let s = e.ingestPulse(smeared)
            expect(s != nil && abs(s!.offsetMilliseconds - 80) < 0.5, "1 Hz flash + smeared pulse +80 must PAIR even if old isBeepLike gate was false", s.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
            expect(e.diagnostics.contains(where: { $0.kind == .audioPulse }), "EVT/ingest: AUDIOPULSE diagnostic is engine ingest")
            expect(e.diagnostics.contains(where: { $0.kind == .paired }), "EVT/ingest: PAIR diagnostic matches ingest")
        }

        do {
            // Isolated 1 Hz pulse next to a flash pairs (in-order and delayed).
            let e = SyncMeasurementEngine()
            var paired = 0
            for i in 0..<6 {
                let t = Double(i)
                _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: t, luminance: 0.58, threshold: 0.124))
                if i > 0 {
                    let pulse = AudioPulseEvent(
                        timestampSeconds: Double(i - 1) + 0.080,
                        envelope: 0.30,
                        threshold: 0.05,
                        durationSeconds: 0.055,
                        sharpness: 0.20,
                        isBeepLike: false
                    )
                    if e.ingestPulse(pulse) != nil { paired += 1 }
                }
            }
            if e.ingestPulse(AudioPulseEvent(
                timestampSeconds: 5.080,
                envelope: 0.30,
                threshold: 0.05,
                durationSeconds: 0.055,
                sharpness: 0.20,
                isBeepLike: false
            )) != nil { paired += 1 }
            expect(e.snapshot().validCount == 6, "isolated 1 Hz pulse next to FLASH pairs (delayed ingest)", "valid=\(e.snapshot().validCount) paired=\(paired)")
            expect(abs(e.snapshot().medianMilliseconds - 80) < 1.0, "isolated 1 Hz pairs stay ~+80 ms")
        }

        do {
            // Overlapping/ongoing speech still rejected (duration > 85 ms, !isBeepLike).
            let e = SyncMeasurementEngine()
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.0, luminance: 0.8, threshold: 0.1))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: 1.050))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: 1.150))
            let s = e.ingestPulse(.beepLike(timestampSeconds: 1.080, envelope: 0.85))
            expect(s != nil && abs(s!.offsetMilliseconds - 80) < 0.5, "overlapping speech still rejected; pair is the +80 ms beep", s.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
            expect(e.snapshot().validCount == 1, "speech does not create extra pairs", "n=\(e.snapshot().validCount)")
            expect(!AudioPulseEvent.voiceLike(timestampSeconds: 0).isPairable, "ongoing speech duration is not pairable")
        }

        do {
            // Detector: isolated 1 Hz that would fail the old sharp/short gate still onsets.
            let d = AudioPulseDetector()
            let rate = 48_000.0
            func feed(from t0: Double, until t1: Double, paint: (Double) -> Float) -> [AudioPulseEvent] {
                var hits: [AudioPulseEvent] = []
                var t = t0
                let buf = 1024
                while t < t1 {
                    var samples = [Float](repeating: 0, count: buf)
                    for i in 0..<buf { samples[i] = paint(t + Double(i) / rate) }
                    if let ev = d.processMonoSamples(samples, bufferStartSeconds: t, sampleRate: rate) {
                        hits.append(ev)
                    }
                    t += Double(buf) / rate
                }
                return hits
            }
            func smear(_ t: Double, start: Double, dur: Double, amp: Float) -> Float {
                guard t >= start && t < start + dur else { return 0 }
                let local = t - start
                let fade = min(0.008, dur / 4)
                let env: Float
                if local < fade { env = Float(local / fade) }
                else if local > dur - fade { env = Float(max(0, (dur - local) / fade)) }
                else { env = 1 }
                return env * amp * Float(sin(2 * Double.pi * 1_000 * t))
            }
            _ = feed(from: 0.0, until: 0.8, paint: { _ in 0.001 })
            let hits = feed(from: 0.8, until: 2.6, paint: { t in
                0.001 + smear(t, start: 1.0, dur: 0.070, amp: 0.045) + smear(t, start: 2.0, dur: 0.070, amp: 0.045)
            })
            expect(hits.count == 2, "isolated 1 Hz 70 ms smear still onsets (not dropped as speech)", "n=\(hits.count) times=\(hits.map { String(format: "%.3f beep=%d", $0.timestampSeconds, $0.isBeepLike ? 1 : 0) })")
            if hits.count >= 1 {
                expect(hits[0].isBeepLike && hits[0].isPairable, "isolated 1 Hz detector emit is beep-like / pairable")
            }
            let e = SyncMeasurementEngine()
            if hits.count >= 2 {
                _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.0, luminance: 0.8, threshold: 0.1))
                let a = e.ingestPulse(hits[0])
                _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 2.0, luminance: 0.8, threshold: 0.1))
                let b = e.ingestPulse(hits[1])
                expect(a != nil && abs((a?.offsetMilliseconds ?? 999)) < 20, "isolated 1 Hz detector pulse pairs with FLASH", a.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
                expect(b != nil && abs((b?.offsetMilliseconds ?? 999)) < 20, "second isolated 1 Hz detector pulse pairs", b.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
            }
        }

        do {
            // VU-aligned wall times with different unified times must not pair.
            // Stamping the strip with wall-clock would put both in one column.
            let e = SyncMeasurementEngine()
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 10.0, luminance: 0.95, threshold: 0.1))
            let s = e.ingestPulse(.beepLike(timestampSeconds: 12.0, envelope: 0.80))
            expect(s == nil, "unified 2 s apart must not PAIR (would look aligned on a wall-clock VU)")
            expect(e.snapshot().validCount == 0, "wall-aligned / unified-mismatched events stay unpaired")

            let h = MeterHistory()
            h.appendLuma(t: 10.0, value: 0.95)
            h.appendMic(t: 12.0, value: 0.80)
            h.appendMark(t: 10.0, kind: .flash)
            h.appendMark(t: 12.0, kind: .audioPulse)
            let kinds = h.markKindsByColumn(now: 12.0, windowSeconds: 90, count: 90)
            let flashCols = kinds.enumerated().compactMap { $0.element.contains(.flash) ? $0.offset : nil }
            let pulseCols = kinds.enumerated().compactMap { $0.element.contains(.audioPulse) ? $0.offset : nil }
            expect(!flashCols.isEmpty && !pulseCols.isEmpty, "unified-domain strip still shows FLASH and AUDIOPULSE")
            if let fc = flashCols.first, let pc = pulseCols.first {
                expect(abs(fc - pc) >= 1, "unified 2 s apart occupy different VU columns (not wall-clock collapsed)", "flashCol=\(fc) pulseCol=\(pc)")
            }

            // Same unified domain, +80 ms: pairs AND sits on nearby columns.
            let e2 = SyncMeasurementEngine()
            _ = e2.ingestFlash(VisualFlashEvent(timestampSeconds: 10.0, luminance: 0.95, threshold: 0.1))
            let s2 = e2.ingestPulse(.beepLike(timestampSeconds: 10.080, envelope: 0.80))
            expect(s2 != nil && abs(s2!.offsetMilliseconds - 80) < 0.5, "same unified domain +80 ms pairs")
            let h2 = MeterHistory()
            h2.appendLuma(t: 10.0, value: 0.95)
            h2.appendMic(t: 10.080, value: 0.80)
            h2.appendMark(t: 10.0, kind: .flash)
            h2.appendMark(t: 10.080, kind: .audioPulse)
            h2.appendMark(t: 10.080, kind: .pair)
            let k2 = h2.markKindsByColumn(now: 11.0, windowSeconds: 5, count: 50).flatMap { $0 }
            expect(k2.contains(.flash) && k2.contains(.audioPulse) && k2.contains(.pair), "EVT marks on unified time match ingest FLASH+AUDIOPULSE+PAIR")
        }

        do {
            // Old isBeepLike duration gate (≤85 ms) would be false for a 250 ms
            // periodic tone. Isolated 1 Hz +80 ms must still PAIR on onset.
            let e = SyncMeasurementEngine()
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.0, luminance: 0.8, threshold: 0.1))
            let longTone = AudioPulseEvent(
                timestampSeconds: 1.080,
                envelope: 0.55,
                threshold: 0.05,
                durationSeconds: 0.250,
                sharpness: 0.85,
                isBeepLike: false
            )
            expect(longTone.isPairable, "250 ms periodic tone is pairable even if old isBeepLike was false")
            let s = e.ingestPulse(longTone)
            expect(s != nil && abs(s!.offsetMilliseconds - 80) < 0.5, "1 Hz flash + 250 ms tone +80 PAIR even if old isBeepLike was false", s.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
        }

        func feedTone(_ d: AudioPulseDetector, from t0: Double, until t1: Double, rate: Double = 48_000, buf: Int = 1024, paint: (Double) -> Float) -> [AudioPulseEvent] {
            var hits: [AudioPulseEvent] = []
            var t = t0
            while t < t1 {
                var samples = [Float](repeating: 0, count: buf)
                for i in 0..<buf { samples[i] = paint(t + Double(i) / rate) }
                if let ev = d.processMonoSamples(samples, bufferStartSeconds: t, sampleRate: rate) {
                    hits.append(ev)
                }
                t += Double(buf) / rate
            }
            return hits
        }
        func hzTone(_ t: Double, start: Double, dur: Double, amp: Float, f: Double = 1_000) -> Float {
            guard t >= start && t < start + dur else { return 0 }
            let local = t - start
            let fade = min(0.004, dur / 8)
            let env: Float
            if local < fade { env = Float(local / fade) }
            else if local > dur - fade { env = Float(max(0, (dur - local) / fade)) }
            else { env = 1 }
            return env * amp * Float(sin(2 * Double.pi * f * t))
        }

        // MARK: - CANONICAL Harkwood Standard (measured, not a 1.000 Hz click)
        //
        // External file Guy plays (never bundled):
        //   Sync-One2_Test_1080p_29.97_H.264_PCM_Stereo.mov
        //   1920x1080, 30000/1001, pcm_s16le 48 kHz stereo
        // Flash: exactly 2 frames, every 30 frames = 1001.000 ms (0.9990 Hz), NOT 1.000 Hz
        // Beep: 3000 Hz burst, mean 66.678 ms (2 frames), not a 10–20 ms click
        // File A/V offset 0.000 ms (onset aligned to flash frame start)
        // First event t=11.011 s (300 title frames = 10.010 s + 30 black = 1.001 s)
        // Pairing must not treat the cadence as 1.000 Hz (that walks ~1 ms/beep).
        // Speech stays overlapping/ongoing — a periodic 66.7 ms 3 kHz tone is not speech.

        let harkwoodPeriod = 30.0 * 1_001.0 / 30_000.0
        let harkwoodT0 = 11.011
        let harkwoodBeepDur = 0.066_678
        let harkwoodBeepHz = 3_000.0
        let harkwoodN = 12

        func harkwoodPulse(t: Double, isBeepLike: Bool = false) -> AudioPulseEvent {
            AudioPulseEvent(
                timestampSeconds: t,
                envelope: 0.55,
                threshold: 0.05,
                durationSeconds: harkwoodBeepDur,
                sharpness: 0.85,
                isBeepLike: isBeepLike
            )
        }

        do {
            expect(abs(harkwoodPeriod - 1.001) < 1e-12, "CANONICAL period is 1001.000 ms, not 1.000 s")
            expect(abs(harkwoodPeriod * 1_000.0 - 1_001.0) < 1e-9, "CANONICAL period * 1000 is 1001.000 ms")
            let title = 300.0 * 1_001.0 / 30_000.0
            let black = 30.0 * 1_001.0 / 30_000.0
            expect(abs(title - 10.010) < 1e-12, "300 title frames at 30000/1001 = 10.010 s")
            expect(abs(black - 1.001) < 1e-12, "30 black frames at 30000/1001 = 1.001 s")
            expect(abs((title + black) - harkwoodT0) < 1e-12, "first event t=11.011 s (10.010 title + 1.001 black)")
            expect(abs(1.0 / harkwoodPeriod - 0.999_000_999) < 1e-9, "CANONICAL cadence is 0.9990 Hz, not 1.000 Hz")
            let twoFrames = 2.0 * 1_001.0 / 30_000.0
            expect(abs(twoFrames * 1_000.0 - 66.733_3) < 0.01, "2 frames at 29.97 is ~66.7 ms")
            expect(abs(harkwoodBeepDur * 1_000.0 - 66.678) < 1e-9, "measured beep mean is 66.678 ms, not a 10–20 ms click")
        }

        do {
            // 1001 ms flash + 66.7 ms 3 kHz, pulse onset +0 ms, MUST PAIR.
            let e = SyncMeasurementEngine()
            let pulse = harkwoodPulse(t: harkwoodT0)
            expect(pulse.isPairable, "66.7 ms 3 kHz is pairable without a 10–20 ms click")
            expect(abs(pulse.durationSeconds - harkwoodBeepDur) < 1e-12, "CANONICAL pulse duration is 66.678 ms")
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: harkwoodT0, luminance: 0.90, threshold: 0.1))
            let s = e.ingestPulse(pulse)
            expect(s != nil && abs(s!.offsetMilliseconds) < 0.5, "CANONICAL +0 ms MUST PAIR (file A/V offset 0.000 ms)", s.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
            expect(abs((s?.videoTimestampSeconds ?? -1) - harkwoodT0) < 1e-12, "CANONICAL first pair video is t=11.011 s", s.map { String(format: "%.6f", $0.videoTimestampSeconds) } ?? "nil")
            expect(abs((s?.audioTimestampSeconds ?? -1) - harkwoodT0) < 1e-12, "CANONICAL first pair audio onset is t=11.011 s")
        }

        do {
            // 1001 ms flash + 66.7 ms 3 kHz, pulse onset +80 ms, MUST PAIR.
            let e = SyncMeasurementEngine()
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: harkwoodT0, luminance: 0.90, threshold: 0.1))
            let s = e.ingestPulse(harkwoodPulse(t: harkwoodT0 + 0.080))
            expect(s != nil && abs(s!.offsetMilliseconds - 80) < 0.5, "CANONICAL +80 ms MUST PAIR", s.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
        }

        do {
            // Cadence 1001 ms × N stays flat. Treating it as 1.000 Hz walks ~1 ms/beep.
            let e = SyncMeasurementEngine()
            var fake1Hz: [Double] = []
            for i in 0..<harkwoodN {
                let t = harkwoodT0 + Double(i) * harkwoodPeriod
                _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: t, luminance: 0.90, threshold: 0.1))
                _ = e.ingestPulse(harkwoodPulse(t: t))
                let pulseIf1Hz = harkwoodT0 + Double(i) * 1.0
                fake1Hz.append((pulseIf1Hz - t) * 1_000.0)
            }
            let snap = e.snapshot()
            expect(snap.validCount == harkwoodN, "CANONICAL 1001 ms × N all PAIR at +0 ms", "valid=\(snap.validCount)")
            expect(abs(snap.medianMilliseconds) < 0.5, "CANONICAL +0 cadence median stays 0.000 ms", String(format: "med %.3f", snap.medianMilliseconds))
            expect(abs(snap.walkMsPerEvent ?? 999) < 0.2, "CANONICAL 1001 ms × N stays flat (no 1 ms/beep walk)", snap.walkMsPerEvent.map { String(format: "%.4f", $0) } ?? "nil")
            let fakeWalk = MeasurementStatistics.walkMsPerEvent(fake1Hz) ?? 0
            expect(abs(fakeWalk + 1.0) < 0.05, "treating Harkwood as 1.000 Hz would walk −1 ms/beep", String(format: "fakeWalk %.4f", fakeWalk))
            let first = snap.recentValidSamples.last
            expect(abs((first?.videoTimestampSeconds ?? -1) - harkwoodT0) < 1e-12, "CANONICAL first event of the train is 11.011 s")
        }

        do {
            let e = SyncMeasurementEngine()
            for i in 0..<harkwoodN {
                let t = harkwoodT0 + Double(i) * harkwoodPeriod
                _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: t, luminance: 0.90, threshold: 0.1))
                _ = e.ingestPulse(harkwoodPulse(t: t + 0.080))
            }
            let snap = e.snapshot()
            expect(snap.validCount == harkwoodN, "CANONICAL 1001 ms × N all PAIR at +80 ms", "valid=\(snap.validCount)")
            expect(abs(snap.medianMilliseconds - 80) < 0.5, "CANONICAL +80 cadence median stays +80 ms")
            expect(abs(snap.walkMsPerEvent ?? 999) < 0.2, "CANONICAL +80 ms at 1001 ms × N stays flat", snap.walkMsPerEvent.map { String(format: "%.4f", $0) } ?? "nil")
        }

        do {
            // Detector: 66.7 ms 3 kHz (not a 10–20 ms click), first event 11.011, +0 and +80 MUST PAIR.
            func paintBeeps(_ t: Double, offset: Double) -> Float {
                var x: Float = 0.001
                for i in 0..<harkwoodN {
                    let start = harkwoodT0 + Double(i) * harkwoodPeriod + offset
                    x += hzTone(t, start: start, dur: harkwoodBeepDur, amp: 0.55, f: harkwoodBeepHz)
                }
                return x
            }
            let until = harkwoodT0 + Double(harkwoodN) * harkwoodPeriod + 0.25

            for offset in [0.0, 0.080] {
                let d = AudioPulseDetector()
                _ = feedTone(d, from: 10.0, until: harkwoodT0 - 0.05, paint: { _ in 0.001 })
                let hits = feedTone(d, from: harkwoodT0 - 0.05, until: until, paint: { paintBeeps($0, offset: offset) })
                let label = offset == 0 ? "+0" : "+80"
                expect(hits.count == harkwoodN, "CANONICAL detector 66.7 ms 3 kHz \(label) onsets \(harkwoodN)× (not dropped as speech / not a click)", "n=\(hits.count) times=\(hits.map { String(format: "%.3f", $0.timestampSeconds) })")
                if let first = hits.first {
                    expect(abs(first.timestampSeconds - (harkwoodT0 + offset)) < 0.015, "CANONICAL detector first onset is 11.011\(label == "+80" ? "+80 ms" : " s")", String(format: "%.4f", first.timestampSeconds))
                    expect(first.isPairable, "CANONICAL 66.7 ms 3 kHz detector emit is pairable (not a 10–20 ms click)")
                }
                let e = SyncMeasurementEngine()
                var paired = 0
                for i in 0..<min(hits.count, harkwoodN) {
                    let tFlash = harkwoodT0 + Double(i) * harkwoodPeriod
                    _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: tFlash, luminance: 0.90, threshold: 0.1))
                    if e.ingestPulse(hits[i]) != nil { paired += 1 }
                }
                expect(paired == harkwoodN && e.snapshot().validCount == harkwoodN, "CANONICAL 1001 ms flash + 66.7 ms 3 kHz \(label) MUST PAIR", "paired=\(paired) valid=\(e.snapshot().validCount)")
                let want = offset * 1_000.0
                expect(abs(e.snapshot().medianMilliseconds - want) < 15, "CANONICAL detector \(label) median near \(Int(want)) ms", String(format: "med %.2f", e.snapshot().medianMilliseconds))
                expect(abs(e.snapshot().walkMsPerEvent ?? 999) < 0.2, "CANONICAL detector 1001 ms × N \(label) stays flat", e.snapshot().walkMsPerEvent.map { String(format: "%.4f", $0) } ?? "nil")
            }
        }

        do {
            // 2-frame white every 30 frames at 30000/1001, first event 11.011.
            // Sample on the file's frame grid (n * 1001/30000), not wall 10.000 s.
            let d = VideoFlashDetector()
            let frameDt = 1_001.0 / 30_000.0
            let firstFlashFrame = 330 // 300 title + 30 black → t=11.011
            let lastFlashFrame = firstFlashFrame + (harkwoodN - 1) * 30
            var times: [Double] = []
            for frame in (firstFlashFrame - 60)...(lastFlashFrame + 8) {
                let t = Double(frame) * frameDt
                let luma: Double
                if frame < firstFlashFrame {
                    luma = 0.05
                } else {
                    luma = ((frame - firstFlashFrame) % 30) < 2 ? 0.90 : 0.05
                }
                if let ev = d.processLuminance(luma, timestampSeconds: t) {
                    times.append(ev.timestampSeconds)
                }
            }
            expect(times.count == harkwoodN, "CANONICAL 2-frame flash every 30 frames at 29.97 is \(harkwoodN) events (1001 ms, not 1.000 Hz)", "n=\(times.count) times=\(times.prefix(4).map { String(format: "%.4f", $0) })")
            if times.count == harkwoodN {
                expect(abs(times[0] - harkwoodT0) < 1e-9, "CANONICAL first flash is t=11.011 s", String(format: "%.6f", times[0]))
                for i in 0..<harkwoodN {
                    let want = harkwoodT0 + Double(i) * harkwoodPeriod
                    expect(abs(times[i] - want) < 1e-9, "CANONICAL flash \(i) on 1001 ms cadence", String(format: "got %.6f want %.6f", times[i], want))
                }
            }
        }

        func runFlashShapes(_ shapes: [[Double]], fps: Double, t0: Double, period: Double) -> [Double] {
            let d = VideoFlashDetector()
            var times: [Double] = []
            let dt = 1.0 / fps
            var t = t0 - 0.55
            while t < t0 - 0.001 {
                _ = d.processLuminance(0.05, timestampSeconds: t)
                t += dt
            }
            for (k, shape) in shapes.enumerated() {
                let start = t0 + Double(k) * period
                while t < start - 1e-9 {
                    _ = d.processLuminance(0.05, timestampSeconds: t)
                    t += dt
                }
                t = start
                for luma in shape {
                    if let ev = d.processLuminance(luma, timestampSeconds: t) {
                        times.append(ev.timestampSeconds)
                    }
                    t += dt
                }
                let hold = start + 0.45
                while t < hold {
                    _ = d.processLuminance(0.05, timestampSeconds: t)
                    t += dt
                }
            }
            return times
        }

        // MARK: - 2-frame first vs last edge (must not SPAN −50/+11)
        //
        // Harkwood is 2 frames white + 66.7 ms 3 kHz at file A/V 0.000 ms.
        // Trigger may fire on the second/last white frame when the first is a
        // dim partial. Stamping that last edge on some hits and the first on
        // others splits a +0 file into clusters ~33–67 ms apart (Guy Mac-smoke
        // SPAN 60.8, −50/+11). Stamp the FIRST rising frame consistently.

        do {
            // 29.97 grid: full first vs dim first + full second. Same first-edge stamp.
            let n = 8
            let full = Array(repeating: [0.90, 0.90], count: n)
            let dim = Array(repeating: [0.22, 0.90], count: n)
            let fps = 30_000.0 / 1_001.0
            let fullT = runFlashShapes(full, fps: fps, t0: harkwoodT0, period: harkwoodPeriod)
            let dimT = runFlashShapes(dim, fps: fps, t0: harkwoodT0, period: harkwoodPeriod)
            expect(fullT.count == n && dimT.count == n, "2-frame full and dim-first each fire \(n)×", "full=\(fullT.count) dim=\(dimT.count)")
            if fullT.count == n && dimT.count == n {
                for i in 0..<n {
                    let want = harkwoodT0 + Double(i) * harkwoodPeriod
                    expect(abs(fullT[i] - want) < 1e-6, "2-frame full-white stamps FIRST frame", String(format: "i=%d got %.6f want %.6f", i, fullT[i], want))
                    expect(abs(dimT[i] - want) < 1e-6, "2-frame dim-first stamps FIRST frame not second (+33 ms)", String(format: "i=%d got %.6f want %.6f delta %.1f ms", i, dimT[i], want, (dimT[i] - want) * 1000))
                    expect(abs(dimT[i] - fullT[i]) < 1e-6, "dim-first and full-white share one edge", String(format: "i=%d dim %.6f full %.6f", i, dimT[i], fullT[i]))
                }
            }
        }

        do {
            // 60 fps smear of a 66.7 ms 2-frame pulse: first camera frames can be dim.
            let n = 8
            let smear = Array(repeating: [0.18, 0.45, 0.90, 0.40], count: n)
            let stamps = runFlashShapes(smear, fps: 60.0, t0: harkwoodT0, period: harkwoodPeriod)
            expect(stamps.count == n, "2-frame 60 fps smear fires \(n)×", "n=\(stamps.count)")
            if stamps.count == n {
                for i in 0..<n {
                    let start = harkwoodT0 + Double(i) * harkwoodPeriod
                    let deltaMs = (stamps[i] - start) * 1000
                    expect(abs(deltaMs) < 20, "2-frame smear stamps FIRST camera frame not peak/last (~33–67 ms)", String(format: "i=%d delta %+.1f ms stamp %.4f start %.4f", i, deltaMs, stamps[i], start))
                }
            }
        }

        do {
            // Gradual rise that only becomes flashLike on the last white frame.
            let n = 8
            let late = Array(repeating: [0.10, 0.16, 0.25, 0.92], count: n)
            let stamps = runFlashShapes(late, fps: 60.0, t0: harkwoodT0, period: harkwoodPeriod)
            expect(stamps.count == n, "2-frame last-peak still fires \(n)×", "n=\(stamps.count)")
            if stamps.count == n {
                for i in 0..<n {
                    let start = harkwoodT0 + Double(i) * harkwoodPeriod
                    let deltaMs = (stamps[i] - start) * 1000
                    expect(deltaMs < 20 && deltaMs > -5, "2-frame last-peak stamps FIRST edge not last (~50 ms)", String(format: "i=%d delta %+.1f ms", i, deltaMs))
                }
            }
        }

        do {
            // Mixed first vs last shapes + 66.7 ms 3 kHz at +0 must be ONE cluster.
            // Guy Mac-smoke: MEAS 24, SPAN 60.8, clusters −50/+11. That split is
            // first vs last edge, not 1001 ms wrong-neighbor.
            let n = 24
            var shapes: [[Double]] = []
            for k in 0..<n {
                switch k % 4 {
                case 0: shapes.append([0.90, 0.90, 0.90, 0.90])
                case 1: shapes.append([0.22, 0.90, 0.90, 0.40])
                case 2: shapes.append([0.18, 0.45, 0.90, 0.40])
                default: shapes.append([0.10, 0.16, 0.25, 0.92])
                }
            }
            let stamps = runFlashShapes(shapes, fps: 60.0, t0: harkwoodT0, period: harkwoodPeriod)
            expect(stamps.count == n, "mixed 2-frame first/last fires \(n)×", "n=\(stamps.count)")
            let e = SyncMeasurementEngine()
            var offsets: [Double] = []
            for i in 0..<min(stamps.count, n) {
                let start = harkwoodT0 + Double(i) * harkwoodPeriod
                _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: stamps[i], luminance: 0.90, threshold: 0.1))
                if let s = e.ingestPulse(harkwoodPulse(t: start)) {
                    offsets.append(s.offsetMilliseconds)
                }
            }
            let snap = e.snapshot()
            expect(snap.validCount == n, "mixed 2-frame + 66.7 ms 3 kHz at +0 all PAIR", "valid=\(snap.validCount)")
            expect(abs(snap.medianMilliseconds) < 15, "mixed 2-frame +0 median near 0 (file A/V 0.000 ms)", String(format: "med %.2f", snap.medianMilliseconds))
            expect(snap.spanMilliseconds < 20, "mixed 2-frame first vs last is one cluster (not SPAN 50+ / −50/+11)", String(format: "span %.2f min %.2f max %.2f offs %@", snap.spanMilliseconds, snap.minMilliseconds, snap.maxMilliseconds, offsets.map { String(format: "%+.1f", $0) }.joined(separator: " ")))
            expect(abs(snap.walkMsPerEvent ?? 999) < 0.2, "mixed 2-frame +0 stays flat", snap.walkMsPerEvent.map { String(format: "%.4f", $0) } ?? "nil")
            let late50 = offsets.filter { $0 < -40 }.count
            let early11 = offsets.filter { $0 > 5 }.count
            expect(!(late50 >= 3 && early11 >= 3), "must not split into −50 LATE and +11 EARLY clusters", "late50=\(late50) early11=\(early11) offs=\(offsets.map { String(format: "%+.1f", $0) })")
        }

        do {
            // Speech is overlapping/ongoing. A periodic 66.7 ms 3 kHz tone is not speech.
            expect(harkwoodPulse(t: harkwoodT0).isPairable, "periodic 66.7 ms 3 kHz is not speech")
            expect(!AudioPulseEvent.voiceLike(timestampSeconds: harkwoodT0).isPairable, "overlapping/ongoing speech is still not pairable")
            let e = SyncMeasurementEngine()
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: harkwoodT0, luminance: 0.90, threshold: 0.1))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: harkwoodT0 + 0.050))
            _ = e.ingestPulse(.voiceLike(timestampSeconds: harkwoodT0 + 0.150))
            let s = e.ingestPulse(harkwoodPulse(t: harkwoodT0 + 0.080, isBeepLike: true))
            expect(s != nil && abs(s!.offsetMilliseconds - 80) < 0.5, "speech stays rejected; CANONICAL pair is the 66.7 ms 3 kHz +80", s.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
            expect(e.snapshot().validCount == 1, "overlapping speech does not create extra pairs", "n=\(e.snapshot().validCount)")
        }

        do {
            // Longer isolated 200–400 ms tone still PAIR on onset (not the Harkwood canonical).
            for dur in [0.200, 0.300, 0.400] {
                let d = AudioPulseDetector()
                _ = feedTone(d, from: 0.0, until: 0.8, paint: { _ in 0.001 })
                let hits = feedTone(d, from: 0.8, until: 1.9, paint: { t in
                    0.001 + hzTone(t, start: 1.080, dur: dur, amp: 0.60)
                })
                let ms = Int(dur * 1000)
                expect(hits.count == 1, "\(ms) ms isolated tone onsets once", "n=\(hits.count) times=\(hits.map { String(format: "%.3f", $0.timestampSeconds) })")
                if let onset = hits.first {
                    expect(abs(onset.timestampSeconds - 1.080) < 0.015, "\(ms) ms tone PAIR stamp is ONSET not mid/end", String(format: "onset %.4f (mid would be %.3f end %.3f)", onset.timestampSeconds, 1.080 + dur / 2, 1.080 + dur))
                    expect(onset.timestampSeconds < 1.080 + 0.050, "\(ms) ms tone must not stamp late in the tone", String(format: "%.4f", onset.timestampSeconds))
                    expect(onset.isBeepLike && onset.isPairable, "\(ms) ms isolated tone is pairable (not speech)")
                    let e = SyncMeasurementEngine()
                    _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.0, luminance: 0.8, threshold: 0.1))
                    let s = e.ingestPulse(onset)
                    expect(s != nil && abs((s?.offsetMilliseconds ?? 999) - 80) < 20, "isolated \(ms) ms tone +80 PAIR on onset", s.map { String(format: "%+.2f", $0.offsetMilliseconds) } ?? "nil")
                }
            }
        }


        if failed == 0 {
            print("ALL HARNESS TESTS PASSED")
        } else {
            print("FAILED: \(failed)")
            exit(1)
        }
    }
}
