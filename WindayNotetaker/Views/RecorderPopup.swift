import SwiftUI

/// Compact floating pill shown at the top of the screen. States:
/// sign in → ready → recording (with Stop & summarize / Discard / Collapse) →
/// processing → done (auto-dismisses).
struct RecorderPopup: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var client: SupabaseClient

    @State private var collapsed = false

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        card
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
            .padding(12)
            .fixedSize()
            .onChange(of: model.isRecording) { recording in
                if recording { collapsed = false }
            }
    }

    @ViewBuilder
    private var card: some View {
        if !client.isAuthenticated {
            SignInView().frame(width: 300)
        } else if let done = model.doneFlash {
            doneRow(done)
        } else if model.isRecording {
            if collapsed { collapsedRow } else { recordingRow }
        } else if let status = model.activeStatus {
            processingRow(status)
        } else {
            readyRow
        }
    }

    // MARK: Rows

    private var readyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.meetDetector.isMeetActive ? "Meeting detected" : "Winday Notetaker")
                    .font(.subheadline.weight(.semibold))
                Text("Start an AI meeting note")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Button { Task { await model.startRecording() } } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            closeButton
        }
    }

    private var recordingRow: some View {
        HStack(spacing: 10) {
            RecordingDot()
            ElapsedText(start: model.recordingStartedAt ?? Date())
                .font(.subheadline.weight(.semibold).monospacedDigit())
            MiniLevel(level: model.recorder.level).frame(width: 40)
            Spacer(minLength: 10)
            Button { Task { await model.stopRecordingAndProcess() } } label: {
                Text("Stop & summarize")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Menu {
                Button { collapsed = true } label: { Label("Collapse", systemImage: "chevron.up") }
                Button(role: .destructive) {
                    Task { await model.cancelRecording() }
                } label: { Label("Discard recording", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(width: 18)
        }
    }

    private var collapsedRow: some View {
        HStack(spacing: 8) {
            RecordingDot()
            ElapsedText(start: model.recordingStartedAt ?? Date())
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { collapsed = false }
        .help("Expand")
    }

    private func processingRow(_ status: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(status).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func doneRow(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.subheadline.weight(.medium))
        }
    }

    private var closeButton: some View {
        Button { model.hidePopup() } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .imageScale(.medium)
        }
        .buttonStyle(.plain)
        .help("Hide")
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
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green)
                    .frame(width: max(2, CGFloat(min(level, 1)) * geo.size.width))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .frame(height: 5)
    }
}
