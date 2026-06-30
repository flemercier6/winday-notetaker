import SwiftUI

@main
struct WindayNotetakerApp: App {
    @StateObject private var model = AppViewModel()
    @StateObject private var config = Config.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(config)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environmentObject(config)
        }
    }
}
