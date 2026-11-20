import AppKit

@main
struct TestMeetingPanelResize {
    @MainActor static func main() {
        _ = NSApplication.shared
        let screen = NSScreen.main!.visibleFrame
        let frame = NSRect(x: screen.midX - 200, y: screen.midY - 200, width: 410, height: 425)
        let panel = NSPanel(contentRect: frame, styleMask: [.resizable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.minSize = MeetingPanelSize.minimum
        let grip = MeetingResizeGrip()
        panel.contentView!.addSubview(grip)
        let domain = "clicky-resize-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        grip.finished = { MeetingPanelSize.save($0, in: defaults) }

        func event(_ type: NSEvent.EventType, _ screenPoint: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: screenPoint),
                               modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ dx: CGFloat, _ dy: CGFloat) {
            let start = NSPoint(x: panel.frame.maxX - 8, y: panel.frame.minY + 8)
            let end = NSPoint(x: start.x + dx, y: start.y + dy)
            grip.mouseDown(with: event(.leftMouseDown, start))
            grip.mouseDragged(with: event(.leftMouseDragged, end))
            grip.mouseUp(with: event(.leftMouseUp, end))
        }
        let initial = panel.frame
        drag(50, -30)
        precondition(panel.frame.width == initial.width + 50 && panel.frame.height == initial.height + 30)
        precondition(panel.frame.minX == initial.minX && panel.frame.maxY == initial.maxY)
        let saved = UserDefaults(suiteName: domain)!
        precondition(MeetingPanelSize.preferred(in: saved) == panel.frame.size)
        drag(-500, 500)
        precondition(panel.frame.size == MeetingPanelSize.minimum)
        print("Passed native corner drag, layout bounds and saved size.")
    }
}
