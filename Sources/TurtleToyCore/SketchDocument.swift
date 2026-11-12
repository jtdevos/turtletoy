import Foundation

// MARK: - Document identity

/// Identity and saved baseline of whatever is in the editor.
///
/// The editor text itself lives in the view model; this only records where it
/// came from and what it looked like when it was last loaded or saved, which is
/// enough to derive the window title, the unsaved-changes flag and file names.
public struct SketchDocumentState: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        /// A built-in gallery preset that has not been saved to a file.
        case preset(id: String, title: String)
        /// A new sketch that has never been saved.
        case untitled
        /// A sketch file on disk.
        case file(URL)
    }

    public static let fileExtension = "turtle"
    public static let untitledName = "Untitled"

    public var origin: Origin
    /// The text as last loaded or saved. The buffer is dirty when it differs.
    public var savedText: String

    public init(origin: Origin, savedText: String) {
        self.origin = origin
        self.savedText = savedText
    }

    public static func preset(_ preset: PresetProgram) -> SketchDocumentState {
        SketchDocumentState(origin: .preset(id: preset.id, title: preset.title), savedText: preset.code)
    }

    public static func untitled(savedText: String = "") -> SketchDocumentState {
        SketchDocumentState(origin: .untitled, savedText: savedText)
    }

    public static func file(_ url: URL, savedText: String) -> SketchDocumentState {
        SketchDocumentState(origin: .file(url), savedText: savedText)
    }

    public var fileURL: URL? {
        if case .file(let url) = origin { return url }
        return nil
    }

    public var presetID: String? {
        if case .preset(let id, _) = origin { return id }
        return nil
    }

    public var isPreset: Bool { presetID != nil }

    /// Name shown in the window title.
    public var displayName: String {
        switch origin {
        case .preset(_, let title): return title
        case .untitled: return Self.untitledName
        case .file(let url): return url.lastPathComponent
        }
    }

    public func isDirty(_ text: String) -> Bool {
        text != savedText
    }

    public func windowTitle(for text: String) -> String {
        isDirty(text) ? "\(displayName) — Edited" : displayName
    }

    /// Default file name offered by the Save panel.
    public var suggestedSaveFilename: String {
        switch origin {
        case .preset(_, let title):
            return "\(Self.slug(title)).\(Self.fileExtension)"
        case .untitled:
            return "\(Self.untitledName).\(Self.fileExtension)"
        case .file(let url):
            return url.lastPathComponent
        }
    }

    /// Base name (no extension) for artwork exported from this document.
    public var exportBaseName: String {
        switch origin {
        case .preset(_, let title):
            return Self.slug(title)
        case .untitled:
            return Self.untitledName.lowercased()
        case .file(let url):
            let stem = url.deletingPathExtension().lastPathComponent
            return stem.isEmpty ? Self.untitledName.lowercased() : stem
        }
    }

    /// "Cyber Lotus Mandala" -> "cyber_lotus_mandala" (matches the historical PNG export naming).
    static func slug(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "_")
    }
}

// MARK: - Sketch files

public enum SketchFileError: LocalizedError, Equatable {
    case notUTF8(String)

    public var errorDescription: String? {
        switch self {
        case .notUTF8(let name):
            return "“\(name)” is not a UTF-8 text file, so it can't be opened as a sketch."
        }
    }
}

/// Plain-text UTF-8 `.turtle` sketch files. The file is just the source text.
public enum SketchFile {
    public static func read(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard var text = String(data: data, encoding: .utf8) else {
            throw SketchFileError.notUTF8(url.lastPathComponent)
        }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text
    }

    public static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Appends `.turtle` when the URL has no extension at all.
    public static func normalizedSaveURL(_ url: URL) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension(SketchDocumentState.fileExtension) : url
    }
}

// MARK: - Session restore

/// What is persisted between launches: the buffer text and where it came from.
public struct SketchSession: Codable, Equatable, Sendable {
    public var text: String
    public var filePath: String?
    public var presetID: String?

    public init(text: String, filePath: String? = nil, presetID: String? = nil) {
        self.text = text
        self.filePath = filePath
        self.presetID = presetID
    }

    public init(text: String, document: SketchDocumentState) {
        self.init(text: text, filePath: document.fileURL?.path, presetID: document.presetID)
    }

    /// Launch flags that drive headless rendering / screenshots. They expect a
    /// pristine first preset, so the session is neither restored nor written.
    public static let headlessLaunchFlags: Set<String> = [
        "--render-showcase",
        "--render-crawl-frames",
        "--capture-ide-screenshot",
        "--render-ide-frames",
        "--screencapture-window",
        "--screencapture-frames",
        "--auto-crawl"
    ]

    public static func isSessionEnabled(arguments: [String]) -> Bool {
        !arguments.contains(where: headlessLaunchFlags.contains)
    }

    public struct Restored: Equatable, Sendable {
        public var text: String
        public var document: SketchDocumentState
        /// Set when the session was based on a gallery preset.
        public var preset: PresetProgram?
    }

    /// Rebuilds the document identity for a stored session.
    ///
    /// - A file that can still be read becomes the baseline, so edits that were
    ///   never saved show up as unsaved changes again.
    /// - A file that has gone missing degrades to an untitled buffer that keeps the text.
    public func restore(
        presets: [PresetProgram] = PresetGallery.all,
        readFile: (URL) -> String? = { try? SketchFile.read(from: $0) }
    ) -> Restored {
        if let filePath {
            let url = URL(fileURLWithPath: filePath)
            if let onDisk = readFile(url) {
                return Restored(text: text, document: .file(url, savedText: onDisk), preset: nil)
            }
            return Restored(text: text, document: .untitled(), preset: nil)
        }
        if let presetID, let preset = presets.first(where: { $0.id == presetID }) {
            return Restored(text: text, document: .preset(preset), preset: preset)
        }
        return Restored(text: text, document: .untitled(), preset: nil)
    }
}

/// Stores the last session in `UserDefaults` as a small JSON blob.
public struct SketchSessionStore {
    public static let defaultKey = "TurtleToy.lastSession.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = SketchSessionStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> SketchSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SketchSession.self, from: data)
    }

    public func save(_ session: SketchSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
