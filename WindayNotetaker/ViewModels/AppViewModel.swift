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
    /// Set when recording starts (drives the live elapsed timer).
    @Published var recordingStartedAt: Date?
    /// Brief success message shown before the popup auto-dismisses.
    @Published var doneFlash: String?
    /// Set when processing failed but the transcript (or summary) is preserved,
    /// so the popup can offer a Retry that resumes from the failed step.
    @Published var failedMeeting: Meeting?

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
        // Reset the dismiss latch once the meeting is over and nothing is pending.
        if !likely && !isRecording && activeStatus == nil && failedMeeting == nil { dismissed = false }
        let shouldShow = isRecording || activeStatus != nil || failedMeeting != nil || (likely && !dismissed)
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
            recordingStartedAt = Date()
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
        recordingStartedAt = nil

        guard var meeting = meetings.first(where: { $0.id == id }) else { return }
        meeting.endedAt = Date()
        meeting.status = .recorded
        update(meeting)

        await runPipeline(for: meeting)
    }

    /// Stop recording and DISCARD it — no transcript, no summary. Removes the
    /// in-progress meeting and its audio file, then hides the popup.
    func cancelRecording() async {
        guard let id = recordingMeetingID else { return }
        await recorder.stop()
        recordingMeetingID = nil
        recordingStartedAt = nil

        if let meeting = meetings.first(where: { $0.id == id }),
           let url = meeting.audioFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        meetings.removeAll { $0.id == id }
        persist()
        activeStatus = nil
        hidePopup()
    }

    // MARK: - Pipeline

    func runPipeline(for meeting: Meeting) async {
        guard client.isAuthenticated else {
            errorMessage = "Sign in to process meetings."
            return
        }
        failedMeeting = nil
        await syncSettings()

        let pipeline = PipelineCoordinator(client: client, config: config)
        do {
            let result = try await pipeline.process(meeting, autoExport: config.autoExportToNotion) { [weak self] stage in
                Task { @MainActor in self?.activeStatus = stage.rawValue }
            }
            update(result)
            activeStatus = nil
            finish(result)
        } catch {
            // Upload/transcribe failure — nothing was captured yet.
            var failed = meeting
            failed.status = .failed
            failed.errorMessage = error.localizedDescription
            update(failed)
            activeStatus = nil
            presentFailure(failed)
        }
    }

    /// Retry a failed meeting, resuming from the first missing step (transcript →
    /// summary → export). The transcript/summary already obtained are reused, so
    /// a Gemini rate-limit only re-runs the summary, never the whole call.
    func retryProcessing(_ meeting: Meeting) async {
        guard client.isAuthenticated else { return }
        failedMeeting = nil

        // Never uploaded — redo the whole pipeline from scratch.
        if meeting.audioPath == nil {
            await runPipeline(for: meeting)
            return
        }

        var m = meeting
        m.errorMessage = nil
        await syncSettings()
        let pipeline = PipelineCoordinator(client: client, config: config)
        do {
            if m.transcript == nil {
                activeStatus = PipelineCoordinator.Stage.transcribing.rawValue
                m = try await pipeline.transcribeOnly(m)
            }
            if m.summary == nil {
                activeStatus = PipelineCoordinator.Stage.summarizing.rawValue
                m = try await pipeline.summarizeOnly(m)
            }
            if config.autoExportToNotion && config.isNotionConfigured && m.notionPageURL == nil {
                activeStatus = PipelineCoordinator.Stage.exporting.rawValue
                m.notionPageURL = try await pipeline.export(m)
                m.status = .exported
            }
            m.errorMessage = nil
            update(m)
            activeStatus = nil
            finish(m)
        } catch {
            m.status = .failed
            m.errorMessage = error.localizedDescription
            update(m)
            activeStatus = nil
            presentFailure(m)
        }
    }

    /// Dismiss the failed state (give up on the retry).
    func dismissFailure() {
        failedMeeting = nil
        hidePopup()
    }

    // MARK: Pipeline result handling

    private func finish(_ meeting: Meeting) {
        if meeting.errorMessage != nil {
            presentFailure(meeting)
        } else {
            failedMeeting = nil
            doneFlash = meeting.notionPageURL != nil ? "Sent to Notion" : "Summary ready"
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self?.doneFlash = nil
                self?.hidePopup()
            }
        }
    }

    private func presentFailure(_ meeting: Meeting) {
        failedMeeting = meeting
        activeStatus = nil
        updatePopup(meetingLikely: true)   // keep the popup up so Retry is reachable
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
