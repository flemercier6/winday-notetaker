import Foundation
import Combine

/// Central app state and orchestration hub.
///
/// Owns the meeting history, the live recorder, and drives the
/// record → upload → transcribe → summarize → export pipeline through Supabase.
@MainActor
final class AppViewModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selectedMeetingID: Meeting.ID?

    /// Non-nil while a recording or pipeline run is in progress.
    @Published var activeStatus: String?
    @Published var errorMessage: String?

    let recorder = AudioRecorder()
    let meetDetector = MeetDetector()
    let client = SupabaseClient.shared

    private let config = Config.shared
    private let store = MeetingStore.shared
    private var recordingMeetingID: Meeting.ID?

    init() {
        meetings = store.load()
        meetDetector.startMonitoring()
    }

    var selectedMeeting: Meeting? {
        meetings.first { $0.id == selectedMeetingID }
    }

    var isRecording: Bool { recorder.isRecording }

    // MARK: - Settings sync

    /// Mirror the user's non-secret prefs to `user_settings` so the Edge
    /// Functions use the right models / Notion database.
    func syncSettings() async {
        guard let userId = client.userId else { return }
        do {
            try await client.upsertSettings([
                "user_id": userId,
                "notion_database_id": config.notionDatabaseID,
                "auto_export_notion": config.autoExportToNotion,
                "deepgram_model": config.deepgramModel,
                "gemini_model": config.geminiModel,
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Recording

    func startRecording(title: String? = nil) async {
        errorMessage = nil
        let name = title?.isEmpty == false
            ? title!
            : "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))"
        var meeting = Meeting(title: name, status: .recording)
        let url = store.newRecordingURL(for: meeting)
        meeting.audioFileURL = url

        do {
            try await recorder.start(to: url)
            recordingMeetingID = meeting.id
            meetings.insert(meeting, at: 0)
            selectedMeetingID = meeting.id
            activeStatus = "Recording…"
            persist()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stops recording and kicks off the processing pipeline.
    func stopRecordingAndProcess() async {
        guard let id = recordingMeetingID else { return }
        await recorder.stop()
        recordingMeetingID = nil

        guard var meeting = meetings.first(where: { $0.id == id }) else { return }
        meeting.endedAt = Date()
        meeting.status = .recorded
        update(meeting)

        await runPipeline(for: meeting)
    }

    // MARK: - Pipeline

    func runPipeline(for meeting: Meeting) async {
        guard client.isAuthenticated else {
            errorMessage = "Sign in (Settings → Account) to process meetings."
            return
        }

        // Keep settings fresh server-side before the functions read them.
        await syncSettings()

        let pipeline = PipelineCoordinator(client: client, config: config)
        do {
            let result = try await pipeline.process(meeting, autoExport: config.autoExportToNotion) { [weak self] stage in
                Task { @MainActor in self?.activeStatus = stage.rawValue }
            }
            update(result)
            activeStatus = nil
        } catch {
            var failed = meeting
            failed.status = .failed
            failed.errorMessage = error.localizedDescription
            update(failed)
            errorMessage = error.localizedDescription
            activeStatus = nil
        }
    }

    /// Manually (re)export a meeting that already has a summary to Notion.
    func exportToNotion(_ meeting: Meeting) async {
        guard config.isNotionConfigured else {
            errorMessage = "Set your Notion database ID in Settings → Notion."
            return
        }
        guard meeting.summary != nil else {
            errorMessage = "This meeting has no summary to export yet."
            return
        }
        await syncSettings()
        activeStatus = "Sending to Notion…"
        let pipeline = PipelineCoordinator(client: client, config: config)
        do {
            var updated = meeting
            updated.notionPageURL = try await pipeline.export(meeting)
            updated.status = .exported
            update(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
        activeStatus = nil
    }

    func deleteMeeting(_ meeting: Meeting) {
        if let url = meeting.audioFileURL { try? FileManager.default.removeItem(at: url) }
        meetings.removeAll { $0.id == meeting.id }
        if selectedMeetingID == meeting.id { selectedMeetingID = meetings.first?.id }
        persist()
    }

    // MARK: - Helpers

    private func update(_ meeting: Meeting) {
        if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[idx] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
        persist()
    }

    private func persist() { store.save(meetings) }
}
