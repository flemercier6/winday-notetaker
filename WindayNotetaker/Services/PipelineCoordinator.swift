import Foundation

/// Runs the post-recording pipeline through the Supabase backend:
/// upload audio → insert row → transcribe → summarize → optionally export.
///
/// Failure policy: once a stage's result is obtained it is never thrown away.
/// If summarize fails we keep the transcript; if export fails we keep the
/// summary. Only upload/transcribe failures (where there's nothing yet) throw.
@MainActor
struct PipelineCoordinator {
    let client: SupabaseClient
    let config: Config

    enum Stage: String {
        case uploading = "Preparing…"
        case transcribing = "Transcribing…"
        case summarizing = "Summarizing…"
        case exporting = "Saving notes…"
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

        // 1) Compress to AAC, upload, then create the server row (throws —
        //    nothing kept yet). Raw WAV is far too large for Storage on long
        //    calls; AAC keeps the two channels and fits comfortably.
        onStage(.uploading)
        let uploadURL = try await AudioCompressor.encodeToM4A(audioURL)
        defer { try? FileManager.default.removeItem(at: uploadURL) }
        let audioPath = "\(userId)/\(meeting.id.uuidString).m4a"
        try await client.uploadRecording(fileURL: uploadURL, to: audioPath, contentType: "audio/mp4")
        meeting.audioPath = audioPath

        // The row is created in the Winday CRM's `meetings` table (shared
        // backend). Column names match that schema: `meeting_title`,
        // `stopped_at`, `duration_seconds`.
        let iso = ISO8601DateFormatter()
        let stoppedAt = meeting.endedAt ?? Date()
        var payload: [String: Any] = [
            "id": meeting.id.uuidString,
            "user_id": userId,
            "meeting_title": meeting.title,
            "status": "recorded",
            "audio_path": audioPath,
            "started_at": iso.string(from: meeting.startedAt),
            "stopped_at": iso.string(from: stoppedAt),
            "duration_seconds": Int(stoppedAt.timeIntervalSince(meeting.startedAt).rounded()),
        ]
        // Calendar-armed recordings carry the Meet URL + the company/contacts
        // resolved from the calendar event (kept in metadata; the functions merge
        // over it, so it survives transcribe/summarize/export).
        if let cal = meeting.calendar {
            if let url = cal.meetURL { payload["meeting_url"] = url }
            var calMeta: [String: Any] = [
                "google_event_id": cal.googleEventID,
                "contact_ids": cal.contactIDs,
            ]
            if let cid = cal.companyID { calMeta["company_id"] = cid }
            if let cname = cal.companyName { calMeta["company_name"] = cname }
            if let clogo = cal.companyLogoURL { calMeta["company_logo_url"] = clogo }
            payload["metadata"] = ["calendar": calMeta]
        }
        try await client.insertMeeting(payload)

        // Link the record to the company via its contacts (non-fatal on failure).
        if let cal = meeting.calendar, !cal.contactIDs.isEmpty {
            try? await client.linkMeetingContacts(meetingID: meeting.id.uuidString, contactIDs: cal.contactIDs)
        }

        // 2) Transcribe (throws — no transcript yet).
        onStage(.transcribing)
        meeting = try await transcribeOnly(meeting)

        // 3) Summarize — KEEP the transcript if this fails.
        onStage(.summarizing)
        do {
            meeting = try await summarizeOnly(meeting)
        } catch {
            meeting.status = .failed
            meeting.errorMessage = "Summary failed: \(error.localizedDescription)"
            return meeting
        }

        // 4) Export to Notion — KEEP the summary if this fails.
        if autoExport && config.isNotionConfigured {
            onStage(.exporting)
            meeting.status = .exporting
            do {
                meeting.notionPageURL = try await export(meeting)
                meeting.status = .exported
            } catch {
                meeting.status = .ready
                meeting.errorMessage = "Notion export failed: \(error.localizedDescription)"
            }
        }

        onStage(.done)
        return meeting
    }

    /// Transcribe (or re-transcribe) a meeting whose audio is already uploaded.
    func transcribeOnly(_ meeting: Meeting) async throws -> Meeting {
        var m = meeting
        m.status = .transcribing
        let tr = try await client.invoke("transcribe",
                                         body: [
                                            "meeting_id": m.id.uuidString,
                                            "deepgram_model": config.deepgramModel,
                                         ],
                                         as: TranscribeResponse.self)
        m.transcript = tr.transcript
        m.status = .summarizing
        return m
    }

    /// Summarize a meeting that already has a transcript.
    func summarizeOnly(_ meeting: Meeting) async throws -> Meeting {
        var m = meeting
        let sr = try await client.invoke("summarize",
                                         body: [
                                            "meeting_id": m.id.uuidString,
                                            "gemini_model": config.geminiModel,
                                         ],
                                         as: SummarizeResponse.self)
        m.summary = sr.summary
        if m.title.isEmpty || m.title.hasPrefix("Meeting ") {
            m.title = sr.summary.headline
        }
        m.status = .ready
        m.errorMessage = nil
        return m
    }

    /// Export an already-summarized meeting to Notion. Returns the page URL.
    @discardableResult
    func export(_ meeting: Meeting) async throws -> String {
        let resp = try await client.invoke("export-notion",
                                           body: [
                                            "meeting_id": meeting.id.uuidString,
                                            "notion_database_id": config.notionDatabaseID,
                                           ],
                                           as: ExportResponse.self)
        return resp.url
    }

    // Edge Function response envelopes.
    private struct TranscribeResponse: Decodable { let transcript: Transcript }
    private struct SummarizeResponse: Decodable { let summary: MeetingSummary }
    private struct ExportResponse: Decodable { let url: String }
}
