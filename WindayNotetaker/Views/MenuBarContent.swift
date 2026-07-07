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
            if model.isRecording {
                Button("Stop & save") { Task { await model.stopRecordingAndProcess() } }
                Button("Discard recording") { Task { await model.cancelRecording() } }
                Button("Show recorder") { model.showPopup() }
            } else {
                Button("Open recorder") { model.showPopup() }
            }
        } else {
            Button("Sign in…") { model.showPopup() }
        }

        Divider()

        Button("Settings…") { openSettings() }

        if client.isAuthenticated {
            Button("Sign out") {
                client.signOut()
                model.showPopup()
            }
        }

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
