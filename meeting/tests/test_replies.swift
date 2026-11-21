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
        let message = ChatLine(id: "sample", role: "assistant", images: nil, text: source)
        let content = ConversationTranscript(messages: [message])
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 88),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func transcript(in view: NSView) -> ReplySelectionView? {
            if let found = view as? ReplySelectionView { return found }
            return view.subviews.lazy.compactMap { transcript(in: $0) }.first
        }
        guard let view = transcript(in: host), let layout = view.layoutManager, let container = view.textContainer,
              let scroll = view.enclosingScrollView else { fatalError("Missing transcript") }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        precondition(used.height > 0 && used.maxY <= view.bounds.height + 1, "Transcript clipped vertically")
        let horizontal = view.bounds.width > scroll.contentSize.width + 1
        precondition(horizontal == expectsHorizontalScroll, "Unexpected scroll layout for \(width) points")
        if expectsHorizontalScroll {
            scroll.contentView.scroll(to: NSPoint(x: view.bounds.width - scroll.contentSize.width, y: 0))
            precondition(scroll.contentView.bounds.minX > 0, "Wide table cannot be scrolled horizontally")
        }
        if let output = CommandLine.arguments.dropFirst().first {
            window.setContentSize(NSSize(width: width, height: ceil(used.height) + 12))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = URL(fileURLWithPath: output).appendingPathComponent("reply-\(Int(width)).png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        }
        return used.height
    }
}
