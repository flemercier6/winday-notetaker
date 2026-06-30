import Foundation

/// A single recorded meeting and everything derived from it.
///
/// A `Meeting` flows through the pipeline:
/// `recorded` → `transcribing` → `summarizing` → `ready` → (optionally) `exported`.
struct Meeting: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case recording
        case recorded
        case transcribing
        case summarizing
        case ready
        case exporting
        case exported
        case failed
    }

    let id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    /// Local file URL of the mixed (mic + system) audio recording.
    var audioFileURL: URL?
    /// Storage path of the uploaded recording in the Supabase `recordings`
    /// bucket (e.g. "<userId>/<meetingId>.caf").
    var audioPath: String?
    var transcript: Transcript?
    var summary: MeetingSummary?
    /// URL of the Notion page once exported.
    var notionPageURL: String?
    var status: Status
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date = Date(),
        status: Status = .recording
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.status = status
    }

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}
