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
    func testOneHzWhiteFlashOnDarkFieldIsOneEventEach() {
        let d = VideoFlashDetector()
        let fps = 60.0
        func luma(_ t: Double) -> Double {
            let phase = t.truncatingRemainder(dividingBy: 1.0)
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
        XCTAssertEqual(times.count, 8, "zero-flash regression: got \(times)")
        for i in 0..<min(8, times.count) {
            XCTAssertEqual(times[i], Double(i + 1), accuracy: 0.03)
        }
    }

    func testBrightFirstFrameDoesNotHideLaterFlash() {
        let d = VideoFlashDetector()
        var hits = 0
        if d.processLuminance(0.90, timestampSeconds: 0.0) != nil { hits += 1 }
        for i in 1..<30 {
            if d.processLuminance(0.05, timestampSeconds: Double(i) / 60.0) != nil { hits += 1 }
        }
        if d.processLuminance(0.87, timestampSeconds: 1.0) != nil { hits += 1 }
        XCTAssertEqual(hits, 1)
    }

    func testStuckBrightAfterHoldoffDoesNotRefire() {
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
        XCTAssertEqual(hits, 1)
    }

    func testElevatedPostFlashFloorStillYieldsOneHzEvents() {
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
        XCTAssertEqual(times.count, 5, "got \(times)")
    }

    func testFlatLumaInventNoFlashes() {
        let d = VideoFlashDetector()
        var hits = 0
        var t = 0.0
        while t < 5.0 {
            if d.processLuminance(0.15, timestampSeconds: t) != nil { hits += 1 }
            t += 1.0 / 60.0
        }
        XCTAssertEqual(hits, 0)
    }

    /// Live path after host-map: pts == host. Video 30.000 fps, audio 1.001 family.
    func runAlreadyMappedNTSC(trueOffsetMs: Double, events: Int, warmupSeconds: Double = 3.0) -> [Double] {
        let clock = CaptureClock()
        let ntsc = 1001.0 / 1000.0
        let videoFps = 30.0
        let trueOffset = trueOffsetMs / 1000.0
        let total = warmupSeconds + Double(events) + 0.5
        var offsets: [Double] = []
        var tV = 0.0
        var tA = 0.0
        var nextEvent = warmupSeconds
        while tV <= total || tA <= total {
            if tA > total || (tV <= total && tV <= tA) {
                let real = tV
                _ = clock.observe(stream: .video, ptsSeconds: tV, hostSeconds: tV)
                tV += 1.0 / videoFps
                if clock.allowsPublishedPairs,
                   real + 1e-9 >= nextEvent,
                   nextEvent < warmupSeconds + Double(events) {
                    let i = nextEvent
                    let vU = clock.unified(stream: .video, ptsSeconds: i)
                    let aU = clock.unified(stream: .audio, ptsSeconds: (i + trueOffset) * ntsc)
                    offsets.append((aU - vU) * 1000)
                    nextEvent += 1.0
                }
            } else {
                let aPTS = tA * ntsc
                _ = clock.observe(stream: .audio, ptsSeconds: aPTS, hostSeconds: aPTS)
                tA += 0.01
            }
        }
        return offsets
    }

    func testAlreadyMapped30vs2997PlusSixDoesNotWalk() {
        let offsets = runAlreadyMappedNTSC(trueOffsetMs: 6, events: 25)
        XCTAssertGreaterThanOrEqual(offsets.count, 25)
        XCTAssertEqual(MeasurementStatistics.median(offsets), 6, accuracy: 3)
        XCTAssertLessThan(abs(MeasurementStatistics.walkMsPerEvent(offsets) ?? 999), 0.15)
    }

    func testAlreadyMapped30vs2997Minus43DoesNotWalk() {
        let offsets = runAlreadyMappedNTSC(trueOffsetMs: -43, events: 25)
        XCTAssertGreaterThanOrEqual(offsets.count, 25)
        XCTAssertEqual(MeasurementStatistics.median(offsets), -43, accuracy: 3)
        let walk = MeasurementStatistics.walkMsPerEvent(offsets) ?? 999
        XCTAssertLessThan(abs(walk), 0.15, "walk \(walk)")
    }

    func testRawAlreadyMapped30vs2997WalksOneMsPerEvent() {
        var raw: [Double] = []
        let ntsc = 1001.0 / 1000.0
        for i in 0..<25 {
            raw.append(((Double(i) + 0.006) * ntsc - Double(i)) * 1000)
        }
        XCTAssertEqual(MeasurementStatistics.walkMsPerEvent(raw) ?? 0, 1.001, accuracy: 0.05)
    }

    func testPickerPrefersNTSCCaptureDuration() {
        let ntsc60 = FrameRate.preferredCaptureDuration(program: .fps2997, maxFrameRate: 60)
        XCTAssertEqual(ntsc60.value, 1001)
        XCTAssertEqual(ntsc60.timescale, 60_000)
        let ntsc30 = FrameRate.preferredCaptureDuration(program: .fps2997, maxFrameRate: 30)
        XCTAssertEqual(ntsc30.value, 1001)
        XCTAssertEqual(ntsc30.timescale, 30_000)
        let i60 = FrameRate.preferredCaptureDuration(program: .fps30, maxFrameRate: 60)
        XCTAssertEqual(i60.value, 1)
        XCTAssertEqual(i60.timescale, 60)
        let i30 = FrameRate.preferredCaptureDuration(program: .fps30, maxFrameRate: 30)
        XCTAssertEqual(i30.value, 1)
        XCTAssertEqual(i30.timescale, 30)
        let p60 = FrameRate.preferredCaptureDuration(program: .fps60, maxFrameRate: 60)
        XCTAssertEqual(p60.value, 1)
        XCTAssertEqual(p60.timescale, 60)
        let p5994 = FrameRate.preferredCaptureDuration(program: .fps5994, maxFrameRate: 60)
        XCTAssertEqual(p5994.value, 1001)
        XCTAssertEqual(p5994.timescale, 60_000)
    }

    func runTrueHostCaptureVsNTSCFile(captureFps: Double, trueOffsetMs: Double, events: Int) -> (offsets: [Double], relativeSlope: Double) {
        let clock = CaptureClock()
        let fileFps = 30_000.0 / 1_001.0
        let eventPeriod = 30.0 / fileFps
        let trueOffset = trueOffsetMs / 1000.0
        let warmupSeconds = 4.2
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

    func testInteger30CaptureVs297EventsWalksUntilNTSCLock() {
        let (off, slope) = runTrueHostCaptureVsNTSCFile(captureFps: 30.0, trueOffsetMs: 6, events: 25)
        XCTAssertGreaterThanOrEqual(off.count, 25)
        XCTAssertEqual(slope, 1.0, accuracy: 0.0008, "relative A−V stays 1.0")
        let walk = MeasurementStatistics.walkMsPerEvent(off) ?? 0
        XCTAssertEqual(walk, 1.001, accuracy: 0.08, "walk \(walk)")
    }

    func testNTSCCaptureLockFlattens297File() {
        for fps in [30_000.0 / 1_001.0, 60_000.0 / 1_001.0] {
            let (off, slope) = runTrueHostCaptureVsNTSCFile(captureFps: fps, trueOffsetMs: 6, events: 25)
            XCTAssertGreaterThanOrEqual(off.count, 25)
            XCTAssertEqual(slope, 1.0, accuracy: 0.0008)
            XCTAssertEqual(MeasurementStatistics.median(off), 6, accuracy: 3)
            let walk = MeasurementStatistics.walkMsPerEvent(off) ?? 999
            XCTAssertLessThan(abs(walk), 0.15, "fps \(fps) walk \(walk)")
        }
    }

    func testPicker297DoesNotSilentlySelectInteger30() {
        let locked30 = CaptureFormatProbe(
            width: 1920, height: 1080,
            ranges: [CaptureFrameDurationRange(minDuration: .integer30, maxDuration: .integer30)]
        )
        XCTAssertNil(CaptureFrameDuration.selectLock(program: .fps2997, formats: [locked30]))

        let wide30 = CaptureFormatProbe(
            width: 1920, height: 1080,
            ranges: [CaptureFrameDurationRange(minDuration: .integer30, maxDuration: CaptureFrameDuration(value: 1, timescale: 1))]
        )
        let choice = CaptureFrameDuration.selectLock(program: .fps2997, formats: [wide30])
        XCTAssertEqual(choice?.duration.value, 1001)
        XCTAssertEqual(choice?.duration.timescale, 30_000)
        XCTAssertTrue(choice?.duration.isNTSCFamily ?? false)
    }

    func testPicker297Prefers60000Over30000() {
        let ntsc60fmt = CaptureFormatProbe(
            width: 1280, height: 720,
            ranges: [CaptureFrameDurationRange(minDuration: .ntsc60, maxDuration: CaptureFrameDuration(value: 1, timescale: 1))]
        )
        let ntsc30fmt = CaptureFormatProbe(
            width: 1920, height: 1080,
            ranges: [CaptureFrameDurationRange(minDuration: .ntsc30, maxDuration: CaptureFrameDuration(value: 1, timescale: 1))]
        )
        let choice = CaptureFrameDuration.selectLock(program: .fps2997, formats: [ntsc30fmt, ntsc60fmt])
        XCTAssertEqual(choice?.duration.timescale, 60_000)
        XCTAssertEqual(choice?.duration.value, 1001)
    }

    func testIntegerFooterMissWhenPickerIs297() {
        let miss = FrameRate.captureFooter(observedFPS: 30.0, picker: .fps2997)
        XCTAssertTrue(miss.contains("MISS"))
        XCTAssertTrue(miss.contains("integer"))
        let ok = FrameRate.captureFooter(observedFPS: 30.0, picker: .fps30)
        XCTAssertFalse(ok.contains("MISS"))
    }

}
