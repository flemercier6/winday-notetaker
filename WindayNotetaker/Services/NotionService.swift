import Foundation

/// Creates a Notion page from a `MeetingSummary` inside a target database.
///
/// The target database must have (at minimum) a Title property. We additionally
/// try to set common properties if they exist; missing ones are simply ignored
/// by writing only the Title and putting everything else in page content blocks,
/// which works against ANY database regardless of its schema.
struct NotionService {
    enum ServiceError: LocalizedError {
        case missingConfig
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingConfig: return "Notion token or database ID is not set (Settings → Notion)."
            case let .http(code, body): return "Notion returned HTTP \(code): \(body)"
            }
        }
    }

    let token: String
    let databaseID: String
    let apiVersion: String

    /// Creates the page and returns its public URL.
    @discardableResult
    func export(meeting: Meeting, summary: MeetingSummary) async throws -> String {
        guard !token.isEmpty, !databaseID.isEmpty else { throw ServiceError.missingConfig }

        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(meeting: meeting, summary: summary))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.http(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let created = try JSONDecoder().decode(CreatedPage.self, from: data)
        return created.url
    }

    // MARK: - Body building

    private func body(meeting: Meeting, summary: MeetingSummary) -> [String: Any] {
        [
            "parent": ["database_id": databaseID],
            "properties": [
                // "Name"/"title" is the canonical title property in most databases.
                "title": [
                    "title": [["text": ["content": summary.headline]]]
                ]
            ],
            "children": contentBlocks(meeting: meeting, summary: summary),
        ]
    }

    private func contentBlocks(meeting: Meeting, summary: MeetingSummary) -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        blocks.append(heading("📝 Summary"))
        blocks.append(paragraph(summary.summary))

        if !summary.keyPoints.isEmpty {
            blocks.append(heading("📌 Key points"))
            for point in summary.keyPoints {
                blocks.append(bullet(point))
            }
        }

        if !summary.nextSteps.isEmpty {
            blocks.append(heading("✅ Next steps & priorities"))
            // Sort high → low so the most important actions are on top.
            let order: [MeetingSummary.Priority] = [.high, .medium, .low]
            let sorted = summary.nextSteps.sorted {
                (order.firstIndex(of: $0.priority) ?? 99) < (order.firstIndex(of: $1.priority) ?? 99)
            }
            for step in sorted {
                blocks.append(todo(label: stepLabel(step), checked: false))
            }
        }

        blocks.append(divider())
        let date = meeting.startedAt.formatted(date: .abbreviated, time: .shortened)
        blocks.append(paragraph("Recorded with Winday Notetaker • \(date)"))

        return blocks
    }

    private func stepLabel(_ step: MeetingSummary.ActionItem) -> String {
        var parts = ["\(step.priority.emoji) \(step.task)"]
        if let owner = step.owner, !owner.isEmpty { parts.append("— \(owner)") }
        if let due = step.due, !due.isEmpty { parts.append("(\(due))") }
        return parts.joined(separator: " ")
    }

    // MARK: - Block helpers

    private func richText(_ text: String) -> [[String: Any]] {
        // Notion rejects rich-text content longer than 2000 chars per item.
        [["type": "text", "text": ["content": String(text.prefix(1990))]]]
    }
    private func heading(_ text: String) -> [String: Any] {
        ["object": "block", "type": "heading_2",
         "heading_2": ["rich_text": richText(text)]]
    }
    private func paragraph(_ text: String) -> [String: Any] {
        ["object": "block", "type": "paragraph",
         "paragraph": ["rich_text": richText(text)]]
    }
    private func bullet(_ text: String) -> [String: Any] {
        ["object": "block", "type": "bulleted_list_item",
         "bulleted_list_item": ["rich_text": richText(text)]]
    }
    private func todo(label: String, checked: Bool) -> [String: Any] {
        ["object": "block", "type": "to_do",
         "to_do": ["rich_text": richText(label), "checked": checked]]
    }
    private func divider() -> [String: Any] {
        ["object": "block", "type": "divider", "divider": [:]]
    }

    private struct CreatedPage: Decodable { let url: String }
}
