import Foundation

/// Runs the post-recording pipeline for a meeting:
/// transcribe (Deepgram) → summarize (Gemini) → optionally export (Notion).
///
/// Pure orchestration: it owns no UI state, takes a `Meeting`, mutates a copy
/// as each stage completes, and reports progress through a callback so the
/// view model can drive the UI.
struct PipelineCoordinator {
    let config: Config

    enum Stage: String {
        case transcribing = "Transcribing with Deepgram…"
        case summarizing = "Summarizing with Gemini…"
        case exporting = "Sending to Notion…"
        case done = "Done"
    }

    /// Process a recorded meeting. `autoExport` controls whether we push to
    /// Notion automatically when it's configured.
    func process(
        _ meeting: Meeting,
        autoExport: Bool,
        onStage: @escaping (Stage) -> Void
    ) async throws -> Meeting {
        var meeting = meeting
        guard let audioURL = meeting.audioFileURL else {
            throw NSError(domain: "Pipeline", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio file to process."])
        }

        // 1) Transcribe
        onStage(.transcribing)
        meeting.status = .transcribing
        let deepgram = DeepgramService(apiKey: config.deepgramAPIKey, model: config.deepgramModel)
        let transcript = try await deepgram.transcribe(fileURL: audioURL)
        meeting.transcript = transcript

        // 2) Summarize
        onStage(.summarizing)
        meeting.status = .summarizing
        let gemini = GeminiService(apiKey: config.geminiAPIKey, model: config.geminiModel)
        let summary = try await gemini.summarize(transcript: transcript, meetingTitle: meeting.title)
        meeting.summary = summary
        if meeting.title.isEmpty || meeting.title.hasPrefix("Meeting ") {
            meeting.title = summary.headline
        }
        meeting.status = .ready

        // 3) Export to Notion (optional)
        if autoExport && config.isNotionConfigured {
            onStage(.exporting)
            meeting.status = .exporting
            meeting.notionPageURL = try await export(meeting, summary: summary)
            meeting.status = .exported
        }

        onStage(.done)
        return meeting
    }

    /// Export an already-summarized meeting to Notion. Returns the page URL.
    @discardableResult
    func export(_ meeting: Meeting, summary: MeetingSummary) async throws -> String {
        let notion = NotionService(
            token: config.notionToken,
            databaseID: config.notionDatabaseID,
            apiVersion: config.notionAPIVersion
        )
        return try await notion.export(meeting: meeting, summary: summary)
    }
}
