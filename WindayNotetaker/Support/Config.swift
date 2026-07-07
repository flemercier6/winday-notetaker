import Foundation
import Combine

/// App configuration.
///
/// IMPORTANT: no third-party API secrets live here anymore. Deepgram, Gemini and
/// Notion keys are stored server-side as Supabase Edge Function secrets. The app
/// only knows the Supabase URL + publishable key (both safe to ship — access is
/// gated by Supabase Auth + Row Level Security) and non-secret per-user prefs.
final class Config: ObservableObject {
    static let shared = Config()

    // MARK: Supabase connection (publishable, from Info.plist)

    let supabaseURL: String
    let supabaseAnonKey: String

    // MARK: Non-secret per-user settings (UserDefaults; passed to Edge Functions per request)

    /// Notion database (data source) ID where summaries are created as pages.
    @Published var notionDatabaseID: String {
        didSet { defaults.set(notionDatabaseID, forKey: "notion_database_id") }
    }
    @Published var deepgramModel: String {
        didSet { defaults.set(deepgramModel, forKey: "deepgram_model") }
    }
    @Published var geminiModel: String {
        didSet { defaults.set(geminiModel, forKey: "gemini_model") }
    }
    @Published var autoExportToNotion: Bool {
        didSet { defaults.set(autoExportToNotion, forKey: "auto_export_notion") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let plist = Bundle.main.infoDictionary ?? [:]
        supabaseURL = (plist["WNSupabaseURL"] as? String) ?? ""
        supabaseAnonKey = (plist["WNSupabaseAnonKey"] as? String) ?? ""

        notionDatabaseID = defaults.string(forKey: "notion_database_id") ?? ""
        deepgramModel = defaults.string(forKey: "deepgram_model")
            ?? (plist["WNDeepgramModel"] as? String) ?? "nova-3"
        geminiModel = defaults.string(forKey: "gemini_model")
            ?? (plist["WNGeminiModel"] as? String) ?? "gemini-flash-latest"
        // Default ON: once a Notion database is configured, summaries are sent
        // automatically. Users can turn it off in Settings → Notion.
        autoExportToNotion = defaults.object(forKey: "auto_export_notion") as? Bool ?? true
    }

    var isNotionConfigured: Bool { !notionDatabaseID.isEmpty }
}
