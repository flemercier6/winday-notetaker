import SwiftUI

@main
struct WindayNotetakerApp: App {
    @StateObject private var model = AppViewModel()
    @StateObject private var config = Config.shared
    @StateObject private var client = SupabaseClient.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(config)
                .environmentObject(client)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environmentObject(config)
                .environmentObject(client)
                .environmentObject(model)
        }
    }
}
