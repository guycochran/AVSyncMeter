import XCTest
@testable import AVSyncMeter

final class WalkAndClockTests: XCTestCase {
    func testConstantOffsetsDoNotWalk() {
        for trueMs in [0.0, 50.0, -80.0] {
            let offsets = SyntheticRig.run(trueOffsetMs: trueMs, events: 36, agcDecayPerSecond: 0)
            XCTAssertGreaterThanOrEqual(offsets.count, 30, "\(trueMs) ms event count")
            let med = MeasurementStatistics.median(offsets)
            let walk = MeasurementStatistics.walkMsPerEvent(offsets) ?? 999
            XCTAssertEqual(med, trueMs, accuracy: 3, "\(trueMs) ms median \(med)")
            XCTAssertLessThan(abs(walk), 0.15, "\(trueMs) ms walk \(walk)")
        }
    }

    func testSyntheticAudioDelayMovesMedianByN() {
        let pre = SyntheticRig.run(trueOffsetMs: 0, events: 10, agcDecayPerSecond: 0)
        let post = SyntheticRig.run(trueOffsetMs: 164, events: 30, agcDecayPerSecond: 0)
        let medPre = MeasurementStatistics.median(pre)
        let medPost = MeasurementStatistics.median(post)
        XCTAssertEqual(medPre, 0, accuracy: 3)
        XCTAssertEqual(medPost, 164, accuracy: 3)
        XCTAssertEqual(medPost - medPre, 164, accuracy: 4)
    }

    func testAGCDoesNotWalkOnset() {
        let offsets = SyntheticRig.run(trueOffsetMs: 50, events: 36, agcDecayPerSecond: 0.03)
        let walk = MeasurementStatistics.walkMsPerEvent(offsets) ?? 999
        XCTAssertGreaterThanOrEqual(offsets.count, 20)
        XCTAssertLessThan(abs(walk), 0.25, "walk \(walk)")
        XCTAssertEqual(MeasurementStatistics.median(offsets), 50, accuracy: 5)
    }

    func testCaptureClockFlattensThousandPpmWalk() {
        var raw: [Double] = []
        for i in 0..<30 {
            let hostV = Double(i)
            let hostA = Double(i) + 0.011
            raw.append((hostA * 1.001 - hostV) * 1000)
        }
        let rawWalk = MeasurementStatistics.walkMsPerEvent(raw) ?? 0
        XCTAssertEqual(rawWalk, 1.0, accuracy: 0.05)

        let clock = CaptureClock()
        var t = 0.0
        while t <= 8.0 {
            _ = clock.observe(stream: .video, ptsSeconds: t, hostSeconds: t)
            t += 1.0 / 60.0
        }
        t = 0.0
        while t <= 8.0 {
            _ = clock.observe(stream: .audio, ptsSeconds: t * 1.001, hostSeconds: t)
            t += 0.01
        }
        var unified: [Double] = []
        for i in 8..<40 {
            let hostV = Double(i)
            let hostA = Double(i) + 0.050
            _ = clock.observe(stream: .video, ptsSeconds: hostV, hostSeconds: hostV)
            _ = clock.observe(stream: .audio, ptsSeconds: hostA * 1.001, hostSeconds: hostA)
            let vU = clock.unified(stream: .video, ptsSeconds: hostV)
            let aU = clock.unified(stream: .audio, ptsSeconds: hostA * 1.001)
            unified.append((aU - vU) * 1000)
        }
        let uWalk = MeasurementStatistics.walkMsPerEvent(unified) ?? 999
        XCTAssertLessThan(abs(uWalk), 0.15, "walk \(uWalk)")
        XCTAssertEqual(MeasurementStatistics.median(unified), 50, accuracy: 3)
    }

