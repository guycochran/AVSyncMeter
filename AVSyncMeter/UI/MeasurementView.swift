import SwiftUI

struct MeasurementView: View {
    @EnvironmentObject private var session: MeasurementSession
    @ObservedObject private var settings = AppSettings.shared
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var showTestSignal = false
    @State private var showSetTrue = false
    @State private var knownTrueText = "0"
    @State private var calibrateNote: String?

    var body: some View {
        ZStack {
            VenueTheme.bg.ignoresSafeArea()
            VStack(spacing: 10) {
                header
                preview
                resultBlock
                statsRow
                meters
                controls
                calibrateRow
                if let calibrateNote {
                    Text(calibrateNote)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(VenueTheme.early)
                        .multilineTextAlignment(.center)
                }
                if settings.showDistanceHelper {
                    distanceNote
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(session)
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
                .environmentObject(session)
        }
        .sheet(isPresented: $showTestSignal) {
            TestSignalView()
        }
        .sheet(isPresented: $showSetTrue) {
            setTrueSheet
        }
    }

    private var header: some View {
        HStack {
            Text("AV SYNC METER")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(VenueTheme.dim)
            Spacer()
            Button("DIAG") { showDiagnostics = true }
            Button("SET") { showSettings = true }
            Button("SIG") { showTestSignal = true }
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .foregroundStyle(VenueTheme.meter)
        .buttonStyle(.plain)
    }

    private var preview: some View {
        ZStack {
            CameraPreviewView(session: session.capture.session, regionFraction: settings.regionFraction)
            if let err = session.captureError {
                VStack(spacing: 6) {
                    Text("NO CAMERA")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                    Text(err)
                        .font(.system(size: 11, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(VenueTheme.dim)
                    Text("Simulator cannot measure live video.\nUse a device or inject a test from Diagnostics.")
                        .font(.system(size: 11, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(VenueTheme.dim)
                }
                .padding()
                .background(Color.black.opacity(0.72))
            }
        }
        .frame(maxHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(VenueTheme.line, lineWidth: 1)
        )
    }

    private var resultBlock: some View {
        let offset = session.snapshot.correctedCurrentMilliseconds
        let direction = offset.map { MeasurementSession.headline($0) } ?? (session.runState == .idle ? "IDLE" : "LISTENING")
        let color: Color = {
            guard let offset else { return VenueTheme.dim }
            if abs(offset) < 0.5 { return VenueTheme.stable }
            return offset > 0 ? VenueTheme.early : VenueTheme.late
        }()
        return VStack(spacing: 4) {
            Text(direction)
                .font(.system(size: 28, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let offset {
                Text(String(format: "%+.0f ms", offset))
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(recommendedDelay(offset))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VenueTheme.meter)
                Text(frameLine(offset))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
            } else {
                Text("— ms")
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
                Text("No pairs yet")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
            }
            stabilityBadge
            calibrationBadge
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(VenueTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var stabilityBadge: some View {
        let stable = session.snapshot.isStable
        return Text(stable ? "SYNC STABLE" : "SYNC UNSTABLE")
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(stable ? VenueTheme.stable : VenueTheme.unstable)
            .padding(.top, 2)
    }

    private var calibrationBadge: some View {
        Group {
            if session.snapshot.calibrationApplied {
                Text(String(format: "Calibrated: %+.0f ms", session.snapshot.calibrationOffsetMilliseconds))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VenueTheme.early)
            } else {
                Text("No calibration applied (0 ms). Not a claim of zero sensor latency.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var statsRow: some View {
        let s = session.snapshot
        return HStack(spacing: 0) {
            stat("MEAS", "\(s.validCount)")
            stat("AVG", fmt(s.meanMilliseconds))
            stat("MED", fmt(s.medianMilliseconds))
            stat("VAR", fmt(s.standardDeviationMilliseconds))
        }
        .background(VenueTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(VenueTheme.dim)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var meters: some View {
        VStack(alignment: .leading, spacing: 6) {
            meter(label: "LUMA", value: session.liveLuminance)
            meter(label: "MIC ", value: min(1, session.liveAudioLevel * 4))
            if session.capture.observedVideoFPS > 0 {
                Text(String(format: "Capture %.1f fps", session.capture.observedVideoFPS))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
            }
        }
    }

    private func meter(label: String, value: Double) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(VenueTheme.dim)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(VenueTheme.line)
                    Rectangle()
                        .fill(VenueTheme.meter)
                        .frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, value)))))
                }
            }
            .frame(height: 8)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            btn("START", VenueTheme.stable) { session.startMeasurement() }
            btn("STOP", VenueTheme.unstable) { session.stopMeasurement() }
            btn("RESET", VenueTheme.dim) { session.reset() }
        }
    }

    private func btn(_ title: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(color.opacity(0.18))
                .foregroundStyle(color)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var calibrateRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                btn("ZERO", VenueTheme.meter) { zeroAsTrue(0) }
                btn("SET TRUE", VenueTheme.early) { showSetTrue = true }
                btn("CLEAR", VenueTheme.dim) { clearCal() }
            }
            if abs(settings.previousCalibrationOffsetMilliseconds - settings.calibrationOffsetMilliseconds) > 0.0001 {
                Button("UNDO LAST CAL") { undoCal() }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VenueTheme.meter)
                    .buttonStyle(.plain)
            }
            Text("ZERO = this reading is actually 0. CLEAR = none applied. 0 cal ≠ zero sensor latency.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(VenueTheme.dim)
                .multilineTextAlignment(.center)
        }
    }

    private var setTrueSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("This source is actually")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                TextField("e.g. 40", text: $knownTrueText)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                Text("AUDIO EARLY is positive (e.g. +40). AUDIO LATE is negative. Stored calibration = measured − known true.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Phone camera and microphone processing can introduce measurement bias. For critical systems, verify results against a known reference.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Spacer()
            }
            .padding()
            .navigationTitle("Set true offset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSetTrue = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let known = Double(knownTrueText.replacingOccurrences(of: " ", with: "")) ?? 0
                        zeroAsTrue(known)
                        showSetTrue = false
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }

    private func zeroAsTrue(_ knownTrue: Double) {
        switch session.applyCalibrationZero(knownTrueOffset: knownTrue) {
        case .noMeasurement:
            calibrateNote = "Cannot zero: no measurement yet. Start and get at least one pair."
        case .applied(let measured, let stored, let known):
            if abs(known) < 0.0001 {
                calibrateNote = String(format: "Zeroed. Stored cal %+.0f ms (measured %+.0f). Displayed offset is now 0.", stored, measured)
            } else {
                calibrateNote = String(format: "Set true %+.0f ms. Stored cal %+.0f ms (measured %+.0f).", known, stored, measured)
            }
        case .nothingToUndo:
            break
        }
    }

    private func clearCal() {
        _ = session.clearCalibration()
        calibrateNote = "Calibration cleared. None applied — not a claim of zero sensor latency."
    }

    private func undoCal() {
        switch session.undoLastCalibration() {
        case .nothingToUndo:
            calibrateNote = "Nothing to undo."
        case .applied(_, let stored, _):
            if abs(stored) < 0.0001 {
                calibrateNote = "Undo: calibration none applied."
            } else {
                calibrateNote = String(format: "Undo: restored cal %+.0f ms.", stored)
            }
        case .noMeasurement:
            break
        }
    }

    private var distanceNote: some View {
        Text("Sound ≈ 343 m/s  ·  ≈ 1.1 ft/ms. Distance is informational and is not subtracted from the measurement.")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(VenueTheme.dim)
    }

    private func recommendedDelay(_ offsetMs: Double) -> String {
        if offsetMs >= 0 {
            return String(format: "Recommended audio delay: %+.0f ms", offsetMs)
        }
        return String(format: "Reduce audio delay by %.0f ms", abs(offsetMs))
    }

    private func frameLine(_ offsetMs: Double) -> String {
        let frames = settings.frameRate.frames(forMilliseconds: offsetMs)
        return String(format: "%@ fps  /  %+.2f frames", settings.frameRate.displayName, frames)
    }

    private func fmt(_ v: Double) -> String {
        guard session.snapshot.validCount > 0 else { return "—" }
        return String(format: "%+.1f", v)
    }
}
