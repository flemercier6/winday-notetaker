import Foundation
import Combine
import AppKit

/// Central app state and orchestration hub. Runs as a background agent: it
/// watches for meetings, shows the top recorder pill + the bottom-right progress
/// popup, and drives record → transcribe → summarize → export through Supabase.
@MainActor
final class AppViewModel: ObservableObject {
    static let shared = AppViewModel()

    @Published var meetings: [Meeting] = []

    @Published var activeStatus: String?
    @Published var errorMessage: String?
    @Published var recordingStartedAt: Date?
    /// Non-nil in the "done" state: shows a confirmation + Open in Notion.
    @Published var doneFlash: String?
    @Published var doneNotionURL: String?
    /// Set when processing failed but the transcript/summary is preserved.
    @Published var failedMeeting: Meeting?

    let recorder = AudioRecorder()
    let meetDetector = MeetDetector()
    let client = SupabaseClient.shared

    private let config = Config.shared
    private let store = MeetingStore.shared
    private let recorderPanel = FloatingPanelController(anchor: .topCenter, autosaveName: "WindayRecorderPanel")
    private let progressPanel = FloatingPanelController(anchor: .bottomTrailing)
    private var cancellables = Set<AnyCancellable>()
    private var recordingMeetingID: Meeting.ID?
    private var agentStarted = false

    /// User hid the top pill with "–": keep it hidden until the meeting is over.
    private var dismissed = false
    /// User opened the recorder from the menu with no meeting in progress.
    private var manuallyShown = false
    /// Auto-end only for recordings tied to a detected Meet window.
    private var autoEndArmed = false
    private var pendingEnd: Task<Void, Never>?

    init() {
        meetings = store.load()
        meetDetector.startMonitoring()

        recorder.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        meetDetector.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        recorder.onExternalStop = { [weak self] in
            Task { @MainActor in await self?.stopRecordingAndProcess() }
        }
    }

    var isRecording: Bool { recorder.isRecording }

    // MARK: - Agent lifecycle

    func beginAgent() {
        guard !agentStarted else { return }
        agentStarted = true

        recorderPanel.configure(RecorderPopup()
            .environmentObject(self)
            .environmentObject(SupabaseClient.shared)
            .environmentObject(Config.shared))
        progressPanel.configure(ProgressPopup()
            .environmentObject(self))

        // Recompute which popup is visible whenever relevant state changes.
        Publishers.MergeMany(
            $activeStatus.map { _ in () }.eraseToAnyPublisher(),
            $doneFlash.map { _ in () }.eraseToAnyPublisher(),
            $failedMeeting.map { _ in () }.eraseToAnyPublisher(),
            recorder.$isRecording.map { _ in () }.eraseToAnyPublisher(),
            meetDetector.$isMeetActive.map { _ in () }.eraseToAnyPublisher(),
            meetDetector.$micInUse.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.updatePopups() }
        .store(in: &cancellables)

        // Auto-end when the Meet window disappears for a sustained period.
        meetDetector.$isMeetActive
            .receive(on: RunLoop.main)
            .sink { [weak self] active in self?.handleMeetPresence(active) }
            .store(in: &cancellables)
    }

    // MARK: - Popup visibility

    func showPopup() {
        dismissed = false
        manuallyShown = true
        NSApp.activate(ignoringOtherApps: true)
        updatePopups()
    }

    /// Hide the top pill ("–"): stays hidden for the rest of this meeting.
    func hidePopup() {
        dismissed = true
        manuallyShown = false
        updatePopups()
    }

    private func updatePopups() {
        let likely = meetDetector.meetingLikely
        let hasProgress = activeStatus != nil || doneFlash != nil || failedMeeting != nil

        if !likely && !isRecording && !hasProgress && !manuallyShown { dismissed = false }

        let recorderVisible = !hasProgress && !dismissed && (isRecording || likely || manuallyShown)
        if recorderVisible { recorderPanel.show() } else { recorderPanel.hide() }
        if hasProgress { progressPanel.show() } else { progressPanel.hide() }
    }

    // MARK: - End-of-meeting detection

    private func handleMeetPresence(_ active: Bool) {
        guard isRecording, autoEndArmed else { pendingEnd?.cancel(); pendingEnd = nil; return }
        if active {
            pendingEnd?.cancel(); pendingEnd = nil
        } else if pendingEnd == nil {
            pendingEnd = Task { @MainActor [weak self] in
                // Grace period so a quick tab switch doesn't end the meeting.
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled,
                      self.isRecording, !self.meetDetector.isMeetActive else { return }
                await self.stopRecordingAndProcess()
            }
        }
    }

    // MARK: - Recording

    func startRecording() async {
        errorMessage = nil
        guard client.isAuthenticated else { return }
        let name = "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))"
        var meeting = Meeting(title: name, status: .recording)
        let url = store.newRecordingURL(for: meeting)
        meeting.audioFileURL = url

        do {
            recorder.targetWindowID = meetDetector.meetWindowID
            autoEndArmed = (meetDetector.meetWindowID != nil)   // only auto-end real Meet calls
            try await recorder.start(to: url)
            recordingMeetingID = meeting.id
            recordingStartedAt = Date()
            manuallyShown = false
            dismissed = false
            meetings.insert(meeting, at: 0)
            persist()
            updatePopups()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecordingAndProcess() async {
        guard let id = recordingMeetingID else { return }
        pendingEnd?.cancel(); pendingEnd = nil
        autoEndArmed = false
        await recorder.stop()
        recordingMeetingID = nil
        recordingStartedAt = nil

        guard var meeting = meetings.first(where: { $0.id == id }) else { return }
        meeting.endedAt = Date()
        meeting.status = .recorded
        update(meeting)

        await runPipeline(for: meeting)
    }

    func cancelRecording() async {
        guard let id = recordingMeetingID else { return }
        pendingEnd?.cancel(); pendingEnd = nil
        autoEndArmed = false
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
        dismissed = false
        updatePopups()
    }

    // MARK: - Pipeline

    func runPipeline(for meeting: Meeting) async {
        guard client.isAuthenticated else { return }
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
            var failed = meeting
            failed.status = .failed
            failed.errorMessage = error.localizedDescription
            update(failed)
            activeStatus = nil
            presentFailure(failed)
        }
    }

    func retryProcessing(_ meeting: Meeting) async {
        guard client.isAuthenticated else { return }
        failedMeeting = nil

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

    // MARK: - Progress result

    private func finish(_ meeting: Meeting) {
        if meeting.errorMessage != nil { presentFailure(meeting); return }
        failedMeeting = nil
        doneNotionURL = meeting.notionPageURL
        doneFlash = "Notes ready"
        updatePopups()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if self?.doneFlash != nil { self?.dismissProgress() }
        }
    }

    private func presentFailure(_ meeting: Meeting) {
        failedMeeting = meeting
        activeStatus = nil
        updatePopups()
    }

    /// Open the exported Notion page (from the done popup) and dismiss.
    func openNotionPage() {
        if let s = doneNotionURL, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        dismissProgress()
    }

    func dismissProgress() {
        doneFlash = nil
        doneNotionURL = nil
        failedMeeting = nil
        activeStatus = nil
        updatePopups()
    }

    func dismissFailure() {
        failedMeeting = nil
        updatePopups()
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
