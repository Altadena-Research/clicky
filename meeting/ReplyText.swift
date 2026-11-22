import SwiftUI
import ImageIO

struct ChatLine: Decodable, Identifiable, Equatable {
    let id: String
    let role: String
    let images: [String]?
    let text: String
}

enum ReplyBlock: Equatable {
    case body(String), heading(String), code(String)
    case table(ReplyTable)

    static func parse(_ source: String) -> [Self] {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var blocks: [Self] = []
        var fence: Substring?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let text = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if text.hasPrefix(marker) && text.allSatisfy({ $0 == marker.first }) {
                    fence = nil
                } else {
                    blocks.append(.code(String(line)))
                }
            } else if text.hasPrefix("```") || text.hasPrefix("~~~") {
                fence = text.prefix { $0 == text.first }
            } else if index < lines.count, let header = ReplyTable.cells(in: line),
                      let alignments = ReplyTable.alignments(in: lines[index], count: header.count) {
                index += 1
                var rows = [header]
                while index < lines.count, let cells = ReplyTable.cells(in: lines[index]) {
                    var row = Array(cells.prefix(header.count))
                    row.append(contentsOf: repeatElement("", count: header.count - row.count))
                    rows.append(row)
                    index += 1
                }
                blocks.append(.table(ReplyTable(rows: rows, alignments: alignments)))
            } else {
                let hashes = text.prefix { $0 == "#" }
                if (1...6).contains(hashes.count), text.dropFirst(hashes.count).first == " " {
                    blocks.append(.heading(String(text.dropFirst(hashes.count + 1))))
                } else if text.hasPrefix("- ") || text.hasPrefix("* ") {
                    blocks.append(.body("•  " + text.dropFirst(2)))
                } else {
                    blocks.append(.body(String(line)))
                }
            }
        }
        return blocks
    }
}

struct ReplyTable: Equatable {
    static let minimumColumnWidth: CGFloat = 84
    let rows: [[String]]
    let alignments: [TextAlignment]
    var minimumWidth: CGFloat { CGFloat(alignments.count) * Self.minimumColumnWidth }

    fileprivate static func cells(in line: Substring) -> [String]? {
        guard line.contains("|") else { return nil }
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("```") || text.hasPrefix("~~~") || text.hasPrefix("# ") ||
            text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("> ") { return nil }
        var cells: [String] = []
        var cell = ""
        var characters = text.makeIterator()
        while let character = characters.next() {
            switch character {
            case "\\":
                if let next = characters.next() {
                    if next != "|" { cell.append("\\") }
                    cell.append(next)
                } else {
                    cell.append(character)
                }
            case "|":
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            default:
                cell.append(character)
            }
        }
        guard !cells.isEmpty else { return nil }
        if text.first == "|" { cells.removeFirst() }
        if !cell.isEmpty { cells.append(cell.trimmingCharacters(in: .whitespaces)) }
        return cells.isEmpty ? nil : cells
    }

    fileprivate static func alignments(in line: Substring, count: Int) -> [TextAlignment]? {
        guard let rules = cells(in: line), rules.count == count else { return nil }
        var result: [TextAlignment] = []
        for rule in rules {
            var dashes = rule[...]
            let left = dashes.first == ":"
            if left { dashes.removeFirst() }
            let right = dashes.last == ":"
            if right { dashes.removeLast() }
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            if left && right { result.append(.center) }
            else { result.append(right ? .trailing : .leading) }
        }
        return result
    }
}

struct ConversationTranscript: NSViewRepresentable {
    let messages: [ChatLine]

    func makeNSView(context: Context) -> TranscriptScrollView {
        TranscriptScrollView(frame: .zero)
    }

    func updateNSView(_ view: TranscriptScrollView, context: Context) {
        view.display(messages)
    }
}

