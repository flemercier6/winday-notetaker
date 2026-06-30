import Foundation

/// Summarizes a transcript into structured meeting intelligence with Gemini.
///
/// We force JSON output via `responseMimeType: application/json` plus a
/// `responseSchema`, so the model returns exactly the `MeetingSummary` shape.
struct GeminiService {
    enum ServiceError: LocalizedError {
        case missingKey
        case http(Int, String)
        case noContent
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Gemini API key is not set (Settings → API Keys)."
            case let .http(code, body): return "Gemini returned HTTP \(code): \(body)"
            case .noContent: return "Gemini returned no content."
            case let .decoding(msg): return "Could not read Gemini response: \(msg)"
            }
        }
    }

    let apiKey: String
    let model: String

    func summarize(transcript: Transcript, meetingTitle: String) async throws -> MeetingSummary {
        guard !apiKey.isEmpty else { throw ServiceError.missingKey }

        let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header auth keeps the key out of URLs/logs.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(for: transcript, title: meetingTitle))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.http(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        // Gemini wraps the JSON we asked for inside candidates[0].content.parts[0].text.
        let envelope = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let jsonText = envelope.candidates?.first?.content.parts.first?.text,
              let jsonData = jsonText.data(using: .utf8) else {
            throw ServiceError.noContent
        }

        do {
            return try JSONDecoder().decode(MeetingSummary.self, from: jsonData)
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Request building

    private func requestBody(for transcript: Transcript, title: String) -> [String: Any] {
        let prompt = """
        You are an expert sales/meeting assistant for Winday CRM. Analyze the \
        following meeting transcript (speaker-diarized) and produce structured \
        notes. The user is "Speaker 0" unless context clearly says otherwise.

        Meeting title: \(title)

        Be concise and action-oriented. For next_steps, infer the owner when \
        possible and assign a realistic priority (high/medium/low). Write in the \
        same language as the transcript.

        TRANSCRIPT:
        \(transcript.labelled)
        """

        return [
            "contents": [
                ["role": "user", "parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "temperature": 0.3,
                "responseMimeType": "application/json",
                "responseSchema": responseSchema,
            ],
        ]
    }

    /// JSON schema matching `MeetingSummary`. Gemini guarantees this shape.
    private var responseSchema: [String: Any] {
        [
            "type": "OBJECT",
            "properties": [
                "headline": ["type": "STRING"],
                "summary": ["type": "STRING"],
                "key_points": ["type": "ARRAY", "items": ["type": "STRING"]],
                "next_steps": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "task": ["type": "STRING"],
                            "owner": ["type": "STRING"],
                            "priority": ["type": "STRING", "enum": ["high", "medium", "low"]],
                            "due": ["type": "STRING"],
                        ],
                        "required": ["task", "priority"],
                    ],
                ],
            ],
            "required": ["headline", "summary", "key_points", "next_steps"],
        ]
    }

    private struct GeminiResponse: Decodable {
        let candidates: [Candidate]?
        struct Candidate: Decodable { let content: Content }
        struct Content: Decodable { let parts: [Part] }
        struct Part: Decodable { let text: String? }
    }
}
