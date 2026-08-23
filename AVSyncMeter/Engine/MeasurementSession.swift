import Foundation
import AVFoundation
import Combine

/// Owns capture, detectors, and the measurement engine. SwiftUI observes this object.
/// The raw measurement engine stays independent of SwiftUI.
final class MeasurementSession: ObservableObject {
    enum RunState: String {
        case idle
        case listening
        case measuring
    }

    let settings: AppSettings
    let capture = CaptureManager()
    let flashDetector = VideoFlashDetector()
    let pulseDetector = AudioPulseDetector()
    let engine = SyncMeasurementEngine()

    @Published var runState: RunState = .idle
    @Published var snapshot: MeasurementSnapshot = .empty
    @Published var lastSample: SyncSample?
    @Published var liveLuminance: Double = 0
    @Published var liveAudioLevel: Double = 0
    @Published var captureError: String?
    @Published var statusNote: String = "Idle"
    @Published var diagnostics: [DiagnosticEvent] = []

    private var cancellables = Set<AnyCancellable>()
    private let measureQueue = DispatchQueue(label: "com.guycochran.avsyncmeter.measure")

    init(settings: AppSettings = .shared) {
        self.settings = settings
        applySettingsToEngine()
        capture.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in self?.captureError = err }
            .store(in: &cancellables)
        capture.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                guard let self else { return }
                if running && self.runState == .idle {
                    self.runState = .listening
                    self.statusNote = "LISTENING"
                }
            }
            .store(in: &cancellables)

        capture.onVideoBuffer = { [weak self] buffer in
            self?.handleVideo(buffer)
        }
        capture.onAudioBuffer = { [weak self] buffer in
            self?.handleAudio(buffer)
        }
    }

    func startMeasurement() {
        applySettingsToEngine()
        statusNote = "LISTENING"
        runState = .listening
        captureError = nil
        capture.requestPermissionsAndStart()
    }

    func stopMeasurement() {
        capture.stop()
        runState = .idle
        statusNote = "Stopped"
    }

    func reset() {
        measureQueue.sync {
            engine.reset()
            flashDetector.reset()
            pulseDetector.reset()
        }
        lastSample = nil
        snapshot = engine.snapshot()
        diagnostics = []
        statusNote = runState == .idle ? "Reset" : "LISTENING"
    }

    func applySettingsToEngine() {
        flashDetector.configuration.regionFraction = settings.regionFraction
        flashDetector.configuration.sensitivity = settings.flashSensitivity
        flashDetector.configuration.manualThreshold = settings.manualVisualThreshold
        pulseDetector.configuration.sensitivity = settings.audioSensitivity
        pulseDetector.configuration.manualThreshold = settings.manualAudioThreshold
        engine.configuration.pairingWindowSeconds = settings.pairingWindowSeconds
        engine.configuration.calibrationOffsetMilliseconds = settings.calibrationOffsetMilliseconds
        engine.configuration.stabilityThresholdMilliseconds = settings.stabilityThresholdMilliseconds
        engine.configuration.outlierMADMultiplier = settings.outlierMADMultiplier
    }

    /// Raw measured offset used for Zero / Set true: median of valid samples if any, else current pair.
    func measuredOffsetForCalibration() -> Double? {
        let snap = engine.snapshot()
        return CalibrationMath.measuredOffsetForZero(
            validCount: snap.validCount,
            medianMilliseconds: snap.medianMilliseconds,
            currentOffsetMilliseconds: snap.currentOffsetMilliseconds
        )
    }

    enum CalibrationActionResult: Equatable {
        case applied(measured: Double, stored: Double, knownTrue: Double)
        case noMeasurement
        case nothingToUndo
    }

    /// Treat the current reading as `knownTrueOffset` (0 = “this is actually 0”).
    /// Stores `calibrationOffset = measured − knownTrue`. Does not write 0 when there is no pair.
    @discardableResult
    func applyCalibrationZero(knownTrueOffset: Double = 0) -> CalibrationActionResult {
        guard let measured = measuredOffsetForCalibration() else {
            return .noMeasurement
        }
        let stored = CalibrationMath.calibrationOffset(measuredOffset: measured, knownTrueOffset: knownTrueOffset)
        settings.previousCalibrationOffsetMilliseconds = settings.calibrationOffsetMilliseconds
        settings.calibrationOffsetMilliseconds = stored
        applySettingsToEngine()
        publishSnapshotNow()
        return .applied(measured: measured, stored: stored, knownTrue: knownTrueOffset)
    }

    @discardableResult
    func clearCalibration() -> CalibrationActionResult {
        let measured = measuredOffsetForCalibration() ?? 0
        settings.previousCalibrationOffsetMilliseconds = settings.calibrationOffsetMilliseconds
        settings.calibrationOffsetMilliseconds = 0
        applySettingsToEngine()
        publishSnapshotNow()
        return .applied(measured: measured, stored: 0, knownTrue: measured)
    }

    @discardableResult
    func undoLastCalibration() -> CalibrationActionResult {
        let previous = settings.previousCalibrationOffsetMilliseconds
        let current = settings.calibrationOffsetMilliseconds
        if abs(previous - current) < 0.000_1 {
            return .nothingToUndo
        }
        settings.previousCalibrationOffsetMilliseconds = current
        settings.calibrationOffsetMilliseconds = previous
        applySettingsToEngine()
        publishSnapshotNow()
        let measured = measuredOffsetForCalibration() ?? 0
        return .applied(measured: measured, stored: previous, knownTrue: measured - previous)
    }

    private func publishSnapshotNow() {
        let snap = engine.snapshot()
        snapshot = snap
        if let ms = snap.correctedCurrentMilliseconds {
            statusNote = Self.headline(ms)
        }
    }

    /// Inject synthetic events (UI demo / tests). Uses the same pairing path as live capture.
    func injectSynthetic(videoSeconds: Double, audioSeconds: Double, luminance: Double = 0.9, envelope: Double = 0.4) {
        applySettingsToEngine()
        measureQueue.async { [weak self] in
            guard let self else { return }
            _ = self.engine.ingestFlash(VisualFlashEvent(timestampSeconds: videoSeconds, luminance: luminance, threshold: 0.1))
            _ = self.engine.ingestPulse(AudioPulseEvent(timestampSeconds: audioSeconds, envelope: envelope, threshold: 0.1))
            self.publishEngine()
        }
    }

    private func handleVideo(_ buffer: CMSampleBuffer) {
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
        guard pts.isFinite, let image = CMSampleBufferGetImageBuffer(buffer) else { return }
        measureQueue.async { [weak self] in
            guard let self else { return }
            if let flash = self.flashDetector.processPixelBuffer(image, timestampSeconds: pts) {
                _ = self.engine.ingestFlash(flash)
            }
            let luma = self.flashDetector.lastLuminance
            self.publishEngine(luminance: luma)
        }
    }

    private func handleAudio(_ buffer: CMSampleBuffer) {
        measureQueue.async { [weak self] in
            guard let self else { return }
            if let pulse = self.pulseDetector.processSampleBuffer(buffer) {
                _ = self.engine.ingestPulse(pulse)
            }
            let level = self.pulseDetector.lastEnvelope
            DispatchQueue.main.async {
                self.liveAudioLevel = level
            }
            self.publishEngine()
        }
    }

    private func publishEngine(luminance: Double? = nil) {
        let snap = engine.snapshot()
        let last = engine.statistics.rawSamples.last
        let logs = engine.diagnostics
        DispatchQueue.main.async {
            self.snapshot = snap
            self.lastSample = last
            self.diagnostics = logs
            if let luminance { self.liveLuminance = luminance }
            if snap.validCount > 0 {
                self.runState = .measuring
                if let ms = snap.correctedCurrentMilliseconds {
                    self.statusNote = Self.headline(ms)
                }
            }
        }
    }

    static func headline(_ offsetMs: Double) -> String {
        if abs(offsetMs) < 0.5 { return "IN SYNC" }
        return offsetMs > 0 ? "AUDIO EARLY" : "AUDIO LATE"
    }
}
