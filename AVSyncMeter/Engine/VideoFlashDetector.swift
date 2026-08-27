import Foundation
import CoreVideo

/// Detects a single rapid positive luminance transition in a configurable central region.
///
/// Stamp is the **first rising edge** of the bright run, not the last white
/// frame of a 2-frame pulse. Trigger still requires a flash-like pop (so work
/// lights do not fire), but a 2-frame Harkwood flash can present a dim first
/// frame (rolling shutter / camera phase) that is not flash-like; the second
/// frame then trips the trigger. Walking back to the first sample above the
/// pre-flash floor keeps a 0.000 ms file in one cluster instead of mixing
/// first-edge and last-edge stamps (~33-67 ms, SPAN -50/+11).
///
/// Phone PTS is the first row in time. A 59.94 rolling shutter spans ~17 ms
/// across the frame, so a 2-frame 29.97 flash that is first-row-white on one
/// capture and last-row-white on another must not hop a whole frame (~17–33 ms).
/// When a readout-axis luma profile is available, the stamp is interpolated
/// inside that first rising frame: `PTS + (firstWhiteRow / (rows-1)) * readout`.
/// Scalar `processLuminance` stays first-rising-frame (no row information).
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
        /// Capture connection rotation. 90 matches CaptureManager (portrait).
        /// Phone PTS is first sensor row in time; after 90° CW that is the right
        /// edge of the buffer, so readout is sampled along −X.
        var bufferRotationDegrees: Int = 90
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
    private var lastFrameTimestamp: Double?

    private struct LumaSample {
        var timestampSeconds: Double
        var luminance: Double
        var readoutSeconds: Double
        var readoutLuma: [Double]
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
        lastFrameTimestamp = nil
    }

    func processPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        timestampSeconds: Double,
        rotationDegrees: Double? = nil
    ) -> VisualFlashEvent? {
        let luma = averageLuminance(in: pixelBuffer, regionFraction: configuration.regionFraction)
        let rot = rotationDegrees.map { Self.normalizedRightAngle(Int($0.rounded())) }
            ?? configuration.bufferRotationDegrees
        let profile = readoutLumaProfile(
            in: pixelBuffer,
            regionFraction: configuration.regionFraction,
            rotationDegrees: rot
        )
        let readout = nextReadoutSeconds(timestampSeconds)
        return processFrame(
            luminance: luma,
            timestampSeconds: timestampSeconds,
            readoutSeconds: readout,
            readoutLuma: profile
        )
    }

    /// Testable path: inject a scalar luminance sample (0...1) with a media timestamp.
    /// No row information — stamps the first rising *frame*, not a row inside it.
    @discardableResult
    func processLuminance(_ luminance: Double, timestampSeconds: Double) -> VisualFlashEvent? {
        _ = nextReadoutSeconds(timestampSeconds)
        return processFrame(
            luminance: luminance,
            timestampSeconds: timestampSeconds,
            readoutSeconds: 0,
            readoutLuma: []
        )
    }

    /// Testable rolling-shutter path. `readoutLuma` is luma along the readout axis,
    /// index 0 = first row in time (phone PTS). `readoutSeconds` is the frame period
    /// (~16.68 ms at 59.94). Trigger still uses the mean (do not fire on one bright
    /// row of a work light). Stamp interpolates the first white row inside the
    /// first rising frame.
    @discardableResult
    func processReadoutLuma(
        _ readoutLuma: [Double],
        timestampSeconds: Double,
        readoutSeconds: Double
    ) -> VisualFlashEvent? {
        _ = nextReadoutSeconds(timestampSeconds)
        let mean: Double
        if readoutLuma.isEmpty {
            mean = 0
        } else {
            mean = readoutLuma.reduce(0, +) / Double(readoutLuma.count)
        }
        return processFrame(
            luminance: mean,
            timestampSeconds: timestampSeconds,
            readoutSeconds: readoutSeconds,
            readoutLuma: readoutLuma
        )
    }

    @discardableResult
    private func processFrame(
        luminance: Double,
        timestampSeconds: Double,
        readoutSeconds: Double,
        readoutLuma: [Double]
    ) -> VisualFlashEvent? {
        lastLuminance = luminance
        lastThreshold = effectiveThreshold()
        recordRecent(
            timestampSeconds: timestampSeconds,
            luminance: luminance,
            readoutSeconds: readoutSeconds,
            readoutLuma: readoutLuma
        )

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

    private func nextReadoutSeconds(_ timestampSeconds: Double) -> Double {
        let prev = lastFrameTimestamp
        lastFrameTimestamp = timestampSeconds
        if let prev {
            let dt = timestampSeconds - prev
            if dt > 0.004 && dt < 0.12 { return dt }
        }
        return 1.001 / 60.0
    }

    private func recordRecent(
        timestampSeconds: Double,
        luminance: Double,
        readoutSeconds: Double,
        readoutLuma: [Double]
    ) {
        recent.append(LumaSample(
            timestampSeconds: timestampSeconds,
            luminance: luminance,
            readoutSeconds: readoutSeconds,
            readoutLuma: readoutLuma
        ))
        let keep = timestampSeconds - (configuration.lookbackSeconds + 0.05)
        while let first = recent.first, first.timestampSeconds < keep {
            recent.removeFirst()
        }
    }

    /// First rising edge of this bright run. Trigger may be the second/last
    /// white frame of a 2-frame pulse; stamp the first sample after the last
    /// dark frame inside the lookback window. With a readout profile, that
    /// stamp is the first white *row* in time, not the whole frame's PTS.
    private func firstEdgeTimestamp(hitTime: Double) -> Double {
        let lookback = configuration.lookbackSeconds
        let onsetFloor = max(floorAtHit, baseline) + lastThreshold * 0.25
        var firstBright: LumaSample?
        for sample in recent {
            if sample.timestampSeconds < hitTime - lookback - 1e-9 { continue }
            if sample.timestampSeconds > hitTime + 1e-9 { break }
            if !sampleIsBright(sample, floor: onsetFloor) {
                firstBright = nil
            } else if firstBright == nil {
                firstBright = sample
            }
        }
        guard let first = firstBright else { return hitTime }
        return interpolateReadout(first, whiteFloor: onsetFloor)
    }

    /// Scalar-bright (existing first-rising-frame) OR any readout row is white.
    /// Last-row-only frames have a low mean and would be skipped without the profile,
    /// then the next full-white frame's PTS hops ~one capture frame.
    private func sampleIsBright(_ sample: LumaSample, floor: Double) -> Bool {
        if sample.luminance > floor { return true }
        for luma in sample.readoutLuma where luma > floor { return true }
        return false
    }

    /// Phone PTS = first row. Stamp PTS + fraction * readoutSeconds.
    private func interpolateReadout(_ sample: LumaSample, whiteFloor: Double) -> Double {
        let rows = sample.readoutLuma
        let R = sample.readoutSeconds
        guard rows.count >= 2, R > 1e-6, R < 0.12 else {
            return sample.timestampSeconds
        }
        var i = 0
        while i < rows.count, rows[i] <= whiteFloor {
            i += 1
        }
        if i >= rows.count {
            return sample.timestampSeconds
        }
        let denom = Double(rows.count - 1)
        let pos: Double
        if i == 0 {
            pos = 0
        } else {
            let y0 = rows[i - 1]
            let y1 = rows[i]
            let span = y1 - y0
            let frac: Double
            if abs(span) < 1e-9 {
                frac = 1
            } else {
                frac = min(1, max(0, (whiteFloor - y0) / span))
            }
            pos = (Double(i - 1) + frac) / denom
        }
        return sample.timestampSeconds + pos * R
    }

    /// Re-arm on a relative drop from the flash peak, not an absolute dark.
    /// Locked AE can leave luma on an elevated floor that never crosses
    /// `baseline + threshold * 0.45`.
    private func shouldRearm(luminance: Double) -> Bool {
        let span = max(peakLuminance - floorAtHit, lastThreshold)
        let drop = peakLuminance - luminance
        return drop >= span * configuration.rearmDropFraction
    }

    static func normalizedRightAngle(_ degrees: Int) -> Int {
        var r = degrees % 360
        if r < 0 { r += 360 }
        let snapped = ((r + 45) / 90) * 90
        return snapped == 360 ? 0 : snapped
    }

    /// Average luma in the central square. Supports 32BGRA and 420f/420v via the Y plane.
    /// Connection rotation does not remap this buffer: plane 0 is still luma, and the
    /// region is the buffer center. A flat reading here is real scene/AE luma, not a
    /// format mix-up. Trigger and the VU needle still use this scalar.
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

    /// Luma along the rolling-shutter axis. Index 0 = first row in time (PTS).
    /// Spans the full readout axis so first-row vs last-row white is visible;
    /// the perpendicular axis stays the central `regionFraction` strip (same
    /// screen-center intent as the trigger ROI, not the bezel).
    func readoutLumaProfile(
        in pixelBuffer: CVPixelBuffer,
        regionFraction: Double,
        rotationDegrees: Int
    ) -> [Double] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width >= 8, height >= 8 else { return [] }

        let rot = Self.normalizedRightAngle(rotationDegrees)
        let alongX = (rot == 90 || rot == 270)
        let reverse = (rot == 90 || rot == 180)
        let axisLen = alongX ? width : height
        let perpLen = alongX ? height : width
        let frac = min(0.9, max(0.08, regionFraction))
        let pw = max(8, Int(Double(perpLen) * frac))
        let p0 = (perpLen - pw) / 2
        let p1 = p0 + pw
        let pStep = max(1, pw / 8)
        let bins = min(64, max(16, axisLen / 8))

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isBGRA = format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB

        if isBGRA {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
            let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            return sampleReadoutBins(
                bins: bins, axisLen: axisLen, reverse: reverse, alongX: alongX,
                p0: p0, p1: p1, pStep: pStep
            ) { x, y in
                let row = ptr.advanced(by: y * bpr)
                let i = x * 4
                let b = Double(row[i])
                let g = Double(row[i + 1])
                let r = Double(row[i + 2])
                return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            }
        }
        if CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
           let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            return sampleReadoutBins(
                bins: bins, axisLen: axisLen, reverse: reverse, alongX: alongX,
                p0: p0, p1: p1, pStep: pStep
            ) { x, y in
                Double(ptr[y * bpr + x]) / 255.0
            }
        }
        return []
    }

    private func sampleReadoutBins(
        bins: Int,
        axisLen: Int,
        reverse: Bool,
        alongX: Bool,
        p0: Int,
        p1: Int,
        pStep: Int,
        lumaAt: (Int, Int) -> Double
    ) -> [Double] {
        var out = [Double](repeating: 0, count: bins)
        let last = Double(max(1, axisLen - 1))
        for b in 0..<bins {
            let u = Double(b) / Double(max(1, bins - 1))
            var axis = Int((last * u).rounded())
            if reverse { axis = (axisLen - 1) - axis }
            axis = min(axisLen - 1, max(0, axis))
            var sum = 0.0
            var n = 0
            var p = p0
            while p < p1 {
                let x = alongX ? axis : p
                let y = alongX ? p : axis
                sum += lumaAt(x, y)
                n += 1
                p += pStep
            }
            out[b] = n > 0 ? sum / Double(n) : 0
        }
        return out
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
