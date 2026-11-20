import AppKit
import SwiftUI

struct ChatLine: Decodable, Identifiable {
    let id: String
    let role: String
    let text: String
}

struct Invitation: Decodable, Equatable {
    let id: String
    let title: String
    let status: String
    let choices: [String: String]
}

private struct BridgeEvent: Decodable {
    let type: String
    let sessions: [String]?
    let labels: [String: String]?
    let selected: String?
    let session: String?
    let connected: Bool?
    let messages: [ChatLine]?
    let invitation: Invitation?
    let project: String?
    let detectionError: String?
    let message: String?
}

@MainActor
final class MeetingStore: ObservableObject {
    @Published var sessions: [String] = []
    @Published var labels: [String: String] = [:]
    @Published var selected: String?
    @Published var connected = false
    @Published var messages: [ChatLine] = []
    @Published var draft = ""
    @Published var sending = false
    @Published var error: String?
    @Published var invitation: Invitation?
    @Published var project = ""
    @Published var detectionError: String?
    var invitationChanged: (() -> Void)?
    var opened: (() -> Void)?
    var receivedSuggestion: ((String) -> Void)?
    private var process: Process?
    private let input = Pipe()
    private let output = Pipe()
    private var received = Data()
    private var requestedSelection: String?
    private var previousAssistant: String?
    private var loadedSelection: String?
    private var submitted = ""

    func start() {
        guard let bridge = Bundle.main.url(forResource: "bridge", withExtension: "py") else {
            error = "The meeting helper is missing from the app."
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-B", "-u", bridge.path, "ui"]
        child.standardInput = input
        child.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receive(bytes) }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.connected = false
                self?.sending = false
                self?.error = "The local helper exited. Reopen Clicky Meeting to reconnect."
            }
        }
        do {
            try child.run()
            process = child
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
    }

    func label(_ session: String) -> String {
        let name = labels[session] ?? ""
        return (name.isEmpty ? "Claude session" : name) + " · " + session.prefix(8)
    }

    func select(_ session: String) {
        requestedSelection = session
        error = nil
        write(["op": "select", "session": session])
    }

    func respond(_ op: String, session: String? = nil) {
        guard let invitation else { return }
        var request = ["op": op, "meeting": invitation.id]
        request["session"] = session
        error = nil
        write(request)
    }

    func chooseProject() {
        let chooser = NSOpenPanel()
        chooser.canChooseFiles = false
        chooser.canChooseDirectories = true
        chooser.prompt = "Use this folder"
        chooser.directoryURL = URL(fileURLWithPath: project)
        NSApp.activate(ignoringOtherApps: true)
        if chooser.runModal() == .OK, let path = chooser.url?.path {
            write(["op": "project", "path": path])
        }
    }

    func ask() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selected, connected, !sending, !question.isEmpty else { return }
        guard question.count <= 4000 else { error = "Keep the question under 4,001 characters."; return }
        sending = true
        submitted = draft
        error = nil
        write(["op": "ask", "session": selected, "question": question])
    }

    private func write(_ request: [String: String]) {
        do {
            guard process?.isRunning == true else { throw CocoaError(.fileWriteUnknown) }
            var bytes = try JSONEncoder().encode(request)
            bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes)
        } catch {
            self.error = "Couldn’t reach the local meeting helper."
            sending = false
        }
    }

    private func receive(_ bytes: Data) {
        received.append(bytes)
        while let end = received.firstIndex(of: 10) {
            let line = received[..<end]
            let event = try? JSONDecoder().decode(BridgeEvent.self, from: line)
            received.removeSubrange(...end)
            guard let event else { continue }
            if event.type == "error" {
                error = event.message
                sending = false
            } else if event.type == "opened" {
                error = nil
                opened?()
            } else if event.type == "sent" {
                if draft == submitted && selected == event.session { draft = "" }
                sending = false
            } else if event.type == "view" {
                project = event.project ?? ""
                detectionError = event.detectionError
                let changed = invitation != event.invitation
                invitation = event.invitation
                if changed { error = nil; invitationChanged?() }
                sessions = event.sessions ?? []
                labels = event.labels ?? [:]
                selected = event.selected
                connected = event.connected == true
                messages = event.messages ?? []
                let assistant = messages.last { $0.role == "assistant" }
                if let assistant, let selected, loadedSelection == selected,
                   assistant.id != previousAssistant, connected {
                    receivedSuggestion?(assistant.text)
                }
                previousAssistant = assistant?.id
                loadedSelection = selected
                if selected == nil, sessions.count == 1, requestedSelection != sessions[0] {
                    select(sessions[0])
                }
            }
        }
    }
}

