import Foundation
import Combine
import AppKit
import CoreGraphics

/// Central app state and orchestration hub. Runs as a background agent: it
/// watches for meetings, shows the top recorder pill + the bottom-right progress
/// popup, and drives record → transcribe → summarize → export through Supabase.
@MainActor
final class AppViewModel: ObservableObject {
    static let shared = AppViewModel()

    @Published var meetings: [Meeting] = []
    /// Imminent calendar calls (from the CRM's Google Calendar), used to arm the
    /// recorder popup ~1 min before a scheduled call.
    @Published var upcoming: [UpcomingMeeting] = []

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
    // Ready pill: fixed at top-center. Recording visualizer: bottom-right,
    // draggable + remembered. Progress: transient bottom-right.
    private let readyPanel = FloatingPanelController(anchor: .topCenter, movable: false)
    private let recordingPanel = FloatingPanelController(anchor: .bottomTrailing, movable: true)
    private let progressPanel = FloatingPanelController(anchor: .bottomTrailing)
    private var cancellables = Set<AnyCancellable>()
    private var recordingMeetingID: Meeting.ID?
    private var agentStarted = false

    /// User hid the top pill with "–": keep it hidden until the meeting is over.
    private var dismissed = false
    /// User opened the recorder from the menu with no meeting in progress.
    private var manuallyShown = false
    /// Auto-end: watch the meeting window's liveness while recording.
    private var endMonitor: Timer?
    private var recordingMeetWindowID: CGWindowID?
    private var meetGoneSince: Date?
    /// Polls the calendar for imminent calls.
    private var upcomingTimer: Timer?

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

        readyPanel.configure(RecorderPopup()
            .environmentObject(self)
            .environmentObject(SupabaseClient.shared)
            .environmentObject(Config.shared))
        recordingPanel.configure(RecorderPopup()
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
            meetDetector.$micInUse.map { _ in () }.eraseToAnyPublisher(),
            // React to sign-in / sign-out so the sign-in popup shows/hides.
            client.$session.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.updatePopups() }
        .store(in: &cancellables)

        // Surface the correct popup immediately on launch (e.g. sign-in).
        updatePopups()

        // Recovery: if a previous run left a meeting failed with its audio still
        // on disk, surface it so the user can Retry (e.g. after updating the app).
        // The transcript/summary regenerate from the saved recording — nothing is
        // re-recorded.
        if let failed = meetings.first(where: { m in
            guard m.status == .failed, let url = m.audioFileURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }) {
            presentFailure(failed)
        }

        // Poll the calendar so the recorder can arm ~1 min before a scheduled
        // call. 30s granularity is enough for a 1-minute lead time.
        upcomingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshUpcoming() }
        }
        Task { await refreshUpcoming() }
    }

    // MARK: - Calendar arming

    /// The calendar call to record right now, if any: armed from 1 min before its
    /// start until a bit after it ends, and not already recorded.
    var armedMeeting: UpcomingMeeting? {
        let now = Date()
        let recorded = Set(meetings.compactMap { $0.calendar?.googleEventID })
        return upcoming.first { ev in
            guard !recorded.contains(ev.googleEventID) else { return false }
            let start = ev.start
            let end = ev.end ?? start.addingTimeInterval(30 * 60)
            return now >= start.addingTimeInterval(-60) && now <= end.addingTimeInterval(5 * 60)
        }
    }

    func refreshUpcoming() async {
        guard client.isAuthenticated else {
            if !upcoming.isEmpty { upcoming = [] }
            return
        }
        if let resp = try? await client.fetchUpcomingMeetings() {
            upcoming = resp.meetings
        }
        updatePopups()
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
        // Signed out: always surface the sign-in popup (RecorderPopup renders
        // SignInView), and nothing else. Without this the popup only appears on
        // a detected meeting, so a fresh launch would show no way to sign in.
        guard client.isAuthenticated else {
            readyPanel.show()
            recordingPanel.hide()
            progressPanel.hide()
            return
        }

        // A calendar call armed for now also surfaces the popup, even before the
        // Meet window is open.
        let likely = meetDetector.meetingLikely || armedMeeting != nil
        let hasProgress = activeStatus != nil || doneFlash != nil || failedMeeting != nil

        if !likely && !isRecording && !hasProgress && !manuallyShown { dismissed = false }

        let readyVisible = !hasProgress && !isRecording && !dismissed && (likely || manuallyShown)
        let recordingVisible = !hasProgress && isRecording && !dismissed

        if readyVisible { readyPanel.show() } else { readyPanel.hide() }
        if recordingVisible { recordingPanel.show() } else { recordingPanel.hide() }
        if hasProgress { progressPanel.show() } else { progressPanel.hide() }
    }

    // MARK: - End-of-meeting detection

    private func startEndMonitor() {
        meetGoneSince = nil
        endMonitor?.invalidate()
        endMonitor = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMeetEnd() }
        }
    }

    private func stopEndMonitor() {
        endMonitor?.invalidate()
        endMonitor = nil
        meetGoneSince = nil
    }

    /// Ends the meeting when the tracked Meet window is gone (or navigated away
    /// from a Meet tab) for a sustained grace period. Never uses the mic level,
    /// so muting during the call does not stop the recording.
    private func checkMeetEnd() {
        guard isRecording else { stopEndMonitor(); return }

        // If we started without a target (e.g. detected via the mic), adopt a
        // Meet window if one shows up while recording.
        if recordingMeetWindowID == nil, let id = meetDetector.meetWindowID {
            recordingMeetWindowID = id
        }
        guard let id = recordingMeetWindowID else { return }   // no Meet to track → manual stop only

        if meetDetector.isMeetWindow(id) {
            meetGoneSince = nil
        } else {
            if meetGoneSince == nil { meetGoneSince = Date() }
            if let since = meetGoneSince, Date().timeIntervalSince(since) >= 3 {
                stopEndMonitor()
                Task { await stopRecordingAndProcess() }
            }
        }
    }

    // MARK: - Recording

    func startRecording() async {
        errorMessage = nil
        guard client.isAuthenticated else { return }
        // If a calendar call is armed, record into its context: use its title and
        // link the record to the resolved company/contacts.
        let armed = armedMeeting
        let name = armed?.title ?? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))"
        var meeting = Meeting(title: name, status: .recording)
        meeting.calendar = armed?.context()
        let url = store.newRecordingURL(for: meeting)
        meeting.audioFileURL = url

        do {
            recorder.targetWindowID = meetDetector.meetWindowID
            recordingMeetWindowID = meetDetector.meetWindowID
            try await recorder.start(to: url)
            recordingMeetingID = meeting.id
            recordingStartedAt = Date()
            manuallyShown = false
            dismissed = false
            meetings.insert(meeting, at: 0)
            persist()
            startEndMonitor()
            updatePopups()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecordingAndProcess() async {
        guard let id = recordingMeetingID else { return }
        stopEndMonitor()
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
        stopEndMonitor()
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
