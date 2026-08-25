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
}
