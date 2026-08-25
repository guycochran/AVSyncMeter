import Foundation

/// Phase 2 SIG beep: generated PCM, not `AudioServicesPlaySystemSound(1104)`.
/// 1104 follows the silent switch and is not a PA pulse. This tone is a short
/// loud 1 kHz burst intended to play with the ringer off.
///
/// Not a measurement timestamp. Same-phone loopback while measuring the house
/// injects extra AUDIOPULSE.
enum TestSignalBeep {
    static let frequencyHz: Double = 1_000
    static let durationSeconds: Double = 0.016
    static let sampleRate: Double = 44_100
    static let peakAmplitude: Float = 0.95

    /// playAndRecord + measurement + mixWithOthers + defaultToSpeaker so the
    /// tone can play while capture owns the mic, without voice-chat AEC.
    /// Same policy as CaptureManager.activateMeasurementAudioSession.
    static let sessionCategory = "playAndRecord"
    static let sessionMode = "measurement"
    static let sessionMixWithOthers = true
    static let sessionDefaultToSpeaker = true
    static let sessionAllowBluetooth = false
    static let sessionPrefersEchoCancelledInput = false
    static let sessionPreferredMicrophoneMode = "wideSpectrum"
    static let usedAsMeasurementTimestamp = false

    static var sampleCount: Int {
        max(1, Int((durationSeconds * sampleRate).rounded()))
    }

    /// ~16 ms of 1 kHz with a 1.5 ms fade so the burst is a beep, not a click.
    static func pcmSamples() -> [Float] {
        let n = sampleCount
        let fade = 0.0015
        let dur = durationSeconds
        let freq = frequencyHz
        let rate = sampleRate
        let amp = Double(peakAmplitude)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            let env: Double
            if t < fade {
                env = t / fade
            } else if t > dur - fade {
                env = max(0, (dur - t) / fade)
            } else {
                env = 1
            }
            samples[i] = Float(amp * env * sin(2 * Double.pi * freq * t))
        }
        return samples
    }

    static func wavData() -> Data {
        let floats = pcmSamples()
        var pcm = [Int16]()
        pcm.reserveCapacity(floats.count)
        for s in floats {
            let clipped = max(-1.0, min(1.0, s))
            pcm.append(Int16((Double(clipped) * 32767.0).rounded()))
        }
        let dataSize = UInt32(pcm.count * 2)
        let rate = UInt32(sampleRate)
        var d = Data()
        func ascii(_ s: String) { d.append(contentsOf: s.utf8) }
        func u16(_ v: UInt16) {
            var le = v.littleEndian
            d.append(Data(bytes: &le, count: 2))
        }
        func u32(_ v: UInt32) {
            var le = v.littleEndian
            d.append(Data(bytes: &le, count: 4))
        }
        func i16(_ v: Int16) {
            var le = v.littleEndian
            d.append(Data(bytes: &le, count: 2))
        }
        ascii("RIFF")
        u32(36 + dataSize)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(rate)
        u32(rate * 2)
        u16(2)
        u16(16)
        ascii("data")
        u32(dataSize)
        for s in pcm { i16(s) }
        return d
    }
}
