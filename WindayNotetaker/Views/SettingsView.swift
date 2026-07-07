import SwiftUI
import ServiceManagement

/// Settings window. No third-party API keys here — those are stored server-side
/// as Supabase Edge Function secrets. This screen only covers the account,
/// the (non-secret) Notion target database, model choices, and the summary
/// prompt.
struct SettingsView: View {
    @EnvironmentObject private var config: Config
    @EnvironmentObject private var client: SupabaseClient
    @EnvironmentObject private var model: AppViewModel

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView {
            accountTab
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            summaryTab
                .tabItem { Label("Summary", systemImage: "text.badge.star") }
            notionTab
                .tabItem { Label("Notion", systemImage: "doc.text") }
            modelsTab
                .tabItem { Label("Models", systemImage: "cpu") }
        }
        .frame(width: 520, height: 420)
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
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            // Revert the toggle if macOS refused the change.
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Text("Keeps the menu-bar recorder available after a restart.")
                    .font(.caption).foregroundStyle(.secondary)
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

    private var summaryTab: some View {
        Form {
            Section("Summary length") {
                SummaryLengthToggle(selection: $config.summaryLength)
                Text("Short: 2–3 sentences. Medium: balanced. Long: detailed, multi-paragraph.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Summary prompt") {
                TextEditor(text: $config.summaryPrompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                HStack {
                    Spacer()
                    Button("Reset to default") {
                        config.summaryPrompt = Config.defaultSummaryPrompt
                    }
                    .disabled(config.summaryPrompt == Config.defaultSummaryPrompt)
                }
            }
            Section {
                Text("""
                This instruction is sent to Gemini for every summary. The output structure \
                (summary, key points, next steps) and speaker identification are always \
                enforced — customize the tone, focus, or language here.
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

    // MARK: - Length toggle

    /// Horizontal segmented toggle (Short / Medium / Long) with a sliding
    /// selection pill: the highlight animates horizontally to the tapped option
    /// via matchedGeometryEffect.
    private struct SummaryLengthToggle: View {
        @Binding var selection: String
        @Namespace private var ns

        private let options: [(key: String, label: String)] = [
            ("short", "Short"), ("medium", "Medium"), ("long", "Long"),
        ]
        private let accent = Color(red: 0.0, green: 0.47, blue: 1.0)   // #0077FF

        var body: some View {
            HStack(spacing: 0) {
                ForEach(options, id: \.key) { option in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            selection = option.key
                        }
                    } label: {
                        Text(option.label)
                            .font(.system(size: 12, weight: selection == option.key ? .semibold : .regular))
                            .foregroundStyle(selection == option.key ? .white : .primary)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background {
                                if selection == option.key {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(accent)
                                        .matchedGeometryEffect(id: "selection", in: ns)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .frame(maxWidth: 280)
        }
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
