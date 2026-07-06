import SwiftUI

/// The floating popup shown at the top of the screen. Adapts to the current
/// state: sign in → meeting detected (Record) → recording (level + Stop) →
/// processing → done.
struct RecorderPopup: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var client: SupabaseClient

    var body: some View {
        content
            .frame(width: 340)
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .topTrailing) { closeButton }
            .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if !client.isAuthenticated {
            SignInView()
        } else if model.isRecording {
            recordingView
        } else if let status = model.activeStatus {
            processingView(status)
        } else {
            readyView
        }
    }

    // MARK: States

    private var readyView: some View {
        VStack(spacing: 12) {
            Label(model.meetDetector.isMeetActive ? "Google Meet detected" : "Ready to record",
                  systemImage: "video.fill")
                .font(.headline)
                .foregroundStyle(model.meetDetector.isMeetActive ? .green : .primary)
            Text("Capture the meeting audio and your mic, then get an AI summary in Notion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await model.startRecording() }
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var recordingView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Recording…").font(.headline)
            }
            LevelBar(level: model.recorder.level)
            Button(role: .destructive) {
                Task { await model.stopRecordingAndProcess() }
            } label: {
                Label("Stop & summarize", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
        }
    }

    private func processingView(_ status: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(status).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var closeButton: some View {
        Button {
            model.hidePopup()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .imageScale(.medium)
        }
        .buttonStyle(.plain)
        .padding(6)
        .help("Hide")
    }
}

/// Simple live level meter (0...1).
private struct LevelBar: View {
    let level: Float
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill").foregroundStyle(.red).font(.caption)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green)
                        .frame(width: max(2, CGFloat(min(level, 1)) * geo.size.width))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}
