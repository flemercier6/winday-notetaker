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
    /// Set when recording was armed from a calendar event — links the record to
    /// that event and, via its contacts, to the corresponding CRM company.
    var calendar: CalendarContext?

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

/// Links a recorded meeting to the calendar event it came from and to the CRM
/// company/contacts resolved for that event.
struct CalendarContext: Codable, Equatable {
    var googleEventID: String
    var meetURL: String?
    var companyID: String?
    var companyName: String?
    var companyLogoURL: String?
    var contactIDs: [String]
}

/// An imminent calendar call returned by the `upcoming-meetings` Edge Function.
struct UpcomingMeeting: Codable, Equatable, Identifiable {
    let googleEventID: String
    let title: String
    let startISO: String
    let endISO: String?
    let meetURL: String?
    let companyID: String?
    let companyName: String?
    let companyLogoURL: String?
    let contactIDs: [String]

    var id: String { googleEventID }

    enum CodingKeys: String, CodingKey {
        case googleEventID = "google_event_id"
        case title
        case startISO = "start"
        case endISO = "end"
        case meetURL = "meet_url"
        case companyID = "company_id"
        case companyName = "company_name"
        case companyLogoURL = "company_logo_url"
        case contactIDs = "contact_ids"
    }

    var start: Date { Self.iso.date(from: startISO) ?? .distantFuture }
    var end: Date? { endISO.flatMap { Self.iso.date(from: $0) } }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func context() -> CalendarContext {
        CalendarContext(googleEventID: googleEventID, meetURL: meetURL,
                        companyID: companyID, companyName: companyName,
                        companyLogoURL: companyLogoURL, contactIDs: contactIDs)
    }
}

struct UpcomingResponse: Codable {
    let calendarConnected: Bool
    let meetings: [UpcomingMeeting]
    let error: String?

    enum CodingKeys: String, CodingKey {
        case calendarConnected = "calendar_connected"
        case meetings
        case error
    }
}
