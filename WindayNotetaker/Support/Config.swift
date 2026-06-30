import Foundation
import Combine

/// App configuration: secrets (Keychain) + non-secret settings (UserDefaults +
/// Info.plist defaults from Config.xcconfig).
///
/// `@Published` so SwiftUI views (Settings) react to changes.
final class Config: ObservableObject {
    static let shared = Config()

    // MARK: Keychain-backed secrets

    @Published var deepgramAPIKey: String {
        didSet { Keychain.set(deepgramAPIKey, for: "deepgram_api_key") }
    }
    @Published var geminiAPIKey: String {
        didSet { Keychain.set(geminiAPIKey, for: "gemini_api_key") }
    }
    @Published var notionToken: String {
        didSet { Keychain.set(notionToken, for: "notion_token") }
    }

    // MARK: UserDefaults-backed settings

    /// Notion database (data source) ID where summaries are created as pages.
    @Published var notionDatabaseID: String {
        didSet { defaults.set(notionDatabaseID, forKey: "notion_database_id") }
    }

    // MARK: Info.plist defaults (from Config.xcconfig, overridable)

    @Published var deepgramModel: String {
        didSet { defaults.set(deepgramModel, forKey: "deepgram_model") }
    }
    @Published var geminiModel: String {
        didSet { defaults.set(geminiModel, forKey: "gemini_model") }
    }

    let notionAPIVersion: String

    private let defaults = UserDefaults.standard

    private init() {
        deepgramAPIKey = Keychain.get("deepgram_api_key") ?? ""
        geminiAPIKey = Keychain.get("gemini_api_key") ?? ""
        notionToken = Keychain.get("notion_token") ?? ""
        notionDatabaseID = defaults.string(forKey: "notion_database_id") ?? ""

        let plist = Bundle.main.infoDictionary ?? [:]
        deepgramModel = defaults.string(forKey: "deepgram_model")
            ?? (plist["WNDeepgramModel"] as? String) ?? "nova-3"
        geminiModel = defaults.string(forKey: "gemini_model")
            ?? (plist["WNGeminiModel"] as? String) ?? "gemini-flash-latest"
        notionAPIVersion = (plist["WNNotionAPIVersion"] as? String) ?? "2022-06-28"
    }

    /// True when the minimum keys to run the full pipeline are present.
    var isTranscriptionConfigured: Bool { !deepgramAPIKey.isEmpty }
    var isSummaryConfigured: Bool { !geminiAPIKey.isEmpty }
    var isNotionConfigured: Bool { !notionToken.isEmpty && !notionDatabaseID.isEmpty }
}
