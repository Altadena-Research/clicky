import SwiftUI

struct QueuedQuestion: Identifiable {
    let id = UUID()
    let text: String
    let images: [ChatImage]

    var preview: String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !line.isEmpty { return line }
        return images.count == 1 ? "Image" : "\(images.count) images"
    }
}

struct MeetingQueueView: View {
    @ObservedObject var store: MeetingStore
    @State private var expanded = false

    var body: some View {
        let items = store.waiting
        VStack(alignment: .leading, spacing: 5) {
            if let first = items.first {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                        Text("\(items.count) queued").fontWeight(.semibold).fixedSize()
                        if !expanded {
                            Text("Next · \(first.preview)").foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(items.count) queued messages. \(expanded ? "Hide" : "Show") queue")
                    .accessibilityValue(expanded ? "" : "Next · \(first.preview)")
                    .help(expanded ? "Hide queued messages" : "Show queued messages")
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                HStack(spacing: 6) {
                                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                    Text(item.preview).lineLimit(1).help(item.text)
                                    if !item.images.isEmpty && !item.text.isEmpty {
                                        Label("\(item.images.count)", systemImage: "paperclip").fixedSize()
                                    }
                                    Spacer(minLength: 2)
                                    Button { store.removeQueued(item.id) } label: {
                                        Image(systemName: "xmark.circle").padding(3)
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel("Remove queued message \(index + 1)")
                                        .help("Remove this message from the queue")
                                }.frame(height: 23)
                            }
                        }
                    }.frame(height: CGFloat(min(3, items.count)) * 23)
                }
            }
            if let reason = store.queueProblem {
                HStack(alignment: .firstTextBaseline) {
                    Text(reason).foregroundStyle(.secondary).lineLimit(3).help(reason)
                    Spacer(minLength: 4)
                    Button("Resume queue", action: store.resumeQueue).disabled(!store.connected)
                }
            }
        }.font(.caption)
    }
}
