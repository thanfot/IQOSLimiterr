import SwiftUI

@main
struct IQOSLimiterApp: App {
    @StateObject private var bleManager = IQOSBLEManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
        }
    }
}
