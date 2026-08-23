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
            _ = pair(e, tVideo: 10.0, tAudio: 10.0 + 0.850)
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
            _ = pair(e, tVideo: 40.0, tAudio: 40.0 + 0.850)
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
            _ = pair(e, tVideo: 1, tAudio: 1.200)
            _ = pair(e, tVideo: 2, tAudio: 2.300)
            let snap = e.snapshot()
            expect(abs((snap.currentOffsetMilliseconds ?? 0) - 300) < 0.01, "last pair is 300")
            expect(abs(snap.medianMilliseconds - 200) < 0.01, "median of 100/200/300 is 200")
            expect(abs((snap.correctedMedianMilliseconds ?? 0) - 200) < 0.01, "headline uses median not last")
            e.configuration.calibrationOffsetMilliseconds = 10
            expect(abs((e.snapshot().correctedMedianMilliseconds ?? 0) - 190) < 0.01, "headline median minus cal")
        }

        if failed == 0 {
            print("ALL HARNESS TESTS PASSED")
        } else {
            print("FAILED: \(failed)")
            exit(1)
        }
    }
}
