import AppKit

@main
struct ComposerTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let store = MeetingStore()
        store.connected = true
        store.selected = UUID().uuidString.lowercased()
        let panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        panel.meetingStore = store
        let board = NSPasteboard.withUniqueName()
        panel.clipboard = board
        defer { board.releaseGlobally() }

        func press(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                         timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                         characters: key, charactersIgnoringModifiers: key,
                                         isARepeat: false, keyCode: key == "v" ? 9 : 8)!
            return panel.performKeyEquivalent(with: event)
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
    }
}
