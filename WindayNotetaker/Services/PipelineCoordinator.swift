import Foundation

/// Runs the post-recording pipeline through the Supabase backend:
/// upload audio → insert row → transcribe → summarize → optionally export.
///
/// All third-party API calls happen server-side in Edge Functions; this client
/// only uploads the recording and invokes the functions by meeting id.
@MainActor
struct PipelineCoordinator {
    let client: SupabaseClient
    let config: Config

    enum Stage: String {
        case uploading = "Uploading recording…"
        case transcribing = "Transcribing with Deepgram…"
        case summarizing = "Summarizing with Gemini…"
        case exporting = "Sending to Notion…"
        case done = "Done"
    }

    func process(
        _ meeting: Meeting,
        autoExport: Bool,
        onStage: @escaping (Stage) -> Void
    ) async throws -> Meeting {
        var meeting = meeting
        guard let userId = client.userId else { throw SupabaseClient.ClientError.notAuthenticated }
        guard let audioURL = meeting.audioFileURL else {
            throw NSError(domain: "Pipeline", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio file to process."])
        }

        // 1) Upload audio + create the server row the functions operate on.
        onStage(.uploading)
        let audioPath = "\(userId)/\(meeting.id.uuidString).caf"
        try await client.uploadRecording(fileURL: audioURL, to: audioPath)
        meeting.audioPath = audioPath

        let iso = ISO8601DateFormatter()
        try await client.insertMeeting([
            "id": meeting.id.uuidString,
            "user_id": userId,
            "title": meeting.title,
            "status": "recorded",
            "audio_path": audioPath,
            "started_at": iso.string(from: meeting.startedAt),
            "ended_at": iso.string(from: meeting.endedAt ?? Date()),
        ])

        // 2) Transcribe (Deepgram, server-side)
        onStage(.transcribing)
        meeting.status = .transcribing
        let tr = try await client.invoke("transcribe",
                                         body: ["meeting_id": meeting.id.uuidString],
                                         as: TranscribeResponse.self)
        meeting.transcript = tr.transcript

        // 3) Summarize (Gemini, server-side)
        onStage(.summarizing)
        meeting.status = .summarizing
        let sr = try await client.invoke("summarize",
                                         body: ["meeting_id": meeting.id.uuidString],
                                         as: SummarizeResponse.self)
        meeting.summary = sr.summary
        if meeting.title.isEmpty || meeting.title.hasPrefix("Meeting ") {
            meeting.title = sr.summary.headline
        }
        meeting.status = .ready

        // 4) Export to Notion (server-side), optional
        if autoExport && config.isNotionConfigured {
            onStage(.exporting)
            meeting.status = .exporting
            meeting.notionPageURL = try await export(meeting)
            meeting.status = .exported
        }

        onStage(.done)
        return meeting
    }

    /// Export an already-summarized meeting to Notion. Returns the page URL.
    @discardableResult
    func export(_ meeting: Meeting) async throws -> String {
        let resp = try await client.invoke("export-notion",
                                           body: ["meeting_id": meeting.id.uuidString],
                                           as: ExportResponse.self)
        return resp.url
    }

    // Edge Function response envelopes.
    private struct TranscribeResponse: Decodable { let transcript: Transcript }
    private struct SummarizeResponse: Decodable { let summary: MeetingSummary }
    private struct ExportResponse: Decodable { let url: String }
}
