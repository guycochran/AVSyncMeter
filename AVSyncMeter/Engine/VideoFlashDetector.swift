import Foundation
import CoreVideo

/// Detects a single rapid positive luminance transition in a configurable central region.
/// No computer vision or object recognition. One flash = one event via hysteresis / re-arm.
final class VideoFlashDetector {
    struct Configuration {
        var regionFraction: Double = 0.35
        /// Sensitivity 0...1. Higher → smaller delta required.
        var sensitivity: Double = 0.65
        var manualThreshold: Double?
        /// Frames the detector stays latched after a hit so a long flash is one event.
        var holdoffFrames: Int = 8
        var baselineAlpha: Double = 0.08
    }

    var configuration: Configuration
    private(set) var lastLuminance: Double = 0
    private(set) var baseline: Double = 0
    private(set) var lastThreshold: Double = 0.12
    private var hasBaseline = false
    private var armed = true
    private var holdoffRemaining = 0
    private var previousLuminance: Double = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func reset() {
        lastLuminance = 0
        baseline = 0
        hasBaseline = false
        armed = true
        holdoffRemaining = 0
        previousLuminance = 0
    }

    func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, timestampSeconds: Double) -> VisualFlashEvent? {
        let luma = averageLuminance(in: pixelBuffer, regionFraction: configuration.regionFraction)
        return processLuminance(luma, timestampSeconds: timestampSeconds)
    }

    /// Testable path: inject a scalar luminance sample (0...1) with a media timestamp.
    @discardableResult
    func processLuminance(_ luminance: Double, timestampSeconds: Double) -> VisualFlashEvent? {
        lastLuminance = luminance
        lastThreshold = effectiveThreshold()

        if !hasBaseline {
            baseline = luminance
            previousLuminance = luminance
            hasBaseline = true
            return nil
        }

        if holdoffRemaining > 0 {
            holdoffRemaining -= 1
            baseline = baseline * (1 - configuration.baselineAlpha) + luminance * configuration.baselineAlpha
            if holdoffRemaining == 0 {
                armed = true
            }
            previousLuminance = luminance
            return nil
        }

        let rising = luminance - previousLuminance
        let aboveBaseline = luminance - baseline
        let hit = armed && rising > lastThreshold && aboveBaseline > lastThreshold * 0.6

        baseline = baseline * (1 - configuration.baselineAlpha) + luminance * configuration.baselineAlpha
        previousLuminance = luminance

        if hit {
            armed = false
            holdoffRemaining = configuration.holdoffFrames
            return VisualFlashEvent(
                timestampSeconds: timestampSeconds,
                luminance: luminance,
                threshold: lastThreshold
            )
        }
        return nil
    }

    func effectiveThreshold() -> Double {
        if let manual = configuration.manualThreshold { return max(0.01, manual) }
        // sensitivity 0 → 0.28, sensitivity 1 → 0.04
        return max(0.03, 0.28 - configuration.sensitivity * 0.24)
    }

    /// Average luma in the central square. Supports 32BGRA and 420f/420v via the Y plane.
    func averageLuminance(in pixelBuffer: CVPixelBuffer, regionFraction: Double) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let frac = min(0.9, max(0.08, regionFraction))
        let rw = max(8, Int(Double(width) * frac))
        let rh = max(8, Int(Double(height) * frac))
        let x0 = (width - rw) / 2
        let y0 = (height - rh) / 2

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB {
            return averageBGRA(pixelBuffer, x0: x0, y0: y0, rw: rw, rh: rh, width: width)
        }
        // Planar / biplanar YUV: plane 0 is luma.
        if CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
           let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            var sum = 0
            var count = 0
            let step = max(1, min(rw, rh) / 32)
            var y = y0
            while y < y0 + rh {
                let row = ptr.advanced(by: y * bytesPerRow)
                var x = x0
                while x < x0 + rw {
                    sum += Int(row[x])
                    count += 1
                    x += step
                }
                y += step
            }
            guard count > 0 else { return 0 }
            return Double(sum) / Double(count) / 255.0
        }
        return 0
    }

    private func averageBGRA(_ pixelBuffer: CVPixelBuffer, x0: Int, y0: Int, rw: Int, rh: Int, width: Int) -> Double {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        var count = 0
        let step = max(1, min(rw, rh) / 32)
        var y = y0
        while y < y0 + rh {
            let row = ptr.advanced(by: y * bytesPerRow)
            var x = x0
            while x < x0 + rw {
                let i = x * 4
                let b = Double(row[i])
                let g = Double(row[i + 1])
                let r = Double(row[i + 2])
                // Rec. 601 luma
                sum += (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return 0 }
        return sum / Double(count)
    }
}
