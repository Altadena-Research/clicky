import SwiftUI

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

struct ReplyText: View {
    let source: String
    let availableWidth: CGFloat

    private struct Section {
        var blocks: [ReplyBlock]
        var scrollWidth: CGFloat?
    }

    private var selectionSections: [Section] {
        // Keep the whole reply in one selection range except where a table needs its own scroller.
        var sections: [Section] = []
        var contiguous: [ReplyBlock] = []
        for block in ReplyBlock.parse(source) {
            if case let .table(table) = block, table.minimumWidth > availableWidth {
                if !contiguous.isEmpty {
                    sections.append(Section(blocks: contiguous))
                    contiguous = []
                }
                sections.append(Section(blocks: [block], scrollWidth: table.minimumWidth))
            } else {
                contiguous.append(block)
            }
        }
        if !contiguous.isEmpty { sections.append(Section(blocks: contiguous)) }
        return sections
    }

    var body: some View {
        let sections = selectionSections
        VStack(alignment: .leading, spacing: 3) {
            ForEach(sections.indices, id: \.self) { index in
                let section = sections[index]
                if let width = section.scrollWidth {
                    ScrollView(.horizontal) {
                        SelectableReply(blocks: section.blocks).frame(width: width)
                    }.fixedSize(horizontal: false, vertical: true)
                } else {
                    SelectableReply(blocks: section.blocks)
                }
            }
        }
    }
}

private struct SelectableReply: NSViewRepresentable {
    let blocks: [ReplyBlock]

    func makeNSView(context: Context) -> ReplySelectionView {
        // TextKit 1 lays out NSTextTable cells in the same selectable document as the surrounding text.
        let view = ReplySelectionView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        return view
    }

    func updateNSView(_ view: ReplySelectionView, context: Context) {
        view.display(blocks)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ReplySelectionView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let layout = view.layoutManager, let container = view.textContainer else { return nil }
        let previous = container.containerSize
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).maxY)
        container.containerSize = previous
        return CGSize(width: width, height: max(1, height))
    }
}

final class ReplySelectionView: NSTextView {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        // A read-only text view can track the drag while the composer still owns Command-C.
        super.mouseDown(with: event)
        if selectedRange().length > 0 { window?.makeFirstResponder(self) }
    }
    private var displayed: [ReplyBlock] = []

    func display(_ blocks: [ReplyBlock]) {
        guard displayed != blocks else { return }
        displayed = blocks
        let content = NSMutableAttributedString()
        func appendParagraph(_ text: NSAttributedString, style: NSParagraphStyle) {
            let start = content.length
            content.append(text)
            content.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]))
            content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: content.length - start))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 3
        for block in blocks {
            switch block {
            case let .table(table):
                Self.appendTable(table, appendParagraph: appendParagraph)
            case let .code(line):
                let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                appendParagraph(NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.labelColor]), style: paragraph)
            case let .heading(line): appendParagraph(Self.inline(line, bold: true), style: paragraph)
            case let .body(line): appendParagraph(Self.inline(line), style: paragraph)
            }
        }
        if content.length > 0 { content.deleteCharacters(in: NSRange(location: content.length - 1, length: 1)) }
        let range = selectedRange()
        let previous = string as NSString
        textStorage?.setAttributedString(content)
        if range.length > 0, NSMaxRange(range) <= previous.length, NSMaxRange(range) <= content.length,
           previous.substring(with: range) == (content.string as NSString).substring(with: range) {
            setSelectedRange(range)
        }
    }

    private static func appendTable(_ table: ReplyTable, appendParagraph: (NSAttributedString, NSParagraphStyle) -> Void) {
        let layout = NSTextTable()
        layout.numberOfColumns = table.alignments.count
        layout.setContentWidth(100, type: .percentageValueType)
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
            text.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return text
    }
}
