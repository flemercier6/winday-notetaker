import Foundation
import Combine
import AppKit

/// Central app state and orchestration hub. Runs as a background agent: it
/// watches for meetings, shows the floating popup, and drives the
/// record → upload → transcribe → summarize → export pipeline through Supabase.
@MainActor
final class AppViewModel: ObservableObject {
    static let shared = AppViewModel()

    @Published var meetings: [Meeting] = []

    /// Non-nil while a recording or pipeline run is in progress.
    @Published var activeStatus: String?
    @Published var errorMessage: String?

    let recorder = AudioRecorder()
    let meetDetector = MeetDetector()
    let client = SupabaseClient.shared

    private let config = Config.shared
    private let store = MeetingStore.shared
    private let panel = FloatingPanelController()
    private var cancellables = Set<AnyCancellable>()
    private var recordingMeetingID: Meeting.ID?
    private var agentStarted = false
    /// User closed the popup for the current meeting — don't auto-reopen it.
    private var dismissed = false

    init() {
        meetings = store.load()
        meetDetector.startMonitoring()

        // Re-publish nested ObservableObject changes so views observing this
        // model update on mic level and meeting-detection changes.
        recorder.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        meetDetector.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var isRecording: Bool { recorder.isRecording }

    // MARK: - Agent lifecycle (called from AppDelegate)

    func beginAgent() {
        guard !agentStarted else { return }
        agentStarted = true

        let popup = RecorderPopup()
            .environmentObject(self)
            .environmentObject(SupabaseClient.shared)
            .environmentObject(Config.shared)
        panel.configure(popup)

        // Show/hide the popup as meetings come and go, or recording starts/stops.
        meetDetector.$isMeetActive
            .combineLatest(meetDetector.$micInUse)
            .receive(on: RunLoop.main)
            .sink { [weak self] meet, mic in self?.updatePopup(meetingLikely: meet || mic) }
            .store(in: &cancellables)

        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updatePopup(meetingLikely: self.meetDetector.meetingLikely)
            }
            .store(in: &cancellables)
    }

    // MARK: - Popup visibility

    func showPopup() {
        dismissed = false
        NSApp.activate(ignoringOtherApps: true)
        panel.show()
    }

    func hidePopup() {
        dismissed = true
        panel.hide()
    }

    private func updatePopup(meetingLikely likely: Bool) {
        // Reset the dismiss latch once the meeting is over.
        if !likely && !isRecording { dismissed = false }
        let shouldShow = isRecording || activeStatus != nil || (likely && !dismissed)
        if shouldShow { panel.show() } else { panel.hide() }
    }

    // MARK: - Recording

    func startRecording() async {
        errorMessage = nil
        guard client.isAuthenticated else {
            errorMessage = "Sign in first."
            return
        }
        let name = "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))"
        var meeting = Meeting(title: name, status: .recording)
        let url = store.newRecordingURL(for: meeting)
        meeting.audioFileURL = url

        do {
            // Scope capture to the detected Meet window when we have one.
            recorder.targetWindowID = meetDetector.meetWindowID
            try await recorder.start(to: url)
            recordingMeetingID = meeting.id
            meetings.insert(meeting, at: 0)
            persist()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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
            errorMessage = "Sign in to process meetings."
            return
        }
        await syncSettings()

        let pipeline = PipelineCoordinator(client: client, config: config)
        do {
            let result = try await pipeline.process(meeting, autoExport: config.autoExportToNotion) { [weak self] stage in
                Task { @MainActor in self?.activeStatus = stage.rawValue }
            }
            update(result)
            activeStatus = nil
            // Meeting handled — hide the popup shortly after unless still in a call.
            updatePopup(meetingLikely: meetDetector.meetingLikely)
        } catch {
            var failed = meeting
            failed.status = .failed
            failed.errorMessage = error.localizedDescription
            update(failed)
            errorMessage = error.localizedDescription
            activeStatus = nil
        }
    }

    func exportToNotion(_ meeting: Meeting) async {
        guard config.isNotionConfigured else {
            errorMessage = "Set your Notion database ID in Settings → Notion."
            return
        }
        guard meeting.summary != nil else { return }
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

    // MARK: - Settings sync

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
