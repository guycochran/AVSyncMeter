import Foundation

/// Sign convention used throughout AV Sync Meter.
///
///     offsetMilliseconds = audioTimestamp - videoTimestamp
///
/// - AUDIO EARLY: sound arrives before picture → **positive** offset.
///   Recommended Mitti Audio Delay = +offset ms (delay the audio to wait for picture).
/// - AUDIO LATE: picture arrives before sound → **negative** offset.
///   Reduce existing Mitti audio delay by |offset| ms (or delay video if audio delay is already 0).
///
/// Timestamps are media/presentation times from a single AVCaptureSession, in seconds.
enum SyncSignConvention {
    static let documentation = """
    offsetMilliseconds = audioTimestamp - videoTimestamp
    AUDIO EARLY (positive): sound before picture → Mitti Audio Delay = +offset ms
    AUDIO LATE (negative): picture before sound → reduce audio delay by |offset| ms
    """
}

enum SyncDirection: Equatable {
    case audioEarly
    case inSync
    case audioLate

    var headline: String {
        switch self {
        case .audioEarly: return "AUDIO EARLY"
        case .inSync: return "IN SYNC"
        case .audioLate: return "AUDIO LATE"
        }
    }
}

struct VisualFlashEvent: Equatable {
    /// Media timestamp of the detected flash edge, seconds.
    let timestampSeconds: Double
    let luminance: Double
    let threshold: Double
}

struct AudioPulseEvent: Equatable {
    /// Media timestamp of the pulse onset (buffer PTS + sample offset), seconds.
    let timestampSeconds: Double
    let envelope: Double
    let threshold: Double
}

struct SyncSample: Equatable, Identifiable {
    let id: UUID
    let videoTimestampSeconds: Double
    let audioTimestampSeconds: Double
    /// audioTimestamp - videoTimestamp, in milliseconds. See SyncSignConvention.
    let offsetMilliseconds: Double
    let videoLuminance: Double
    let visualThreshold: Double
    let audioEnvelope: Double
    let audioThreshold: Double
    let isOutlier: Bool
    let pairedAt: Date

    var direction: SyncDirection {
        if abs(offsetMilliseconds) < 0.5 { return .inSync }
        return offsetMilliseconds > 0 ? .audioEarly : .audioLate
    }
}

struct DiagnosticEvent: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case flash
        case audioPulse
        case paired
        case rejectedUnpaired
        case rejectedOutlier
        case rejectedExtraPulse
        case rejectedExtraFlash
    }

    let id: UUID
    let kind: Kind
    let message: String
    let videoPTS: Double?
    let audioPTS: Double?
    let offsetMilliseconds: Double?
    let luminance: Double?
    let visualThreshold: Double?
    let audioEnvelope: Double?
    let audioThreshold: Double?
    let captureFPS: Double?
}

struct MeasurementSnapshot: Equatable {
    var currentOffsetMilliseconds: Double?
    var meanMilliseconds: Double
    var medianMilliseconds: Double
    var minMilliseconds: Double
    var maxMilliseconds: Double
    var standardDeviationMilliseconds: Double
    var validCount: Int
    var rejectedCount: Int
    var outlierCount: Int
    var isStable: Bool
    var calibrationOffsetMilliseconds: Double
    var calibrationApplied: Bool
    /// Last 25 valid (non-outlier) pairs, newest first. Offsets are still raw (uncorrected).
    var recentValidSamples: [SyncSample]

    /// Last valid pair minus calibration. Table/debug only — not the main headline.
    var correctedCurrentMilliseconds: Double? {
        guard let current = currentOffsetMilliseconds else { return nil }
        return current - calibrationOffsetMilliseconds
    }

    /// Median of valid samples minus calibration. Same sign convention as the raw offset.
    /// Nil when validCount == 0 so the UI stays LISTENING / no pairs.
    var correctedMedianMilliseconds: Double? {
        guard validCount > 0 else { return nil }
        return medianMilliseconds - calibrationOffsetMilliseconds
    }

    static let empty = MeasurementSnapshot(
        currentOffsetMilliseconds: nil,
        meanMilliseconds: 0,
        medianMilliseconds: 0,
        minMilliseconds: 0,
        maxMilliseconds: 0,
        standardDeviationMilliseconds: 0,
        validCount: 0,
        rejectedCount: 0,
        outlierCount: 0,
        isStable: false,
        calibrationOffsetMilliseconds: 0,
        calibrationApplied: false,
        recentValidSamples: []
    )
}

/// Mid-show zero / known-true calibration.
/// `calibrationOffset = measuredOffset − knownTrueOffset`
/// then `correctedOffset = measuredOffset − calibrationOffset`.
enum CalibrationMath {
    static func calibrationOffset(measuredOffset: Double, knownTrueOffset: Double = 0) -> Double {
        measuredOffset - knownTrueOffset
    }

    /// Prefer median of valid samples when `validCount >= 1`, else the current pair.
    /// Returns nil when there is nothing to zero — callers must not write 0 silently.
    static func measuredOffsetForZero(
        validCount: Int,
        medianMilliseconds: Double,
        currentOffsetMilliseconds: Double?
    ) -> Double? {
        if validCount >= 1 {
            return medianMilliseconds
        }
        return currentOffsetMilliseconds
    }
}
