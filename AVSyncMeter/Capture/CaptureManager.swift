import AVFoundation
import Foundation

/// Single AVCaptureSession delivering synchronized video + audio sample buffers.
///
/// Timing rule: detectors never see Date() or UI timestamps. Each buffer's
/// presentation timestamp is converted onto the session master clock → host
/// clock (`hostMappedPTS`). That mapped PTS *is* the unified time. Do not
/// slope-fit it against `hostNowSeconds()` (callback arrival jitter).
final class CaptureManager: NSObject, ObservableObject {
    enum CaptureError: LocalizedError {
        case cameraDenied
        case microphoneDenied
        case noCamera
        case cannotAddInputs
        case cannotAddOutputs

        var errorDescription: String? {
            switch self {
            case .cameraDenied: return "Camera permission denied. Enable it in Settings."
            case .microphoneDenied: return "Microphone permission denied. Enable it in Settings."
            case .noCamera: return "No camera is available on this device (simulator has no usable camera)."
            case .cannotAddInputs: return "Could not attach camera or microphone to the capture session."
            case .cannotAddOutputs: return "Could not attach video/audio data outputs."
            }
        }
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.guycochran.avsyncmeter.capture")
    private let outputQueue = DispatchQueue(label: "com.guycochran.avsyncmeter.buffers")

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var configured = false
    private var videoDevice: AVCaptureDevice?

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var observedVideoFPS: Double = 0

    /// Program picker. NTSC 29.97/59.94 locks capture to 60_000/1001 (or 30_000/1001);
    /// integer 30/60 keeps 1/60 or 1/30. Default matches AppSettings (29.97).
    var programFrameRate: FrameRate = .fps2997

    var onVideoBuffer: ((CMSampleBuffer, AVCaptureConnection) -> Void)?
    var onAudioBuffer: ((CMSampleBuffer, AVCaptureConnection) -> Void)?

    private var videoFrameTimes: [Double] = []

