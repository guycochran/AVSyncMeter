import Foundation

/// Program frame rate: converts a measured millisecond offset into frames,
/// and selects the capture frame duration (NTSC 1001 family vs integer 30/60).
enum FrameRate: String, CaseIterable, Identifiable, Codable, Hashable {
    case fps23976
    case fps24
    case fps25
    case fps2997
    case fps30
    case fps50
    case fps5994
    case fps60

    var id: String { rawValue }

    /// Exact frames-per-second. Fractional rates use the 1001 family, not 23.976 / 29.97 rounded.
    var framesPerSecond: Double {
        switch self {
        case .fps23976: return 24_000.0 / 1_001.0
        case .fps24: return 24.0
        case .fps25: return 25.0
        case .fps2997: return 30_000.0 / 1_001.0
        case .fps30: return 30.0
        case .fps50: return 50.0
        case .fps5994: return 60_000.0 / 1_001.0
        case .fps60: return 60.0
        }
    }

    var displayName: String {
        switch self {
        case .fps23976: return "23.976"
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps2997: return "29.97"
        case .fps30: return "30"
        case .fps50: return "50"
        case .fps5994: return "59.94"
        case .fps60: return "60"
        }
    }

    /// 23.976 / 29.97 / 59.94 — capture must use a 1001-family duration, not integer 30/60.
    var isNTSCFamily: Bool {
        switch self {
        case .fps23976, .fps2997, .fps5994: return true
        default: return false
        }
    }

    /// Offset in frames: (ms / 1000) * fps. Example: 193 ms @ 29.97 ≈ 5.79 frames.
    func frames(forMilliseconds milliseconds: Double) -> Double {
        (milliseconds / 1_000.0) * framesPerSecond
    }

    /// Classify an observed capture rate as NTSC 1001-family vs integer 24/25/30/50/60.
    /// Nearest-neighbour so 29.970 and 30.000 stay distinct (they are only 0.03 fps apart).
    static func captureFamily(observedFPS: Double) -> String {
        let candidates: [(Double, String)] = [
            (24_000.0 / 1_001.0, "NTSC"),
            (30_000.0 / 1_001.0, "NTSC"),
            (60_000.0 / 1_001.0, "NTSC"),
            (24.0, "integer"),
            (25.0, "integer"),
            (30.0, "integer"),
            (50.0, "integer"),
            (60.0, "integer"),
        ]
        guard observedFPS.isFinite, observedFPS > 1 else { return "—" }
        let best = candidates.min(by: { abs($0.0 - observedFPS) < abs($1.0 - observedFPS) })!
        if abs(best.0 - observedFPS) > 1.0 {
            return abs(observedFPS - observedFPS.rounded()) < 0.05 ? "integer" : "NTSC"
        }
        return best.1
    }

    /// Footer: `Capture 29.97 fps  NTSC  (picker 29.97)`. %.1f hid 29.970 as 30.0.
    /// Picker 29.97/59.94 with integer capture is a lock miss — never silent 1/30.
    static func captureFooter(observedFPS: Double, picker: FrameRate) -> String {
        let family = captureFamily(observedFPS: observedFPS)
        if picker.isNTSCFamily && family == "integer" {
            return String(
                format: "Capture %.2f fps  integer  NTSC lock MISS  (picker %@)",
                observedFPS,
                picker.displayName
            )
        }
        return String(format: "Capture %.2f fps  %@  (picker %@)", observedFPS, family, picker.displayName)
    }

    /// Capture duration matching this picker. Prefer 60_000/1001 when the picker
    /// is 29.97/59.94 and 59+ is available; 30_000/1001 if 60 is not used.
    /// Integer 30/60 pickers keep integer 1/60 or 1/30.
    static func preferredCaptureDuration(program: FrameRate, maxFrameRate: Double) -> CaptureFrameDuration {
        CaptureFrameDuration.preferred(program: program, maxFrameRate: maxFrameRate)
    }
}

/// Integer CMTime-like frame duration for `AVCaptureDevice` lock.
/// `value/timescale` seconds per frame (1001/60000 = 59.94 fps).
struct CaptureFrameDuration: Equatable {
    let value: Int64
    let timescale: Int32

    var seconds: Double { Double(value) / Double(timescale) }
    var framesPerSecond: Double { Double(timescale) / Double(value) }

    static let ntsc60 = CaptureFrameDuration(value: 1001, timescale: 60_000)
    static let ntsc30 = CaptureFrameDuration(value: 1001, timescale: 30_000)
    static let ntsc24 = CaptureFrameDuration(value: 1001, timescale: 24_000)
    static let integer60 = CaptureFrameDuration(value: 1, timescale: 60)
    static let integer30 = CaptureFrameDuration(value: 1, timescale: 30)
    static let integer50 = CaptureFrameDuration(value: 1, timescale: 50)
    static let integer25 = CaptureFrameDuration(value: 1, timescale: 25)
    static let integer24 = CaptureFrameDuration(value: 1, timescale: 24)

    /// 23.976 / 29.97 / 59.94. Tolerance is tighter than 30.000−29.970 so 1/30 is not NTSC.
    var isNTSCFamily: Bool {
        let fps = framesPerSecond
        return abs(fps - 24_000.0 / 1_001.0) < 0.02
            || abs(fps - 30_000.0 / 1_001.0) < 0.02
            || abs(fps - 60_000.0 / 1_001.0) < 0.02
    }

    func isApproximately(_ other: CaptureFrameDuration) -> Bool {
        abs(seconds - other.seconds) < 5e-6
    }

