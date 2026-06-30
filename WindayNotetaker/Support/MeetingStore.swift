import Foundation

/// Persists meetings to a JSON file in Application Support and exposes the
/// recordings directory. Intentionally simple — swap for SwiftData/Core Data
/// if the history grows large.
final class MeetingStore {
    static let shared = MeetingStore()

    private let fileManager = FileManager.default

    /// ~/Library/Application Support/WindayNotetaker
    private(set) lazy var baseDirectory: URL = {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("WindayNotetaker", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Directory where mixed audio recordings are written.
    private(set) lazy var recordingsDirectory: URL = {
        let dir = baseDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var indexURL: URL { baseDirectory.appendingPathComponent("meetings.json") }

    /// A fresh `.wav` URL for a new recording.
    func newRecordingURL(for meeting: Meeting) -> URL {
        recordingsDirectory
            .appendingPathComponent(meeting.id.uuidString)
            .appendingPathExtension("wav")
    }

    func load() -> [Meeting] {
        guard let data = try? Data(contentsOf: indexURL),
              let meetings = try? JSONDecoder().decode([Meeting].self, from: data) else {
            return []
        }
        return meetings.sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ meetings: [Meeting]) {
        guard let data = try? JSONEncoder().encode(meetings) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
