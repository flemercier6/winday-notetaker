import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Winday design tokens (matched to the CRM's popovers in Figma)

/// Palette + type scale of the Winday CRM popovers: a blurred container
/// (backdrop-blur 15, #F9F8F7 @ 30%) holding a white card (border #E0E0E0,
/// radius 10, shadow 0 4 10 15%). Inter typography — black primary text,
/// #888888 secondary. Colors are fixed (not semantic) so the window looks like
/// the CRM in both light and dark mode.
enum WindayTheme {
    static let textPrimary = Color.black
    static let textSecondary = Color(red: 0x88 / 255, green: 0x88 / 255, blue: 0x88 / 255)
    static let border = Color(red: 0xE0 / 255, green: 0xE0 / 255, blue: 0xE0 / 255)
    static let cardBackground = Color.white
    /// The recording popups' card color (#F9F8F7).
    static let popupBackground = Color(red: 0.976, green: 0.973, blue: 0.969)
    static let chipBackground = Color(red: 0xE6 / 255, green: 0xE6 / 255, blue: 0xE6 / 255)
    static let accent = Color(red: 0.0, green: 0.47, blue: 1.0)          // #0077FF

    /// Inter when installed (the CRM's font), otherwise the system font at the
    /// same size/weight — SF is metrically the closest fallback.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "Inter", size: size) != nil {
            return .custom("Inter", size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

/// Strips the Settings window's chrome (no title bar) and makes it transparent
/// so only the rounded popup shape shows — same silhouette as the floating
/// recording popups.
private struct WindowChromeRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Settings window

/// Settings window, styled like the CRM's popovers. No third-party API keys
/// here — those live server-side as Supabase Edge Function secrets.
struct SettingsView: View {
    @EnvironmentObject private var config: Config
    @EnvironmentObject private var client: SupabaseClient
    @EnvironmentObject private var model: AppViewModel

    private enum Tab: String, CaseIterable {
        case account = "Account"
        case summary = "Summary"
        case notion = "Notion"
        case models = "Models"
    }

    @State private var tab: Tab = .account
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        // Same container recipe as the recording popups: #F9F8F7 card with a
        // #E0E0E0 border, a 4pt ultra-thin-material halo, and 8pt of outer
        // padding — on a chromeless, transparent window.
        VStack(alignment: .leading, spacing: 12) {
            tabBar

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .account: accountContent
                    case .summary: summaryContent
                    case .notion: notionContent
                    case .models: modelsContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .frame(width: 520, height: 440)
        .background(WindayTheme.popupBackground,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(WindayTheme.border))
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(8)
        .background(WindowChromeRemover())
    }

    // MARK: Tab bar — CRM-style chips (selected: #E6E6E6 fill; others: dashed)

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                } label: {
                    Text(t.rawValue)
                        .font(WindayTheme.font(12, .medium))
                        .foregroundStyle(WindayTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            if tab == t {
                                Capsule().fill(WindayTheme.chipBackground)
                            } else {
                                Capsule().strokeBorder(
                                    WindayTheme.textSecondary.opacity(0.8),
                                    style: StrokeStyle(lineWidth: 0.5, dash: [2.5, 2]))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: Account

    private var accountContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Account")
            if client.isAuthenticated {
                row("Email") {
                    Text(client.email ?? "—")
                        .font(WindayTheme.font(13))
                        .foregroundStyle(WindayTheme.textPrimary)
                }
                row("Session") {
                    Button("Sign out") { client.signOut() }
                        .buttonStyle(.plain)
                        .font(WindayTheme.font(13, .medium))
                        .foregroundStyle(.red)
                }
            } else {
                Text("You're signed out. Close Settings and sign in from the recorder popup.")
                    .font(WindayTheme.font(13))
                    .foregroundStyle(WindayTheme.textSecondary)
                    .padding(.vertical, 10)
            }

            sectionDivider
            sectionTitle("General")
            row("Launch at login") {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(WindayTheme.accent)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            caption("Keeps the menu-bar recorder available after a restart.")

            sectionDivider
            sectionTitle("Where are my API keys?")
            caption("""
            Your Deepgram, Gemini and Notion secrets live server-side as Supabase Edge \
            Function secrets — never on this Mac. The app only holds the public Supabase \
            URL + key, and talks to the backend on your behalf.
            """)
        }
    }

    // MARK: Summary

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Summary length")
            SummaryLengthToggle(selection: $config.summaryLength)
                .padding(.vertical, 6)
            caption("Short: 2–3 sentences. Medium: balanced. Long: detailed, multi-paragraph.")

            sectionDivider
            sectionTitle("Summary prompt")
            TextEditor(text: $config.summaryPrompt)
                .font(WindayTheme.font(12))
                .foregroundStyle(WindayTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 150)
                .background(WindayTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(WindayTheme.border))
                .padding(.vertical, 6)
            HStack {
                caption("Sent to Gemini for every summary. Structure and speaker identification stay enforced.")
                Spacer()
                Button("Reset to default") {
                    config.summaryPrompt = Config.defaultSummaryPrompt
                }
                .buttonStyle(.plain)
                .font(WindayTheme.font(12, .medium))
                .foregroundStyle(config.summaryPrompt == Config.defaultSummaryPrompt
                                 ? WindayTheme.textSecondary.opacity(0.5)
                                 : WindayTheme.accent)
                .disabled(config.summaryPrompt == Config.defaultSummaryPrompt)
            }
        }
    }

    // MARK: Notion

    private var notionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Notion export")
            row("Database ID") {
                TextField("32-character database ID", text: $config.notionDatabaseID)
                    .textFieldStyle(.plain)
                    .font(WindayTheme.font(13))
                    .foregroundStyle(WindayTheme.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 280)
            }
            row("Auto-send each summary") {
                Toggle("", isOn: $config.autoExportToNotion)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(WindayTheme.accent)
            }

            sectionDivider
            caption("""
            The Notion integration token is a server secret (NOTION_TOKEN). Here you only \
            set the target database:
            1. Open the database in Notion → ••• → Connections → add your integration.
            2. Copy the 32-character database ID from its URL and paste it above.
            """)
        }
    }

    // MARK: Models

    private var modelsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Models")
            row("Deepgram") {
                TextField("nova-3", text: $config.deepgramModel)
                    .textFieldStyle(.plain)
                    .font(WindayTheme.font(13))
                    .foregroundStyle(WindayTheme.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220)
            }
            caption("Default: nova-3")

            sectionDivider
            row("Gemini") {
                TextField("gemini-flash-latest", text: $config.geminiModel)
                    .textFieldStyle(.plain)
                    .font(WindayTheme.font(13))
                    .foregroundStyle(WindayTheme.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220)
            }
            caption("Default: gemini-flash-latest (always points at the newest Flash).")
        }
    }

    // MARK: Building blocks (CRM popover look)

    /// Section header — like "Details" in the CRM popover.
    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(WindayTheme.font(13, .semibold))
            .foregroundStyle(WindayTheme.textPrimary)
            .padding(.bottom, 8)
    }

    /// Label/value row — secondary label at the left, value at the right.
    private func row<Content: View>(_ label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(WindayTheme.font(13))
                .foregroundStyle(WindayTheme.textSecondary)
            Spacer(minLength: 24)
            value()
        }
        .padding(.vertical, 7)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(WindayTheme.font(11))
            .foregroundStyle(WindayTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }

    /// Hairline divider — #E0E0E0, like the CRM popover separators.
    private var sectionDivider: some View {
        Rectangle()
            .fill(WindayTheme.border)
            .frame(height: 1)
            .padding(.vertical, 12)
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

        var body: some View {
            HStack(spacing: 0) {
                ForEach(options, id: \.key) { option in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            selection = option.key
                        }
                    } label: {
                        Text(option.label)
                            .font(WindayTheme.font(12, selection == option.key ? .semibold : .regular))
                            .foregroundStyle(selection == option.key ? .white : WindayTheme.textSecondary)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background {
                                if selection == option.key {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(WindayTheme.accent)
                                        .matchedGeometryEffect(id: "selection", in: ns)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(WindayTheme.chipBackground.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .frame(maxWidth: 280)
        }
    }
}
