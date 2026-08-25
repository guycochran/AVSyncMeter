import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: MeasurementSession
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Program frame rate") {
                    Picker("Frame rate", selection: $settings.frameRate) {
                        ForEach(FrameRate.allCases) { rate in
                            Text(rate.displayName).tag(rate)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("29.97 / 59.94 lock the camera to the NTSC 1001 family (60_000/1001 then 30_000/1001 from the device format list). If the format cannot lock, the footer says NTSC lock MISS instead of silently using 1/30. 30 / 60 keep integer 1/60 or 1/30. Also converts milliseconds into frames.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Detection") {
                    labeledSlider("Flash sensitivity", value: $settings.flashSensitivity)
                    labeledSlider("Audio sensitivity", value: $settings.audioSensitivity)
                    VStack(alignment: .leading) {
                        Text(String(format: "Target region %.0f%%", settings.regionFraction * 100))
                        Slider(value: $settings.regionFraction, in: 0.12...0.70)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Pairing window ±%.0f ms", settings.pairingWindowSeconds * 1000))
                        Slider(value: $settings.pairingWindowSeconds, in: 0.20...2.0)
                        Text("Default 400 ms covers monitor+PA+Mitti. Ring-down 220–350 ms still expires vs the next 1 Hz flash.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Manual thresholds (optional)") {
                    Toggle(isOn: manualVisualBinding) { Text("Override visual threshold") }
                    if settings.manualVisualThreshold != nil {
                        Slider(value: visualManual, in: 0.02...0.40)
                        Text(String(format: "Δ luma %.3f", settings.manualVisualThreshold ?? 0))
                            .font(.footnote)
                    }
                    Toggle(isOn: manualAudioBinding) { Text("Override audio threshold") }
                    if settings.manualAudioThreshold != nil {
                        Slider(value: audioManual, in: 0.01...0.40)
                        Text(String(format: "Envelope %.3f", settings.manualAudioThreshold ?? 0))
                            .font(.footnote)
                    }
                }

                Section("Stability / outliers") {
                    VStack(alignment: .leading) {
                        Text(String(format: "SYNC STABLE if stddev ≤ %.1f ms", settings.stabilityThresholdMilliseconds))
                        Slider(value: $settings.stabilityThresholdMilliseconds, in: 2...30)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Outlier MAD k %.1f", settings.outlierMADMultiplier))
                        Slider(value: $settings.outlierMADMultiplier, in: 2...6)
                    }
                }

                Section("Calibration") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: "Stored calibration: %+.1f ms", settings.calibrationOffsetMilliseconds))
                        Slider(value: $settings.calibrationOffsetMilliseconds, in: -500...500, step: 0.5)
                        Text("correctedOffset = measuredOffset − calibrationOffset. Default 0 ms is “none applied”, not zero sensor latency. Prefer ZERO / SET TRUE on the main meter during a show.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Clear calibration") {
                                settings.previousCalibrationOffsetMilliseconds = settings.calibrationOffsetMilliseconds
                                settings.calibrationOffsetMilliseconds = 0
                                session.applySettingsToEngine()
                            }
                            Spacer()
                            Button("Undo") {
                                let prev = settings.previousCalibrationOffsetMilliseconds
                                settings.previousCalibrationOffsetMilliseconds = settings.calibrationOffsetMilliseconds
                                settings.calibrationOffsetMilliseconds = prev
                                session.applySettingsToEngine()
                            }
                        }
                        .font(.footnote.weight(.semibold))
                        Text("Phone camera and microphone processing can introduce measurement bias. For critical systems, verify results against a known reference.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Meters") {
                    VStack(alignment: .leading) {
                        Text(String(format: "VU history %.0f s", settings.meterHistorySeconds))
                        Slider(value: $settings.meterHistorySeconds, in: MeterHistory.minWindowSeconds...MeterHistory.maxWindowSeconds, step: 1)
                        Text("Scrolling LUMA + MIC of the last 1–90 seconds on the measure screen. Newest at the right. Default 30 s.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Info") {
                    Text("AV Sync Meter \(AppVersion.label)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Toggle("Show speed-of-sound note", isOn: $settings.showDistanceHelper)
                    Text("Sound ≈ 343 m/s ≈ 1.1 ft/ms. This app measures from the seat, including acoustic travel. Distance correction is informational and off by default. It is never auto-applied.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        session.applySettingsToEngine()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var visualManual: Binding<Double> {
        Binding(
            get: { settings.manualVisualThreshold ?? 0.12 },
            set: { settings.manualVisualThreshold = $0 }
        )
    }

    private var audioManual: Binding<Double> {
        Binding(
            get: { settings.manualAudioThreshold ?? 0.08 },
            set: { settings.manualAudioThreshold = $0 }
        )
    }

    private var manualVisualBinding: Binding<Bool> {
        Binding(
            get: { settings.manualVisualThreshold != nil },
            set: { settings.manualVisualThreshold = $0 ? 0.12 : nil }
        )
    }

    private var manualAudioBinding: Binding<Bool> {
        Binding(
            get: { settings.manualAudioThreshold != nil },
            set: { settings.manualAudioThreshold = $0 ? 0.08 : nil }
        )
    }

    private func labeledSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title)  \(Int(value.wrappedValue * 100))%")
            Slider(value: value, in: 0...1)
        }
    }
}
