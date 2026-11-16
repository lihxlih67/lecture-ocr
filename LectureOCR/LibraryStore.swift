import Foundation

struct OCRSettings: Codable, Equatable {
    var keepHistory = true
    var historyLimit = 300
    var archiveDirectoryPath: String?
    var modelDirectoryPath: String?
    var defaultMode = "Гибрид"
    var animationsEnabled = true

    static let defaultsKey = "lectureocr.settings.v2"

    static func load() -> OCRSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(OCRSettings.self, from: data) else {
            return OCRSettings()
        }
        return value
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

struct HistoryRecord: Identifiable, Codable {
    var id: UUID
    var sourceFilename: String
    var displayName: String
    var page: Int?
    var blocks: [OCRBlock]
    var width: Double
    var height: Double
    var previewFilename: String?
    var savedAt: Date
    var mode: String

    var pageTitle: String {
        page.map { "\(displayName) · стр. \($0 + 1)" } ?? displayName
    }

    func queueItem(in root: URL) -> QueueItem {
        QueueItem(id: id,
                  url: root.appendingPathComponent("Originals", isDirectory: true).appendingPathComponent(sourceFilename),
                  page: page, originalName: displayName, libraryFileName: sourceFilename)
    }
}

struct HistoryManifest: Codable {
    var version = 1
    var records: [HistoryRecord] = []
}

struct QueueSession: Codable {
    var version = 1
    var queue: [QueueItem] = []
    var selectedID: UUID?
    var mode: String = "Гибрид"
}

enum LibraryStore {
    static let folderName = "Lecture OCR Library"
    static let manifestName = "manifest.json"
    static let sessionName = "queue.json"

    static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lecture OCR/Library", isDirectory: true)
    }

    static func root(settings: OCRSettings) -> URL {
        settings.archiveDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultRoot()
    }

    static func defaultModelDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lecture OCR/PaddleX/official_models", isDirectory: true)
    }

    static func modelDirectory(settings: OCRSettings) -> URL {
        settings.modelDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultModelDirectory()
    }

    static func ensureDirectories(at root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Originals", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Previews", isDirectory: true), withIntermediateDirectories: true)
    }

    static func archiveOriginal(_ source: URL, at root: URL) throws -> String {
        try ensureDirectories(at: root)
        let ext = source.pathExtension.isEmpty ? "image" : source.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        let destination = root.appendingPathComponent("Originals", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        return name
    }

    static func storePreview(_ source: URL, pageID: UUID, at root: URL) throws -> String {
        try ensureDirectories(at: root)
        let name = "\(pageID.uuidString).png"
        let destination = root.appendingPathComponent("Previews", isDirectory: true).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
        return name
    }

    static func readManifest(at root: URL) -> HistoryManifest {
        let url = root.appendingPathComponent(manifestName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let manifest = try? decoder.decode(HistoryManifest.self, from: data) else {
            return HistoryManifest()
        }
        return manifest
    }

    static func writeManifest(_ manifest: HistoryManifest, at root: URL) throws {
        try ensureDirectories(at: root)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: root.appendingPathComponent(manifestName), options: .atomic)
    }

    static func readSession(at root: URL) -> QueueSession? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(sessionName)) else { return nil }
        return try? JSONDecoder().decode(QueueSession.self, from: data)
    }

    static func writeSession(_ session: QueueSession, at root: URL) throws {
        try ensureDirectories(at: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: root.appendingPathComponent(sessionName), options: .atomic)
    }

    static func mergeDirectory(_ source: URL, into destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: source.path) else { return }
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if fm.fileExists(atPath: target.path) {
                let targetIsDirectory = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory && targetIsDirectory { try mergeDirectory(item, into: target) }
            } else {
                try fm.copyItem(at: item, to: target)
            }
        }
    }
}
