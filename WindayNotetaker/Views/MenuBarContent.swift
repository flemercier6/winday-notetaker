import SwiftUI
import AppKit

/// Contents of the menu-bar dropdown: account, the current recording controls,
/// the list of recorded meetings with their state (each can be processed or
/// deleted), plus settings / sign-out / quit.
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

            Divider()

            recordingsSection

            Divider()

            settingsItem
            Button("Sign out") {
                client.signOut()
                model.showPopup()
            }
        } else {
            Button("Sign in…") { model.showPopup() }
            Divider()
            settingsItem
        }

        Divider()

        Button("Quit Winday Notetaker") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    // MARK: - Recordings

    @ViewBuilder
    private var recordingsSection: some View {
        if model.meetings.isEmpty {
            Text("No recordings yet").foregroundStyle(.secondary)
        } else {
            Text("Recordings")
            ForEach(model.meetings.prefix(20)) { meeting in
                if isBusy(meeting.status) {
                    // Actively recording/processing: status only, no actions.
                    Text("\(emoji(meeting.status))  \(meeting.title) — \(label(meeting.status))")
                } else {
                    Menu("\(emoji(meeting.status))  \(meeting.title)") {
                        Text(label(meeting.status)).foregroundStyle(.secondary)
                        Divider()
                        processButton(meeting)
                        if let s = meeting.notionPageURL, let url = URL(string: s) {
                            Button("Open in Notion") { NSWorkspace.shared.open(url) }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { model.discardMeeting(meeting) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func processButton(_ meeting: Meeting) -> some View {
        switch meeting.status {
        case .recorded, .failed:
            Button("Transcribe & summarize") { Task { await model.retryProcessing(meeting) } }
        case .ready where meeting.notionPageURL == nil:
            Button("Send to Notion") { Task { await model.exportMeetingToNotion(meeting) } }
        default:
            EmptyView()
        }
    }

    // MARK: - Status helpers

    private func isBusy(_ s: Meeting.Status) -> Bool {
        switch s {
        case .recording, .transcribing, .summarizing, .exporting: return true
        default: return false
        }
    }

    private func emoji(_ s: Meeting.Status) -> String {
        switch s {
        case .recording: return "🔴"
        case .recorded: return "•"
        case .transcribing, .summarizing, .exporting: return "⏳"
        case .ready: return "✓"
        case .exported: return "📤"
        case .failed: return "⚠️"
        }
    }

    private func label(_ s: Meeting.Status) -> String {
        switch s {
        case .recording: return "Recording…"
        case .recorded: return "Not processed yet"
        case .transcribing: return "Transcribing…"
        case .summarizing: return "Summarizing…"
        case .exporting: return "Saving to Notion…"
        case .ready: return "Summarized"
        case .exported: return "Sent to Notion"
        case .failed: return "Failed"
        }
    }

    // MARK: - Settings

    @ViewBuilder
    private var settingsItem: some View {
        // SettingsLink is the reliable way to open the Settings scene from a
        // MenuBarExtra on macOS 14+. The manual selector often no-ops there.
        if #available(macOS 14.0, *) {
            SettingsLink { Text("Settings…") }
        } else {
            Button("Settings…") { openSettings() }
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
