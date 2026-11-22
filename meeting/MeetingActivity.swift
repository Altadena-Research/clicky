import SwiftUI

struct MeetingWorkItem: Decodable, Equatable, Identifiable {
    let id: String
    let reference: String
    let kind: String
    let title: String
    let status: String
    let updated: String?
    let detail: String?
    let thread: String?

    var isWorking: Bool {
        status == "running" && kind != "terminal" && kind != "listener"
    }
    var isFinished: Bool { ["completed", "failed", "stopped"].contains(status) }
    var updatedLabel: String? {
        guard let updated else { return nil }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let date = (try? fractional.parse(updated)) ?? (try? Date.ISO8601FormatStyle().parse(updated))
        return date?.formatted(date: .abbreviated, time: .shortened)
    }
    var kindLabel: String {
        switch kind {
        case "claudeAgent": return "Claude agent"
        case "codexJob": return "Codex job"
        case "codexAgent": return "Codex subagent"
        case "shell": return "Background shell"
        case "listener": return "Monitor"
        default: return "Terminal"
        }
    }
    var stateLabel: String {
        switch status {
        case "waiting": return "Needs input"
        case "unknown": return "Unconfirmed"
        case "completed": return "Finished"
        default: return status.capitalized
        }
    }
    var symbol: String {
        switch kind {
        case "shell", "terminal": return "terminal"
        case "listener": return "waveform"
        default: return "person.2"
        }
    }
    var tint: Color {
        switch status {
        case "running": return .accentColor
        case "completed": return .green
        case "waiting", "failed": return .orange
        default: return .secondary
        }
    }
}

struct MeetingActivityInspector: View {
    let items: [MeetingWorkItem]
    let close: () -> Void
    @State private var expanded: String?
    @State private var showFinished = false
    @State private var showUnknown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Meeting activity").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close activity")
                    .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
            }
            if items.isEmpty {
                Text("No activity reported for this session.").foregroundStyle(.secondary)
                    .font(.callout)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    section("Paired terminal", rows: items.filter { $0.kind == "terminal" })
                    section("Background work", rows: items.filter {
                        $0.kind != "terminal" && $0.kind != "listener" && !$0.isFinished && $0.status != "unknown"
                    })
                    section("Listeners", rows: items.filter { $0.kind == "listener" && $0.status == "listening" })
                    let unknown = items.filter { $0.kind != "terminal" && $0.status == "unknown" }
                    if !unknown.isEmpty {
                        DisclosureGroup("Unconfirmed (\(unknown.count))", isExpanded: $showUnknown) { rows(unknown) }
                            .font(.caption.weight(.semibold))
                    }
                    let finished = items.filter(\.isFinished)
                    if !finished.isEmpty {
                        DisclosureGroup("Finished (\(finished.count))", isExpanded: $showFinished) { rows(finished) }
                            .font(.caption.weight(.semibold))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private func section(_ title: String, rows entries: [MeetingWorkItem]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(title) (\(entries.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                rows(entries)
            }
        }
    }

    private func rows(_ entries: [MeetingWorkItem]) -> some View {
        ForEach(entries) { entry in
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    expanded = expanded == entry.id ? nil : entry.id
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: entry.symbol).foregroundStyle(entry.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.callout).lineLimit(2)
                            Text(entry.kindLabel + " · " + entry.stateLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: expanded == entry.id ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(entry.title + ", " + entry.kindLabel + ", " + entry.stateLabel)
                    .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                if expanded == entry.id {
                    VStack(alignment: .leading, spacing: 3) {
                        if let detail = entry.detail, !detail.isEmpty { Text(detail) }
                        Text(entry.reference).font(.caption.monospaced())
                        if let thread = entry.thread, thread != entry.reference { Text("Thread " + thread).font(.caption.monospaced()) }
                        if let updated = entry.updatedLabel { Text("Updated " + updated).font(.caption2) }
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(.leading, 5)
                }
            }.padding(.vertical, 3)
        }
    }
}
