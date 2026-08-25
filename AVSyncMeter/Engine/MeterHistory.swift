import Foundation

/// Rolling LUMA / MIC levels plus FLASH / AUDIOPULSE / PAIR marks for the measure-screen history strip.
/// Feed from the same live luma/mic as the needles — never from valid pairs.
/// Display only — not a measurement timestamp and not part of pairing.
final class MeterHistory {
    static let minWindowSeconds: Double = 1
    static let maxWindowSeconds: Double = 90
    static let defaultWindowSeconds: Double = 90

    enum MarkKind: String, Equatable {
        case flash
        case audioPulse
        case pair
    }

    struct Mark: Equatable {
        var t: Double
        var kind: MarkKind
    }

    private struct Point {
        var t: Double
        var v: Double
    }

    private var luma: [Point] = []
    private var mic: [Point] = []
    private var eventMarks: [Mark] = []

    /// Collapse samples closer than this and keep the peak so a 1-frame flash still shows.
    private let minSpacing = 1.0 / 120.0

    var lastTimestamp: Double {
        max(luma.last?.t ?? 0, mic.last?.t ?? 0, eventMarks.map(\.t).max() ?? 0)
    }

    var lumaCount: Int { luma.count }
    var micCount: Int { mic.count }
    var markCount: Int { eventMarks.count }

    static func clampedWindow(_ seconds: Double) -> Double {
        min(max(seconds, minWindowSeconds), maxWindowSeconds)
    }

    func reset() {
        luma.removeAll(keepingCapacity: true)
        mic.removeAll(keepingCapacity: true)
        eventMarks.removeAll(keepingCapacity: true)
    }

    func appendLuma(t: Double, value: Double) {
        append(to: &luma, t: t, value: value)
    }

    func appendMic(t: Double, value: Double) {
        append(to: &mic, t: t, value: value)
    }

    func appendMark(t: Double, kind: MarkKind) {
        guard t.isFinite else { return }
        eventMarks.append(Mark(t: t, kind: kind))
        if eventMarks.count > 1, let prev = eventMarks.dropLast().last, t < prev.t {
            eventMarks.sort { $0.t < $1.t }
        }
        let cutoff = lastTimestamp - Self.maxWindowSeconds - 0.5
        if let idx = eventMarks.firstIndex(where: { $0.t >= cutoff }), idx > 0 {
            eventMarks.removeFirst(idx)
        }
    }

    /// Peak-held columns, oldest at index 0, newest at the right.
    func lumaColumns(now: Double, windowSeconds: Double, count: Int) -> [Double] {
        columns(luma, now: now, windowSeconds: windowSeconds, count: count)
    }

    func micColumns(now: Double, windowSeconds: Double, count: Int) -> [Double] {
        columns(mic, now: now, windowSeconds: windowSeconds, count: count)
    }

    /// Marks inside `(now − window) ... now`, oldest first.
    func marks(now: Double, windowSeconds: Double) -> [Mark] {
        let w = Self.clampedWindow(windowSeconds)
        guard w > 0, now.isFinite else { return [] }
        let start = now - w
        return eventMarks.filter { $0.t >= start && $0.t <= now }
    }

    /// Per-column overlay kinds, oldest at index 0, newest at the right.
    func markKindsByColumn(now: Double, windowSeconds: Double, count: Int) -> [[MarkKind]] {
        let n = max(count, 1)
        let w = Self.clampedWindow(windowSeconds)
        var out = [[MarkKind]](repeating: [], count: n)
        guard w > 0, now.isFinite else { return out }
        let start = now - w
        let dt = w / Double(n)
        for mark in eventMarks {
            guard mark.t >= start && mark.t <= now else { continue }
            var c = Int((mark.t - start) / dt)
            if c >= n { c = n - 1 }
            if c < 0 { c = 0 }
            if !out[c].contains(mark.kind) {
                out[c].append(mark.kind)
            }
        }
        return out
    }

    private func append(to points: inout [Point], t: Double, value: Double) {
        let v = min(1, max(0, value))
        guard t.isFinite else { return }
        if let last = points.last, t < last.t { return }
        if let lastIdx = points.indices.last, t - points[lastIdx].t < minSpacing {
            points[lastIdx].v = max(points[lastIdx].v, v)
            points[lastIdx].t = t
            return
        }
        points.append(Point(t: t, v: v))
        trim(&points, now: t)
    }

    private func trim(_ points: inout [Point], now: Double) {
        let cutoff = now - Self.maxWindowSeconds - 0.5
        guard let idx = points.firstIndex(where: { $0.t >= cutoff }), idx > 0 else { return }
        points.removeFirst(idx)
    }

    private func columns(_ points: [Point], now: Double, windowSeconds: Double, count: Int) -> [Double] {
        let n = max(count, 1)
        let w = Self.clampedWindow(windowSeconds)
        var out = [Double](repeating: 0, count: n)
        guard !points.isEmpty, w > 0, now.isFinite else { return out }
        let start = now - w
        let dt = w / Double(n)
        var i = 0
        let nPts = points.count
        while i < nPts && points[i].t < start { i += 1 }
        for c in 0..<n {
            let t1 = start + Double(c + 1) * dt
            var peak = 0.0
            // Last column is inclusive so a sample stamped at `now` still paints NOW.
            if c == n - 1 {
                while i < nPts && points[i].t <= now {
                    peak = max(peak, points[i].v)
                    i += 1
                }
            } else {
                while i < nPts && points[i].t < t1 {
                    peak = max(peak, points[i].v)
                    i += 1
                }
            }
            out[c] = peak
        }
        return out
    }
}
