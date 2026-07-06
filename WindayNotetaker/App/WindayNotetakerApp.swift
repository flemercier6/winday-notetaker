import SwiftUI
import AppKit

@main
struct WindayNotetakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Winday Notetaker", image: "WindayLogo") {
            MenuBarContent()
        }

        Settings {
            SettingsView()
                .environmentObject(Config.shared)
                .environmentObject(SupabaseClient.shared)
                .environmentObject(AppViewModel.shared)
        }
    }
}

/// Runs the app as a background agent: no Dock icon (LSUIElement), no main
/// window. The floating recorder popup + menu bar are the whole UI.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppViewModel.shared.beginAgent()
    }
}
