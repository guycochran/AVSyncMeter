import AVFoundation
import Foundation

/// Single AVCaptureSession delivering synchronized video + audio sample buffers.
///
/// Timing rule: every detection uses the buffer's presentation timestamp
/// (`CMSampleBufferGetPresentationTimeStamp`). Date(), UI timestamps, and
/// independent timers are not used for measurement.
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

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var observedVideoFPS: Double = 0

    var onVideoBuffer: ((CMSampleBuffer) -> Void)?
    var onAudioBuffer: ((CMSampleBuffer) -> Void)?

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

        audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(audioOutput) else {
            session.commitConfiguration()
            throw CaptureError.cannotAddOutputs
        }
        session.addOutput(audioOutput)

        session.commitConfiguration()
        configured = true
    }

    private static func bestCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTripleCamera, .builtInDualWideCamera],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
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
            onVideoBuffer?(sampleBuffer)
        } else if output === audioOutput {
            onAudioBuffer?(sampleBuffer)
        }
    }
}
