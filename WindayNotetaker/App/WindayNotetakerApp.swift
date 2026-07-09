import SwiftUI
import AppKit
import ServiceManagement

@main
struct WindayNotetakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Main dashboard: a regular window (with a Dock icon) listing the
        // recorded calls. The floating recorder popups still appear on top
        // during meetings; the menu-bar icon remains for quick access.
        Window("Winday Notetaker", id: "dashboard") {
            DashboardView()
                .environmentObject(Config.shared)
                .environmentObject(SupabaseClient.shared)
                .environmentObject(AppViewModel.shared)
        }
        .defaultSize(width: 680, height: 520)

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
        registerLaunchAtLoginOnce()
        AppViewModel.shared.beginAgent()
    }

    /// The recorder should always be running so calls are never missed, so opt
    /// into launch at login on first run. Done exactly once — if the user turns
    /// the toggle off in Settings afterwards, we never force it back on.
    private func registerLaunchAtLoginOnce() {
        let key = "wn_didAutoRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
    }

    /// Clicking the Dock icon (or relaunching) with no visible window reopens
    /// the dashboard — AppKit handles it when we return true.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        return true
    }

    /// Closing the dashboard window must not quit the app: the agent keeps
    /// watching the calendar/browser and recording meetings in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
