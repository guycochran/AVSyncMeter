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
/// Timestamps are unified capture times (host-mapped via CaptureClock), in seconds.
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
    /// Unified timestamp of the detected flash edge, seconds.
    let timestampSeconds: Double
    let luminance: Double
    let threshold: Double
}

struct AudioPulseEvent: Equatable {
    /// Unified timestamp of the pulse onset (buffer start + sample offset), seconds.
    let timestampSeconds: Double
    let envelope: Double
    let threshold: Double
    /// How long the burst stayed up. Harkwood measured ~66.7 ms 3 kHz (2 frames), not a 10–20 ms click. Speech is overlapping/ongoing.
    var durationSeconds: Double = 0.016
    /// 0...1. High = sharp/high-band (1 kHz beep / click). Low = dull onset.
    var sharpness: Double = 1.0
    /// Short sharp transient, not sustained voice. Default true so injected
    /// test pulses keep pairing like a house beep.
    var isBeepLike: Bool = true

    /// Isolated house hit must pair even when the old isBeepLike
    /// duration gate was false. Harkwood is 1001 ms / 66.7 ms 3 kHz,
    /// not a 1.000 Hz click. A periodic tone (sharp, including 66.7 ms
    /// or 200–400 ms) is not speech. Speech is overlapping/ongoing
    /// (low sharpness, long dull energy), not a once-per-second spike.
    var isPairable: Bool {
        if isBeepLike { return true }
        if sharpness >= 0.40 { return true }
        return durationSeconds >= 0.001 && durationSeconds <= 0.085
    }

    static func beepLike(timestampSeconds: Double, envelope: Double = 0.85, threshold: Double = 0.1) -> AudioPulseEvent {
        AudioPulseEvent(
            timestampSeconds: timestampSeconds,
            envelope: envelope,
            threshold: threshold,
            durationSeconds: 0.016,
            sharpness: 0.9,
            isBeepLike: true
        )
    }

    static func voiceLike(timestampSeconds: Double, envelope: Double = 0.45, threshold: Double = 0.1) -> AudioPulseEvent {
        AudioPulseEvent(
            timestampSeconds: timestampSeconds,
            envelope: envelope,
            threshold: threshold,
            durationSeconds: 0.12,
            sharpness: 0.12,
            isBeepLike: false
        )
    }
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
        case clockSettling
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
    /// Linear slope of valid offsets vs event index (ms per beep). Nil if fewer than 8 valid.
    /// A constant delay must sit near 0. ~1 ms/beep is a walking meter, not a house change.
    var walkMsPerEvent: Double?

    static let walkFlatLimitMsPerEvent = 0.2
    /// A few ms. Guy's −23 to −55 step had SPAN 32 with WALK +0.06 — that is not green.
    static let walkSpanTightLimitMilliseconds = 8.0

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

    /// max-min of valid samples. 0 when empty (UI shows em dash via validCount).
    var spanMilliseconds: Double {
        guard validCount > 0 else { return 0 }
        return maxMilliseconds - minMilliseconds
    }

    /// WALK badge is green only if the slope is flat AND the span is tight.
    /// |walk|<0.2 with SPAN 32 (stepped clusters that cancel) must not look green.
    var walkLooksStable: Bool {
        guard let walk = walkMsPerEvent, validCount >= 8 else { return false }
        return abs(walk) < Self.walkFlatLimitMsPerEvent
            && spanMilliseconds <= Self.walkSpanTightLimitMilliseconds
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
        recentValidSamples: [],
        walkMsPerEvent: nil
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
