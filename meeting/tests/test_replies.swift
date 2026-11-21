import AppKit
import SwiftUI

@main
struct ReplyTests {
    @MainActor static func main() throws {
        let source = """
        ## Weekly notes
        | Topic | Update |
        |:---|---|
        | Schedule | **Confirmed.** The room is booked for Thursday. There is enough time for questions after the demo. |
        | Materials | Bring the printed agenda and the sample marked `A\\|B`. |

        - Share the notes.
        """
        let blocks = ReplyBlock.parse(source)
        guard case let .table(table) = blocks[1] else { fatalError("Expected a table after the heading") }
        precondition(blocks.count == 4 && blocks.first == .heading("Weekly notes") && blocks.last == .body("•  Share the notes."))
        precondition(table.rows.count == 3 && table.rows[0] == ["Topic", "Update"])
        precondition(table.rows[1][1].hasPrefix("**Confirmed.**") && table.rows[2][1].contains("`A|B`"))
        let ragged = ReplyBlock.parse("Name | Center | Total\r\n:-- | :-: | --:\r\n| One | |\r\nTwo | B | 2 | extra")
        precondition(ragged == [.table(ReplyTable(rows: [["Name", "Center", "Total"], ["One", "", ""], ["Two", "B", "2"]],
                                                  alignments: [.leading, .center, .trailing]))])
        let fenced = ReplyBlock.parse("```md\n| A | B |\n|---|---|\n```\nplain | text")
        precondition(fenced == [.code("| A | B |"), .code("|---|---|"), .body("plain | text")])
        precondition(ReplyBlock.parse("A | B\n--- | typo") == [.body("A | B"), .body("--- | typo")])

        _ = NSApplication.shared
        let narrow = try snapshot(source, width: 280)
        let wide = try snapshot(source, width: 670)
        precondition(narrow > wide && wide > 65, "Expected long cells to wrap when the panel narrows (\(narrow), \(wide))")
        let manyColumns = "Day | Time | Location | Owner | Status | Next action\n---|---|---|---|---|---\nFri | Noon | Main hall | Team | Ready | Share the notes"
        _ = try snapshot(manyColumns, width: 285, expectsHorizontalScroll: true)
        print("Passed Markdown parsing, narrow and wide reply layout, and scrolling a six-column table.")
    }

    @MainActor static func snapshot(_ source: String, width: CGFloat, expectsHorizontalScroll: Bool = false) throws -> CGFloat {
        let content = ReplyText(source: source, availableWidth: width).frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true).padding(12).background(.background)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width + 24, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        let size = host.fittingSize
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        precondition(abs(size.width - width - 24) < 1)
        func scrollsHorizontally(_ view: NSView) -> Bool {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.bounds.width > scroll.contentSize.width + 1 { return true }
            return view.subviews.contains(where: scrollsHorizontally)
        }
        precondition(scrollsHorizontally(host) == expectsHorizontalScroll, "Unexpected scroll layout for \(width) points")
        if expectsHorizontalScroll {
            func checkVerticalBounds(_ view: NSView) {
                if let reply = view as? ReplySelectionView, let layout = reply.layoutManager, let container = reply.textContainer,
                   let scroll = reply.enclosingScrollView, let document = scroll.documentView {
                    layout.ensureLayout(for: container)
                    let rect = reply.convert(layout.usedRect(for: container), to: document)
                    precondition(rect.minY >= -1 && rect.maxY <= document.bounds.height + 1,
                                 "A table cell would be clipped vertically")
                }
                view.subviews.forEach(checkVerticalBounds)
            }
            checkVerticalBounds(host)
        }
        if let output = CommandLine.arguments.dropFirst().first {
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = URL(fileURLWithPath: output).appendingPathComponent("reply-\(Int(width)).png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        }
        return size.height
    }
}
