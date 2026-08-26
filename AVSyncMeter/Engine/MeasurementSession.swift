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
    let captureClock = CaptureClock()

    @Published var runState: RunState = .idle
    @Published var snapshot: MeasurementSnapshot = .empty
    @Published var lastSample: SyncSample?
    @Published var liveLuminance: Double = 0
    @Published var liveAudioLevel: Double = 0
    let meterHistory = MeterHistory()
    @Published var captureError: String?
    @Published var statusNote: String = "Idle"
    @Published var diagnostics: [DiagnosticEvent] = []
    @Published var clockSnapshot: ClockSnapshot = .empty

    private var cancellables = Set<AnyCancellable>()
    private let measureQueue = DispatchQueue(label: "com.guycochran.avsyncmeter.measure")

    init(settings: AppSettings = .shared) {
        self.settings = settings
        applySettingsToEngine()
        capture.setProgramFrameRate(settings.frameRate)
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

        capture.onVideoBuffer = { [weak self] buffer, _ in
            self?.handleVideo(buffer)
        }
        capture.onAudioBuffer = { [weak self] buffer, _ in
            self?.handleAudio(buffer)
        }
    }

    func startMeasurement() {
        applySettingsToEngine()
        capture.setProgramFrameRate(settings.frameRate)
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
            captureClock.reset()
        }
        lastSample = nil
        snapshot = engine.snapshot()
        clockSnapshot = .empty
        diagnostics = []
        meterHistory.reset()
        statusNote = runState == .idle ? "Reset" : "LISTENING"
    }

    func applySettingsToEngine() {
        flashDetector.configuration.regionFraction = settings.regionFraction
        flashDetector.configuration.sensitivity = settings.flashSensitivity
        flashDetector.configuration.manualThreshold = settings.manualVisualThreshold
        pulseDetector.configuration.sensitivity = settings.audioSensitivity
        pulseDetector.configuration.manualThreshold = settings.manualAudioThreshold
        engine.configuration.pairingWindowSeconds = settings.pairingWindowSeconds
        engine.configuration.maxPairOffsetSeconds = settings.pairingWindowSeconds
        engine.configuration.calibrationOffsetMilliseconds = settings.calibrationOffsetMilliseconds
        engine.configuration.stabilityThresholdMilliseconds = settings.stabilityThresholdMilliseconds
        engine.configuration.outlierMADMultiplier = settings.outlierMADMultiplier
        capture.setProgramFrameRate(settings.frameRate)
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
        if let ms = snap.correctedMedianMilliseconds {
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
        guard let image = CMSampleBufferGetImageBuffer(buffer) else { return }
        let pts = CaptureManager.hostMappedPTS(sampleBuffer: buffer, session: capture.session)
            ?? CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
        guard pts.isFinite else { return }
        measureQueue.async { [weak self] in
            guard let self else { return }
            // Session-mapped PTS is already host time. Do not fit against
            // callback hostNow — that double map jitters the slope.
            let unified = self.captureClock.observe(stream: .video, ptsSeconds: pts, hostSeconds: pts)
            var marks: [(kind: MeterHistory.MarkKind, t: Double)] = []
            if let flash = self.flashDetector.processPixelBuffer(image, timestampSeconds: unified) {
                if self.captureClock.acceptDetectedEvent(stream: .video) {
                    // EVT FLASH = engine ingest, not a VU envelope tick.
                    if let sample = self.engine.ingestFlash(flash) {
                        marks.append((.flash, flash.timestampSeconds))
                        marks.append((.pair, sample.audioTimestampSeconds))
                    } else {
                        marks.append((.flash, flash.timestampSeconds))
                    }
                } else {
                    self.engine.noteHeldForClock(flash: flash, pulse: nil)
                }
            }
            let luma = self.flashDetector.lastLuminance
            self.publishEngine(luminance: luma, sampleTime: unified, marks: marks)
        }
    }

    private func handleAudio(_ buffer: CMSampleBuffer) {
        let pts = CaptureManager.hostMappedPTS(sampleBuffer: buffer, session: capture.session)
            ?? CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
        guard pts.isFinite else { return }
        measureQueue.async { [weak self] in
            guard let self else { return }
            let unifiedStart = self.captureClock.observe(stream: .audio, ptsSeconds: pts, hostSeconds: pts)
            var marks: [(kind: MeterHistory.MarkKind, t: Double)] = []
            if let pulse = self.pulseDetector.processSampleBuffer(buffer, bufferStartOverride: unifiedStart) {
                if self.captureClock.acceptDetectedEvent(stream: .audio) {
                    // EVT AUDIOPULSE = engine ingest (same unified time as pairing).
                    // Detector-fire without ingest used to paint blue marks from
                    // wall-clock while flashes expired unpaired 3 s later.
                    if let sample = self.engine.ingestPulse(pulse) {
                        marks.append((.audioPulse, pulse.timestampSeconds))
                        marks.append((.pair, sample.audioTimestampSeconds))
                    } else {
                        marks.append((.audioPulse, pulse.timestampSeconds))
                    }
                } else {
                    self.engine.noteHeldForClock(flash: nil, pulse: pulse)
                }
            }
            let level = self.pulseDetector.lastEnvelope
            self.publishEngine(audioLevel: level, sampleTime: unifiedStart, marks: marks)
        }
    }

    private func publishEngine(
        luminance: Double? = nil,
        audioLevel: Double? = nil,
        sampleTime: Double? = nil,
        marks: [(kind: MeterHistory.MarkKind, t: Double)] = []
    ) {
        let snap = engine.snapshot()
        let last = engine.statistics.rawSamples.last
        let logs = engine.diagnostics
        let clock = captureClock.snapshot()
        DispatchQueue.main.async {
            self.snapshot = snap
            self.lastSample = last
            self.diagnostics = logs
            self.clockSnapshot = clock
            // CaptureClock unified seconds — the same domain pairing uses.
            // Wall-clock (CFAbsoluteTimeGetCurrent) made 1 Hz LUMA+MIC look
            // aligned on the strip while |unified dt| outside the pairing window never paired.
            if let luminance, let sampleTime {
                self.liveLuminance = luminance
                self.meterHistory.appendLuma(t: sampleTime, value: luminance)
            }
            if let audioLevel, let sampleTime {
                self.liveAudioLevel = audioLevel
                self.meterHistory.appendMic(t: sampleTime, value: MeterHistory.displayMicLevel(audioLevel))
            }
            for mark in marks {
                self.meterHistory.appendMark(t: mark.t, kind: mark.kind)
            }
            if !clock.settled && self.runState != .idle && snap.validCount == 0 {
                self.statusNote = "CLOCK SETTLING"
            } else if snap.validCount > 0 {
                self.runState = .measuring
                if let ms = snap.correctedMedianMilliseconds {
                    self.statusNote = Self.headline(ms)
                }
            }
        }
    }

    static func headline(_ offsetMs: Double) -> String {
        SyncSignConvention.headline(offsetMs)
    }
}