    func requestPermissionsAndStart() {
        Task { @MainActor in
            let cam = await AVCaptureDevice.requestAccess(for: .video)
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            if !cam {
                self.lastError = CaptureError.cameraDenied.localizedDescription
                return
            }
            if !mic {
                self.lastError = CaptureError.microphoneDenied.localizedDescription
                return
            }
            self.start()
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureIfNeeded()
                if let camera = self.videoDevice {
                    self.session.beginConfiguration()
                    Self.lockFrameRateIfPossible(camera, program: self.programFrameRate)
                    self.session.commitConfiguration()
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.applyFocusLockLeavingExposureOpen()
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.lastError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    private func configureIfNeeded() throws {
        if configured { return }
        session.beginConfiguration()
        // inputPriority so NTSC 1001 lock can pick a format; .high was snapping to 1/30.
        session.sessionPreset = .inputPriority

        guard let camera = Self.bestCamera() else {
            session.commitConfiguration()
            throw CaptureError.noCamera
        }
        self.videoDevice = camera
        Self.lockFrameRateIfPossible(camera, program: programFrameRate)
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(cameraInput) else {
            session.commitConfiguration()
            throw CaptureError.cannotAddInputs
        }
        session.addInput(cameraInput)

        if let mic = AVCaptureDevice.default(for: .audio) {
            let micInput = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(micInput) {
                session.addInput(micInput)
            } else {
                session.commitConfiguration()
                throw CaptureError.cannotAddInputs
            }
        } else {
            session.commitConfiguration()
            throw CaptureError.cannotAddInputs
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw CaptureError.cannotAddOutputs
        }
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        // AVCaptureAudioDataOutput.audioSettings is macOS-only. Parse whatever
        // Linear PCM iOS delivers (AudioPulseDetector.parseMono).
        audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(audioOutput) else {
            session.commitConfiguration()
            throw CaptureError.cannotAddOutputs
        }
        session.addOutput(audioOutput)

        session.commitConfiguration()
        configured = true
    }

    /// Re-apply the picker-matching duration if the session is already configured.
    func setProgramFrameRate(_ rate: FrameRate) {
        programFrameRate = rate
        sessionQueue.async { [weak self] in
            guard let self, let camera = self.videoDevice else { return }
            self.session.beginConfiguration()
            Self.lockFrameRateIfPossible(camera, program: rate)
            self.session.commitConfiguration()
        }
    }

    /// Lock capture to the NTSC 1001 family when the program picker is 29.97/59.94.
    /// Probe every format's CMTime endpoints; prefer 60_000/1001 then 30_000/1001.
    /// Do not silently fall through to 1/30 or 1/60. Read back; if it snapped to
    /// integer, try the next format. Footer shows NTSC lock MISS from observed fps.
    /// Keep AE continuous — locking exposure kills FLASH.
    private static func lockFrameRateIfPossible(_ camera: AVCaptureDevice, program: FrameRate) {
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            let probes = probeFormats(camera)
            if program.isNTSCFamily {
                _ = applyNTSCLock(camera, probes: probes, program: program)
            } else if let choice = CaptureFrameDuration.selectLock(program: program, formats: probes) {
                applyDuration(camera, formatIndex: choice.formatIndex, duration: choice.duration)
            }
            // Converge on the screen. Do not freeze AE: locking exposure on a
            // dark monitor (or mid-flash) crushes ISO so the white flash never
            // crosses the luma threshold. 400 ms holdoff swallows AE recovery.
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } catch {
            // Frame-rate lock is a preference, not a requirement.
        }
    }

    private static func probeFormats(_ camera: AVCaptureDevice) -> [CaptureFormatProbe] {
        camera.formats.map { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges.map { r in
                CaptureFrameDurationRange(
                    minDuration: CaptureFrameDuration(value: r.minFrameDuration.value, timescale: r.minFrameDuration.timescale),
                    maxDuration: CaptureFrameDuration(value: r.maxFrameDuration.value, timescale: r.maxFrameDuration.timescale)
                )
            }
            return CaptureFormatProbe(width: Int(dims.width), height: Int(dims.height), ranges: ranges)
        }
    }

    /// Try 60_000/1001 then 30_000/1001 on every format that can take them.
    /// Success = readback is 1001-family, not a silent 1/30 snap.
    @discardableResult
    private static func applyNTSCLock(_ camera: AVCaptureDevice, probes: [CaptureFormatProbe], program: FrameRate) -> Bool {
        let targets: [CaptureFrameDuration]
        switch program {
        case .fps23976:
            targets = [.ntsc60, .ntsc30, .ntsc24]
        default:
            targets = [.ntsc60, .ntsc30]
        }
        for target in targets {
            for idx in CaptureFrameDuration.rankedFormatIndices(formats: probes, containing: target) {
                applyDuration(camera, formatIndex: idx, duration: target)
                if readbackIsNTSC(camera) { return true }
            }
        }
        if let listed = CaptureFrameDuration.closestListedNTSC(program: program, formats: probes) {
            applyDuration(camera, formatIndex: listed.formatIndex, duration: listed.duration)
            if readbackIsNTSC(camera) { return true }
        }
        return false
    }

    private static func applyDuration(_ camera: AVCaptureDevice, formatIndex: Int, duration: CaptureFrameDuration) {
        guard camera.formats.indices.contains(formatIndex) else { return }
        let format = camera.formats[formatIndex]
        if camera.activeFormat !== format {
            camera.activeFormat = format
        }
        let t = CMTime(value: duration.value, timescale: duration.timescale)
        camera.activeVideoMinFrameDuration = t
        camera.activeVideoMaxFrameDuration = t
    }

    private static func readbackIsNTSC(_ camera: AVCaptureDevice) -> Bool {
        let t = camera.activeVideoMinFrameDuration
        guard t.isValid, t.isNumeric, t.seconds > 1e-9 else { return false }
        let fps = 1.0 / t.seconds
        return abs(fps - 24_000.0 / 1_001.0) < 0.02
            || abs(fps - 30_000.0 / 1_001.0) < 0.02
            || abs(fps - 60_000.0 / 1_001.0) < 0.02
    }

    /// Lock focus only. Build 7 locked AE/AWB/AF on session start; locking
    /// exposure on a dark monitor (or mid-flash) flattened luma so the flash
    /// never crossed thr ~0.124 (previous builds logged FLASH luma ~0.87).
    /// Leave AE and AWB continuous. 400 ms video holdoff already swallows the
    /// AE-recovery double-pump that this lock was meant to prevent. HDR and
    /// low-light boost stay off so the ISP does not compress the flash.
    func lockFocusWhileMeasuring() {
        sessionQueue.async { [weak self] in
            self?.applyFocusLockLeavingExposureOpen()
        }
    }

    private func applyFocusLockLeavingExposureOpen() {
        guard let camera = videoDevice else { return }
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if camera.isFocusModeSupported(.locked) {
                camera.focusMode = .locked
            }
            // Do not lock exposure. Continuous AE keeps flash contrast.
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            camera.isSubjectAreaChangeMonitoringEnabled = false
            if camera.isLowLightBoostSupported {
                camera.automaticallyEnablesLowLightBoostWhenAvailable = false
            }
            if camera.activeFormat.isVideoHDRSupported {
                camera.automaticallyAdjustsVideoHDREnabled = false
                if camera.isVideoHDREnabled {
                    camera.isVideoHDREnabled = false
                }
            }
        } catch {
            // Focus lock is best-effort; measurement still runs.
        }
    }

    private static func bestCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTripleCamera, .builtInDualWideCamera],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    /// Convert a sample buffer PTS onto the host clock using the session master clock.
    static func hostMappedPTS(sampleBuffer: CMSampleBuffer, session: AVCaptureSession) -> Double? {
        let raw = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let output = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
        let pts = (output.isValid && output.isNumeric) ? output : raw
        guard pts.isNumeric else { return nil }

        if let master = session.synchronizationClock {
            let converted = CMSyncConvertTime(pts, from: master, to: CMClockGetHostTimeClock())
            if converted.isNumeric {
                let s = CMTimeGetSeconds(converted)
                if s.isFinite { return s }
            }
        }
        let s = CMTimeGetSeconds(pts)
        return s.isFinite ? s : nil
    }

    /// Callback arrival on the host clock. Must not be the CaptureClock slope
    /// fit target — that is the double-map that walked unlocked hits.
    static func hostNowSeconds() -> Double {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }
}

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            if pts.isFinite {
                videoFrameTimes.append(pts)
                if videoFrameTimes.count >= 16 {
                    let span = videoFrameTimes.last! - videoFrameTimes.first!
                    if span > 0 {
                        let fps = Double(videoFrameTimes.count - 1) / span
                        DispatchQueue.main.async { self.observedVideoFPS = fps }
                    }
                    videoFrameTimes.removeAll(keepingCapacity: true)
                }
            }
            onVideoBuffer?(sampleBuffer, connection)
        } else if output === audioOutput {
            onAudioBuffer?(sampleBuffer, connection)
        }
    }
}
