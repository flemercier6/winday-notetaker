import SwiftUI

/// Settings window: API keys (stored in Keychain) + model and Notion config.
struct SettingsView: View {
    @EnvironmentObject private var config: Config

    var body: some View {
        TabView {
            apiKeysTab
                .tabItem { Label("API Keys", systemImage: "key.fill") }
            notionTab
                .tabItem { Label("Notion", systemImage: "doc.text") }
            modelsTab
                .tabItem { Label("Models", systemImage: "cpu") }
        }
        .frame(width: 480, height: 360)
        .padding()
    }

    private var apiKeysTab: some View {
        Form {
            Section {
                SecureField("Deepgram API key", text: $config.deepgramAPIKey)
                Text("Used for speech-to-text (model: \(config.deepgramModel)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                SecureField("Gemini API key", text: $config.geminiAPIKey)
                Text("Used for summaries & next steps (model: \(config.geminiModel)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Keys are stored securely in your macOS Keychain and never leave your machine except to call the respective APIs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var notionTab: some View {
        Form {
            Section("Notion integration") {
                SecureField("Internal integration token (secret_…)", text: $config.notionToken)
                TextField("Database ID", text: $config.notionDatabaseID)
            }
            Section {
                Text("""
                1. Create an internal integration at notion.so/my-integrations and copy its token.
                2. Open the target database in Notion, click ••• → Connections → add your integration.
                3. Copy the database ID from its URL (the 32-character string before ?v=).
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
        }
        .formStyle(.grouped)
    }
}
