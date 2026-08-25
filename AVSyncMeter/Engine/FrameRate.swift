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

    /// PTS a camera locked to `captureFps` assigns to a 29.97-file event at `fileWall`.
    /// Integer-30 stamps `floor(fileWall × 30) / 30`, which walks ~1 ms/beep vs 29.97 wall.
    /// NTSC 30_000/1001 or 60_000/1001 lands on the same wall time as the file.
    static func videoPTS(fileWallSeconds: Double, captureFps: Double) -> Double {
        guard captureFps > 1e-9, fileWallSeconds.isFinite else { return fileWallSeconds }
        let index = (fileWallSeconds * captureFps + 1e-12).rounded(.down)
        return index / captureFps
    }
}