    /// Pick a capture duration from the program picker and the active format's max fps.
    /// Integer 30.000 vs a 29.97 file is 1000 ppm (~1 ms per 1 Hz beep) even when
    /// both stream clocks are true host — relative A−V stays 1.0 and cannot flatten it.
    static func preferred(program: FrameRate, maxFrameRate: Double) -> CaptureFrameDuration {
        let can60 = maxFrameRate >= 59.0
        let can50 = maxFrameRate >= 49.0
        switch program {
        case .fps2997, .fps5994:
            return can60 ? .ntsc60 : .ntsc30
        case .fps23976:
            return can60 ? .ntsc60 : .ntsc24
        case .fps30, .fps60:
            return can60 ? .integer60 : .integer30
        case .fps24:
            return can60 ? .integer60 : .integer24
        case .fps50:
            return can50 ? .integer50 : .integer25
        case .fps25:
            return can50 ? .integer50 : .integer25
        }
    }

    /// Probe-based lock. NTSC picker prefers 60_000/1001 then 30_000/1001 from the
    /// device format list and never silently returns 1/30 or 1/60. Nil = cannot lock.
    static func selectLock(program: FrameRate, formats: [CaptureFormatProbe]) -> CaptureLockChoice? {
        if formats.isEmpty { return nil }
        if program.isNTSCFamily {
            let targets: [CaptureFrameDuration]
            switch program {
            case .fps23976:
                targets = [.ntsc60, .ntsc30, .ntsc24]
            default:
                targets = [.ntsc60, .ntsc30]
            }
            for target in targets {
                if let idx = bestFormatIndex(formats: formats, containing: target, preferNative: true) {
                    return CaptureLockChoice(formatIndex: idx, duration: target)
                }
            }
            if let closest = closestListedNTSC(program: program, formats: formats) {
                return closest
            }
            return nil
        }
        let maxRate = formats.flatMap { $0.ranges.map(\.maxFrameRate) }.max() ?? 0
        let duration = preferred(program: program, maxFrameRate: maxRate)
        let idx = bestFormatIndex(formats: formats, containing: duration, preferNative: false) ?? 0
        return CaptureLockChoice(formatIndex: idx, duration: duration)
    }

    /// Ranked format indices that can take `duration`, native 1001 endpoints first, ~1080p preferred.
    static func rankedFormatIndices(formats: [CaptureFormatProbe], containing duration: CaptureFrameDuration) -> [Int] {
        let targetArea = 1920 * 1080
        func score(_ i: Int) -> (Int, Int) {
            let f = formats[i]
            let native = f.nativelyLists(duration) ? 0 : 1
            let area = abs(max(1, f.width * f.height) - targetArea)
            return (native, area)
        }
        return formats.indices.filter { i in
            formats[i].ranges.contains { $0.contains(duration) }
        }.sorted { score($0) < score($1) }
    }

    static func bestFormatIndex(formats: [CaptureFormatProbe], containing duration: CaptureFrameDuration, preferNative: Bool) -> Int? {
        _ = preferNative
        return rankedFormatIndices(formats: formats, containing: duration).first
    }

    /// If no range contains 60_000/1001 or 30_000/1001, pick the closest 1001-family
    /// duration actually listed on a range endpoint. Still never 1/30.
    static func closestListedNTSC(program: FrameRate, formats: [CaptureFormatProbe]) -> CaptureLockChoice? {
        let want = program.framesPerSecond
        var best: (idx: Int, duration: CaptureFrameDuration, err: Double)?
        for (i, f) in formats.enumerated() {
            for range in f.ranges {
                for d in [range.minDuration, range.maxDuration] where d.isNTSCFamily {
                    let err = abs(d.framesPerSecond - want)
                    if best == nil || err < best!.err {
                        best = (i, d, err)
                    }
                }
            }
        }
        guard let best else { return nil }
        return CaptureLockChoice(formatIndex: best.idx, duration: best.duration)
    }

    /// PTS a camera locked to `captureFps` assigns to a 29.97-file event at `fileWall`.
    /// Integer-30 stamps `floor(fileWall × 30) / 30`, which walks ~1 ms/beep vs 29.97 wall.
    /// NTSC 30_000/1001 or 60_000/1001 lands on the same wall time as the file.
    static func videoPTS(fileWallSeconds: Double, captureFps: Double) -> Double {
        guard captureFps > 1e-9, fileWallSeconds.isFinite else { return fileWallSeconds }
        let index = (fileWallSeconds * captureFps + 1e-12).rounded(.down)
        return index / captureFps
    }
}

/// One format's supported min/max frame durations (CMTime endpoints, not fps slop).
struct CaptureFrameDurationRange: Equatable {
    /// Shortest frame = highest fps.
    var minDuration: CaptureFrameDuration
    /// Longest frame = lowest fps.
    var maxDuration: CaptureFrameDuration

    var maxFrameRate: Double {
        let s = minDuration.seconds
        return s > 1e-9 ? 1.0 / s : 0
    }

    func contains(_ duration: CaptureFrameDuration) -> Bool {
        let t = duration.seconds
        return t + 1e-6 >= minDuration.seconds && t - 1e-6 <= maxDuration.seconds
    }
}

struct CaptureFormatProbe: Equatable {
    var width: Int
    var height: Int
    var ranges: [CaptureFrameDurationRange]

    func nativelyLists(_ duration: CaptureFrameDuration) -> Bool {
        ranges.contains {
            $0.minDuration.isApproximately(duration) || $0.maxDuration.isApproximately(duration)
        }
    }
}

struct CaptureLockChoice: Equatable {
    var formatIndex: Int
    var duration: CaptureFrameDuration
}