final class TranscriptScrollView: NSScrollView {
    private let transcript = ReplySelectionView(usingTextLayoutManager: false)
    private var messages: [ChatLine] = []
    private var rendered: [RenderedMessage] = []
    private var needsTextUpdate = false
    private var wrapWidth: CGFloat?
    private var minimumTableWidth: CGFloat = 0
    private var fittingDocument = false
    private var followLatest = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textContainerInset = .zero
        transcript.textContainer?.lineFragmentPadding = 0
        transcript.textContainer?.widthTracksTextView = false
        transcript.isVerticallyResizable = false
        transcript.isHorizontallyResizable = false
        transcript.setAccessibilityLabel("Meeting conversation")
        documentView = transcript
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ incoming: [ChatLine]) {
        guard incoming != messages else { return }
        followLatest = messages.isEmpty || documentVisibleRect.maxY >= transcript.frame.height - 2
        messages = incoming
        let previous = Dictionary(uniqueKeysWithValues: rendered.map { ($0.message.id, $0) })
        rendered = incoming.map { message in
            if let cached = previous[message.id], cached.message == message { return cached }
            return RenderedMessage(message)
        }
        minimumTableWidth = rendered.map(\.minimumTableWidth).max() ?? 0
        needsTextUpdate = true
        fitDocument()
    }

    override func layout() {
        super.layout()
        fitDocument()
    }

    fileprivate func fitDocument() {
        let available = contentSize.width
        guard available > 0, !fittingDocument, !transcript.trackingSelection,
              let container = transcript.textContainer, let layout = transcript.layoutManager else { return }
        fittingDocument = true
        defer { fittingDocument = false }
        let width = max(available, minimumTableWidth)
        // Prose still wraps at the viewport edge if one of the tables requires horizontal scrolling.
        let constrained = minimumTableWidth > available ? available : nil
        if hasHorizontalScroller != (constrained != nil) { hasHorizontalScroller = constrained != nil }
        if needsTextUpdate || wrapWidth != constrained {
            transcript.display(rendered, wrapWidth: constrained)
            wrapWidth = constrained
            needsTextUpdate = false
        }
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let size = NSSize(width: width, height: max(1, ceil(layout.usedRect(for: container).maxY)))
        if transcript.frame.size != size { transcript.setFrameSize(size) }
        if followLatest, transcript.selectedRange().length == 0 {
            contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: max(0, size.height - contentSize.height)))
            reflectScrolledClipView(contentView)
        }
        followLatest = false
    }
}

final class ReplySelectionView: NSTextView {
    fileprivate private(set) var trackingSelection = false
    private var messageRanges: [String: NSRange] = [:]
    private var displayed: [RenderedMessage] = []
    private var displayedWrapWidth: CGFloat?

    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        // AppKit tracks the drag synchronously. Let it finish before applying a live transcript update.
        trackingSelection = true
        super.mouseDown(with: event)
        if selectedRange().length > 0 { window?.makeFirstResponder(self) }
        trackingSelection = false
        (enclosingScrollView as? TranscriptScrollView)?.fitDocument()
    }

    fileprivate func display(_ messages: [RenderedMessage], wrapWidth: CGFloat?) {
        guard let storage = textStorage else { return }
        let appending = !displayed.isEmpty && displayed.count < messages.count && displayedWrapWidth == wrapWidth
            && zip(displayed, messages).allSatisfy { $0 === $1 }
        defer {
            displayed = messages
            displayedWrapWidth = wrapWidth
        }
        if appending {
            // Leave TextKit's original selection anchor intact, including an upward drag or Shift selection.
            let suffix = NSMutableAttributedString()
            let previousText = displayed[displayed.count - 1].content(wrapWidth: wrapWidth)
            suffix.append(previousText.attributedSubstring(from: NSRange(location: previousText.length - 1, length: 1)))
            for message in messages.dropFirst(displayed.count) {
                let text = message.content(wrapWidth: wrapWidth)
                messageRanges[message.message.id] = NSRange(location: storage.length + suffix.length, length: text.length)
                suffix.append(text)
            }
            suffix.deleteCharacters(in: NSRange(location: suffix.length - 1, length: 1))
            storage.append(suffix)
            return
        }
        let selection = selectedRange()
        let first = messageRanges.first { NSLocationInRange(selection.location, $0.value) }
        let last = messageRanges.first { selection.length > 0 && NSLocationInRange(NSMaxRange(selection) - 1, $0.value) }
        let selectedText = selection.length > 0 ? (string as NSString).substring(with: selection) : nil
        let content = NSMutableAttributedString()
        messageRanges.removeAll(keepingCapacity: true)
        for message in messages {
            let text = message.content(wrapWidth: wrapWidth)
            messageRanges[message.message.id] = NSRange(location: content.length, length: text.length)
            content.append(text)
        }
        if content.length > 0 { content.deleteCharacters(in: NSRange(location: content.length - 1, length: 1)) }
        storage.setAttributedString(content)
        if let selectedText, let first, let last,
           let newFirst = messageRanges[first.key], let newLast = messageRanges[last.key] {
            let start = newFirst.location + selection.location - first.value.location
            let end = newLast.location + NSMaxRange(selection) - last.value.location
            if start <= end, end <= content.length {
                let range = NSRange(location: start, length: end - start)
                if (content.string as NSString).substring(with: range) == selectedText {
                    setSelectedRange(range)
                    return
                }
            }
        }
        setSelectedRange(NSRange(location: 0, length: 0))
    }
}

private final class RenderedMessage {
    let message: ChatLine
    let minimumTableWidth: CGFloat
    private let blocks: [ReplyBlock]
    private let thumbnails: [NSTextAttachment]
    private var lastWidth: CGFloat?
    private var cachedText: NSAttributedString?

