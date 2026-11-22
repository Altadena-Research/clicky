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
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: project) }
        let base = project.appendingPathComponent(".clicky-attachments")
        let session = store.selected!
        let folder = base.appendingPathComponent(session)
        let image = store.images[0]
        let file = folder.appendingPathComponent(image.id + ".png")
        try image.save(for: session, in: folder.path)
        try image.save(for: session, in: folder.path)
        let saved = try Data(contentsOf: file)
        let ignore = try String(contentsOf: base.appendingPathComponent(".gitignore"), encoding: .utf8)
        precondition(saved == image.png && ignore == "*\n")
        for (url, expected) in [(folder, 0o700), (base, 0o700), (file, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == expected)
        }
        let otherSession = UUID().uuidString.lowercased()
        let redirected = base.appendingPathComponent(otherSession)
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: project)
        do {
            try image.save(for: otherSession, in: redirected.path)
            fatalError("Attachment followed a redirected session folder")
        } catch ChatImage.ImageError.folder { }
        print("Passed project attachment storage, private permissions, Git exclusion and redirected-folder rejection.")
        board.clearContents()
        board.setString("paste\ntext", forType: .string)
        precondition(press("v", .control) && store.draft == "paste\ntext")
        store.activity = "working"
        store.ask()
        precondition(store.waiting.count == 1 && store.canStop && !store.hasDraft && store.activityLabel == "Claude is working…")
        precondition(press("c", .control) && store.waiting.isEmpty && store.images.count == 2 && store.hasDraft)
        print("Passed screenshot and text paste, image-only draft, and Ctrl+C cancelling queued input.")

        try testQueue(image: image, project: project)

        store.activity = "ready"
        let source = "## Notes\nFirst **review** today.\n```text\nAlpha section\n  Beta section\n```\nThen discuss."
        let older = ChatLine(id: "older", role: "user", images: [file.path],
                             text: "Earlier [update](https://example.test/notes).")
        let first = ChatLine(id: "demo", role: "assistant", images: nil, text: source)
        let second = ChatLine(id: "question", role: "user", images: nil, text: "Which group owns the review?")
        let third = ChatLine(id: "followup", role: "assistant", images: nil, text: "The design group owns it.")
        store.messages = [older, first, second, third]
        let host = NSHostingView(rootView: MeetingView(store: store, hide: {}))
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(NSSize(width: 460, height: 630))
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
        let shown = view.string as NSString
        let thumbnail = shown.range(of: "\u{fffc}")
        let link = shown.range(of: "update")
        precondition(thumbnail.location != NSNotFound && link.location != NSNotFound)
        precondition(view.textStorage?.attribute(.attachment, at: thumbnail.location, effectiveRange: nil) is NSTextAttachment)
        precondition(view.textStorage?.attribute(.link, at: link.location, effectiveRange: nil) != nil)
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
        func dragAndCopy(_ text: String, backwards: Bool = false, reverseMidDrag: Bool = false) {
            let range = (view.string as NSString).range(of: text)
            precondition(range.location != NSNotFound, "Missing expected rendered transcript text")
            let start = backwards ? NSMaxRange(range) : range.location
            let end = backwards ? range.location : NSMaxRange(range)
            // Post in reverse order so AppKit's tracking loop consumes the drag before the mouse-up.
            NSApp.postEvent(mouse(.leftMouseUp, at: end, number: 5), atStart: true)
            NSApp.postEvent(mouse(.leftMouseDragged, at: end, number: 4), atStart: true)
            if reverseMidDrag {
                NSApp.postEvent(mouse(.leftMouseDragged, at: start - 3, number: 3), atStart: true)
                NSApp.postEvent(mouse(.leftMouseDragged, at: end, number: 2), atStart: true)
            }
            panel.sendEvent(mouse(.leftMouseDown, at: start, number: 1))
            precondition(panel.firstResponder === view && view.selectedRange() == range,
                         "Expected drag to select \(range), got \(view.selectedRange())")
            panel.sendEvent(keyDown("c", .command))
            precondition(board.string(forType: .string) == text, "Copied text differs from highlight")
        }
        dragAndCopy("review today.\nAlpha section\n  Beta")
        let acrossReplies = "discuss.\nYou\nWhich group owns the review?\nClaude\nThe design"
        dragAndCopy(acrossReplies, reverseMidDrag: true)
        dragAndCopy(acrossReplies, backwards: true)
        let previousRange = view.selectedRange()
        func waitForUpdate(_ marker: String) {
            let timeout = Date().addingTimeInterval(2)
            while !view.string.contains(marker), Date() < timeout {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                host.layoutSubtreeIfNeeded()
            }
            precondition(view.string.contains(marker))
        }
        let appended = ChatLine(id: "new", role: "assistant", images: nil, text: "A new reply.")
        store.messages.append(appended)
        waitForUpdate("A new reply.")
        precondition(view.selectedRange() == previousRange)
        store.messages = [first, second, third, appended, ChatLine(id: "last", role: "user", images: nil, text: "Last question.")]
        waitForUpdate("Last question.")
        precondition(view.selectedRange().location < previousRange.location)
        panel.sendEvent(keyDown("c", .command))
        precondition(board.string(forType: .string) == acrossReplies)
        precondition(store.activity == "ready" && store.draft == "paste\ntext")
        print("Passed cross-reply dragging down, up, and back across the anchor, Cmd+C, and selection during a transcript refresh.")

        func workItem(_ kind: String, _ status: String) -> MeetingWorkItem {
            MeetingWorkItem(id: kind, reference: kind, kind: kind, title: "Fixture", status: status,
                            updated: nil, detail: nil, thread: nil)
        }
        store.activityItems = [workItem("terminal", "running"), workItem("listener", "listening"),
                               workItem("codexJob", "running"), workItem("claudeAgent", "running"),
                               workItem("codexAgent", "idle"), workItem("shell", "queued")]
        precondition(store.backgroundCount == 2)
        func buttonClick(at point: NSPoint) {
            func click(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(click(.leftMouseUp), atStart: true)
            panel.sendEvent(click(.leftMouseDown))
            if let release = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                panel.sendEvent(release)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let transcriptScroll = view.enclosingScrollView!
        let transcriptTop = transcriptScroll.convert(transcriptScroll.bounds, to: nil).maxY
        buttonClick(at: NSPoint(x: panel.contentLayoutRect.maxX - 45, y: transcriptTop + 32))
        precondition(store.showingActivity, "The activity button should open the drawer")
        func setWidth(_ width: CGFloat) -> CGFloat {
            panel.setContentSize(NSSize(width: width, height: 600))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            return view.enclosingScrollView!.bounds.width
        }
        let beside = setWidth(780)
        precondition(beside > 350 && beside < 600, "Inspector should sit beside wide chat: \(beside)")
        let compact = setWidth(380)
        precondition(compact < 2, "Inspector should take the compact transcript area: \(compact)")
        let top = transcriptScroll.convert(transcriptScroll.bounds, to: nil).maxY
        buttonClick(at: NSPoint(x: panel.contentLayoutRect.maxX - 46, y: top + 32))
        precondition(!store.showingActivity)
        precondition(setWidth(380) > 260 && store.draft == "paste\ntext")
        print("Passed working count and wide and compact activity drawers, with the composer draft preserved.")

        store.activity = "working"
        store.images = []
        for text in ["Keep this first", "Remove this second", "Keep this third"] {
            store.draft = text
            store.ask()
        }
        store.draft = "I can keep typing"
        panel.setContentSize(MeetingPanelSize.minimum)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let collapsedHeight = transcriptScroll.bounds.height
        buttonClick(at: NSPoint(x: 46, y: 62))
        precondition(transcriptScroll.bounds.height < collapsedHeight - 55)
        buttonClick(at: NSPoint(x: panel.contentLayoutRect.maxX - 27, y: 85))
        precondition(store.waiting.map(\.text) == ["Keep this first", "Keep this third"])
        precondition(store.draft == "I can keep typing")
        buttonClick(at: NSPoint(x: panel.contentLayoutRect.maxX - 29, y: 27))
        precondition(store.draft.isEmpty && store.waiting.last?.text == "I can keep typing")
        print("Passed compact queue disclosure, removal of a middle row, and submission from the still-active composer.")
    }

    @MainActor static func testQueue(image: ChatImage, project: URL) throws {
        var writes: [[String: Any]] = []
        let store = MeetingStore { writes.append($0) }
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased()
        func event(_ values: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: values)
            line.append(10)
            store.receive(line)
        }
        func view(_ session: String, _ activity: String, connected: Bool = true) throws {
            try event(["type": "view", "sessions": [a, b], "selected": session, "connected": connected,
                       "attachmentFolder": project.appendingPathComponent(".clicky-attachments/" + session).path,
                       "activity": activity])
        }
        func reply(_ type: String, to request: [String: Any]) throws {
            try event(["type": type, "session": request["session"]!, "requestID": request["requestID"]!,
                       "message": "Check delivery before retrying."])
        }
        func submit(_ text: String) {
            store.draft = text
            precondition(store.canSend)
            store.ask()
            precondition(!store.hasDraft)
        }
        try view(a, "working")
        submit("First")
        submit("Remove me")
        store.attach([image])
        submit("")
        submit("Third")
        precondition(writes.isEmpty && store.waiting.count == 4)
        store.removeQueued(store.waiting[1].id)
        store.draft = "Unfinished"
        try view(b, "ready")
        precondition(writes.isEmpty && store.waiting.isEmpty && !store.hasDraft)
        try view(a, "ready")
        precondition(writes.count == 1 && store.draft == "Unfinished")
        precondition(writes[0]["question"] as? String == "First")
        precondition(store.waiting.map(\.preview) == ["Image", "Third"])
        submit("Fourth")
        store.ask() // Repeated Return on an empty composer.
        try view(a, "ready") // An update already in the pipe before the acknowledgment.
        precondition(writes.count == 1)
        try reply("sent", to: writes[0])
        try reply("sent", to: writes[0])
        submit("Fifth")
        try view(a, "sent")
        try view(a, "attention")
        try view(a, "stopping")
        precondition(writes.count == 1)
        try view(a, "ready")
        precondition(writes.count == 2 && writes[1]["images"] as? [String] == [image.id])
        precondition(FileManager.default.fileExists(atPath:
            project.appendingPathComponent(".clicky-attachments/" + a + "/" + image.id + ".png").path))
        try reply("deferred", to: writes[1])
        precondition(store.waiting.map(\.preview) == ["Image", "Third", "Fourth", "Fifth"])
        try view(a, "working")
        try view(a, "ready")
        precondition(writes.count == 3 && writes[1]["requestID"] as? String == writes[2]["requestID"] as? String)
        try view(b, "ready")
        submit("Other session")
        try reply("sent", to: writes[2])
        precondition(writes.count == 4 && writes[3]["session"] as? String == b && store.activityLabel == "Sending…")
        try reply("sent", to: writes[3])
        try view(a, "unknown", connected: false)
        try view(a, "ready")
        precondition(writes.count == 4 && store.queueProblem != nil)
        store.resumeQueue()
        precondition(writes.count == 5 && writes.last?["question"] as? String == "Third")
        try reply("error", to: writes[4])
        try view(a, "ready")
        store.draft = "Still editing"
        store.interruptFromKeyboard()
        precondition(store.draft == "Still editing" && store.waiting.count == 3 && writes.count == 5)
        store.removeQueued(store.waiting[0].id)
        store.resumeQueue()
        precondition(writes.count == 6 && writes[5]["question"] as? String == "Fourth")
        try reply("sent", to: writes[5])
        try view(a, "working")
        try event(["type": "error", "session": a, "pauseQueue": true, "message": "Acknowledgment timed out."])
        try view(a, "ready")
        precondition(store.waiting.map(\.text) == ["Fifth"] && store.queueProblem != nil && writes.count == 6)
        store.resumeQueue()
        precondition(writes.count == 7 && writes[6]["question"] as? String == "Fifth")
        try reply("sent", to: writes[6])
        try view(a, "ready")
        precondition(store.waiting.isEmpty && store.draft == "Still editing" && writes.count == 7)
        print("Passed FIFO delivery, rapid Return, image ownership, per-item cancellation, session switching and recovery.")
    }
}
