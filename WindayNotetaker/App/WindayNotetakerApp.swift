import SwiftUI
import AppKit
import ServiceManagement

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
        // Custom CRM-styled panel instead of a native NSMenu (which can't be
        // themed): rows, hover states and status tags are SwiftUI views.
        .menuBarExtraStyle(.window)

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
        // Never render an empty (invisible) status item: fall back to a system
        // symbol if the asset can't be loaded for any reason.
        let fallback = NSImage(systemSymbolName: "waveform.circle.fill",
                               accessibilityDescription: "Winday Notetaker") ?? NSImage()
        fallback.isTemplate = true
        return fallback
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
        registerLaunchAtLoginOnce()
        AppViewModel.shared.beginAgent()
    }

    /// A menu-bar agent is useless when it isn't running, so opt into launch
    /// at login on first run. Done exactly once — if the user turns the toggle
    /// off in Settings afterwards, we never force it back on.
    private func registerLaunchAtLoginOnce() {
        let key = "wn_didAutoRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
    }

    /// Escape hatch when the menu-bar icon is hidden (crowded menu bar / notch):
    /// launching the app again (Spotlight, Finder, Dock) lands here on the
    /// running instance and surfaces the recorder popup.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppViewModel.shared.showPopup()
        return true
    }
}
