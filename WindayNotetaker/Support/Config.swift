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

    /// The default instruction sent to Gemini for the summary. Users can
    /// customize it in Settings; the JSON output structure (summary, key
    /// points, next steps) and speaker identification stay enforced server-side.
    static let defaultSummaryPrompt = """
    You are an expert sales/meeting assistant for Winday CRM. Analyze the \
    following meeting transcript and produce structured notes. The speaker \
    labelled "You" is the app's user; "Participant 1/2/…" are the other \
    attendees. Be concise and action-oriented. For next_steps, infer the owner \
    when possible (the user vs a participant) and assign a realistic priority. \
    Write in the same language as the transcript.
    """

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
    /// User-customizable summary instruction for Gemini (Settings → Summary).
    @Published var summaryPrompt: String {
        didSet { defaults.set(summaryPrompt, forKey: "summary_prompt") }
    }
    /// Desired summary length: "short" | "medium" | "long".
    @Published var summaryLength: String {
        didSet { defaults.set(summaryLength, forKey: "summary_length") }
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
            ?? (plist["WNGeminiModel"] as? String) ?? "gemini-2.5-flash"
        // Default ON: once a Notion database is configured, summaries are sent
        // automatically. Users can turn it off in Settings → Notion.
        autoExportToNotion = defaults.object(forKey: "auto_export_notion") as? Bool ?? true
        summaryPrompt = defaults.string(forKey: "summary_prompt") ?? Self.defaultSummaryPrompt
        summaryLength = defaults.string(forKey: "summary_length") ?? "medium"
    }

    var isNotionConfigured: Bool { !notionDatabaseID.isEmpty }
}
