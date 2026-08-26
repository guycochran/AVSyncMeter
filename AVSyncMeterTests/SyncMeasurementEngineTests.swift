import XCTest
@testable import AVSyncMeter

final class SyncMeasurementEngineTests: XCTestCase {
    private func engine() -> SyncMeasurementEngine {
        SyncMeasurementEngine(configuration: .init(pairingWindowSeconds: 1.0))
    }

    private func pair(_ engine: SyncMeasurementEngine, tVideo: Double, tAudio: Double) -> SyncSample? {
        _ = engine.ingestFlash(VisualFlashEvent(timestampSeconds: tVideo, luminance: 0.8, threshold: 0.1))
        return engine.ingestPulse(AudioPulseEvent(timestampSeconds: tAudio, envelope: 0.4, threshold: 0.1))
    }

    func testExactSync() {
        let e = engine()
        let sample = pair(e, tVideo: 10.0, tAudio: 10.0)
        XCTAssertNotNil(sample)
        XCTAssertEqual(sample!.offsetMilliseconds, 0, accuracy: 0.0001)
        XCTAssertEqual(sample!.direction, .inSync)
        XCTAssertEqual(e.snapshot().correctedCurrentMilliseconds ?? -1, 0, accuracy: 0.0001)
    }

    func testAudio200msEarly() {
        let e = engine()
        let sample = pair(e, tVideo: 5.0, tAudio: 5.200)
        XCTAssertNotNil(sample)
        XCTAssertEqual(sample!.offsetMilliseconds, 200, accuracy: 0.001)
        XCTAssertEqual(sample!.direction, .audioEarly)
        // AUDIO EARLY → recommended Mitti delay is +offset
        XCTAssertGreaterThan(sample!.offsetMilliseconds, 0)
    }

    func testAudio200msLate() {
        let e = engine()
        let sample = pair(e, tVideo: 5.0, tAudio: 4.800)
        XCTAssertNotNil(sample)
        XCTAssertEqual(sample!.offsetMilliseconds, -200, accuracy: 0.001)
        XCTAssertEqual(sample!.direction, .audioLate)
    }

    func testRepeatedEventsEverySecond() {
        let e = engine()
        for i in 0..<8 {
            let t = Double(i)
            _ = pair(e, tVideo: t, tAudio: t + 0.193)
        }
        let snap = e.snapshot()
        XCTAssertEqual(snap.validCount, 8)
        XCTAssertEqual(snap.medianMilliseconds, 193, accuracy: 0.01)
        XCTAssertEqual(snap.meanMilliseconds, 193, accuracy: 0.01)
    }

    func testSmallRandomJitter() {
        let e = engine()
        let offsets = [198.0, 201.0, 199.5, 202.0, 197.0, 200.5, 199.0]
        for (i, ms) in offsets.enumerated() {
            _ = pair(e, tVideo: Double(i), tAudio: Double(i) + ms / 1000.0)
        }
        let snap = e.snapshot()
        XCTAssertEqual(snap.validCount, offsets.count)
        XCTAssertEqual(snap.medianMilliseconds, 199.5, accuracy: 1.0)
        XCTAssertLessThan(snap.standardDeviationMilliseconds, 5)
        XCTAssertTrue(snap.isStable)
    }

