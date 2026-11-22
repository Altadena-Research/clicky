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
    var startedAt: TimeInterval? = nil
    var endedAt: TimeInterval? = nil

    var hasLiveTimer: Bool {
        startedAt != nil && endedAt == nil && (status == "running" || status == "listening")
    }
    var durationLabel: String {
        if kind == "codexAgent" || kind == "terminal" { return hasLiveTimer ? "Current turn" : "Last turn" }
        return kind == "listener" ? "Listening time" : "Run time"
    }
    func elapsed(at now: Date) -> String? {
        guard let startedAt, startedAt > 0 else { return nil }
        let end: TimeInterval
        if hasLiveTimer { end = now.timeIntervalSince1970 }
        else if (isFinished || status == "idle"), let endedAt { end = endedAt }
        else { return nil }
        guard let seconds = Int(exactly: (end - startedAt).rounded(.down)), seconds >= 0 else { return nil }
        return Duration.seconds(seconds).formatted(.time(pattern: seconds < 3600 ? .minuteSecond : .hourMinuteSecond))
    }

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
                if entry.hasLiveTimer {
                    TimelineView(.periodic(from: .now, by: 1)) { clock in
                        rowButton(entry, elapsed: entry.elapsed(at: clock.date))
                    }
                } else {
                    rowButton(entry, elapsed: entry.elapsed(at: .now))
                }
                if expanded == entry.id {
                    VStack(alignment: .leading, spacing: 3) {
                        if let detail = entry.detail, !detail.isEmpty { Text(detail) }
                        Text(entry.reference).font(.caption.monospaced())
                        if let thread = entry.thread, thread != entry.reference { Text("Thread " + thread).font(.caption.monospaced()) }
                        if let start = entry.startedAt {
                            let date = Date(timeIntervalSince1970: start)
                            Text("Started " + date.formatted(date: .abbreviated, time: .standard)).font(.caption2)
                        }
                        if let updated = entry.updatedLabel { Text("Updated " + updated).font(.caption2) }
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(.leading, 5)
                }
            }.padding(.vertical, 3)
        }
    }

    private func rowButton(_ entry: MeetingWorkItem, elapsed: String?) -> some View {
        Button {
            expanded = expanded == entry.id ? nil : entry.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: entry.symbol).foregroundStyle(entry.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.callout).lineLimit(2)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(entry.kindLabel + " · " + entry.stateLabel)
                        Spacer(minLength: 0)
                        if let elapsed {
                            Text(verbatim: elapsed).monospacedDigit().fixedSize().help(entry.durationLabel)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: expanded == entry.id ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(entry.title + ", " + entry.kindLabel + ", " + entry.stateLabel)
            .accessibilityValue(elapsed.map { entry.durationLabel + " " + $0 } ?? "")
            .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
    }
}
