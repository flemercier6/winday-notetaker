import Foundation

/// A diarized transcript returned by Deepgram Nova-3.
struct Transcript: Codable, Equatable {
    struct Utterance: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        /// Deepgram speaker index (0, 1, 2, …). Diarization groups turns by speaker.
        let speaker: Int
        let text: String
        let start: TimeInterval
        let end: TimeInterval

        private enum CodingKeys: String, CodingKey {
            case speaker, text, start, end
        }
    }

    /// Full concatenated transcript text.
    let fullText: String
    /// Per-speaker utterances in chronological order.
    let utterances: [Utterance]
    /// Detected language code (e.g. "en", "fr"), when available.
    let language: String?

    /// Speaker-labelled transcript, e.g.
    /// `Speaker 0: Hello\nSpeaker 1: Hi there`.
    /// This is what we hand to Gemini for summarization.
    var labelled: String {
        utterances
            .map { "Speaker \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }
}
