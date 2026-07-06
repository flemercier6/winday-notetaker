import SwiftUI
import AppKit

/// Contents of the menu-bar dropdown. The app has no main window, so this is the
/// entry point to the recorder popup, settings, account and quit.
struct MenuBarContent: View {
    @ObservedObject private var client = SupabaseClient.shared
    @ObservedObject private var model = AppViewModel.shared

    var body: some View {
        if client.isAuthenticated {
            Text(client.email ?? "Signed in").foregroundStyle(.secondary)
            Button(model.isRecording ? "Show recorder (recording…)" : "Open recorder") {
                model.showPopup()
            }
        } else {
            Button("Sign in…") { model.showPopup() }
        }

        Divider()

        Button("Settings…") { openSettings() }

        Divider()

        Button("Quit Winday Notetaker") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // macOS 13+ Settings selector.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
