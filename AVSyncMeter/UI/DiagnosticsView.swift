import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var session: MeasurementSession
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var demoOffset: Double = 200
    @State private var showSetTrue = false
    @State private var knownTrueText = "0"
    @State private var calibrateNote: String?

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
                    labeled("SPAN", session.snapshot.validCount > 0 ? String(format: "%+.1f ms", session.snapshot.spanMilliseconds) : "—")
                    labeled("STABLE", session.snapshot.validCount > 0 ? (session.snapshot.isStable ? "yes" : "no") : "—")
                    if let offset = session.snapshot.correctedMedianMilliseconds {
                        labeled("Median", String(format: "%+.0f ms  %@", offset, MeasurementSession.headline(offset)))
                        labeled("Advice", SyncSignConvention.recommendedDelay(offset))
                        labeled("Frames", String(format: "%@ fps  /  %+.2f", settings.frameRate.displayName, settings.frameRate.frames(forMilliseconds: offset)))
                    }
                }

                Section("RAW / CORRECTED") {
                    Text("Headline / Mitti delay = CORRECTED median")
                        .font(.system(.footnote, design: .monospaced))
                    labeled("RAW", rawLabel)
                    labeled("CORRECTED", correctedLabel)
                    if session.snapshot.calibrationApplied {
                        Text(String(format: "Cal: %+.0f ms applied. ZERO can make CORRECTED 0 — not lab-grade.", session.snapshot.calibrationOffsetMilliseconds))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(VenueTheme.early)
                    } else {
                        Text("Cal: none applied")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Calibrate") {
                    HStack(spacing: 8) {
                        diagBtn("ZERO", VenueTheme.meter) { zeroAsTrue(0) }
                        diagBtn("SET TRUE", VenueTheme.early) { showSetTrue = true }
                        diagBtn("CLEAR", VenueTheme.dim) { clearCal() }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    if abs(settings.previousCalibrationOffsetMilliseconds - settings.calibrationOffsetMilliseconds) > 0.0001 {
                        Button("UNDO LAST CAL") { undoCal() }
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(VenueTheme.meter)
                            .buttonStyle(.plain)
                    }
                    if let calibrateNote {
                        Text(calibrateNote)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(VenueTheme.early)
                    }
                    Text("ZERO = this reading is actually 0. CLEAR = none applied. 0 cal ≠ zero sensor latency. SET stays in the header.")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Section("Honesty") {
                    Text("Not laboratory-grade. Type the number into Mitti (app does not push delay). Use a PCM test file. Start the file from the beginning (10 s lead-in). Harkwood Sync-One2 files: external only, not bundled — harkwood.co.uk/products/sync-one2/test-files/")
                        .font(.system(.footnote, design: .monospaced))
                    Text("Audio is always fast — picture is late through the video chain. That is the common house case at delay 0, not a recipe to type AUDIO EARLY when the meter says LATE.")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Section("Last 25 valid · newest first") {
                    last25
                }

                Section("Meters") {
                    meters
                }

                Section("Capture clocks") {
                    let c = session.clockSnapshot
                    labeled("Locked", c.locked ? "yes" : "no")
                    labeled("Settled", c.settled ? "yes — A−V slope frozen, publishing" : "no — pairs held")
                    labeled("Video slope host/pts", String(format: "%.6f  n=%d", c.videoSlope, c.videoObservations))
                    labeled("Audio slope host/pts", String(format: "%.6f  n=%d", c.audioSlope, c.audioObservations))
                    labeled("Video PTS vs host", String(format: "%+.0f ppm", c.videoPpmVersusHost))
                    labeled("Audio PTS vs host", String(format: "%+.0f ppm", c.audioPpmVersusHost))
                    labeled("Relative A−V", String(format: "%.6f  %+.0f ppm", c.relativeSlope, c.relativeDriftPPM))
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
                    Button("Inject 5 stable late pairs (+200 ms)") {
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
            .sheet(isPresented: $showSetTrue) {
                setTrueSheet
            }
        }
        .preferredColorScheme(.dark)
    }

    private var rawLabel: String {
        guard session.snapshot.validCount > 0 else { return "— ms" }
        return String(format: "%+.0f ms  (phone measurement)", session.snapshot.medianMilliseconds)
    }

    private var correctedLabel: String {
        guard let corr = session.snapshot.correctedMedianMilliseconds else { return "— ms" }
        let note = session.snapshot.calibrationApplied ? "after cal" : "same as RAW (none applied)"
        return String(format: "%+.0f ms  (%@)", corr, note)
    }

    private func labeled(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).font(.system(.body, design: .monospaced))
        }
    }

    private func diagBtn(_ title: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(color.opacity(0.18))
                .foregroundStyle(color)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var last25: some View {
        let samples = session.snapshot.recentValidSamples
        let cal = session.snapshot.calibrationOffsetMilliseconds
        let total = session.snapshot.validCount
        let rowHeight: CGFloat = 15
        let visibleRows = min(max(samples.count, 1), 8)
        return VStack(alignment: .leading, spacing: 2) {
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
                            let dir = SyncSignConvention.shortTag(corrected)
                            let color: Color = {
                                switch SyncSignConvention.displayDirection(corrected) {
                                case .audioEarly: return VenueTheme.early
                                case .audioLate: return VenueTheme.late
                                case .inSync: return VenueTheme.stable
                                }
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
    }

    private func tableCell(_ text: String, dim: Bool, width: CGFloat, align: Alignment, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color ?? (dim ? VenueTheme.dim : Color.white))
            .frame(width: width, alignment: align)
    }

    private var meters: some View {
        VStack(alignment: .leading, spacing: 6) {
            meter(label: "LUMA", value: session.liveLuminance, color: VenueTheme.meter)
            meter(label: "MIC ", value: MeterHistory.displayMicLevel(session.liveAudioLevel), color: VenueTheme.late)
            vuHistory
            if session.capture.observedVideoFPS > 0 {
                Text(FrameRate.captureFooter(observedFPS: session.capture.observedVideoFPS, picker: settings.frameRate))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
    }

    private var vuHistory: some View {
        let window = MeterHistory.clampedWindow(settings.meterHistorySeconds)
        let now = session.meterHistory.lastTimestamp
        return VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "VU  last %.0fs  ·  live luma/mic  ·  newest right", window))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(VenueTheme.dim)
            vuStrip(label: "LUMA", color: VenueTheme.meter, now: now, window: window, luma: true)
            vuStrip(label: "MIC ", color: VenueTheme.late, now: now, window: window, luma: false)
            vuMarkLane(now: now, window: window)
            HStack {
                Text(String(format: "−%.0fs", window))
                Spacer()
                Text("NOW")
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(VenueTheme.dim)
            HStack(spacing: 10) {
                legendSwatch(VenueTheme.meter, "FLASH")
                legendSwatch(VenueTheme.late, "AUDIOPULSE")
                legendSwatch(VenueTheme.early, "PAIR")
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(VenueTheme.dim)
        }
    }

    private func vuStrip(label: String, color: Color, now: Double, window: Double, luma: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(VenueTheme.dim)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                let n = max(Int(geo.size.width.rounded()), 1)
                let cols = luma
                    ? session.meterHistory.lumaColumns(now: now, windowSeconds: window, count: n)
                    : session.meterHistory.micColumns(now: now, windowSeconds: window, count: n)
                let marks = session.meterHistory.markKindsByColumn(now: now, windowSeconds: window, count: n)
                Canvas { context, size in
                    let h = size.height
                    let w = size.width
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.35)))
                    guard n > 0, w > 0, h > 0 else { return }
                    let barW = w / CGFloat(n)
                    for (i, v) in cols.enumerated() {
                        let vh = h * CGFloat(min(1, max(0, v)))
                        if vh <= 0.5 { continue }
                        let rect = CGRect(x: CGFloat(i) * barW, y: h - vh, width: max(barW, 1), height: vh)
                        context.fill(Path(rect), with: .color(color))
                    }
                    for (i, kinds) in marks.enumerated() {
                        let x = CGFloat(i) * barW + barW * 0.5
                        if luma, kinds.contains(.flash) {
                            var tri = Path()
                            tri.move(to: CGPoint(x: x, y: 0))
                            tri.addLine(to: CGPoint(x: x - 3.5, y: 7))
                            tri.addLine(to: CGPoint(x: x + 3.5, y: 7))
                            tri.closeSubpath()
                            context.fill(tri, with: .color(.white))
                        }
                        if !luma, kinds.contains(.audioPulse) {
                            var tri = Path()
                            tri.move(to: CGPoint(x: x, y: 0))
                            tri.addLine(to: CGPoint(x: x - 3.5, y: 7))
                            tri.addLine(to: CGPoint(x: x + 3.5, y: 7))
                            tri.closeSubpath()
                            context.fill(tri, with: .color(.white))
                        }
                        if kinds.contains(.pair) {
                            let rect = CGRect(x: x - 1, y: 0, width: 2, height: h)
                            context.fill(Path(rect), with: .color(VenueTheme.early.opacity(0.9)))
                        }
                    }
                }
            }
            .frame(height: 22)
        }
    }

    private func vuMarkLane(now: Double, window: Double) -> some View {
        HStack(spacing: 8) {
            Text("EVT ")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(VenueTheme.dim)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                let n = max(Int(geo.size.width.rounded()), 1)
                let marks = session.meterHistory.markKindsByColumn(now: now, windowSeconds: window, count: n)
                Canvas { context, size in
                    let h = size.height
                    let w = size.width
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.35)))
                    guard n > 0, w > 0, h > 0 else { return }
                    let barW = w / CGFloat(n)
                    for (i, kinds) in marks.enumerated() {
                        let x = CGFloat(i) * barW + barW * 0.5
                        let tickW = max(2.5, barW)
                        if kinds.contains(.flash) {
                            let rect = CGRect(x: x - tickW * 0.5, y: 1, width: tickW, height: h * 0.45)
                            context.fill(Path(rect), with: .color(VenueTheme.meter))
                        }
                        if kinds.contains(.audioPulse) {
                            let rect = CGRect(x: x - tickW * 0.5, y: h * 0.5, width: tickW, height: h * 0.45)
                            context.fill(Path(rect), with: .color(VenueTheme.late))
                        }
                        if kinds.contains(.pair) {
                            let rect = CGRect(x: x - 1, y: 0, width: 2, height: h)
                            context.fill(Path(rect), with: .color(VenueTheme.early))
                        }
                    }
                }
            }
            .frame(height: 10)
        }
    }

    private func meter(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(VenueTheme.dim)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(VenueTheme.line)
                    Rectangle()
                        .fill(color)
                        .frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, value)))))
                }
            }
            .frame(height: 8)
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
                Text("AUDIO LATE is positive (e.g. +40, beep after flash). AUDIO EARLY is negative (e.g. −40). Stored calibration = measured − known true (engine a−v, not inverted).")
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
}
