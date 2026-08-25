import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var session: MeasurementSession
    @Environment(\.dismiss) private var dismiss
    @State private var demoOffset: Double = 200

    var body: some View {
        NavigationStack {
            List {
                Section("Live") {
                    labeled("Luminance", String(format: "%.3f  thr %.3f", session.liveLuminance, session.flashDetector.effectiveThreshold()))
                    labeled("Audio env", String(format: "%.3f  thr %.3f", session.liveAudioLevel, session.pulseDetector.effectiveThreshold(relativeToBaseline: session.pulseDetector.baseline)))
                    labeled("Capture fps", String(format: "%.2f", session.capture.observedVideoFPS))
                    labeled("Valid / rejected", "\(session.snapshot.validCount) / \(session.snapshot.rejectedCount)")
                    labeled("Outliers", "\(session.snapshot.outlierCount)")
                    if let walk = session.snapshot.walkMsPerEvent {
                        labeled("Walk", String(format: "%+.3f ms/beep", walk))
                    } else {
                        labeled("Walk", "need ≥8 valid")
                    }
                }

                Section("Capture clocks") {
                    let c = session.clockSnapshot
                    labeled("Locked", c.locked ? "yes" : "no")
                    labeled("Settled", c.settled ? "yes — publishing" : "no — pairs held")
                    labeled("Video slope host/pts", String(format: "%.6f  n=%d", c.videoSlope, c.videoObservations))
                    labeled("Audio slope host/pts", String(format: "%.6f  n=%d", c.audioSlope, c.audioObservations))
                    labeled("Video PTS vs host", String(format: "%+.0f ppm", c.videoPpmVersusHost))
                    labeled("Audio PTS vs host", String(format: "%+.0f ppm", c.audioPpmVersusHost))
                    labeled("Relative A−V", String(format: "%+.0f ppm", c.relativeDriftPPM))
                    Text("Pairing uses these unified times, not raw cross-stream PTS. A few hundred ppm of leftover source-clock error is honest. ~1000 ppm (~1 ms per 1 Hz beep) on a constant delay is a meter bug.")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Section("Sign convention") {
                    Text(SyncSignConvention.documentation)
                        .font(.system(.footnote, design: .monospaced))
                }

                Section("Inject synthetic pair (no camera)") {
                    Stepper(value: $demoOffset, in: -400...400, step: 10) {
                        Text(String(format: "Audio offset %+.0f ms", demoOffset))
                    }
                    Button("Inject one pair") {
                        let t = Date().timeIntervalSinceReferenceDate
                        // Synthetic media times, not used as a live measurement clock.
                        session.injectSynthetic(videoSeconds: t, audioSeconds: t + demoOffset / 1000.0)
                    }
                    Button("Inject 5 stable early pairs (+200 ms)") {
                        let t0 = Date().timeIntervalSinceReferenceDate
                        for i in 0..<5 {
                            let t = t0 + Double(i)
                            session.injectSynthetic(videoSeconds: t, audioSeconds: t + 0.200)
                        }
                    }
                }

                Section("Event log") {
                    if session.diagnostics.isEmpty {
                        Text("No events yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.diagnostics.reversed()) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.kind.rawValue.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(event.message)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func labeled(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).font(.system(.body, design: .monospaced))
        }
    }
}
