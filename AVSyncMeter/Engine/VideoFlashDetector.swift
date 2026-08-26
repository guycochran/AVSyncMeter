import Foundation
import CoreVideo

/// Detects a single rapid positive luminance transition in a configurable central region.
///
/// Stamp is the **first rising frame** of the bright run, not the last white
/// frame of a 2-frame pulse. Trigger still requires a flash-like pop (so work
/// lights do not fire), but a 2-frame Harkwood flash can present a dim first
/// frame (rolling shutter / camera phase) that is not flash-like; the second
/// frame then trips the trigger. Walking back to the first sample above the
/// pre-flash floor keeps a 0.000 ms file in one cluster instead of mixing
/// first-edge and last-edge stamps (~33-67 ms, SPAN -50/+11).
///
/// Dark floor is updated only on quiet frames (not during the flash, not during
/// holdoff), and it always snaps down when a darker frame appears so a bright
/// first sample cannot hide later flashes. A lagging EMA that includes the flash
/// is how a threshold can walk 1 ms/s; this detector does not do that.
///
/// One flash = one event via latch + ~400 ms holdoff + re-arm on a *relative*
/// drop from the flash peak toward the pre-flash floor. Absolute "must go dark"
/// fails when locked AE never returns to the original floor.
final class VideoFlashDetector {
    struct Configuration {
        var regionFraction: Double = 0.35
        /// Sensitivity 0...1. Higher → smaller delta required.
        var sensitivity: Double = 0.65
        var manualThreshold: Double?
        /// Seconds the detector stays latched after a hit so a long flash is one event.
        /// 8 frames at 60 fps was ~133 ms — projector persistence / AE recovery can
        /// double-flash ~150 ms later and steal the next pulse. 400 ms matches audio.
        var holdoffSeconds: Double = 0.40
        /// Quiet-frame dark-floor blend. Small on purpose — this is not an onset tracker.
        var floorAlpha: Double = 0.02
        /// Re-arm once luma has fallen this fraction of (peak − pre-flash floor).
        /// 0.5 = halfway back toward the floor, not an absolute dark level.
        var rearmDropFraction: Double = 0.50
        /// Walk back at most this far from the trigger to the first rising frame.
        /// 2 frames at 29.97 is 66.7 ms; ~5 frames at 60 fps is 83 ms. Must stay
        /// well under the 400 ms holdoff and the 1001 ms Harkwood period.
        var lookbackSeconds: Double = 0.090
    }

    var configuration: Configuration
    private(set) var lastLuminance: Double = 0
    /// Dark floor (quiet-frame only). Exposed as `baseline` for Diagnostics.
    private(set) var baseline: Double = 0
    private(set) var lastThreshold: Double = 0.12
    private var hasBaseline = false
    private var holdoffUntilSeconds: Double = -1
    private var awaitingRearm = false
    private var previousLuminance: Double = 0
    private var peakLuminance: Double = 0
    private var floorAtHit: Double = 0
    private var recent: [LumaSample] = []

    private struct LumaSample {
        var timestampSeconds: Double
        var luminance: Double
    }

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func reset() {
        lastLuminance = 0
        baseline = 0
        hasBaseline = false
        holdoffUntilSeconds = -1
        awaitingRearm = false
        previousLuminance = 0
        peakLuminance = 0
        floorAtHit = 0
        recent.removeAll()
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
        recordRecent(timestampSeconds: timestampSeconds, luminance: luminance)

        if !hasBaseline {
            baseline = luminance
            previousLuminance = luminance
            hasBaseline = true
            return nil
        }

        // Asymmetric floor: a darker frame always pulls the floor down. A bright
        // first frame (or a mid-flash start) must not permanently hide 1 Hz flashes.
        if luminance < baseline {
            baseline = luminance
        }

        if timestampSeconds < holdoffUntilSeconds {
            if luminance > peakLuminance { peakLuminance = luminance }
            previousLuminance = luminance
            return nil
        }

        if awaitingRearm {
            if luminance > peakLuminance { peakLuminance = luminance }
            if shouldRearm(luminance: luminance) {
                awaitingRearm = false
            } else {
                previousLuminance = luminance
                return nil
            }
        }

        let rising = luminance - previousLuminance
        let aboveFloor = luminance - baseline
        // Work lights / people: a moderate walk through the region is not a
        // white flash. Harkwood/SIG is a near-white pop from a dark field.
        let flashLike = luminance >= 0.42 || rising >= 0.28
        let hit = rising > lastThreshold && aboveFloor > lastThreshold * 0.5 && flashLike

        if hit {
            awaitingRearm = true
            holdoffUntilSeconds = timestampSeconds + configuration.holdoffSeconds
            peakLuminance = luminance
            floorAtHit = min(baseline, previousLuminance)
            let onset = firstEdgeTimestamp(hitTime: timestampSeconds)
            previousLuminance = luminance
            // Do not fold the flash into the dark floor.
            return VisualFlashEvent(
                timestampSeconds: onset,
                luminance: luminance,
                threshold: lastThreshold
            )
        }

        // Quiet frame only: very slow dark-floor update. Never chase a rising edge.
        if rising < lastThreshold * 0.25 {
            let a = configuration.floorAlpha
            baseline = baseline * (1 - a) + luminance * a
        }
        previousLuminance = luminance
        return nil
    }

    func effectiveThreshold() -> Double {
        if let manual = configuration.manualThreshold { return max(0.01, manual) }
        // sensitivity 0 → 0.28, sensitivity 1 → 0.04
        return max(0.03, 0.28 - configuration.sensitivity * 0.24)
    }

    private func recordRecent(timestampSeconds: Double, luminance: Double) {
        recent.append(LumaSample(timestampSeconds: timestampSeconds, luminance: luminance))
        let keep = timestampSeconds - (configuration.lookbackSeconds + 0.05)
        while let first = recent.first, first.timestampSeconds < keep {
            recent.removeFirst()
        }
    }

    /// First rising frame of this bright run. Trigger may be the second/last
    /// white frame of a 2-frame pulse; stamp the first sample after the last
    /// dark frame inside the lookback window.
    private func firstEdgeTimestamp(hitTime: Double) -> Double {
        let lookback = configuration.lookbackSeconds
        let onsetFloor = max(floorAtHit, baseline) + lastThreshold * 0.25
        var firstBrightAfterDark: Double?
        for sample in recent {
            if sample.timestampSeconds < hitTime - lookback - 1e-9 { continue }
            if sample.timestampSeconds > hitTime + 1e-9 { break }
            if sample.luminance <= onsetFloor {
                firstBrightAfterDark = nil
            } else if firstBrightAfterDark == nil {
                firstBrightAfterDark = sample.timestampSeconds
            }
        }
        return firstBrightAfterDark ?? hitTime
    }

    /// Re-arm on a relative drop from the flash peak, not an absolute dark.
    /// Locked AE can leave luma on an elevated floor that never crosses
    /// `baseline + threshold * 0.45`.
    private func shouldRearm(luminance: Double) -> Bool {
        let span = max(peakLuminance - floorAtHit, lastThreshold)
        let drop = peakLuminance - luminance
        return drop >= span * configuration.rearmDropFraction
    }

    /// Average luma in the central square. Supports 32BGRA and 420f/420v via the Y plane.
    /// Connection rotation does not remap this buffer: plane 0 is still luma, and the
    /// region is the buffer center. A flat reading here is real scene/AE luma, not a
    /// format mix-up.
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
