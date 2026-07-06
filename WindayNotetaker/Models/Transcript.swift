import Foundation

/// A transcript returned by Deepgram. With multichannel capture, channel 0 is
/// your microphone ("You") and channel 1 is the meeting audio, where diarization
/// further splits multiple remote participants ("Participant 1", "2", …).
struct Transcript: Codable, Equatable {
    struct Utterance: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        /// Human label for who spoke: "You", "Participant 1", …
        let speaker: String
        let text: String
        let start: TimeInterval
        let end: TimeInterval

        private enum CodingKeys: String, CodingKey {
            case speaker, text, start, end
        }
    }

    /// Full concatenated transcript text.
    let fullText: String
    /// Labelled utterances in chronological order.
    let utterances: [Utterance]
    /// Detected language code (e.g. "en", "fr"), when available.
    let language: String?

    /// Speaker-labelled transcript, e.g. `You: Hello\nParticipant 1: Hi`.
    var labelled: String {
        utterances
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }
}