struct ReplyText: View {
    let source: String

    var body: some View {
        // Text's default Markdown mode only interprets inline spans.
        // Render meeting-note blocks separately to retain headings, lists and code.
        let lines = source.components(separatedBy: .newlines)
        var inCode = false
        let blocks = lines.map { line -> (String, String) in
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("```") { inCode.toggle(); return ("fence", "") }
            if inCode { return ("code", line) }
            let prefix = text.prefix { $0 == "#" }
            if (1...6).contains(prefix.count), text.dropFirst(prefix.count).first == " " {
                return ("heading", String(text.dropFirst(prefix.count + 1)))
            }
            if text.hasPrefix("- ") || text.hasPrefix("* ") { return ("body", "•  " + text.dropFirst(2)) }
            return ("body", line)
        }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(blocks.indices, id: \.self) { index in
                let block = blocks[index]
                if block.0 == "code" {
                    Text(verbatim: block.1).font(.system(.caption, design: .monospaced))
                } else if block.0 != "fence" {
                    let formatted = try? AttributedString(markdown: block.1, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                    Text(formatted ?? AttributedString(block.1))
                        .font(block.0 == "heading" ? .headline : .body)
                }
            }
        }.textSelection(.enabled)
    }
}

struct InvitationView: View {
    @ObservedObject var store: MeetingStore
    var body: some View {
        if let invite = store.invitation {
            VStack(alignment: .leading, spacing: 5) {
                Text(invite.status == "opening" ? "Connecting to Claude…" : "Open a Claude chat for this meeting?")
                    .font(.headline)
                Text(invite.title).lineLimit(1).truncationMode(.tail)
                if invite.status == "opening" {
                    Text("Check your Claude terminal for any permission prompts.").font(.caption)
                } else {
                    if invite.status == "retry" {
                        Text("Still waiting. Check Claude or run /clicky-meeting in the meeting chat.").font(.caption)
                    } else if invite.choices.isEmpty {
                        Text("New chats open in " + URL(fileURLWithPath: store.project).lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if invite.choices.isEmpty {
                            Button(invite.status == "retry" ? "Retry" : "Open") { store.respond("open") }
                                .buttonStyle(.borderedProminent).onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                        } else {
                            Menu("Choose conversation") {
                                ForEach(invite.choices.keys.sorted(), id: \.self) { session in
                                    Button((invite.choices[session] ?? "") + " · " + session.prefix(8)) {
                                        store.respond("open", session: session)
                                    }
                                }
                            }.onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                        }
                        Button("Not now") { store.respond("dismiss") }
                            .onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
                    }
                }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MeetingView: View {
    @ObservedObject var store: MeetingStore
    let hide: () -> Void
    @FocusState private var typing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(Color.accentColor)
                Text("Meeting").font(.title2.bold())
                Spacer()
                if store.sessions.count > 1 || (!store.sessions.isEmpty && !store.connected) {
                    Menu("Sessions") {
                        ForEach(store.sessions, id: \.self) { id in
                            Button(store.label(id)) { store.select(id) }
                        }
                    }.fixedSize()
                }
                Button(action: hide) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("Collapse").accessibilityLabel("Collapse")
            }
            if store.invitation != nil { InvitationView(store: store) }
            if let selected = store.selected {
                Label(store.connected ? store.label(selected) : "Session disconnected",
                      systemImage: store.connected ? "link" : "link.badge.plus")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    if store.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.connected ? "Ready for your question" : "Connect your meeting").font(.headline)
                            Text(store.connected ? "Replies from this Claude conversation appear here." :
                                store.detectionError ?? "Start a Wispr Notetaker recording. Clicky will offer to open its Claude conversation.")
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(store.messages) { message in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.role == "assistant" ? "Claude" : "You")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    ReplyText(source: message.text)
                                }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.onChange(of: store.messages.last?.id) { _, _ in reader.scrollTo("bottom") }
                .onAppear { reader.scrollTo("bottom") }
            }
            if let error = store.error, store.invitation == nil { Text(error).foregroundStyle(.red).font(.caption) }
            Divider()
            HStack {
                TextField("Ask about this meeting…", text: $store.draft)
                    .textFieldStyle(.plain).focused($typing).onSubmit { store.ask() }
                    .disabled(!store.connected)
                Button(action: { store.ask() }) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Send question")
                    .disabled(!store.connected || store.sending || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial).onAppear { typing = true }
    }
}

private class ChatPanel: NSPanel {
    var didCollapse: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil); didCollapse?() }
}

