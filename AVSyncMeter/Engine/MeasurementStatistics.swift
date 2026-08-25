import Foundation

/// Running statistics over paired offsets. Never treats a single event as "the answer".
/// Outliers use median + MAD (median absolute deviation) and stay in the raw log.
struct MeasurementStatistics {
    private(set) var rawSamples: [SyncSample] = []
    var calibrationOffsetMilliseconds: Double = 0
    var stabilityThresholdMilliseconds: Double = 8
    var outlierMADMultiplier: Double = 3.5

    mutating func reset() {
        rawSamples.removeAll()
    }

    mutating func append(_ sample: SyncSample) {
        rawSamples.append(sample)
    }

    /// Recompute outlier flags from the full set (median + MAD).
    mutating func recomputeOutliers() {
        let offsets = rawSamples.map(\.offsetMilliseconds)
        guard offsets.count >= 3 else {
            rawSamples = rawSamples.map { sample in
                let copy = sample
                return SyncSample(
                    id: copy.id,
                    videoTimestampSeconds: copy.videoTimestampSeconds,
                    audioTimestampSeconds: copy.audioTimestampSeconds,
                    offsetMilliseconds: copy.offsetMilliseconds,
                    videoLuminance: copy.videoLuminance,
                    visualThreshold: copy.visualThreshold,
                    audioEnvelope: copy.audioEnvelope,
                    audioThreshold: copy.audioThreshold,
                    isOutlier: false,
                    pairedAt: copy.pairedAt
                )
            }
            return
        }
        let med = Self.median(offsets)
        let absDevs = offsets.map { abs($0 - med) }
        let mad = Self.median(absDevs)
        let scale = 1.4826
        let threshold = max(1.0, outlierMADMultiplier * scale * max(mad, 0.001))
        rawSamples = rawSamples.map { sample in
            let outlier = abs(sample.offsetMilliseconds - med) > threshold
            return SyncSample(
                id: sample.id,
                videoTimestampSeconds: sample.videoTimestampSeconds,
                audioTimestampSeconds: sample.audioTimestampSeconds,
                offsetMilliseconds: sample.offsetMilliseconds,
                videoLuminance: sample.videoLuminance,
                visualThreshold: sample.visualThreshold,
                audioEnvelope: sample.audioEnvelope,
                audioThreshold: sample.audioThreshold,
                isOutlier: outlier,
                pairedAt: sample.pairedAt
            )
        }
    }

    var validOffsets: [Double] {
        rawSamples.filter { !$0.isOutlier }.map(\.offsetMilliseconds)
    }

    static let recentValidLimit = 25

    /// Newest first. Valid-only so the table matches the median/headline population.
    func recentValidSamples(limit: Int = recentValidLimit) -> [SyncSample] {
        Array(rawSamples.filter { !$0.isOutlier }.suffix(limit).reversed())
    }

    func snapshot(rejectedUnpaired: Int) -> MeasurementSnapshot {
        let valid = validOffsets
        let current = rawSamples.last(where: { !$0.isOutlier })?.offsetMilliseconds
        let mean = valid.isEmpty ? 0 : valid.reduce(0, +) / Double(valid.count)
        let med = valid.isEmpty ? 0 : Self.median(valid)
        let minV = valid.min() ?? 0
        let maxV = valid.max() ?? 0
        let std = Self.standardDeviation(valid)
        let applied = abs(calibrationOffsetMilliseconds) > 0.000_1
        let stable = valid.count >= 3 && std <= stabilityThresholdMilliseconds
        return MeasurementSnapshot(
            currentOffsetMilliseconds: current,
            meanMilliseconds: mean,
            medianMilliseconds: med,
            minMilliseconds: minV,
            maxMilliseconds: maxV,
            standardDeviationMilliseconds: std,
            validCount: valid.count,
            rejectedCount: rejectedUnpaired + rawSamples.filter(\.isOutlier).count,
            outlierCount: rawSamples.filter(\.isOutlier).count,
            isStable: stable,
            calibrationOffsetMilliseconds: calibrationOffsetMilliseconds,
            calibrationApplied: applied,
            recentValidSamples: recentValidSamples(),
            walkMsPerEvent: Self.walkMsPerEvent(valid)
        )
    }

    /// Ordinary-least-squares slope of offset vs index, milliseconds per event.
    /// A constant delay must be ≪ 1 ms/event. Nil if n < 8.
    static func walkMsPerEvent(_ offsets: [Double]) -> Double? {
        guard offsets.count >= 8 else { return nil }
        let n = Double(offsets.count)
        let sumX = (n - 1) * n / 2
        let sumXX = (n - 1) * n * (2 * n - 1) / 6
        let sumY = offsets.reduce(0, +)
        var sumXY = 0.0
        for (i, y) in offsets.enumerated() {
            sumXY += Double(i) * y
        }
        let det = n * sumXX - sumX * sumX
        guard abs(det) > 1e-12 else { return nil }
        return (n * sumXY - sumX * sumY) / det
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return sqrt(variance)
    }
}