    init(_ message: ChatLine) {
        self.message = message
        blocks = ReplyBlock.parse(message.text)
        minimumTableWidth = blocks.compactMap { block -> CGFloat? in
            if case let .table(table) = block { return table.minimumWidth }
            return nil
        }.max() ?? 0
        thumbnails = (message.images ?? []).compactMap { path in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 180
                  ] as CFDictionary) else { return nil }
            let scale = min(1, 90 / CGFloat(bitmap.width), 65 / CGFloat(bitmap.height))
            let image = NSImage(cgImage: bitmap, size: NSSize(width: CGFloat(bitmap.width) * scale,
                                                              height: CGFloat(bitmap.height) * scale))
            image.accessibilityDescription = "Attached image"
            let attachment = NSTextAttachment()
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
            return attachment
        }
    }

    func content(wrapWidth: CGFloat?) -> NSAttributedString {
        if let cachedText, lastWidth == wrapWidth { return cachedText }
        let content = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func appendParagraph(_ text: NSAttributedString, style: NSParagraphStyle) {
            let start = content.length
            content.append(text)
            content.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: content.length - start))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 3
        paragraph.tailIndent = wrapWidth ?? 0
        let caption = paragraph.mutableCopy() as! NSMutableParagraphStyle
        caption.paragraphSpacingBefore = 12
        caption.paragraphSpacing = 4
        appendParagraph(NSAttributedString(string: message.role == "assistant" ? "Claude" : "You",
                                           attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                                                        .foregroundColor: NSColor.secondaryLabelColor]), style: caption)
        if !thumbnails.isEmpty {
            let row = NSMutableAttributedString()
            for thumbnail in thumbnails {
                if row.length > 0 { row.append(NSAttributedString(string: " ")) }
                row.append(NSAttributedString(attachment: thumbnail))
            }
            appendParagraph(row, style: paragraph)
        }
        for block in blocks {
            switch block {
            case let .table(table):
                Self.appendTable(table, wrapWidth: wrapWidth, appendParagraph: appendParagraph)
            case let .code(line):
                let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                appendParagraph(NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.labelColor]), style: paragraph)
            case let .heading(line): appendParagraph(Self.inline(line, bold: true), style: paragraph)
            case let .body(line): appendParagraph(Self.inline(line), style: paragraph)
            }
        }
        cachedText = content
        lastWidth = wrapWidth
        return content
    }

    private static func appendTable(_ table: ReplyTable, wrapWidth: CGFloat?, appendParagraph: (NSAttributedString, NSParagraphStyle) -> Void) {
        let layout = NSTextTable()
        layout.numberOfColumns = table.alignments.count
        if let wrapWidth {
            layout.setContentWidth(max(wrapWidth, table.minimumWidth), type: .absoluteValueType)
        } else {
            layout.setContentWidth(100, type: .percentageValueType)
        }
        let rows = table.rows.enumerated().map { index, row in row.map { inline($0, bold: index == 0) } }
        let widths = table.alignments.indices.map { column in
            rows.map { ceil($0[column].size().width) }.max() ?? 0
        }
        let widest = widths.indices.max { widths[$0] < widths[$1] }
        for (rowIndex, row) in rows.enumerated() {
            for (column, cell) in row.enumerated() {
                let cellBlock = NSTextTableBlock(table: layout, startingRow: rowIndex, rowSpan: 1,
                                                startingColumn: column, columnSpan: 1)
                // Let short labels hug their contents; leave the rest of the width for prose.
                if column != widest, widths[column] + 12 <= ReplyTable.minimumColumnWidth {
                    cellBlock.setContentWidth(widths[column], type: .absoluteValueType)
                }
                cellBlock.setWidth(6, type: .absoluteValueType, for: .padding)
                if rowIndex < table.rows.count - 1 {
                    cellBlock.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                    cellBlock.setBorderColor(.separatorColor, for: .maxY)
                }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cellBlock]
                switch table.alignments[column] {
                case .leading: style.alignment = .natural
                case .center: style.alignment = .center
                case .trailing: style.alignment = .right
                }
                appendParagraph(cell, style)
            }
        }
    }

    private static let reportLinks = try! NSRegularExpression(
        pattern: #"(?<![\w/])http://aurelius-mac-2:8700/output/raw/[0-9a-f]{12}(?=$|[\s),.\]>!?])"#)

    private static func inline(_ source: String, bold: Bool = false) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        let text = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            let weight: NSFont.Weight = bold || intent.contains(.stronglyEmphasized) ? .bold : .regular
            let size = NSFont.systemFontSize
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                                              : NSFont.systemFont(ofSize: size, weight: weight)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let link = run.link { attributes[.link] = link }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let part = NSMutableAttributedString(string: String(parsed[run.range].characters), attributes: attributes)
            if run.link == nil && !intent.contains(.code) {
                for match in reportLinks.matches(in: part.string, range: NSRange(location: 0, length: part.length)) {
                    let raw = (part.string as NSString).substring(with: match.range)
                    if let url = URL(string: raw) { part.addAttribute(.link, value: url, range: match.range) }
                }
            }
            text.append(part)
        }
        return text
    }
}
