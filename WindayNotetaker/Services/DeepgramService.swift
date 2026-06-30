import Foundation

/// Transcribes a pre-recorded audio file with Deepgram (Nova-3 by default).
///
/// Uses the pre-recorded endpoint with diarization + utterances so we get
/// speaker-separated turns, which makes the Gemini summary much sharper.
struct DeepgramService {
    enum ServiceError: LocalizedError {
        case missingKey
        case http(Int, String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Deepgram API key is not set (Settings → API Keys)."
            case let .http(code, body): return "Deepgram returned HTTP \(code): \(body)"
            case let .decoding(msg): return "Could not read Deepgram response: \(msg)"
            }
        }
    }

    let apiKey: String
    let model: String

    /// Uploads `fileURL` and returns the diarized transcript.
    func transcribe(fileURL: URL) async throws -> Transcript {
        guard !apiKey.isEmpty else { throw ServiceError.missingKey }

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            .init(name: "model", value: model),
            .init(name: "smart_format", value: "true"),
            .init(name: "punctuate", value: "true"),
            .init(name: "diarize", value: "true"),
            .init(name: "utterances", value: "true"),
            .init(name: "detect_language", value: "true"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)
        let (data, response) = try await URLSession.shared.upload(for: request, from: audioData)

        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.http(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        return try parse(data)
    }

    // MARK: - Response parsing

    private func parse(_ data: Data) throws -> Transcript {
        do {
            let decoded = try JSONDecoder().decode(DGResponse.self, from: data)
            guard let channel = decoded.results.channels.first,
                  let alternative = channel.alternatives.first else {
                throw ServiceError.decoding("empty results")
            }

            let utterances: [Transcript.Utterance] = (decoded.results.utterances ?? []).map {
                .init(speaker: $0.speaker ?? 0, text: $0.transcript, start: $0.start, end: $0.end)
            }

            return Transcript(
                fullText: alternative.transcript,
                utterances: utterances,
                language: channel.detected_language
            )
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }

    // Minimal subset of the Deepgram pre-recorded response we care about.
    private struct DGResponse: Decodable {
        let results: Results
        struct Results: Decodable {
            let channels: [Channel]
            let utterances: [Utterance]?
        }
        struct Channel: Decodable {
            let alternatives: [Alternative]
            let detected_language: String?
        }
        struct Alternative: Decodable {
            let transcript: String
        }
        struct Utterance: Decodable {
            let transcript: String
            let start: TimeInterval
            let end: TimeInterval
            let speaker: Int?
        }
    }
}
