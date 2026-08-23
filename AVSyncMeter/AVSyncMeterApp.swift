import SwiftUI

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
