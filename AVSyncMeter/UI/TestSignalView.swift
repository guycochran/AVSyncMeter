import SwiftUI
import AVFoundation

/// Phase 1/2 original test signal: dark field, large white flash, matching short beep, 1 Hz.
/// This is not a third-party pattern and is not a substitute for a house-sync generator.
struct TestSignalView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var beep = TestSignalBeepPlayer()
    @State private var running = false
    @State private var flashOn = false
    @State private var counter = 0
    @State private var fps: FrameRate = .fps2997
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            (flashOn ? Color.white : Color.black).ignoresSafeArea()
            VStack {
                HStack {
                    Button("Close") { stop(); dismiss() }
                        .foregroundStyle(flashOn ? Color.black : Color.white)
                    Spacer()
                    Text("PHASE 2 TEST SIGNAL")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(flashOn ? Color.black.opacity(0.6) : Color.white.opacity(0.5))
                }
                .padding()
                Spacer()
                Text(String(format: "%@ fps   frame %d", fps.displayName, counter))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(flashOn ? Color.black : Color.white)
                Text(running ? "1 Hz flash + pulse" : "Stopped")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(flashOn ? Color.black.opacity(0.7) : Color.white.opacity(0.6))
                Text("Same-phone loopback while measuring the house injects extra AUDIOPULSE.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(flashOn ? Color.black.opacity(0.7) : Color.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                Spacer()
                Picker("fps", selection: $fps) {
                    ForEach(FrameRate.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                Button(running ? "STOP SIGNAL" : "START SIGNAL") {
                    running ? stop() : start()
                }
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .padding()
                .foregroundStyle(flashOn ? Color.black : Color.white)
            }
        }
        .onAppear { beep.prepare() }
        .onDisappear { stop() }
        .preferredColorScheme(.dark)
    }

    private func start() {
        running = true
        beep.prepare()
        fire()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            fire()
        }
    }

    private func stop() {
        running = false
        flashOn = false
        timer?.invalidate()
        timer = nil
        beep.stop()
    }

    private func fire() {
        counter += 1
        flashOn = true
        beep.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            flashOn = false
        }
    }
}

/// Generated PCM beep via AVAudioPlayer. Session category plays with the ringer
/// off and mixes with a running capture session. The play() call is not a
/// measurement timestamp.
final class TestSignalBeepPlayer: ObservableObject {
    private var player: AVAudioPlayer?

    func prepare() {
        activateSession()
        if player == nil {
            do {
                let p = try AVAudioPlayer(data: TestSignalBeep.wavData())
                p.volume = 1
                p.prepareToPlay()
                player = p
            } catch {
                player = nil
            }
        } else {
            player?.prepareToPlay()
        }
    }

    func play() {
        activateSession()
        if player == nil {
            prepare()
        }
        player?.currentTime = 0
        player?.play()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
    }

    /// Same measurement session as capture. mode.default + defaultToSpeaker
    /// is speakerphone AEC and was crushing the house PA to env 0.001.
    private func activateSession() {
        if CaptureManager.activateMeasurementAudioSession() { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
