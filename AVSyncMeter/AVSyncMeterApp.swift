import SwiftUI

enum AppVersion {
    static var label: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.2"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(marketing) (\(build))"
    }
}

@main
struct AVSyncMeterApp: App {
    @StateObject private var session = MeasurementSession()

    var body: some Scene {
        WindowGroup {
            MeasurementView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}
