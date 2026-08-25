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
            ScrollView {
            VStack(spacing: 10) {
                header
                preview
                resultBlock
                statsRow
                recentTable
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
            VStack(alignment: .leading, spacing: 1) {
                Text("AV SYNC METER")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
                Text(AppVersion.label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
            }
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
        .frame(maxHeight: 200)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(VenueTheme.line, lineWidth: 1)
        )
    }

    private var resultBlock: some View {
        let offset = session.snapshot.correctedMedianMilliseconds
        let settling = session.runState != .idle && !session.clockSnapshot.settled && offset == nil
        let direction: String = {
            if settling { return "CLOCK SETTLING" }
            return offset.map { MeasurementSession.headline($0) } ?? (session.runState == .idle ? "IDLE" : "LISTENING")
        }()
        let color: Color = {
            if settling { return VenueTheme.meter }
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
                Text(settling ? "Warming capture clock — pairs not published" : "No pairs yet")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
            }
            Text("Headline / Mitti delay = CORRECTED median")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(VenueTheme.dim)
            rawCorrectedRow
            stabilityBadge
            walkBadge
            calibrationBadge
            honestyLine
            pcmHint
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

    private var walkBadge: some View {
        Group {
            if session.runState != .idle && !session.clockSnapshot.settled && session.snapshot.validCount == 0 {
                Text("WALK — (clock settling)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(VenueTheme.meter)
            } else if let walk = session.snapshot.walkMsPerEvent {
                let green = session.snapshot.walkLooksStable
                Text(String(format: "WALK %+.2f ms/beep", walk))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(green ? VenueTheme.stable : VenueTheme.unstable)
            } else {
                Text("WALK — (need ≥8)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
            }
        }
    }

    private var calibrationBadge: some View {
        Group {
            if session.snapshot.calibrationApplied {
                Text(String(format: "Cal: %+.0f ms applied. ZERO can make CORRECTED 0 — not lab-grade.", session.snapshot.calibrationOffsetMilliseconds))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VenueTheme.early)
                    .multilineTextAlignment(.center)
            } else {
                Text("Cal: none applied")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
            }
        }
    }

    private var rawCorrectedRow: some View {
        let raw = session.snapshot.validCount > 0 ? session.snapshot.medianMilliseconds : nil
        let corr = session.snapshot.correctedMedianMilliseconds
        let corrNote = session.snapshot.calibrationApplied ? "after cal" : "same as RAW (none applied)"
        return HStack(spacing: 8) {
            offsetColumn(title: "RAW", value: raw, note: "phone measurement")
            offsetColumn(title: "CORRECTED", value: corr, note: corrNote)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private func offsetColumn(title: String, value: Double?, note: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(VenueTheme.meter)
            if let value {
                Text(String(format: "%+.0f ms", value))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            } else {
                Text("— ms")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
            }
            Text(note)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(VenueTheme.dim)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var honestyLine: some View {
        Text("Not laboratory-grade. Type the number into Mitti (app does not push delay). Use a PCM test file. Start the file from the beginning (10 s lead-in). Harkwood Sync-One2 files: external only, not bundled — harkwood.co.uk/products/sync-one2/test-files/")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(VenueTheme.dim)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }

    private var pcmHint: some View {
        Text("PCM stereo, start from the beginning.")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(VenueTheme.meter)
            .padding(.top, 2)
    }

    private var recentTable: some View {
        let samples = session.snapshot.recentValidSamples
        let cal = session.snapshot.calibrationOffsetMilliseconds
        let total = session.snapshot.validCount
        let rowHeight: CGFloat = 15
        let visibleRows = min(max(samples.count, 1), 15)
        return VStack(alignment: .leading, spacing: 2) {
            Text("LAST 25 VALID · newest first · scroll")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(VenueTheme.dim)
            HStack(spacing: 0) {
                tableCell("#", dim: true, width: 28, align: .leading)
                tableCell("MS", dim: true, width: 72, align: .trailing)
                tableCell("DIR", dim: true, width: 64, align: .leading)
                tableCell("FR", dim: true, width: 56, align: .trailing)
                Spacer(minLength: 0)
            }
            if samples.isEmpty {
                Text("No valid samples")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(samples.enumerated()), id: \.element.id) { index, sample in
                            let seq = total - index
                            let corrected = sample.offsetMilliseconds - cal
                            let dir: String = {
                                if abs(corrected) < 0.5 { return "SYNC" }
                                return corrected > 0 ? "EARLY" : "LATE"
                            }()
                            let color: Color = {
                                if abs(corrected) < 0.5 { return VenueTheme.stable }
                                return corrected > 0 ? VenueTheme.early : VenueTheme.late
                            }()
                            let frames = settings.frameRate.frames(forMilliseconds: corrected)
                            HStack(spacing: 0) {
                                tableCell(String(format: "%02d", seq), dim: false, width: 28, align: .leading)
                                tableCell(String(format: "%+.0f", corrected), dim: false, width: 72, align: .trailing)
                                tableCell(dir, dim: false, width: 64, align: .leading, color: color)
                                tableCell(String(format: "%+.2f", frames), dim: true, width: 56, align: .trailing)
                                Spacer(minLength: 0)
                            }
                            .frame(height: rowHeight)
                        }
                    }
                }
                .frame(height: CGFloat(visibleRows) * rowHeight)
                .scrollIndicators(.visible)
                .background(Color.black.opacity(0.35))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VenueTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func tableCell(_ text: String, dim: Bool, width: CGFloat, align: Alignment, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color ?? (dim ? VenueTheme.dim : Color.white))
            .frame(width: width, alignment: align)
    }

    private var statsRow: some View {
        let s = session.snapshot
        return HStack(spacing: 0) {
            stat("MEAS", "\(s.validCount)")
            stat("AVG", fmt(s.meanMilliseconds))
            stat("MED", fmt(s.medianMilliseconds))
            stat("VAR", fmt(s.standardDeviationMilliseconds))
            stat("SPAN", fmt(s.spanMilliseconds))
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
                Text(FrameRate.captureFooter(observedFPS: session.capture.observedVideoFPS, picker: settings.frameRate))
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
