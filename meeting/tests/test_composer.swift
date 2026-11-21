import AppKit
import SwiftUI

@main
struct ComposerTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let store = MeetingStore()
        store.connected = true
        store.selected = UUID().uuidString.lowercased()
        let panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                              styleMask: [.resizable, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.meetingStore = store
        let board = NSPasteboard.withUniqueName()
        panel.clipboard = board
        defer { board.releaseGlobally() }

        func keyDown(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                             timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                             characters: key, charactersIgnoringModifiers: key,
                             isARepeat: false, keyCode: key == "v" ? 9 : 8)!
        }
        func press(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            panel.performKeyEquivalent(with: keyDown(key, modifiers))
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        board.setData(bitmap.representation(using: .png, properties: [:])!, forType: .png)
        precondition(press("v", .control) && store.images.count == 1)
        precondition(press("v", .command) && store.images.count == 2)
        precondition(store.hasDraft && store.canSend)
        board.clearContents()
        board.setString("paste\ntext", forType: .string)
        precondition(press("v", .control) && store.draft == "paste\ntext")
        store.activity = "working"
        store.ask()
        precondition(store.queued && store.canStop && store.activityLabel == "Message queued")
        precondition(press("c", .control) && !store.queued && store.images.count == 2 && store.hasDraft)
        print("Passed screenshot and text paste, image-only draft, and Ctrl+C cancelling queued input.")

        store.activity = "ready"
        let source = "## Notes\nFirst **review** today.\n```text\nAlpha section\n  Beta section\n```\nThen discuss."
        store.messages = [ChatLine(id: "demo", role: "assistant", images: nil, text: source)]
        let host = NSHostingView(rootView: MeetingView(store: store, hide: {}))
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(NSSize(width: 460, height: 550))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        func reply(in view: NSView) -> ReplySelectionView? {
            if let found = view as? ReplySelectionView { return found }
            return view.subviews.lazy.compactMap { reply(in: $0) }.first
        }
        guard let view = reply(in: host), let layout = view.layoutManager, let container = view.textContainer
        else { fatalError("Missing selectable text in the conversation") }
        precondition(!view.isEditable && view.isSelectable)
        let expected = "review today.\nAlpha section\n  Beta"
        let selected = (view.string as NSString).range(of: expected)
        precondition(selected.location != NSNotFound)
        func position(_ character: Int) -> NSPoint {
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: character)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return view.convert(NSPoint(x: rect.minX + 0.2, y: rect.midY), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, at character: Int, number: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: position(character), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                               context: nil, eventNumber: number, clickCount: 1, pressure: 1)!
        }
        let start = mouse(.leftMouseDown, at: selected.location, number: 1)
        let end = NSMaxRange(selected)
        NSApp.postEvent(mouse(.leftMouseUp, at: end, number: 3), atStart: true)
        NSApp.postEvent(mouse(.leftMouseDragged, at: end, number: 2), atStart: true)
        panel.sendEvent(start)
        precondition(panel.firstResponder === view && view.selectedRange() == selected,
                     "Expected drag to select across prose and two code lines; got \(view.selectedRange()), responder \(String(describing: panel.firstResponder.map { type(of: $0) })), key \(panel.isKeyWindow)")
        view.display(ReplyBlock.parse(source))
        precondition(view.selectedRange() == selected)
        panel.sendEvent(keyDown("c", .command))
        precondition(board.string(forType: .string) == expected)
        precondition(store.activity == "ready" && store.draft == "paste\ntext")
        print("Passed dragging a partial multiline selection and copying it with Command-C from the meeting panel.")
    }
}
