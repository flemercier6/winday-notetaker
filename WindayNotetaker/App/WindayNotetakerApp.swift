import SwiftUI
import AppKit

@main
struct WindayNotetakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            // Constrain the icon to the menu-bar height (the raw asset is large).
            Image("WindayLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
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
