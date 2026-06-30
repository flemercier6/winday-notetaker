import SwiftUI

/// Detail view: shows the summary, key points, next steps/priorities, and the
/// Notion export control for a single meeting.
struct SummaryView: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var config: Config
    let meeting: Meeting

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let summary = meeting.summary {
                    section("Summary", systemImage: "text.alignleft") {
                        Text(summary.summary)
                    }

                    if !summary.keyPoints.isEmpty {
                        section("Key points", systemImage: "list.bullet") {
                            ForEach(summary.keyPoints, id: \.self) { point in
                                Label(point, systemImage: "circle.fill")
                                    .labelStyle(BulletLabelStyle())
                            }
                        }
                    }

                    if !summary.nextSteps.isEmpty {
                        section("Next steps & priorities", systemImage: "checklist") {
                            ForEach(sortedSteps(summary.nextSteps)) { step in
                                NextStepRow(step: step)
                            }
                        }
                    }
                } else if meeting.status == .failed {
                    Label(meeting.errorMessage ?? "Processing failed.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Retry") { Task { await model.runPipeline(for: meeting) } }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.activeStatus ?? "Processing…").foregroundStyle(.secondary)
                    }
                }

                if let transcript = meeting.transcript {
                    DisclosureGroup("Full transcript") {
                        Text(transcript.labelled)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(meeting.title)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.summary?.headline ?? meeting.title)
                .font(.title2.bold())
            HStack(spacing: 12) {
                Label(meeting.startedAt.formatted(date: .abbreviated, time: .shortened),
                      systemImage: "calendar")
                if let duration = meeting.duration {
                    Label(durationText(duration), systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                if let urlString = meeting.notionPageURL, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Label("Open in Notion", systemImage: "arrow.up.right.square")
                    }
                } else if meeting.summary != nil {
                    Button {
                        Task { await model.exportToNotion(meeting) }
                    } label: {
                        Label("Send to Notion", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!config.isNotionConfigured)
                    .help(config.isNotionConfigured ? "Create a Notion page" : "Configure Notion in Settings")
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Helpers

    private func sortedSteps(_ steps: [MeetingSummary.ActionItem]) -> [MeetingSummary.ActionItem] {
        let order: [MeetingSummary.Priority] = [.high, .medium, .low]
        return steps.sorted {
            (order.firstIndex(of: $0.priority) ?? 9) < (order.firstIndex(of: $1.priority) ?? 9)
        }
    }

    private func durationText(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, systemImage: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
    }
}

private struct NextStepRow: View {
    let step: MeetingSummary.ActionItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(step.priority.emoji)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.task)
                HStack(spacing: 8) {
                    if let owner = step.owner, !owner.isEmpty {
                        Label(owner, systemImage: "person").font(.caption).foregroundStyle(.secondary)
                    }
                    if let due = step.due, !due.isEmpty {
                        Label(due, systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}
