import SwiftUI
import AppKit

/// Top-center floating pill (Figma-styled). States: sign in → ready (Start) →
/// recording (audio visualizer + "–" to hide). Progress/done/failure live in the
/// separate bottom-right ProgressPopup.
struct RecorderPopup: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var client: SupabaseClient

    @State private var isHovering = false

    // Palette from the Figma node.
    private let accent = Color(red: 0.0, green: 0.47, blue: 1.0)          // #0077FF
    private let cardBG = Color(red: 0.976, green: 0.973, blue: 0.969)     // #F9F8F7
    private let cardBorder = Color(red: 0.878, green: 0.878, blue: 0.878) // #E0E0E0
    private let ink = Color.black

    var body: some View {
        row
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(cardBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(cardBorder))
            .padding(4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                if isHovering {
                    hoverBadge(icon: model.isRecording ? "minus" : "xmark")
                        .offset(x: -6, y: -6).transition(.opacity)
                }
            }
            .padding(8)
            .fixedSize()
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var row: some View {
        if !client.isAuthenticated {
            SignInView().frame(width: 300)
        } else if model.isRecording {
            recordingRow
        } else {
            readyRow
        }
    }

    // MARK: Ready

    private var readyRow: some View {
        HStack(spacing: 40) {
            HStack(spacing: 12) {
                Image("WindayLogo")
                    .resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(ink).frame(width: 24, height: 24)
                if let armed = model.armedMeeting {
                    // Pre-labelled with the scheduled call + its CRM company.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(armed.title)
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(ink)
                            .lineLimit(1)
                        if let co = armed.companyName, !co.isEmpty {
                            Text(co)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                } else {
                    Text("Start AI Meeting Note")
                        .font(.system(size: 15, weight: .regular)).foregroundStyle(ink)
                }
            }
            SplitButton(title: model.armedMeeting?.meetURL != nil ? "Join and Record" : "Start Transcribing",
                        accent: accent) {
                // Armed from a calendar call → open the Meet link, then record.
                if let s = model.armedMeeting?.meetURL, let url = URL(string: s) {
                    NSWorkspace.shared.open(url)
                }
                Task { await model.startRecording() }
            } menu: {
                Button("Hide") { model.hidePopup() }
            }
        }
    }

    // MARK: Recording — visualizer + hide

    private var recordingRow: some View {
        HStack(spacing: 12) {
            RecordingDot()
            ElapsedText(start: model.recordingStartedAt ?? Date())
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(ink)
            AudioVisualizer(levels: model.recorder.levels, color: accent)
        }
    }

    /// Round badge shown at the top-left on hover — "–" while recording (hide),
    /// "×" otherwise (don't record).
    private func hoverBadge(icon: String) -> some View {
        Button { model.hidePopup() } label: {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(icon == "minus" ? "Hide" : "Close")
    }
}

// MARK: - Audio visualizer (scrolling bars)

private struct AudioVisualizer: View {
    let levels: [Float]
    let color: Color

    private let barWidth: CGFloat = 3.5
    private let spacing: CGFloat = 2.5
    private let maxHeight: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(color.opacity(0.5 + 0.5 * Double(min(levels[i], 1))))
                    .frame(width: barWidth,
                           height: max(3, CGFloat(min(levels[i], 1)) * maxHeight))
            }
        }
        .frame(height: maxHeight)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

// MARK: - Split button (text + chevron menu)

private struct SplitButton<MenuItems: View>: View {
    let title: String
    let accent: Color
    let action: () -> Void
    @ViewBuilder var menu: () -> MenuItems

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)

            Rectangle().fill(.white.opacity(0.28)).frame(width: 1, height: 20)

            Menu {
                menu()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .background(accent)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }
}

// MARK: - Small pieces

private struct RecordingDot: View {
    @State private var dim = false
    var body: some View {
        Circle().fill(.red).frame(width: 9, height: 9)
            .opacity(dim ? 0.3 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

private struct ElapsedText: View {
    let start: Date
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            Text(format(context.date.timeIntervalSince(start)))
        }
    }
    private func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t)); return String(format: "%d:%02d", s / 60, s % 60)
    }
}