    func testClockNotSettledDoesNotAllowPublishedPairs() {
        let clock = CaptureClock()
        var t = 0.0
        while t <= 0.25 {
            _ = clock.observe(stream: .video, ptsSeconds: t, hostSeconds: t)
            _ = clock.observe(stream: .audio, ptsSeconds: t, hostSeconds: t)
            t += 1.0 / 60.0
        }
        XCTAssertFalse(clock.snapshot().settled)
        XCTAssertFalse(clock.allowsPublishedPairs)
        let e = SyncMeasurementEngine()
        if clock.allowsPublishedPairs {
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 0.2, luminance: 0.8, threshold: 0.1))
            _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 0.206, envelope: 0.4, threshold: 0.1))
        }
        XCTAssertEqual(e.snapshot().validCount, 0)
    }

    func testRingDownReplicasAreOneOnset() {
        let d = AudioPulseDetector()
        let rate = 48_000.0
        let buf = 1024
        func feed(from t0: Double, until t1: Double, paint: (Double) -> Float) -> [AudioPulseEvent] {
            var hits: [AudioPulseEvent] = []
            var t = t0
            while t < t1 {
                var samples = [Float](repeating: 0, count: buf)
                for i in 0..<buf {
                    samples[i] = paint(t + Double(i) / rate)
                }
                if let ev = d.processMonoSamples(samples, bufferStartSeconds: t, sampleRate: rate) {
                    hits.append(ev)
                }
                t += Double(buf) / rate
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
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].timestampSeconds, 1.0, accuracy: 0.005)
    }

    func testReplicaPulseDoesNotStealNextFlash() {
        let e = SyncMeasurementEngine(configuration: .init(pairingWindowSeconds: 1.0))
        _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.0, luminance: 0.8, threshold: 0.1))
        _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 1.006, envelope: 0.4, threshold: 0.1))
        _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 1.300, envelope: 0.12, threshold: 0.05))
        _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 2.0, luminance: 0.8, threshold: 0.1))
        _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 2.006, envelope: 0.4, threshold: 0.1))
        let snap = e.snapshot()
        XCTAssertEqual(snap.validCount, 2)
        XCTAssertGreaterThanOrEqual(snap.rejectedCount, 1)
        XCTAssertTrue(snap.recentValidSamples.allSatisfy { abs($0.offsetMilliseconds - 6) < 0.5 })
    }

    func testConstantSixMsAfterLockStaysFlat() {
        let clock = CaptureClock()
        var t = 0.0
        while t <= 2.5 {
            _ = clock.observe(stream: .video, ptsSeconds: t, hostSeconds: t)
            t += 1.0 / 60.0
        }
        t = 0.0
        while t <= 2.5 {
            _ = clock.observe(stream: .audio, ptsSeconds: t * 1.001, hostSeconds: t)
            t += 0.01
        }
        XCTAssertTrue(clock.allowsPublishedPairs)
        var offsets: [Double] = []
        for i in 0..<15 {
            let hostV = 3.0 + Double(i)
            let hostA = hostV + 0.006
            _ = clock.observe(stream: .video, ptsSeconds: hostV, hostSeconds: hostV)
            _ = clock.observe(stream: .audio, ptsSeconds: hostA * 1.001, hostSeconds: hostA)
            let vU = clock.unified(stream: .video, ptsSeconds: hostV)
            let aU = clock.unified(stream: .audio, ptsSeconds: hostA * 1.001)
            offsets.append((aU - vU) * 1000)
        }
        let walk = MeasurementStatistics.walkMsPerEvent(offsets) ?? 999
        XCTAssertEqual(offsets.count, 15)
        XCTAssertEqual(MeasurementStatistics.median(offsets), 6, accuracy: 3)
        XCTAssertLessThan(abs(walk), 0.15)
    }

    func testCallbackJitterDoesNotWalkAfterFreeze() {
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
        XCTAssertTrue(clock.allowsPublishedPairs)
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
        let walk = MeasurementStatistics.walkMsPerEvent(offsets) ?? 999
        XCTAssertEqual(MeasurementStatistics.median(offsets), 6, accuracy: 3)
        XCTAssertLessThan(abs(walk), 0.15)
    }

    func testLongVideoFlashIsOneEvent() {
        let d = VideoFlashDetector()
        var hits = 0
        for i in 0..<30 {
            if d.processLuminance(0.05, timestampSeconds: Double(i) / 60.0) != nil { hits += 1 }
        }
        for f in 0..<20 {
            if d.processLuminance(0.90, timestampSeconds: 1.0 + Double(f) / 60.0) != nil { hits += 1 }
        }
        XCTAssertEqual(hits, 1)
    }

    func testExtraFlash150msDoesNotStealNextPulse() {
        let d = VideoFlashDetector()
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
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].timestampSeconds, 1.0, accuracy: 0.02)
        XCTAssertEqual(events[1].timestampSeconds, 2.0, accuracy: 0.02)
        let e = SyncMeasurementEngine(configuration: .init(pairingWindowSeconds: 1.0))
        _ = e.ingestFlash(events[0])
        _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 1.006, envelope: 0.4, threshold: 0.1))
        _ = e.ingestFlash(events[1])
        _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 2.006, envelope: 0.4, threshold: 0.1))
        XCTAssertEqual(e.snapshot().validCount, 2)
        XCTAssertTrue(e.snapshot().recentValidSamples.allSatisfy { abs($0.offsetMilliseconds - 6) < 1 })
    }

    func testPTSDiscontinuityDropsUntilResettled() {
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
        XCTAssertTrue(clock.allowsPublishedPairs)
        _ = clock.observe(stream: .video, ptsSeconds: 0.05, hostSeconds: 0.05)
        _ = clock.observe(stream: .audio, ptsSeconds: 0.05, hostSeconds: 0.05)
        XCTAssertFalse(clock.allowsPublishedPairs)
        t = 0.0
        while t <= 3.0 {
            _ = clock.observe(stream: .video, ptsSeconds: t, hostSeconds: t)
            t += 1.0 / 60.0
        }
        t = 0.0
        while t <= 3.0 {
            _ = clock.observe(stream: .audio, ptsSeconds: t, hostSeconds: t)
            t += 0.01
        }
        XCTAssertTrue(clock.allowsPublishedPairs)
        var offsets: [Double] = []
        for i in 0..<12 {
            let hostV = 3.0 + Double(i)
            let hostA = hostV + 0.006
            _ = clock.observe(stream: .video, ptsSeconds: hostV, hostSeconds: hostV)
            _ = clock.observe(stream: .audio, ptsSeconds: hostA, hostSeconds: hostA)
            offsets.append((clock.unified(stream: .audio, ptsSeconds: hostA) - clock.unified(stream: .video, ptsSeconds: hostV)) * 1000)
        }
        XCTAssertEqual(MeasurementStatistics.median(offsets), 6, accuracy: 3)
        XCTAssertLessThan(abs(MeasurementStatistics.walkMsPerEvent(offsets) ?? 999), 0.15)
    }

    func testTwentyFiveSecondPlusSixStaysFlatAfterFreeze() {
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
        var offsets: [Double] = []
        for i in 0..<25 {
            let hostV = 3.0 + Double(i)
            let hostA = hostV + 0.006
            _ = clock.observe(stream: .video, ptsSeconds: hostV, hostSeconds: hostV)
            _ = clock.observe(stream: .audio, ptsSeconds: hostA, hostSeconds: hostA)
            offsets.append((clock.unified(stream: .audio, ptsSeconds: hostA) - clock.unified(stream: .video, ptsSeconds: hostV)) * 1000)
        }
        XCTAssertEqual(offsets.count, 25)
        XCTAssertEqual(MeasurementStatistics.median(offsets), 6, accuracy: 3)
        XCTAssertLessThan(abs(MeasurementStatistics.walkMsPerEvent(offsets) ?? 999), 0.15)
    }

    func testForceSettleAfterChatter() {
        let clock = CaptureClock()
        var t = 0.0
        while t <= 2.7 {
            let jv = 0.008 * sin(t * 47.0)
            let ja = 0.007 * sin(t * 53.0 + 0.8)
            _ = clock.observe(stream: .video, ptsSeconds: t, hostSeconds: t + jv)
            _ = clock.observe(stream: .audio, ptsSeconds: t, hostSeconds: t + ja)
            t += 1.0 / 60.0
        }
        XCTAssertTrue(clock.snapshot().settled)
        XCTAssertTrue(clock.allowsPublishedPairs)
    }

    func testDropTwoPairsAfterGateOpens() {
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
        let e = SyncMeasurementEngine(configuration: .init(pairingWindowSeconds: 1.0))
        for i in 0..<6 {
            let tV = 3.0 + Double(i)
            let tA = tV + 0.006
            if clock.acceptDetectedEvent(stream: .video) {
                _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: tV, luminance: 0.8, threshold: 0.1))
            } else {
                e.noteHeldForClock(flash: VisualFlashEvent(timestampSeconds: tV, luminance: 0.8, threshold: 0.1), pulse: nil)
            }
            if clock.acceptDetectedEvent(stream: .audio) {
                _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: tA, envelope: 0.4, threshold: 0.1))
            } else {
                e.noteHeldForClock(flash: nil, pulse: AudioPulseEvent(timestampSeconds: tA, envelope: 0.4, threshold: 0.1))
            }
        }
        XCTAssertEqual(e.snapshot().validCount, 4)
    }
}
