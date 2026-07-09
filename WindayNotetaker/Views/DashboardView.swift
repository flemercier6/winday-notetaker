import SwiftUI
import AppKit

/// The main dashboard window: the list of recorded calls with their state and
/// actions, styled like the Winday CRM (#F9F8F7 surface, Inter typography,
/// CRM status tags). This is the app's primary UI — the menu-bar icon and the
/// floating recorder popups remain as companions during meetings.
struct DashboardView: View {
    @ObservedObject private var client = SupabaseClient.shared
    @ObservedObject private var model = AppViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Rectangle().fill(WindayTheme.border).frame(height: 1)

            if client.isAuthenticated {
                recordingsList
            } else {
                signedOut
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 440, idealHeight: 520)
        .background(WindayTheme.popupBackground)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image("WindayLogo")
                .resizable().renderingMode(.template).scaledToFit()
                .foregroundStyle(WindayTheme.textPrimary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Winday Notetaker")
                    .font(WindayTheme.font(14, .semibold))
                    .foregroundStyle(WindayTheme.textPrimary)
                if let email = client.email {
                    Text(email)
                        .font(WindayTheme.font(10.5))
                        .foregroundStyle(WindayTheme.textSecondary)
                }
            }

            Spacer()

            if client.isAuthenticated {
                if model.isRecording {
                    headerButton("Stop & save", icon: "stop.circle", prominent: true) {
                        Task { await model.stopRecordingAndProcess() }
                    }
                } else {
                    headerButton("Open recorder", icon: "record.circle", prominent: true) {
                        model.showPopup()
                    }
                }
            }
            settingsButton
        }
    }

    private func headerButton(_ title: String, icon: String, prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(title).font(WindayTheme.font(12, .medium))
            }
            .foregroundStyle(prominent ? Color.white : WindayTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(prominent ? WindayTheme.accent : WindayTheme.chipBackground,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WindayTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(WindayTheme.chipBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Settings")
        } else {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WindayTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(WindayTheme.chipBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    // MARK: Signed out

    private var signedOut: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(WindayTheme.textSecondary)
            Text("Sign in to see your recorded calls")
                .font(WindayTheme.font(13))
                .foregroundStyle(WindayTheme.textSecondary)
            Button {
                model.showPopup()
            } label: {
                Text("Sign in…")
                    .font(WindayTheme.font(12.5, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(WindayTheme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Recordings

    @ViewBuilder
    private var recordingsList: some View {
        let items = model.meetings.filter { $0.status != .recording }

        if items.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(WindayTheme.textSecondary)
                Text("No recordings yet")
                    .font(WindayTheme.font(13))
                    .foregroundStyle(WindayTheme.textSecondary)
                Text("Join a Google Meet call and the recorder will offer to capture it.")
                    .font(WindayTheme.font(11.5))
                    .foregroundStyle(WindayTheme.textSecondary.opacity(0.8))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { meeting in
                        DashboardRow(meeting: meeting, model: model)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }
}

// MARK: - Row

/// One recorded call: status dot, title + company/date/duration subtitle, a
/// CRM-style status tag, and the row's actions (always visible).
private struct DashboardRow: View {
    let meeting: Meeting
    let model: AppViewModel

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(WindayTheme.font(12.5, .medium))
                    .foregroundStyle(WindayTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(WindayTheme.font(10.5))
                    .foregroundStyle(WindayTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            if let error = meeting.errorMessage, meeting.status == .failed {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help(error)
            }

            statusTag
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovering ? Color.black.opacity(0.04) : Color.white.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(WindayTheme.border.opacity(0.7), lineWidth: 0.5))
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: hovering)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let company = meeting.calendar?.companyName, !company.isEmpty {
            parts.append(company)
        }
        parts.append(Self.dateFormatter.string(from: meeting.startedAt))
        if let d = meeting.duration, d > 0 {
            parts.append("\(Int((d / 60).rounded())) min")
        }
        return parts.joined(separator: "  ·  ")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    private var isBusy: Bool {
        switch meeting.status {
        case .transcribing, .summarizing, .exporting: return true
        default: return false
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            if !isBusy {
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
                if meeting.status == .ready || meeting.status == .exported,
                   let url = URL(string: "https://crm.winday.app/meetings?m=\(meeting.id.uuidString.lowercased())") {
                    iconButton("rectangle.grid.2x2", help: "Open in Winday CRM") {
                        NSWorkspace.shared.open(url)
                    }
                }
                iconButton("trash", help: "Delete", destructive: true) {
                    model.discardMeeting(meeting)
                }
            } else {
                ProgressView().controlSize(.small).frame(width: 20)
            }
        }
        .frame(minWidth: 96, alignment: .trailing)
    }

    private func iconButton(_ systemName: String, help: String,
                            destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(destructive ? .red : WindayTheme.textSecondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // CRM-style tag (same palette as the menu-bar list).
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
