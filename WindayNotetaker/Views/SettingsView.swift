import SwiftUI

/// Settings window. No third-party API keys here — those are stored server-side
/// as Supabase Edge Function secrets. This screen only covers the account,
/// the (non-secret) Notion target database, and model choices.
struct SettingsView: View {
    @EnvironmentObject private var config: Config
    @EnvironmentObject private var client: SupabaseClient
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        TabView {
            accountTab
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            notionTab
                .tabItem { Label("Notion", systemImage: "doc.text") }
            modelsTab
                .tabItem { Label("Models", systemImage: "cpu") }
        }
        .frame(width: 500, height: 380)
        .padding()
    }

    private var accountTab: some View {
        Form {
            if client.isAuthenticated {
                Section("Signed in") {
                    LabeledContent("Email", value: client.email ?? "—")
                    Button("Sign out", role: .destructive) { client.signOut() }
                }
            } else {
                Section {
                    Text("You're signed out. Close Settings and sign in from the main window.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Where are my API keys?") {
                Text("""
                Your Deepgram, Gemini and Notion secrets live server-side as Supabase \
                Edge Function secrets — never on this Mac. The app only holds the public \
                Supabase URL + key, and talks to the backend on your behalf.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var notionTab: some View {
        Form {
            Section("Notion export") {
                TextField("Database ID", text: $config.notionDatabaseID)
                Toggle("Auto-send each summary to Notion", isOn: $config.autoExportToNotion)
            }
            Section {
                Text("""
                The Notion integration token is a server secret (NOTION_TOKEN). Here you \
                only set the target database:
                1. Open the database in Notion → ••• → Connections → add your integration.
                2. Copy the 32-character database ID from its URL and paste it above.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var modelsTab: some View {
        Form {
            Section("Deepgram") {
                TextField("Model", text: $config.deepgramModel)
                Text("Default: nova-3").font(.caption).foregroundStyle(.secondary)
            }
            Section("Gemini") {
                TextField("Model", text: $config.geminiModel)
                Text("Default: gemini-flash-latest (always points at the newest Flash).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Save model & Notion settings to backend") {
                    Task { await model.syncSettings() }
                }
                Text("Settings are also synced automatically before each meeting is processed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
