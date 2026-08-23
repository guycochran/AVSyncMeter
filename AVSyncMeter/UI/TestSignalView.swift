import SwiftUI
import AudioToolbox

/// Phase 1/2 original test signal: dark field, large white flash, matching short beep, 1 Hz.
/// This is not a third-party pattern and is not a substitute for a house-sync generator.
struct TestSignalView: View {
    @Environment(\.dismiss) private var dismiss
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
        .onDisappear { stop() }
        .preferredColorScheme(.dark)
    }

    private func start() {
        running = true
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
    }

    private func fire() {
        counter += 1
        flashOn = true
        playClick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            flashOn = false
        }
    }

    private func playClick() {
        // Short system click. Not used as a measurement timestamp source.
        AudioServicesPlaySystemSound(1104)
    }
}
