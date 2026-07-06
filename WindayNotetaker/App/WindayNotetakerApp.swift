import SwiftUI
import AppKit

@main
struct WindayNotetakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            // The MenuBarExtra label ignores SwiftUI .frame on some macOS
            // versions, so we resize the NSImage itself (18pt, template).
            Image(nsImage: menuBarIcon())
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
/// A copy of the Winday logo resized to the menu-bar height (~18pt), rendered
/// as a template so macOS tints it for light/dark menu bars.
@MainActor
func menuBarIcon() -> NSImage {
    guard let base = NSImage(named: "WindayLogo"), let img = base.copy() as? NSImage else {
        return NSImage()
    }
    let height: CGFloat = 18
    let width = img.size.height > 0 ? height * (img.size.width / img.size.height) : height
    img.size = NSSize(width: width, height: height)
    img.isTemplate = true
    return img
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppViewModel.shared.beginAgent()
    }
}
