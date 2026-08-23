import Foundation

/// Program frame rate used only for converting a measured millisecond offset into frames.
/// Capture timestamps themselves are independent of this setting.
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

    /// Offset in frames: (ms / 1000) * fps. Example: 193 ms @ 29.97 ≈ 5.79 frames.
    func frames(forMilliseconds milliseconds: Double) -> Double {
        (milliseconds / 1_000.0) * framesPerSecond
    }
}