    func testOneMissingAudio() {
        let e = engine()
        _ = pair(e, tVideo: 0, tAudio: 0.200)
        _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 1.0, luminance: 0.8, threshold: 0.1))
        // Advance far enough that the orphan flash expires.
        _ = pair(e, tVideo: 5.0, tAudio: 5.200)
        let snap = e.snapshot()
        XCTAssertEqual(snap.validCount, 2)
        XCTAssertGreaterThanOrEqual(snap.rejectedCount, 1)
    }

    func testOneMissingFlash() {
        let e = engine()
        _ = pair(e, tVideo: 0, tAudio: 0.200)
        _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 1.0, envelope: 0.4, threshold: 0.1))
        _ = pair(e, tVideo: 5.0, tAudio: 5.200)
        let snap = e.snapshot()
        XCTAssertEqual(snap.validCount, 2)
        XCTAssertGreaterThanOrEqual(snap.rejectedCount, 1)
    }

    func testFalseExtraAudioPulse() {
        let e = engine()
        _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 2.0, luminance: 0.8, threshold: 0.1))
        _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 2.200, envelope: 0.4, threshold: 0.1))
        _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 2.260, envelope: 0.2, threshold: 0.1))
        // Extra pulse should remain unpaired until it ages out.
        _ = pair(e, tVideo: 6.0, tAudio: 6.200)
        XCTAssertEqual(e.snapshot().validCount, 2)
        XCTAssertGreaterThanOrEqual(e.snapshot().rejectedCount, 1)
    }

    func testFalseExtraVideoFlash() {
        let e = engine()
        _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 2.0, luminance: 0.8, threshold: 0.1))
        _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: 2.04, luminance: 0.9, threshold: 0.1))
        _ = e.ingestPulse(AudioPulseEvent(timestampSeconds: 2.200, envelope: 0.4, threshold: 0.1))
        _ = pair(e, tVideo: 6.0, tAudio: 6.200)
        XCTAssertEqual(e.snapshot().validCount, 2)
        XCTAssertGreaterThanOrEqual(e.snapshot().rejectedCount, 1)
    }

    func testExtremeOutlier() {
        let e = engine()
        for i in 0..<6 {
            _ = pair(e, tVideo: Double(i), tAudio: Double(i) + 0.200)
        }
        _ = pair(e, tVideo: 10.0, tAudio: 10.0 + 0.240)
        let snap = e.snapshot()
        XCTAssertEqual(snap.validCount, 6)
        XCTAssertEqual(snap.outlierCount, 1)
        XCTAssertEqual(snap.medianMilliseconds, 200, accuracy: 0.1)
    }

    func testFrameConversion2997() {
        let ms = 193.0
        let frames = FrameRate.fps2997.frames(forMilliseconds: ms)
        XCTAssertEqual(FrameRate.fps2997.framesPerSecond, 30_000.0 / 1_001.0, accuracy: 1e-12)
        XCTAssertEqual(frames, 193.0 / 1000.0 * (30_000.0 / 1_001.0), accuracy: 1e-10)
        XCTAssertEqual(frames, 5.79, accuracy: 0.01)
    }

    func testFrameConversion5994() {
        let ms = 193.0
        let frames = FrameRate.fps5994.frames(forMilliseconds: ms)
        XCTAssertEqual(FrameRate.fps5994.framesPerSecond, 60_000.0 / 1_001.0, accuracy: 1e-12)
        XCTAssertEqual(frames, 193.0 / 1000.0 * (60_000.0 / 1_001.0), accuracy: 1e-10)
    }

    func testRecentValidNewestFirstCapsAt25AndOmitsOutlier() {
        let e = engine()
        for i in 0..<28 {
            _ = pair(e, tVideo: Double(i), tAudio: Double(i) + 0.200)
        }
        _ = pair(e, tVideo: 40.0, tAudio: 40.0 + 0.240)
        let snap = e.snapshot()
        XCTAssertEqual(snap.validCount, 28)
        XCTAssertEqual(snap.outlierCount, 1)
        XCTAssertEqual(snap.recentValidSamples.count, 25)
        XCTAssertEqual(snap.recentValidSamples.first?.offsetMilliseconds ?? 0, 200, accuracy: 0.1)
        XCTAssertFalse(snap.recentValidSamples.contains(where: \.isOutlier))
        // Newest first: last valid pair was the 28th 200ms sample (index 27), not the outlier.
        XCTAssertEqual(snap.recentValidSamples.first?.videoTimestampSeconds ?? -1, 27.0, accuracy: 0.001)
        XCTAssertEqual(snap.recentValidSamples.last?.videoTimestampSeconds ?? -1, 3.0, accuracy: 0.001)
        e.reset()
        XCTAssertTrue(e.snapshot().recentValidSamples.isEmpty)
        XCTAssertEqual(e.snapshot().validCount, 0)
        XCTAssertNil(e.snapshot().correctedMedianMilliseconds)
    }

    func testSpanIsMaxMinusMinOfValidSamples() {
        let e = engine()
        XCTAssertEqual(e.snapshot().spanMilliseconds, 0, accuracy: 0.0001)
        _ = pair(e, tVideo: 0, tAudio: 0.100)
        _ = pair(e, tVideo: 1, tAudio: 1.200)
        _ = pair(e, tVideo: 2, tAudio: 2.140)
        let snap = e.snapshot()
        XCTAssertEqual(snap.validCount, 3)
        XCTAssertEqual(snap.minMilliseconds, 100, accuracy: 0.01)
        XCTAssertEqual(snap.maxMilliseconds, 200, accuracy: 0.01)
        XCTAssertEqual(snap.spanMilliseconds, 100, accuracy: 0.01)
    }

    func testHeadlineUsesMedianNotLastPair() {
        let e = engine()
        XCTAssertNil(e.snapshot().correctedMedianMilliseconds)
        _ = pair(e, tVideo: 0, tAudio: 0.100)
        _ = pair(e, tVideo: 1, tAudio: 1.160)
        _ = pair(e, tVideo: 2, tAudio: 2.220)
        let snap = e.snapshot()
        XCTAssertEqual(snap.validCount, 3)
        XCTAssertEqual(snap.currentOffsetMilliseconds ?? 0, 220, accuracy: 0.01)
        XCTAssertEqual(snap.medianMilliseconds, 160, accuracy: 0.01)
        XCTAssertEqual(snap.correctedMedianMilliseconds ?? 0, 160, accuracy: 0.01)
        e.configuration.calibrationOffsetMilliseconds = 10
        XCTAssertEqual(e.snapshot().correctedMedianMilliseconds ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(e.snapshot().correctedCurrentMilliseconds ?? 0, 210, accuracy: 0.01)
    }

    func testCalibrationSubtracts() {
        let e = SyncMeasurementEngine(configuration: .init(calibrationOffsetMilliseconds: 12))
        _ = pair(e, tVideo: 1, tAudio: 1.200)
        let corrected = e.snapshot().correctedCurrentMilliseconds
        XCTAssertEqual(corrected ?? 0, 188, accuracy: 0.001)
        XCTAssertEqual(e.snapshot().correctedMedianMilliseconds ?? 0, 188, accuracy: 0.001)
        XCTAssertTrue(e.snapshot().calibrationApplied)
    }

    func testZeroThenClearOn193msPair() {
        let e = engine()
        _ = pair(e, tVideo: 1, tAudio: 1.193)
        let snap = e.snapshot()
        let measured = CalibrationMath.measuredOffsetForZero(
            validCount: snap.validCount,
            medianMilliseconds: snap.medianMilliseconds,
            currentOffsetMilliseconds: snap.currentOffsetMilliseconds
        )
        XCTAssertEqual(measured ?? 0, 193, accuracy: 0.001)
        let stored = CalibrationMath.calibrationOffset(measuredOffset: measured!, knownTrueOffset: 0)
        XCTAssertEqual(stored, 193, accuracy: 0.001)
        e.configuration.calibrationOffsetMilliseconds = stored
        XCTAssertEqual(e.snapshot().correctedCurrentMilliseconds ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(e.snapshot().correctedMedianMilliseconds ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(e.snapshot().calibrationOffsetMilliseconds, 193, accuracy: 0.001)
        e.configuration.calibrationOffsetMilliseconds = 0
        XCTAssertEqual(e.snapshot().correctedCurrentMilliseconds ?? 0, 193, accuracy: 0.001)
        XCTAssertFalse(e.snapshot().calibrationApplied)
        XCTAssertNil(CalibrationMath.measuredOffsetForZero(validCount: 0, medianMilliseconds: 0, currentOffsetMilliseconds: nil))
    }

    func testOneHzFlashPlusDelayedPulsePairsInsideWindow() {
        let e = SyncMeasurementEngine()
        for i in 0..<8 {
            let t = Double(i)
            _ = e.ingestFlash(VisualFlashEvent(timestampSeconds: t, luminance: 0.58, threshold: 0.124))
            if i > 0 {
                _ = e.ingestPulse(.beepLike(timestampSeconds: Double(i - 1) + 0.080))
            }
        }
        _ = e.ingestPulse(.beepLike(timestampSeconds: 7.080))
        XCTAssertEqual(e.snapshot().validCount, 8)
        XCTAssertEqual(e.snapshot().medianMilliseconds, 80, accuracy: 1)
    }

    func testFlashDetectorSingleEvent() {
        let d = VideoFlashDetector()
        var hits = 0
        // Dark baseline
        for i in 0..<10 {
            if d.processLuminance(0.05, timestampSeconds: Double(i) * 0.016) != nil { hits += 1 }
        }
        if d.processLuminance(0.85, timestampSeconds: 0.20) != nil { hits += 1 }
        // Stay bright — must not retrigger
        for i in 0..<12 {
            if d.processLuminance(0.80, timestampSeconds: 0.22 + Double(i) * 0.016) != nil { hits += 1 }
        }
        XCTAssertEqual(hits, 1)
    }

    func testAudioDetectorOnsetUsesSampleOffset() {
        let d = AudioPulseDetector()
        let rate = 48_000.0
        var quiet = [Float](repeating: 0.001, count: 2048)
        _ = d.processMonoSamples(quiet, bufferStartSeconds: 0, sampleRate: rate)
        // Pulse starts 512 samples into the buffer.
        var loud = [Float](repeating: 0.001, count: 2048)
        for i in 512..<700 { loud[i] = 0.9 }
        let event = d.processMonoSamples(loud, bufferStartSeconds: 1.0, sampleRate: rate)
        XCTAssertNotNil(event)
        let expected = 1.0 + 512.0 / rate
        XCTAssertEqual(event!.timestampSeconds, expected, accuracy: 32.0 / rate)
    }
}

final class FrameRateTests: XCTestCase {
    func testAllRatesPositive() {
        for rate in FrameRate.allCases {
            XCTAssertGreaterThan(rate.framesPerSecond, 0)
        }
    }

    func testMeterHistoryDefaultWindowAndClamp() {
        XCTAssertEqual(MeterHistory.defaultWindowSeconds, 90, accuracy: 1e-9)
        XCTAssertEqual(MeterHistory.clampedWindow(0), 1, accuracy: 1e-9)
        XCTAssertEqual(MeterHistory.clampedWindow(91), 90, accuracy: 1e-9)
    }

    func testMeterHistoryPeakHoldsNewestAtRight() {
        let h = MeterHistory()
        for i in 0..<30 {
            h.appendLuma(t: Double(i), value: 0.05)
            h.appendMic(t: Double(i), value: 0.02)
        }
        h.appendLuma(t: 29.0, value: 0.98)
        h.appendMic(t: 29.05, value: 0.80)
        let luma = h.lumaColumns(now: 30, windowSeconds: 30, count: 30)
        let mic = h.micColumns(now: 30, windowSeconds: 30, count: 30)
        XCTAssertGreaterThan(luma[29], 0.8)
        XCTAssertLessThan(luma[0], 0.2)
        XCTAssertGreaterThan(mic[29], 0.5)
        h.reset()
        XCTAssertEqual(h.lumaCount, 0)
        XCTAssertEqual(h.micCount, 0)
    }

    func testMeterHistoryRecordsLiveLevelsWithZeroPairs() {
        let h = MeterHistory()
        let e = SyncMeasurementEngine()
        for i in 0..<20 {
            let t = Double(i) * 0.05
            h.appendLuma(t: t, value: i == 10 ? 0.95 : 0.08)
            h.appendMic(t: t, value: i == 12 ? 0.90 : 0.03)
        }
        XCTAssertEqual(e.snapshot().validCount, 0)
        XCTAssertEqual(h.markCount, 0)
        let luma = h.lumaColumns(now: 1, windowSeconds: 1, count: 20)
        let mic = h.micColumns(now: 1, windowSeconds: 1, count: 20)
        XCTAssertTrue(luma.contains(where: { $0 > 0.8 }))
        XCTAssertTrue(mic.contains(where: { $0 > 0.8 }))
        XCTAssertTrue(h.marks(now: 1, windowSeconds: 90).isEmpty)
        XCTAssertEqual(MeterHistory.defaultWindowSeconds, 90, accuracy: 1e-9)
    }

    func testMeterHistoryFlashAudioPulseMarksWithoutPair() {
        let h = MeterHistory()
        h.appendLuma(t: 10, value: 0.95)
        h.appendMic(t: 10.08, value: 0.85)
        h.appendMark(t: 10, kind: .flash)
        h.appendMark(t: 10.08, kind: .audioPulse)
        let ms = h.marks(now: 11, windowSeconds: 90)
        XCTAssertTrue(ms.contains(where: { $0.kind == .flash }))
        XCTAssertTrue(ms.contains(where: { $0.kind == .audioPulse }))
        XCTAssertFalse(ms.contains(where: { $0.kind == .pair }))
        h.appendMark(t: 10.08, kind: .pair)
        XCTAssertTrue(h.marks(now: 11, windowSeconds: 90).contains(where: { $0.kind == .pair }))
        h.reset()
        XCTAssertEqual(h.markCount, 0)
    }
}
