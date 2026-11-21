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
    let rows: [[String]]
    let alignments: [TextAlignment]

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

private func inlineText(_ markdown: String) -> Text {
    let styled = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    return Text(styled ?? AttributedString(markdown))
}

struct ReplyText: View {
    let source: String

    var body: some View {
        let blocks = ReplyBlock.parse(source)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case let .table(table): ReplyTableView(table: table)
                case let .code(line): Text(verbatim: line).font(.system(.caption, design: .monospaced))
                case let .heading(line): inlineText(line).font(.headline)
                case let .body(line): inlineText(line).font(.body)
                }
            }
        }.textSelection(.enabled)
    }
}

private struct ReplyTableView: View {
    let table: ReplyTable

    private func cell(row: Int, column: Int) -> some View {
        let alignment = table.alignments[column]
        let horizontal: HorizontalAlignment = switch alignment {
        case .center: .center
        case .trailing: .trailing
        case .leading: .leading
        }
        return inlineText(table.rows[row][column])
            .font(row == 0 ? .body.weight(.semibold) : .body)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .gridColumnAlignment(horizontal)
    }

    private var grid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow(alignment: .top) {
                    ForEach(table.alignments.indices, id: \.self) { column in
                        cell(row: row, column: column)
                    }
                }
                if row < table.rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
            }
        }
    }

    var body: some View {
        let minimumWidth = CGFloat(table.alignments.count) * 84
        ViewThatFits(in: .horizontal) {
            grid.frame(minWidth: minimumWidth, idealWidth: minimumWidth, maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal) {
                grid.fixedSize(horizontal: false, vertical: true)
                    .frame(width: minimumWidth, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
