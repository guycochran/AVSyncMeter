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
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.applyMeteringLock()
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
        session.sessionPreset = .high

        guard let camera = Self.bestCamera() else {
            session.commitConfiguration()
            throw CaptureError.noCamera
        }
        self.videoDevice = camera
        Self.lockFrameRateIfPossible(camera)
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

    private static func lockFrameRateIfPossible(_ camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            let ranges = camera.activeFormat.videoSupportedFrameRateRanges
            if ranges.contains(where: { $0.maxFrameRate >= 59.0 }) {
                camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
                camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
            }
            // Converge on the screen first; applyMeteringLock freezes AE/AWB/AF
            // once the session is running so a flash cannot pump exposure.
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

    /// Freeze AE / AWB / AF while measuring. A flash that pumps auto-exposure
    /// recovers as a second luma rise ~150 ms later and steals the next pulse.
    func lockMeteringWhileMeasuring() {
        sessionQueue.async { [weak self] in
            self?.applyMeteringLock()
        }
    }

    private func applyMeteringLock() {
        guard let camera = videoDevice else { return }
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if camera.isFocusModeSupported(.locked) {
                camera.focusMode = .locked
            }
            if camera.isExposureModeSupported(.locked) {
                camera.exposureMode = .locked
            }
            if camera.isWhiteBalanceModeSupported(.locked) {
                camera.whiteBalanceMode = .locked
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
            // Metering lock is best-effort; measurement still runs.
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
