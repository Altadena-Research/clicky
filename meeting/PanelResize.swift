import AppKit

@MainActor
enum MeetingPanelSize {
    private static let key = "MeetingPanelSize"
    static let minimum = NSSize(width: 320, height: 340)

    static func preferred(in defaults: UserDefaults = .standard) -> NSSize {
        if let value = defaults.string(forKey: key) {
            let size = NSSizeFromString(value)
            if size.width >= minimum.width, size.height >= minimum.height { return size }
        }
        return NSSize(width: 410, height: 425)
    }

    static func save(_ size: NSSize, in defaults: UserDefaults = .standard) {
        defaults.set(NSStringFromSize(size), forKey: key)
    }
}

final class MeetingResizeGrip: NSView {
    private var original: NSRect?
    private var pointer = NSPoint.zero
    var finished: ((NSSize) -> Void)?

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let marks = NSBezierPath()
        marks.lineWidth = 1
        for length in [4, 9] {
            marks.move(to: NSPoint(x: Int(bounds.maxX) - 6 - length, y: 6))
            marks.line(to: NSPoint(x: Int(bounds.maxX) - 6, y: 6 + length))
        }
        marks.stroke()
    }

    override func resetCursorRects() {
        if #available(macOS 15.0, *) {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        original = window.frame
        pointer = window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let original, let area = window.screen?.visibleFrame else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let width = min(area.maxX - original.minX, max(window.minSize.width, original.width + point.x - pointer.x))
        let height = min(original.maxY - area.minY, max(window.minSize.height, original.height + pointer.y - point.y))
        window.setFrame(NSRect(x: original.minX, y: original.maxY - height, width: width, height: height), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        if let window, original != nil { finished?(window.frame.size) }
        original = nil
    }
}
