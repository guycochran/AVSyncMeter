import Foundation

/// 60 fps luma + 48 kHz click train with a constant true offset.
/// Detectors run first; events are ingested in timestamp order so the pairing
/// queue cannot age out a flash while audio is still being generated.
enum SyntheticRig {
    static func run(trueOffsetMs: Double, events: Int, agcDecayPerSecond: Double) -> [Double] {
        let fps = 60.0
        let sr = 48_000.0
        let flash = VideoFlashDetector()
        let pulse = AudioPulseDetector()
        let engine = SyncMeasurementEngine(configuration: .init(pairingWindowSeconds: 1.0))

        let duration = Double(events) + 2.5
        let trueOffsetSec = trueOffsetMs / 1000.0

        for i in 0..<30 {
            _ = flash.processLuminance(0.05, timestampSeconds: Double(i) / fps - 0.5)
        }
        let quiet = [Float](repeating: 0.001, count: 2048)
        _ = pulse.processMonoSamples(quiet, bufferStartSeconds: -0.2, sampleRate: sr)

        var flashes: [VisualFlashEvent] = []
        var pulses: [AudioPulseEvent] = []

        let frameCount = Int(duration * fps)
        for f in 0..<frameCount {
            let t = Double(f) / fps
            let nearestBeep = (t - 1.0).rounded() + 1.0
            let onFlash = nearestBeep >= 1.0
                && nearestBeep <= Double(events)
                && abs(t - nearestBeep) < (0.5 / fps)
            let luma: Double = onFlash ? 0.90 : 0.05
            if let ev = flash.processLuminance(luma, timestampSeconds: t) {
                flashes.append(ev)
            }
        }

        let buf = 1024
        let totalSamples = Int(duration * sr)
        var i = 0
        while i < totalSamples {
            let n = min(buf, totalSamples - i)
            var samples = [Float](repeating: 0.001, count: n)
            let t0 = Double(i) / sr
            let t1 = t0 + Double(n) / sr
            for ev in 1...events {
                let clickT = Double(ev) + trueOffsetSec
                let clickEnd = clickT + 0.010
                if clickEnd < t0 || clickT > t1 { continue }
                let peak = 0.85 * pow(1.0 - agcDecayPerSecond, Double(ev))
                let attack = Int(0.001 * sr)
                let hold = Int(0.008 * sr)
                let start = Int(((clickT - t0) * sr).rounded(.down))
                var k = 0
                while k < attack {
                    let idx = start + k
                    if idx >= 0 && idx < n {
                        samples[idx] = Float(0.001 + peak * Double(k) / Double(max(1, attack)))
                    }
                    k += 1
                }
                k = 0
                while k < hold {
                    let idx = start + attack + k
                    if idx >= 0 && idx < n { samples[idx] = Float(peak) }
                    k += 1
                }
            }
            if let ev = pulse.processMonoSamples(samples, bufferStartSeconds: t0, sampleRate: sr) {
                pulses.append(ev)
            }
            i += n
        }

        var fi = 0
        var pi = 0
        while fi < flashes.count || pi < pulses.count {
            let takeFlash: Bool
            if pi >= pulses.count {
                takeFlash = true
            } else if fi >= flashes.count {
                takeFlash = false
            } else {
                takeFlash = flashes[fi].timestampSeconds <= pulses[pi].timestampSeconds
            }
            if takeFlash {
                _ = engine.ingestFlash(flashes[fi])
                fi += 1
            } else {
                _ = engine.ingestPulse(pulses[pi])
                pi += 1
            }
        }

        return engine.statistics.rawSamples.filter { !$0.isOutlier }.map(\.offsetMilliseconds)
    }
}
