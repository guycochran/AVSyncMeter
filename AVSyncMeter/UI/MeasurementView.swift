import SwiftUI

struct MeasurementView: View {
    @EnvironmentObject private var session: MeasurementSession
    @ObservedObject private var settings = AppSettings.shared
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var showTestSignal = false

    var body: some View {
        ZStack {
            VenueTheme.bg.ignoresSafeArea()
            VStack(spacing: 8) {
                header
                    .padding(.horizontal, 14)
                VStack(spacing: 10) {
                    preview
                    resultBlock
                    spanStableLine
                    setupLine
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 0)
                controls
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
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
        .frame(maxHeight: 148)
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
            return offset.map { SyncSignConvention.typeThisHeadline($0) } ?? (session.runState == .idle ? "IDLE" : "LISTENING")
        }()
        let color: Color = {
            if settling { return VenueTheme.meter }
            guard let offset else { return VenueTheme.dim }
            switch SyncSignConvention.typeThisDirection(offset) {
            case .inSync: return VenueTheme.stable
            case .audioLate: return VenueTheme.late
            case .audioEarly: return VenueTheme.early
            }
        }()
        return VStack(spacing: 4) {
            Text(direction)
                .font(.system(size: 28, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let offset {
                Text(String(format: "%+.0f ms", SyncSignConvention.typeIncrease(offsetMilliseconds: offset)))
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(SyncSignConvention.typeThisAdvice(offset))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VenueTheme.meter)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(SyncSignConvention.typeThisCaption)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
                    .lineLimit(1)
            } else {
                Text("— ms")
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
                Text(settling ? "Warming capture clock — pairs not published" : "No pairs yet")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(VenueTheme.dim)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(VenueTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var spanStableLine: some View {
        let s = session.snapshot
        let span: String = {
            guard s.validCount > 0 else { return "—" }
            return String(format: "%+.1f", s.spanMilliseconds)
        }()
        let stable = s.isStable
        let stableText = s.validCount > 0 ? (stable ? "STABLE" : "UNSTABLE") : "—"
        let stableColor: Color = {
            guard s.validCount > 0 else { return VenueTheme.dim }
            return stable ? VenueTheme.stable : VenueTheme.unstable
        }()
        return HStack(spacing: 10) {
            Text("SPAN \(span)")
                .foregroundStyle(VenueTheme.dim)
            Text("·")
                .foregroundStyle(VenueTheme.dim)
            Text(stableText)
                .foregroundStyle(stableColor)
        }
        .font(.system(size: 13, weight: .bold, design: .monospaced))
        .frame(maxWidth: .infinity)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var setupLine: some View {
        Text(SyncSignConvention.measureRecipe.joined(separator: " "))
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(VenueTheme.meter)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
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
                .padding(.vertical, 10)
                .background(color.opacity(0.18))
                .foregroundStyle(color)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
