import Foundation
import Combine

/// Central app state and orchestration hub.
///
/// Owns the meeting history, the live recorder, and drives the
/// record → transcribe → summarize → export pipeline. SwiftUI views observe it.
@MainActor
final class AppViewModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selectedMeetingID: Meeting.ID?

    /// Non-nil while a recording or pipeline run is in progress.
    @Published var activeStatus: String?
    @Published var errorMessage: String?

    /// Auto-push every finished summary to Notion when Notion is configured.
    @Published var autoExportToNotion: Bool {
        didSet { UserDefaults.standard.set(autoExportToNotion, forKey: "auto_export_notion") }
    }

    let recorder = AudioRecorder()
    let meetDetector = MeetDetector()

    private let config = Config.shared
    private let store = MeetingStore.shared
    private var recordingMeetingID: Meeting.ID?

    init() {
        meetings = store.load()
        autoExportToNotion = UserDefaults.standard.bool(forKey: "auto_export_notion")
        meetDetector.startMonitoring()
    }

    var selectedMeeting: Meeting? {
        meetings.first { $0.id == selectedMeetingID }
    }

    var isRecording: Bool { recorder.isRecording }

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
        guard config.isTranscriptionConfigured else {
            errorMessage = "Add your Deepgram API key in Settings to transcribe."
            return
        }
        guard config.isSummaryConfigured else {
            errorMessage = "Add your Gemini API key in Settings to summarize."
            return
        }

        let pipeline = PipelineCoordinator(config: config)
        do {
            let result = try await pipeline.process(meeting, autoExport: autoExportToNotion) { [weak self] stage in
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
            errorMessage = "Add your Notion token and database ID in Settings."
            return
        }
        guard let summary = meeting.summary else {
            errorMessage = "This meeting has no summary to export yet."
            return
        }
        activeStatus = "Sending to Notion…"
        let pipeline = PipelineCoordinator(config: config)
        do {
            var updated = meeting
            updated.notionPageURL = try await pipeline.export(meeting, summary: summary)
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
