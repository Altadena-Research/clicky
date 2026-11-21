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

    private static func privateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ImageError.folder }
    }

    func save(for session: String, in path: String?) throws {
        guard let path, path.hasPrefix("/"), UUID(uuidString: session) != nil else { throw ImageError.session }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let base = folder.deletingLastPathComponent()
        guard folder.lastPathComponent == session, base.lastPathComponent == ".clicky-attachments" else {
            throw ImageError.session
        }
        try Self.privateDirectory(base)
        let ignore = base.appendingPathComponent(".gitignore")
        let rules = Data("*\n".utf8)
        do {
            try rules.write(to: ignore, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            var info = stat()
            guard lstat(ignore.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size == rules.count, try Data(contentsOf: ignore) == rules else { throw ImageError.folder }
        }
        try Self.privateDirectory(folder)
        let url = folder.appendingPathComponent(id + ".png")
        try png.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    enum ImageError: LocalizedError {
        case unreadable, session, folder
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn’t read that image. Try a PNG or JPEG."
            case .session: return "Couldn’t locate the paired project. Run /clicky-meeting in the meeting terminal."
            case .folder: return "Couldn’t create a private, Git-ignored attachment folder in the paired project."
            }
        }
    }
}
