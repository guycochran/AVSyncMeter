import Foundation

/// User-tunable detection and display settings. Persisted locally. No network.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var frameRate: FrameRate {
        didSet { defaults.set(frameRate.rawValue, forKey: Keys.frameRate) }
    }

    /// Fraction of frame width/height used as the central flash region (0.1 ... 0.9).
    @Published var regionFraction: Double {
        didSet { defaults.set(regionFraction, forKey: Keys.regionFraction) }
    }

    /// Flash sensitivity 0...1 (higher = easier to trigger).
    @Published var flashSensitivity: Double {
        didSet { defaults.set(flashSensitivity, forKey: Keys.flashSensitivity) }
    }

    /// Audio sensitivity 0...1 (higher = easier to trigger).
    @Published var audioSensitivity: Double {
        didSet { defaults.set(audioSensitivity, forKey: Keys.audioSensitivity) }
    }

    /// Pairing search window, seconds. Default ±1.00 s (LED processor + Mitti delay).
    @Published var pairingWindowSeconds: Double {
        didSet { defaults.set(pairingWindowSeconds, forKey: Keys.pairingWindow) }
    }

    /// Optional manual luminance-delta threshold. nil = automatic from sensitivity.
    @Published var manualVisualThreshold: Double? {
        didSet { persistOptional(manualVisualThreshold, key: Keys.manualVisual) }
    }

    /// Optional manual audio-envelope threshold. nil = automatic from sensitivity.
    @Published var manualAudioThreshold: Double? {
        didSet { persistOptional(manualAudioThreshold, key: Keys.manualAudio) }
    }

    /// Known correction subtracted from the measured offset. Default is 0 ms.
    /// A stored 0 is "no correction applied", not "sensor latency is zero".
    @Published var calibrationOffsetMilliseconds: Double {
        didSet { defaults.set(calibrationOffsetMilliseconds, forKey: Keys.calibration) }
    }

    /// Previous calibrationOffset, for a single Undo after Zero / Set true / Clear.
    @Published var previousCalibrationOffsetMilliseconds: Double {
        didSet { defaults.set(previousCalibrationOffsetMilliseconds, forKey: Keys.previousCalibration) }
    }

    /// Variation (stddev) below this many milliseconds is reported as SYNC STABLE.
    @Published var stabilityThresholdMilliseconds: Double {
        didSet { defaults.set(stabilityThresholdMilliseconds, forKey: Keys.stability) }
    }

    /// MAD outlier k. Samples farther than k * 1.4826 * MAD from the median are outliers.
    @Published var outlierMADMultiplier: Double {
        didSet { defaults.set(outlierMADMultiplier, forKey: Keys.outlierK) }
    }

    /// Informational speed-of-sound helper. Off by default; does not alter measurements.
    @Published var showDistanceHelper: Bool {
        didSet { defaults.set(showDistanceHelper, forKey: Keys.distanceHelper) }
    }

    /// Measure-screen LUMA+MIC history window, seconds. 1...90, default 90.
    @Published var meterHistorySeconds: Double {
        didSet { defaults.set(MeterHistory.clampedWindow(meterHistorySeconds), forKey: Keys.meterHistory) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let frameRate = "avs.frameRate"
        static let regionFraction = "avs.regionFraction"
        static let flashSensitivity = "avs.flashSensitivity"
        static let audioSensitivity = "avs.audioSensitivity"
        static let pairingWindow = "avs.pairWindowSec"
        static let manualVisual = "avs.manualVisual"
        static let manualAudio = "avs.manualAudio"
        static let calibration = "avs.calibration"
        static let previousCalibration = "avs.previousCalibration"
        static let stability = "avs.stability"
        static let outlierK = "avs.outlierK"
        static let distanceHelper = "avs.distanceHelper"
        static let meterHistory = "avs.meterHistorySec"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedRate = defaults.string(forKey: Keys.frameRate) ?? FrameRate.fps2997.rawValue
        frameRate = FrameRate(rawValue: storedRate) ?? .fps2997
        regionFraction = defaults.object(forKey: Keys.regionFraction) as? Double ?? 0.35
        flashSensitivity = defaults.object(forKey: Keys.flashSensitivity) as? Double ?? 0.65
        audioSensitivity = defaults.object(forKey: Keys.audioSensitivity) as? Double ?? 0.65
        let storedPair = defaults.object(forKey: Keys.pairingWindow) as? Double
        if storedPair == nil || abs((storedPair ?? 0) - 0.40) < 1e-9 {
            pairingWindowSeconds = 1.00
        } else {
            pairingWindowSeconds = storedPair!
        }
        if defaults.object(forKey: Keys.manualVisual) != nil {
            manualVisualThreshold = defaults.double(forKey: Keys.manualVisual)
        } else {
            manualVisualThreshold = nil
        }
        if defaults.object(forKey: Keys.manualAudio) != nil {
            manualAudioThreshold = defaults.double(forKey: Keys.manualAudio)
        } else {
            manualAudioThreshold = nil
        }
        calibrationOffsetMilliseconds = defaults.object(forKey: Keys.calibration) as? Double ?? 0
        previousCalibrationOffsetMilliseconds = defaults.object(forKey: Keys.previousCalibration) as? Double ?? 0
        stabilityThresholdMilliseconds = defaults.object(forKey: Keys.stability) as? Double ?? 8
        outlierMADMultiplier = defaults.object(forKey: Keys.outlierK) as? Double ?? 3.5
        showDistanceHelper = defaults.bool(forKey: Keys.distanceHelper)
        if defaults.object(forKey: Keys.meterHistory) != nil {
            meterHistorySeconds = MeterHistory.clampedWindow(defaults.double(forKey: Keys.meterHistory))
        } else {
            meterHistorySeconds = MeterHistory.defaultWindowSeconds
        }
    }

    private func persistOptional(_ value: Double?, key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
