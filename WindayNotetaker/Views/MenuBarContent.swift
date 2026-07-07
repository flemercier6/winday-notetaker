import SwiftUI
import AppKit

/// The menu-bar dropdown, rendered as a custom panel (menuBarExtraStyle(.window))
/// styled like the Winday CRM popovers: #F9F8F7 card, Inter typography, black
/// primary / #888 secondary text, hairline separators, and CRM-style status
/// tags. Lists the recorded meetings with their state; each row exposes
/// process / open-in-Notion / delete actions on hover.
struct MenuBarContent: View {
    @ObservedObject private var client = SupabaseClient.shared
    @ObservedObject private var model = AppViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
                .padding(.bottom, 4)

            if client.isAuthenticated {
                if model.isRecording {
                    MenuActionRow("Stop & save", icon: "stop.circle") {
                        Task { await model.stopRecordingAndProcess() }
                    }
                    MenuActionRow("Discard recording", icon: "xmark.circle", destructive: true) {
                        Task { await model.cancelRecording() }
                    }
                    MenuActionRow("Show recorder", icon: "record.circle") { model.showPopup() }
                } else {
                    MenuActionRow("Open recorder", icon: "record.circle") { model.showPopup() }
                }

                hairline
                recordingsSection
                hairline
            } else {
                MenuActionRow("Sign in…", icon: "person.crop.circle") { model.showPopup() }
                hairline
            }

            settingsRow
            if client.isAuthenticated {
                MenuActionRow("Sign out", icon: "rectangle.portrait.and.arrow.right") {
                    client.signOut()
                    model.showPopup()
                }
            }
            MenuActionRow("Quit Winday Notetaker", icon: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(10)
        .frame(width: 300)
        .background(WindayTheme.popupBackground)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image("WindayLogo")
                .resizable().renderingMode(.template).scaledToFit()
                .foregroundStyle(WindayTheme.textPrimary)
                .frame(width: 15, height: 15)
            Text("Winday Notetaker")
                .font(WindayTheme.font(12, .semibold))
                .foregroundStyle(WindayTheme.textPrimary)
            Spacer()
            if let email = client.email {
                Text(email)
                    .font(WindayTheme.font(10))
                    .foregroundStyle(WindayTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 130, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    // MARK: Recordings

    @ViewBuilder
    private var recordingsSection: some View {
        let items = model.meetings.filter { $0.status != .recording }.prefix(12)

        Text("Recordings")
            .font(WindayTheme.font(12, .semibold))
            .foregroundStyle(WindayTheme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

        if items.isEmpty {
            Text("No recordings yet")
                .font(WindayTheme.font(11))
                .foregroundStyle(WindayTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
        } else {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(items)) { meeting in
                        RecordingRow(meeting: meeting, model: model)
                    }
                }
            }
            .frame(maxHeight: 230)
        }
    }

    // MARK: Settings row (SettingsLink is the reliable opener on macOS 14+)

    @ViewBuilder
    private var settingsRow: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                MenuRowLabel("Settings…", icon: "gearshape")
            }
            .buttonStyle(.plain)
        } else {
            MenuActionRow("Settings…", icon: "gearshape") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    private var hairline: some View {
        Rectangle().fill(WindayTheme.border).frame(height: 1)
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
    }
}

// MARK: - Recording row

/// One recorded meeting: status dot + title + CRM-style status tag; hovering
/// swaps the tag for the row's actions (process / open in Notion / delete).
private struct RecordingRow: View {
    let meeting: Meeting
    let model: AppViewModel

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 6, height: 6)

            Text(meeting.title)
                .font(WindayTheme.font(12))
                .foregroundStyle(WindayTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if hovering && !isBusy {
                actions
            } else {
                statusTag
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(hovering ? Color.black.opacity(0.045) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: hovering)
    }

    private var isBusy: Bool {
        switch meeting.status {
        case .transcribing, .summarizing, .exporting: return true
        default: return false
        }
    }

    // Actions shown on hover.
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if meeting.status == .recorded || meeting.status == .failed {
                iconButton("waveform", help: "Transcribe & summarize") {
                    Task { await model.retryProcessing(meeting) }
                }
            }
            if meeting.status == .ready, meeting.notionPageURL == nil {
                iconButton("paperplane", help: "Send to Notion") {
                    Task { await model.exportMeetingToNotion(meeting) }
                }
            }
            if let s = meeting.notionPageURL, let url = URL(string: s) {
                iconButton("arrow.up.right.square", help: "Open in Notion") {
                    NSWorkspace.shared.open(url)
                }
            }
            iconButton("trash", help: "Delete", destructive: true) {
                model.discardMeeting(meeting)
            }
        }
    }

    private func iconButton(_ systemName: String, help: String,
                            destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(destructive ? .red : WindayTheme.textSecondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // CRM-style tag (like "Closed Won" / "Malt" in the popover).
    private var statusTag: some View {
        Text(tag.label)
            .font(WindayTheme.font(10, .medium))
            .foregroundStyle(tag.fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tag.bg, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(tag.border, lineWidth: 0.5))
    }

    private var tag: (label: String, bg: Color, border: Color, fg: Color) {
        // Palettes lifted from the CRM tags: green (Closed Won), orange (Malt),
        // neutral gray (€ amounts).
        let green = (Color(red: 0.847, green: 1.0, blue: 0.902),
                     Color(red: 0.694, green: 0.925, blue: 0.788),
                     Color(red: 0.0, green: 0.361, blue: 0.212))
        let orange = (Color(red: 1.0, green: 0.918, blue: 0.859),
                      Color(red: 0.925, green: 0.773, blue: 0.694),
                      Color(red: 0.537, green: 0.161, blue: 0.0))
        let gray = (Color(red: 0.945, green: 0.945, blue: 0.945),
                    Color(red: 0.894, green: 0.894, blue: 0.894),
                    Color(red: 0.447, green: 0.451, blue: 0.455))

        switch meeting.status {
        case .exported: return ("In Notion", green.0, green.1, green.2)
        case .ready: return ("Summarized", green.0, green.1, green.2)
        case .failed: return ("Failed", orange.0, orange.1, orange.2)
        case .transcribing, .summarizing, .exporting:
            return ("Processing…", gray.0, gray.1, gray.2)
        default: return ("Not processed", gray.0, gray.1, gray.2)
        }
    }

    private var dotColor: Color {
        switch meeting.status {
        case .exported, .ready: return Color(red: 0.06, green: 0.73, blue: 0.51)
        case .failed: return .orange
        case .transcribing, .summarizing, .exporting: return .yellow
        default: return WindayTheme.textSecondary.opacity(0.6)
        }
    }
}

// MARK: - Menu rows

/// Row label with hover highlight — used by both buttons and SettingsLink.
private struct MenuRowLabel: View {
    let title: String
    let icon: String
    var destructive = false

    @State private var hovering = false

    init(_ title: String, icon: String, destructive: Bool = false) {
        self.title = title
        self.icon = icon
        self.destructive = destructive
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(destructive ? .red : WindayTheme.textSecondary)
                .frame(width: 15)
            Text(title)
                .font(WindayTheme.font(12.5))
                .foregroundStyle(destructive ? .red : WindayTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(hovering ? Color.black.opacity(0.045) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: hovering)
    }
}

private struct MenuActionRow: View {
    let title: String
    let icon: String
    var destructive = false
    let action: () -> Void

    init(_ title: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            MenuRowLabel(title, icon: icon, destructive: destructive)
        }
        .buttonStyle(.plain)
    }
}
