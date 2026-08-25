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
            expect(FrameRate.captureFamily(observedFPS: 30_000.0 / 1_001.0) == "NTSC", "classify 29.97 as NTSC")
            expect(FrameRate.captureFamily(observedFPS: 30.0) == "integer", "classify 30.00 as integer")
            expect(FrameRate.captureFamily(observedFPS: 60_000.0 / 1_001.0) == "NTSC", "classify 59.94 as NTSC")
            expect(FrameRate.captureFamily(observedFPS: 60.0) == "integer", "classify 60.00 as integer")
        }


        if failed == 0 {
            print("ALL HARNESS TESTS PASSED")
        } else {
            print("FAILED: \(failed)")
            exit(1)
        }
    }
}
