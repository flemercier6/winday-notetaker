import SwiftUI

/// Compact floating pill styled after the Winday CRM Figma design: a light
/// off-white card in a frosted translucent container, with a blue split button.
/// States: sign in → ready → recording (Stop & summarize / Discard / Collapse)
/// → processing → done (auto-dismisses).
struct RecorderPopup: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var client: SupabaseClient

    @State private var collapsed = false
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
                    closeBadge.offset(x: -6, y: -6).transition(.opacity)
                }
            }
            .padding(8)
            .fixedSize()
            .onHover { hovering in isHovering = hovering }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .onChange(of: model.isRecording) { recording in
                if recording { collapsed = false }
            }
    }

    /// Small circular close button shown on hover — dismisses the popup (e.g.
    /// when the user doesn't want to record this meeting).
    private var closeBadge: some View {
        Button { model.hidePopup() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Close")
    }

    @ViewBuilder
    private var row: some View {
        if !client.isAuthenticated {
            SignInView().frame(width: 300)
        } else if let done = model.doneFlash {
            doneRow(done)
        } else if model.isRecording {
            if collapsed { collapsedRow } else { recordingRow }
        } else if let status = model.activeStatus {
            processingRow(status)
        } else if let failed = model.failedMeeting {
            failedRow(failed)
        } else {
            readyRow
        }
    }

    // MARK: Rows

    private var readyRow: some View {
        HStack(spacing: 40) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(ink)
                Text("Start AI meeting Note")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ink)
            }
            SplitButton(title: "Start Transcribing", accent: accent) {
                Task { await model.startRecording() }
            } menu: {
                Button("Hide") { model.hidePopup() }
            }
        }
    }

    private var recordingRow: some View {
        HStack(spacing: 24) {
            HStack(spacing: 10) {
                RecordingDot()
                ElapsedText(start: model.recordingStartedAt ?? Date())
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ink)
                MiniLevel(level: model.recorder.level, accent: accent).frame(width: 40)
            }
            SplitButton(title: "Stop & summarize", accent: accent) {
                Task { await model.stopRecordingAndProcess() }
            } menu: {
                Button { collapsed = true } label: { Label("Collapse", systemImage: "chevron.up") }
                Button(role: .destructive) {
                    Task { await model.cancelRecording() }
                } label: { Label("Discard recording", systemImage: "trash") }
            }
        }
    }

    private var collapsedRow: some View {
        HStack(spacing: 8) {
            RecordingDot()
            ElapsedText(start: model.recordingStartedAt ?? Date())
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(ink)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.opacity(0.4))
        }
        .contentShape(Rectangle())
        .onTapGesture { collapsed = false }
        .help("Expand")
    }

    private func processingRow(_ status: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(status).font(.system(size: 14)).foregroundStyle(ink.opacity(0.7))
        }
    }

    private func doneRow(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
            Text(message).font(.system(size: 14, weight: .medium)).foregroundStyle(ink)
        }
    }

    private func failedRow(_ meeting: Meeting) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.transcript != nil ? "Summary failed — transcript saved"
                                                    : "Processing failed")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(ink)
                    Text("You can retry — it won't re-record the call.")
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
                }
            }
            HStack(spacing: 8) {
                Button("Dismiss") { model.dismissFailure() }
                    .buttonStyle(.plain)
                    .foregroundStyle(ink.opacity(0.55))
                Button { Task { await model.retryProcessing(meeting) } } label: {
                    Text("Retry")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Split button (text + chevron menu), styled like the Figma design

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
        Circle()
            .fill(.red)
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.3 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dim = true
                }
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
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct MiniLevel: View {
    let level: Float
    let accent: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.08))
                Capsule().fill(accent)
                    .frame(width: max(2, CGFloat(min(level, 1)) * geo.size.width))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .frame(height: 5)
    }
}
