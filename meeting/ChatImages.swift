import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ChatImage: Identifiable {
    let id = UUID().uuidString.lowercased()
    let png: Data
    let preview: NSImage

    private init(source: CGImageSource) throws {
        var edge = 2400
        while edge >= 300 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let bytes = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { break }
            if bytes.count <= 4 * 1024 * 1024 {
                png = bytes
                preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                return
            }
            edge = edge * 3 / 4
        }
        throw ImageError.unreadable
    }

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageError.unreadable }
        try self.init(source: source)
    }

    init(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ImageError.unreadable }
        try self.init(source: source)
    }

    static func fromPasteboard(_ board: NSPasteboard) throws -> [ChatImage] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let files = (board.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
        }
        if !files.isEmpty { return try files.prefix(5).map(ChatImage.init(url:)) }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = board.data(forType: type) { return [try ChatImage(data: data)] }
        }
        return []
    }

    func save(for session: String) throws {
        guard UUID(uuidString: session) != nil else { throw ImageError.session }
        let base = ProcessInfo.processInfo.environment["CLICKY_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/clicky-meeting")
        let folder = base.appendingPathComponent("attachments").appendingPathComponent(session)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(id + ".png")
        try png.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    enum ImageError: LocalizedError {
        case unreadable, session
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn’t read that image. Try a PNG or JPEG."
            case .session: return "Choose a paired conversation before attaching images."
            }
        }
    }
}
