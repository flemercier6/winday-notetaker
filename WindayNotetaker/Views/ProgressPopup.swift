import SwiftUI

/// Bottom-right popup shown after a meeting ends: live processing status, then a
/// "Notes ready" card with an Open in Notion button, or a failure with Retry.
/// Step labels stay generic (no platform names).
struct ProgressPopup: View {
    @EnvironmentObject private var model: AppViewModel

    @State private var isHovering = false

    private let accent = Color(red: 0.0, green: 0.47, blue: 1.0)
    private let cardBG = Color(red: 0.976, green: 0.973, blue: 0.969)
    private let cardBorder = Color(red: 0.878, green: 0.878, blue: 0.878)
    private let ink = Color.black

    var body: some View {
        content
            .frame(width: 250, alignment: .leading)
            .padding(14)
            .background(cardBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(cardBorder))
            .padding(4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if isHovering { closeBadge.offset(x: 4, y: -4).transition(.opacity) }
            }
            .padding(8)
            .fixedSize()
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var content: some View {
        if let failed = model.failedMeeting {
            failedView(failed)
        } else if model.doneFlash != nil {
            doneView
        } else {
            processingView
        }
    }

    // MARK: States

    private var header: some View {
        HStack(spacing: 8) {
            Image("WindayLogo")
                .resizable().renderingMode(.template).scaledToFit()
                .foregroundStyle(ink).frame(width: 16, height: 16)
            Text("Winday Notetaker")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.opacity(0.7))
        }
    }

    private var processingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.activeStatus ?? "Working…")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(ink)
            }
        }
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(model.doneFlash ?? "Notes ready")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
            }
            if model.doneNotionURL != nil {
                Button { model.openNotionPage() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Open in Notion")
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func failedView(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.transcript != nil ? "Summary failed — transcript saved"
                                                    : "Processing failed")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(ink)
                    Text("You can retry — it won't re-record.")
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
                }
            }
            HStack(spacing: 8) {
                Button("Dismiss") { model.dismissFailure() }
                    .buttonStyle(.plain).foregroundStyle(ink.opacity(0.55))
                Spacer()
                Button { Task { await model.retryProcessing(meeting) } } label: {
                    Text("Retry")
                        .font(.system(size: 14)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var closeBadge: some View {
        Button { model.dismissProgress() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Dismiss")
    }
}
