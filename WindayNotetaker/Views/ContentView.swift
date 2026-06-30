import SwiftUI

/// Root view. Shows the sign-in screen until authenticated, then the main
/// two-column window: meeting history on the left, details on the right.
struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var client: SupabaseClient

    var body: some View {
        Group {
            if client.isAuthenticated {
                mainWindow
            } else {
                SignInView()
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var mainWindow: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 260)
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $model.selectedMeetingID) {
            if model.meetDetector.isMeetActive && !model.isRecording {
                Section {
                    Label("A Google Meet call is in progress", systemImage: "video.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
            Section("Meetings") {
                ForEach(model.meetings) { meeting in
                    MeetingRow(meeting: meeting)
                        .tag(meeting.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { model.deleteMeeting(meeting) }
                        }
                }
                if model.meetings.isEmpty {
                    Text("No meetings yet.\nHit Record during a Google Meet call.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let meeting = model.selectedMeeting {
            SummaryView(meeting: meeting)
        } else {
            // Custom placeholder (ContentUnavailableView is macOS 14+).
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Select a meeting").font(.title3.weight(.semibold))
                Text("Your summary, next steps and priorities will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .status) {
            if let status = model.activeStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if model.isRecording {
                Button {
                    Task { await model.stopRecordingAndProcess() }
                } label: {
                    Label("Stop & Summarize", systemImage: "stop.circle.fill")
                }
                .tint(.red)
            } else {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .help("Start recording the current call")
            }
        }
    }
}

/// A single row in the meeting history list.
private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(meeting.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                statusBadge
            }
            Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch meeting.status {
        case .recording:
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .transcribing, .summarizing, .recorded, .exporting:
            ProgressView().controlSize(.mini)
        case .exported:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .ready:
            Image(systemName: "checkmark").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
