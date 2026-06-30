import Foundation

/// Structured meeting intelligence produced by Gemini.
///
/// The shape mirrors the JSON schema we send to Gemini (`responseSchema`),
/// so the model is forced to return exactly these fields.
struct MeetingSummary: Codable, Equatable {
    struct ActionItem: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        let task: String
        /// Who owns the action, if it could be inferred ("me", "them", a name…).
        let owner: String?
        let priority: Priority
        /// Optional due date in natural language ("end of week", "2026-07-10"…).
        let due: String?

        private enum CodingKeys: String, CodingKey {
            case task, owner, priority, due
        }
    }

    enum Priority: String, Codable, CaseIterable {
        case high, medium, low

        var emoji: String {
            switch self {
            case .high: return "🔴"
            case .medium: return "🟡"
            case .low: return "🟢"
            }
        }
    }

    /// 2–4 sentence executive summary.
    let summary: String
    /// Key discussion points / decisions.
    let keyPoints: [String]
    /// Concrete next steps with owners and priority.
    let nextSteps: [ActionItem]
    /// One-line headline suitable as a meeting/Notion page title.
    let headline: String

    private enum CodingKeys: String, CodingKey {
        case summary
        case keyPoints = "key_points"
        case nextSteps = "next_steps"
        case headline
    }
}