private final class CharacterHitArea: NSView {
    var clicked: (() -> Void)?
    var moved: (() -> Void)?
    private var start = NSPoint.zero
    private var original = NSPoint.zero
    private var dragging = false
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Open meeting companion" }
    override func accessibilityPerformPress() -> Bool { clicked?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        original = window?.frame.origin ?? .zero
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        let delta = NSPoint(x: point.x-start.x, y: point.y-start.y)
        if hypot(delta.x, delta.y) > 3 { dragging = true }
        if dragging {
            window?.setFrameOrigin(NSPoint(x: original.x+delta.x, y: original.y+delta.y))
            moved?()
        }
    }
    override func mouseUp(with event: NSEvent) { if !dragging { clicked?() } }
}

private struct CharacterView: View {
    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            Triangle().fill(Color(red: 0.19, green: 0.58, blue: 1))
                .rotationEffect(.degrees(39)).frame(width: 26, height: 26)
                .shadow(color: .blue.opacity(0.42), radius: 5)
            HStack(spacing: 3) {
                Capsule().frame(width: 2.5, height: 4)
                Capsule().frame(width: 2.5, height: 4)
            }.foregroundStyle(.white).offset(x: 1, y: -1)
        }.padding(2)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = MeetingStore()
    private var character: NSPanel!
    private var chat: ChatPanel!
    private var bubble: NSPanel!
    private var invitePanel: NSPanel!
    private var menuItem: NSStatusItem!
    private var dismissBubble: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        character = panel(size: NSSize(width: 48, height: 48))
        let view = NSHostingView(rootView: CharacterView())
        character.contentView = view
        let hit = CharacterHitArea(frame: view.bounds)
        hit.autoresizingMask = [.width, .height]
        hit.toolTip = "Click for your meeting. Drag to move."
        hit.clicked = { [weak self] in self?.toggleChat() }
        hit.moved = { [weak self] in self?.placePanels() }
        view.addSubview(hit)
        let area = NSScreen.main?.visibleFrame ?? .zero
        character.title = "Clicky character"
        character.setFrameOrigin(NSPoint(x: area.maxX - 76, y: area.midY))
        character.setFrameAutosaveName("MeetingCharacter")
        let preferred = MeetingPanelSize.preferred()
        chat = panel(size: preferred, resizable: true)
        chat.minSize = MeetingPanelSize.minimum
        chat.delegate = self
        chat.didCollapse = { [weak self] in self?.updateInvitation() }
        chat.title = "Meeting conversation"
        let conversation = NSHostingView(rootView: MeetingView(store: store, hide: { [weak self] in self?.hideChat() }))
        conversation.sizingOptions = []
        chat.contentView = conversation
        chat.setContentSize(preferred)
        let grip = MeetingResizeGrip(frame: NSRect(x: preferred.width - 20, y: 0, width: 20, height: 20))
        grip.toolTip = "Drag to resize the meeting panel"
        grip.finished = { MeetingPanelSize.save($0) }
        // NSHostingView can use flipped coordinates. Keep the grip in the lower right.
        grip.translatesAutoresizingMaskIntoConstraints = false
        conversation.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.trailingAnchor.constraint(equalTo: conversation.trailingAnchor),
            grip.bottomAnchor.constraint(equalTo: conversation.bottomAnchor),
            grip.widthAnchor.constraint(equalToConstant: 20),
            grip.heightAnchor.constraint(equalToConstant: 20)
        ])
        chat.isOpaque = false
        chat.contentView?.wantsLayer = true
        chat.contentView?.layer?.cornerRadius = 14
        chat.contentView?.layer?.masksToBounds = true
        bubble = panel(size: NSSize(width: 270, height: 66))
        bubble.ignoresMouseEvents = true
        invitePanel = panel(size: NSSize(width: 296, height: 151))
        invitePanel.title = "Meeting invitation"
        invitePanel.contentView = NSHostingView(rootView: InvitationView(store: store)
            .padding(12).frame(width: 296, height: 151, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)))
        store.invitationChanged = { [weak self] in self?.updateInvitation() }
        store.opened = { [weak self] in self?.showChat() }
        store.receivedSuggestion = { [weak self] text in self?.showSuggestion(text) }
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuItem.button?.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "Clicky Meeting")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Meeting", action: #selector(showChat), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Choose Meeting Project…", action: #selector(chooseProject), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Clicky Meeting", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menuItem.menu = menu
        character.orderFrontRegardless()
        store.start()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === chat else { return }
        MeetingPanelSize.save(window.frame.size)
    }

    private func panel(size: NSSize, resizable: Bool = false) -> ChatPanel {
        let window = ChatPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: resizable ? [.resizable, .nonactivatingPanel] : [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        return window
    }

    @objc private func chooseProject() { store.chooseProject() }

    private func updateInvitation() {
        if store.invitation != nil && !chat.isVisible {
            bubble.orderOut(nil)
            placePanels()
            invitePanel.orderFrontRegardless()
        } else {
            invitePanel.orderOut(nil)
        }
    }

    private func hideChat() {
        chat.orderOut(nil)
        updateInvitation()
    }

    @objc private func showChat() {
        invitePanel.orderOut(nil)
        bubble.orderOut(nil)
        placePanels()
        chat.makeKeyAndOrderFront(nil)
    }

    private func toggleChat() { if chat.isVisible { hideChat() } else { showChat() } }

    private func placePanels() {
        guard let area = character.screen?.visibleFrame else { return }
        for window in [chat, bubble, invitePanel].compactMap({ $0 }) {
            let size = NSSize(width: min(window.frame.width, area.width), height: min(window.frame.height, area.height))
            if size != window.frame.size { window.setContentSize(size) }
            let targetX = character.frame.midX > area.midX ? character.frame.minX-size.width-6 : character.frame.maxX+6
            let point = NSPoint(x: max(area.minX, min(targetX, area.maxX-size.width)),
                                y: max(area.minY, min(character.frame.midY-size.height/2, area.maxY-size.height)))
            window.setFrameOrigin(point)
        }
    }

    private func showSuggestion(_ text: String) {
        guard !chat.isVisible, store.invitation == nil else { return }
        let preview = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        bubble.contentView = NSHostingView(rootView: Text(preview).lineLimit(3).font(.callout)
            .padding(10).frame(width: 270, height: 66, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)))
        placePanels()
        bubble.orderFrontRegardless()
        dismissBubble?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.bubble.orderOut(nil) }
        dismissBubble = work
        DispatchQueue.main.asyncAfter(deadline: .now()+9, execute: work)
    }

    func applicationWillTerminate(_ notification: Notification) { store.stop() }
}

@main
struct ClickyMeeting {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
