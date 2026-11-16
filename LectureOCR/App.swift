import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct QueueItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var page: Int? = nil
    var originalName: String? = nil
    var libraryFileName: String? = nil
    var displayName: String {
        let name = originalName ?? url.lastPathComponent
        return page.map { "\(name) · стр. \($0 + 1)" } ?? name
    }
}

struct OCRBlock: Identifiable, Codable, Hashable {
    var id: String
    var kind: String
    var text: String
    var bbox: [Double]?
}

enum OCRMode: String, CaseIterable, Identifiable {
    case vl = "PaddleOCR‑VL 1.6"
    case structure = "PP‑StructureV3"
    case hybrid = "Гибрид"
    var id: String { rawValue }
    var help: String {
        switch self {
        case .vl: return "Модель разбирает документ и возвращает структурированный текст."
        case .structure: return "Классический OCR и модель структуры документа."
        case .hybrid: return "Печатный OCR плюс отдельная проверка подозрительных рукописных строк."
        }
    }
}

@MainActor
final class OCRModel: ObservableObject {
    @Published var queue: [QueueItem] = [] { didSet { persistSession() } }
    @Published var selectedID: UUID? { didSet { hoveredBlockID = nil; persistSession() } }
    @Published var progress = 0.0
    @Published var status = "Добавьте фотографии лекций или PDF"
    @Published var isRunning = false
    @Published var isMovingArchive = false
    @Published var errorMessage: String?
    @Published var mode: OCRMode = .hybrid {
        didSet {
            if !isRestoring {
                settings.defaultMode = mode.rawValue
                persistSession()
            }
        }
    }
    @Published var pageBlocks: [UUID: [OCRBlock]] = [:]
    @Published var pageSizes: [UUID: CGSize] = [:]
    @Published var pagePreviewImages: [UUID: NSImage] = [:]
    @Published var hoveredBlockID: String?
    @Published var history: [HistoryRecord] = []
    @Published var showingHistory = false { didSet { hoveredBlockID = nil } }
    @Published var selectedHistoryID: UUID? { didSet { hoveredBlockID = nil } }
    @Published var settings: OCRSettings { didSet { settings.save() } }

    private var scopedURLs: Set<URL> = []
    private var isRestoring = true

    var hasResults: Bool { pageBlocks.values.contains { !$0.isEmpty } }
    var archiveRoot: URL { LibraryStore.root(settings: settings) }
    var modelDirectory: URL { LibraryStore.modelDirectory(settings: settings) }
    var activePageID: UUID? { showingHistory ? selectedHistoryID : selectedID }
    var previewItem: QueueItem? { activeItem }
    var activeBlocks: [OCRBlock] { activePageID.flatMap { pageBlocks[$0] } ?? [] }
    var activeHasResult: Bool { !activeBlocks.isEmpty }
    var activeHistoryRecord: HistoryRecord? {
        guard showingHistory, let id = selectedHistoryID else { return nil }
        return history.first(where: { $0.id == id })
    }
    var activeItem: QueueItem? {
        if showingHistory, let record = activeHistoryRecord { return record.queueItem(in: archiveRoot) }
        return queue.first(where: { $0.id == selectedID }) ?? queue.first
    }
    var previewHighlight: [Double]? {
        guard let id = activePageID,
              let blockID = hoveredBlockID,
              let blocks = pageBlocks[id] else { return nil }
        return blocks.first(where: { $0.id == blockID })?.bbox
    }

    init() {
        settings = OCRSettings.load()
        mode = OCRMode(rawValue: settings.defaultMode) ?? .hybrid
        restoreLibrary()
        isRestoring = false
    }

    private func restoreLibrary() {
        let root = archiveRoot
        let manifest = LibraryStore.readManifest(at: root)
        history = manifest.records.sorted { $0.savedAt > $1.savedAt }
        for record in history {
            pageBlocks[record.id] = record.blocks
            pageSizes[record.id] = CGSize(width: record.width, height: record.height)
            if let name = record.previewFilename {
                let url = root.appendingPathComponent("Previews", isDirectory: true).appendingPathComponent(name)
                if let image = NSImage(contentsOf: url) { pagePreviewImages[record.id] = image }
            }
        }
        if let session = LibraryStore.readSession(at: root) {
            queue = session.queue.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            selectedID = queue.contains(where: { $0.id == session.selectedID }) ? session.selectedID : queue.first?.id
            if let restored = OCRMode(rawValue: session.mode) { mode = restored }
        }
        selectedHistoryID = history.first?.id
        status = queue.isEmpty ? (history.isEmpty ? "Добавьте фотографии лекций или PDF" : "В истории: \(history.count) страниц")
                               : "В очереди: \(queue.count) страниц · восстановлено"
    }

    private func persistSession() {
        guard !isRestoring else { return }
        do {
            try LibraryStore.writeSession(QueueSession(queue: queue, selectedID: selectedID, mode: mode.rawValue), at: archiveRoot)
        } catch {
            status = "Не удалось сохранить очередь: \(error.localizedDescription)"
        }
    }

    func hasResult(_ id: UUID) -> Bool { !(pageBlocks[id] ?? []).isEmpty }

    func add(_ urls: [URL]) {
        var added: [QueueItem] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ["jpg", "jpeg", "png", "heic", "heif", "pdf"].contains(ext) else { continue }
            let accessed = url.startAccessingSecurityScopedResource()
            var inputURL = url
            var libraryFileName: String?
            if settings.keepHistory {
                do {
                    libraryFileName = try LibraryStore.archiveOriginal(url, at: archiveRoot)
                    inputURL = archiveRoot.appendingPathComponent("Originals", isDirectory: true)
                        .appendingPathComponent(libraryFileName!)
                } catch {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    errorMessage = "Не удалось скопировать файл в историю: \(error.localizedDescription)"
                    continue
                }
                if accessed { url.stopAccessingSecurityScopedResource() }
            } else if accessed {
                scopedURLs.insert(url)
            }
            if ext == "pdf", let doc = PDFDocument(url: inputURL) {
                for i in 0..<doc.pageCount {
                    added.append(QueueItem(url: inputURL, page: i, originalName: url.lastPathComponent,
                                           libraryFileName: libraryFileName))
                }
            } else if ["jpg", "jpeg", "png", "heic", "heif"].contains(ext) {
                added.append(QueueItem(url: inputURL, originalName: url.lastPathComponent,
                                       libraryFileName: libraryFileName))
            }
        }
        guard !added.isEmpty else { return }
        queue.append(contentsOf: added)
        showingHistory = false
        if selectedID == nil { selectedID = added.first?.id }
        status = "В очереди: \(queue.count) страниц"
    }

    func move(_ item: QueueItem, by offset: Int) {
        guard let i = queue.firstIndex(of: item) else { return }
        let j = max(0, min(queue.count - 1, i + offset))
        if i != j { queue.swapAt(i, j) }
    }

    func remove(_ item: QueueItem) {
        queue.removeAll { $0.id == item.id }
        if selectedID == item.id { selectedID = queue.first?.id }
        if !queue.contains(where: { $0.url == item.url }), scopedURLs.remove(item.url) != nil {
            item.url.stopAccessingSecurityScopedResource()
        }
        status = "Убрано из очереди · сохранённые результаты находятся в истории"
    }

    func hover(block: String?) {
        hoveredBlockID = block
    }

    func edit(_ itemID: UUID, blockID: String, text: String) {
        guard var blocks = pageBlocks[itemID], let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        blocks[index].text = text
        pageBlocks[itemID] = blocks
        persistEditedHistory(itemID)
    }

    private func persistEditedHistory(_ id: UUID) {
        guard let index = history.firstIndex(where: { $0.id == id }), let blocks = pageBlocks[id] else { return }
        history[index].blocks = blocks
        history[index].savedAt = Date()
        history.sort { $0.savedAt > $1.savedAt }
        do { try LibraryStore.writeManifest(HistoryManifest(records: history), at: archiveRoot) }
        catch { status = "Не удалось сохранить исправленный текст: \(error.localizedDescription)" }
    }

    func requeueHistory(_ record: HistoryRecord) {
        let item = record.queueItem(in: archiveRoot)
        if !queue.contains(where: { $0.id == item.id }) { queue.insert(item, at: 0) }
        showingHistory = false
        selectedID = item.id
        status = "Страница возвращена в очередь"
    }

    func setModelDirectory(_ url: URL) {
        var selected = url
        if selected.lastPathComponent != "official_models" {
            let nested = selected.appendingPathComponent("official_models", isDirectory: true)
            if FileManager.default.fileExists(atPath: nested.path) { selected = nested }
        }
        settings.modelDirectoryPath = selected.standardizedFileURL.path
        status = "Папка моделей: \(selected.lastPathComponent)"
    }

    func moveArchive(to destination: URL) {
        let oldRoot = archiveRoot.standardizedFileURL
        let newRoot = destination.standardizedFileURL
        guard oldRoot != newRoot else { return }
        let oldPath = oldRoot.path.hasSuffix("/") ? oldRoot.path : oldRoot.path + "/"
        let newPath = newRoot.path.hasSuffix("/") ? newRoot.path : newRoot.path + "/"
        guard !newPath.hasPrefix(oldPath), !oldPath.hasPrefix(newPath) else {
            errorMessage = "Выберите отдельную папку для библиотеки, вне текущей папки и её родительских папок."
            return
        }
        isMovingArchive = true
        status = "Переношу библиотеку…"
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try LibraryStore.mergeDirectory(oldRoot, into: newRoot)
                }.value
                guard let self else { return }
                var merged = LibraryStore.readManifest(at: newRoot).records
                let mergedIDs = Set(merged.map(\.id))
                merged += LibraryStore.readManifest(at: oldRoot).records.filter { !mergedIDs.contains($0.id) }
                try LibraryStore.writeManifest(HistoryManifest(records: merged), at: newRoot)
                self.settings.archiveDirectoryPath = newRoot.path
                self.queue = self.queue.map { item in
                    guard let stored = item.libraryFileName else { return item }
                    var moved = item
                    moved.url = newRoot.appendingPathComponent("Originals", isDirectory: true).appendingPathComponent(stored)
                    return moved
                }
                self.reloadHistory()
                self.persistSession()
                self.status = "Библиотека перенесена"
            } catch {
                self?.errorMessage = "Не удалось перенести библиотеку: \(error.localizedDescription)"
            }
            self?.isMovingArchive = false
        }
    }

    private func reloadHistory() {
        let root = archiveRoot
        history = LibraryStore.readManifest(at: root).records.sorted { $0.savedAt > $1.savedAt }
        pageBlocks = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0.blocks) })
        pageSizes = Dictionary(uniqueKeysWithValues: history.map { ($0.id, CGSize(width: $0.width, height: $0.height)) })
        pagePreviewImages = [:]
        for record in history {
            if let name = record.previewFilename {
                let url = root.appendingPathComponent("Previews", isDirectory: true).appendingPathComponent(name)
                if let image = NSImage(contentsOf: url) { pagePreviewImages[record.id] = image }
            }
        }
        if !history.contains(where: { $0.id == selectedHistoryID }) { selectedHistoryID = history.first?.id }
    }

    func recognize() {
        guard !queue.isEmpty, !isRunning else { return }
        isRunning = true
        progress = 0
        errorMessage = nil
        status = "Проверка локальных моделей…"
        Task { await runOCR() }
    }

    private func runOCR() async {
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("LectureOCR-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let previewDir = work.appendingPathComponent("previews", isDirectory: true)
            try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
            var inputs: [[String: String]] = []
            for (index, item) in queue.enumerated() {
                let path: String
                if let pageIndex = item.page {
                    guard let pdf = PDFDocument(url: item.url), let page = pdf.page(at: pageIndex) else { continue }
                    let bounds = page.bounds(for: .mediaBox)
                    let scale = min(2.0, 2200 / max(bounds.width, bounds.height))
                    let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                    let output = work.appendingPathComponent("page-\(index).png")
                    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { continue }
                    try png.write(to: output)
                    path = output.path
                } else if ["heic", "heif"].contains(item.url.pathExtension.lowercased()) {
                    guard let image = NSImage(contentsOf: item.url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
                    let output = work.appendingPathComponent("image-\(index).png")
                    try png.write(to: output)
                    path = output.path
                } else { path = item.url.path }
                inputs.append(["id": item.id.uuidString, "path": path])
            }
            guard !inputs.isEmpty else {
                throw NSError(domain: "LectureOCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось подготовить изображения."])
            }
            guard let worker = Bundle.main.url(forResource: "worker", withExtension: "py") else {
                throw NSError(domain: "LectureOCR", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не найден OCR-модуль приложения."])
            }
            let python = Self.pythonURL()
            guard FileManager.default.isExecutableFile(atPath: python.path) else {
                throw NSError(domain: "LectureOCR", code: 3, userInfo: [NSLocalizedDescriptionKey: "Не найден встроенный Python. Соберите приложение через build-app.sh."])
            }
            let modelRoot = modelDirectory
            var required = ["PP-DocLayoutV3", "PP-LCNet_x1_0_doc_ori", "UVDoc"]
            switch mode {
            case .vl: required += ["PaddleOCR-VL-1.6"]
            case .structure: required += ["PP-OCRv5_mobile_det", "eslav_PP-OCRv5_mobile_rec"]
            case .hybrid: required += ["PP-OCRv5_mobile_det", "eslav_PP-OCRv5_mobile_rec", "PP-OCRv6_medium_rec_cyrillic_onnx"]
            }
            let missing = required.filter { !FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent($0).path) }
            guard missing.isEmpty else {
                throw NSError(domain: "LectureOCR", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    "Не все модели установлены: \(missing.joined(separator: ", ")). Скачайте недостающие модели и повторите."])
            }
            try FileManager.default.createDirectory(at: modelRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = python
            process.arguments = [worker.path]
            let sitePackages = Bundle.main.resourceURL!.appendingPathComponent("python/site-packages").path
            var env = ProcessInfo.processInfo.environment
            env["PADDLE_PDX_CACHE_HOME"] = modelRoot.deletingLastPathComponent().path
            env["LECTURE_OCR_MODEL_DIR"] = modelRoot.path
            env["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
            env["PYTHONUNBUFFERED"] = "1"
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            env["PYTHONPATH"] = [sitePackages, env["PYTHONPATH"]].compactMap { $0 }.joined(separator: ":")
            process.environment = env
            let inputPipe = Pipe(), outputPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            try process.run()

            let outputTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let model = self else { return }
                for try await line in outputPipe.fileHandleForReading.bytes.lines {
                    guard let data = line.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    await model.receive(object)
                }
            }
            let request: [String: Any] = ["mode": mode.workerKey, "items": inputs,
                                          "preview_dir": previewDir.path]
            inputPipe.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request))
            inputPipe.fileHandleForWriting.closeFile()
            let exitCode = await Task.detached(priority: .userInitiated) {
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            try await outputTask.value
            if let errorMessage { throw NSError(domain: "LectureOCR", code: 5, userInfo: [NSLocalizedDescriptionKey: errorMessage]) }
            guard exitCode == 0 else {
                throw NSError(domain: "LectureOCR", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: "OCR завершился с ошибкой (код \(exitCode))."])
            }
            progress = 1
            status = "Готово · \(inputs.count) страниц · \(mode.rawValue)"
        } catch {
            errorMessage = error.localizedDescription
            status = "Распознавание не завершено"
        }
        isRunning = false
    }

    private func receive(_ object: [String: Any]) {
        switch object["event"] as? String {
        case "status":
            status = object["message"] as? String ?? status
        case "page":
            guard let idString = object["id"] as? String, let id = UUID(uuidString: idString) else { return }
            let rawBlocks = object["blocks"] as? [[String: Any]] ?? []
            pageBlocks[id] = rawBlocks.compactMap { item in
                guard let blockID = item["id"] as? String, let text = item["text"] as? String else { return nil }
                return OCRBlock(id: blockID, kind: item["kind"] as? String ?? "paragraph",
                                text: text, bbox: item["bbox"] as? [Double])
            }
            let width = object["width"] as? Double ?? 1
            let height = object["height"] as? Double ?? 1
            pageSizes[id] = CGSize(width: width, height: height)
            if let previewPath = object["preview_path"] as? String,
               let image = NSImage(contentsOfFile: previewPath) {
                pagePreviewImages[id] = image
            }
            let previewURL = object["preview_path"] as? String
            persistHistoryResult(id, previewSource: previewURL.map { URL(fileURLWithPath: $0) })
            let done = object["done"] as? Int ?? 0
            let total = max(1, object["total"] as? Int ?? 1)
            progress = Double(done) / Double(total)
            status = "Распознано страниц: \(done) из \(total)"
        case "error":
            errorMessage = object["message"] as? String ?? "Ошибка OCR"
        default:
            break
        }
    }

    private func persistHistoryResult(_ id: UUID, previewSource: URL?) {
        guard settings.keepHistory,
              let itemIndex = queue.firstIndex(where: { $0.id == id }),
              let blocks = pageBlocks[id] else { return }
        var item = queue[itemIndex]
        do {
            if item.libraryFileName == nil {
                item.libraryFileName = try LibraryStore.archiveOriginal(item.url, at: archiveRoot)
                item.url = archiveRoot.appendingPathComponent("Originals", isDirectory: true)
                    .appendingPathComponent(item.libraryFileName!)
                queue[itemIndex] = item
            }
            let prior = history.first(where: { $0.id == id })
            let previewName: String?
            if let previewSource, FileManager.default.fileExists(atPath: previewSource.path) {
                previewName = try LibraryStore.storePreview(previewSource, pageID: id, at: archiveRoot)
            } else {
                previewName = prior?.previewFilename
            }
            let size = pageSizes[id] ?? .zero
            let record = HistoryRecord(id: id, sourceFilename: item.libraryFileName!,
                                       displayName: item.originalName ?? item.url.lastPathComponent,
                                       page: item.page, blocks: blocks,
                                       width: Double(size.width), height: Double(size.height),
                                       previewFilename: previewName, savedAt: Date(), mode: mode.rawValue)
            if let old = history.firstIndex(where: { $0.id == id }) { history[old] = record }
            else { history.append(record) }
            if selectedHistoryID == nil { selectedHistoryID = id }
            pruneHistory()
            status = "Результат сохранён в истории · \(history.count) страниц"
        } catch {
            status = "Распознано, но не удалось сохранить в историю: \(error.localizedDescription)"
        }
    }

    func pruneHistory() {
        let cap = max(10, min(5000, settings.historyLimit))
        let ordered = history.sorted { $0.savedAt > $1.savedAt }
        let removed = Array(ordered.dropFirst(cap))
        history = Array(ordered.prefix(cap))
        do { try LibraryStore.writeManifest(HistoryManifest(records: history), at: archiveRoot) }
        catch { status = "Не удалось обновить историю: \(error.localizedDescription)"; return }
        let retainedSources = Set(history.map(\.sourceFilename)).union(queue.compactMap(\.libraryFileName))
        for record in removed {
            if !queue.contains(where: { $0.id == record.id }) {
                pageBlocks[record.id] = nil
                pageSizes[record.id] = nil
                pagePreviewImages[record.id] = nil
            }
            if let preview = record.previewFilename {
                try? FileManager.default.removeItem(at: archiveRoot.appendingPathComponent("Previews", isDirectory: true).appendingPathComponent(preview))
            }
            if !retainedSources.contains(record.sourceFilename) {
                try? FileManager.default.removeItem(at: archiveRoot.appendingPathComponent("Originals", isDirectory: true).appendingPathComponent(record.sourceFilename))
            }
        }
        if !history.contains(where: { $0.id == selectedHistoryID }) { selectedHistoryID = history.first?.id }
    }

    func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lecture OCR Settings.json"
        panel.allowedContentTypes = [UTType.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: url, options: .atomic)
            status = "Настройки экспортированы"
        } catch { errorMessage = "Не удалось экспортировать настройки: \(error.localizedDescription)" }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try JSONDecoder().decode(OCRSettings.self, from: Data(contentsOf: url))
            settings = imported
            mode = OCRMode(rawValue: imported.defaultMode) ?? .hybrid
            reloadHistory()
            queue = (LibraryStore.readSession(at: archiveRoot)?.queue ?? []).map { item in
                guard let stored = item.libraryFileName else { return item }
                var restored = item
                restored.url = archiveRoot.appendingPathComponent("Originals", isDirectory: true).appendingPathComponent(stored)
                return restored
            }.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            selectedID = queue.first?.id
            status = "Настройки импортированы"
        } catch { errorMessage = "Не удалось прочитать настройки: \(error.localizedDescription)" }
    }

    func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lecture OCR Backup.zip"
        panel.allowedContentTypes = [UTType(filenameExtension: "zip") ?? .archive]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let root = archiveRoot
        let settingsSnapshot = settings
        status = "Создаю архив истории и настроек…"
        Task { [weak self] in
            do {
                try await Self.runBackupExport(root: root, settings: settingsSnapshot, destination: destination)
                self?.status = "Резервная копия сохранена: \(destination.lastPathComponent)"
            } catch { self?.errorMessage = "Не удалось создать резервную копию: \(error.localizedDescription)" }
        }
    }

    private static func runBackupExport(root: URL, settings: OCRSettings, destination: URL) async throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("LectureOCR-Backup-\(UUID().uuidString)", isDirectory: true)
        let snapshot = temp.appendingPathComponent(folderNameForBackup, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        try LibraryStore.mergeDirectory(root, into: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: snapshot.appendingPathComponent("settings.json"), options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", snapshot.path, destination.path]
        try process.run()
        let result = await Task.detached(priority: .userInitiated) {
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard result == 0 else { throw NSError(domain: "LectureOCR", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "ditto завершился с кодом \(result)"]) }
    }

    private static let folderNameForBackup = "Lecture OCR Backup"

    func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "zip") ?? .archive]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let archive = panel.url else { return }
        status = "Импортирую резервную копию…"
        Task { [weak self] in
            do { try await self?.runBackupImport(archive) }
            catch { self?.errorMessage = "Не удалось импортировать копию: \(error.localizedDescription)" }
        }
    }

    private func runBackupImport(_ archive: URL) async throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("LectureOCR-Restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, temp.path]
        try process.run()
        let result = await Task.detached(priority: .userInitiated) {
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard result == 0 else { throw NSError(domain: "LectureOCR", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Архив не удалось распаковать."]) }
        guard let manifestURL = fm.enumerator(at: temp, includingPropertiesForKeys: nil)?.allObjects
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == LibraryStore.manifestName }) else {
            throw NSError(domain: "LectureOCR", code: 21, userInfo: [NSLocalizedDescriptionKey: "В архиве нет истории Lecture OCR."])
        }
        let importedRoot = manifestURL.deletingLastPathComponent()
        let imported = LibraryStore.readManifest(at: importedRoot)
        guard !imported.records.isEmpty else {
            throw NSError(domain: "LectureOCR", code: 22, userInfo: [NSLocalizedDescriptionKey: "В архиве нет сохранённых страниц."])
        }
        let destination = archiveRoot
        try LibraryStore.ensureDirectories(at: destination)
        var combined = LibraryStore.readManifest(at: destination).records
        let existingIDs = Set(combined.map(\.id))
        for record in imported.records where !existingIDs.contains(record.id) {
            let source = importedRoot.appendingPathComponent("Originals", isDirectory: true).appendingPathComponent(record.sourceFilename)
            let target = destination.appendingPathComponent("Originals", isDirectory: true).appendingPathComponent(record.sourceFilename)
            if fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) { try fm.copyItem(at: source, to: target) }
            if let preview = record.previewFilename {
                let sourcePreview = importedRoot.appendingPathComponent("Previews", isDirectory: true).appendingPathComponent(preview)
                let targetPreview = destination.appendingPathComponent("Previews", isDirectory: true).appendingPathComponent(preview)
                if fm.fileExists(atPath: sourcePreview.path), !fm.fileExists(atPath: targetPreview.path) { try fm.copyItem(at: sourcePreview, to: targetPreview) }
            }
            guard fm.fileExists(atPath: target.path) else { continue }
            combined.append(record)
        }
        history = combined.sorted { $0.savedAt > $1.savedAt }
        pruneHistory()
        reloadHistory()
        if let settingsURL = fm.enumerator(at: importedRoot, includingPropertiesForKeys: nil)?.allObjects
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "settings.json" }),
           let backupSettings = try? JSONDecoder().decode(OCRSettings.self, from: Data(contentsOf: settingsURL)) {
            settings.keepHistory = backupSettings.keepHistory
            settings.historyLimit = backupSettings.historyLimit
            settings.defaultMode = backupSettings.defaultMode
            settings.animationsEnabled = backupSettings.animationsEnabled
            mode = OCRMode(rawValue: backupSettings.defaultMode) ?? mode
        }
        status = "История объединена · \(history.count) страниц"
    }

    private static func pythonURL() -> URL {
        Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
    }

    func export(_ type: ExportType) {
        guard hasResults else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Распознанные лекции.\(type.ext)"
        panel.allowedContentTypes = [type.utType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let exportItems: [QueueItem] = showingHistory ? activeItem.map { [$0] } ?? [] : queue
        let pages = exportItems.compactMap { item -> [String: Any]? in
            guard let blocks = pageBlocks[item.id], !blocks.isEmpty else { return nil }
            return ["name": item.displayName, "blocks": blocks.map { ["kind": $0.kind, "text": $0.text] }]
        }
        do {
            if type == .docx {
                let helper = Bundle.main.url(forResource: "export_docx", withExtension: "py")!
                let process = Process(); process.executableURL = Self.pythonURL(); process.arguments = [helper.path, url.path]
                let modelCache = modelDirectory.deletingLastPathComponent()
                var env = ProcessInfo.processInfo.environment
                env["PADDLE_PDX_CACHE_HOME"] = modelCache.path
                env["PYTHONPATH"] = Bundle.main.resourceURL!.appendingPathComponent("python/site-packages").path
                env["PYTHONDONTWRITEBYTECODE"] = "1"
                process.environment = env
                let input = Pipe(); process.standardInput = input
                try process.run()
                input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: ["pages": pages]))
                input.fileHandleForWriting.closeFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "LectureOCR", code: 6, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать DOCX."])
                }
            } else {
                let output = pages.enumerated().map { index, page in
                    let name = page["name"] as? String ?? "Страница \(index + 1)"
                    let blocks = page["blocks"] as? [[String: String]] ?? []
                    if type == .md { return "## \(name)\n\n" + blocks.map { markdown($0) }.joined(separator: "\n\n") }
                    return "=== \(name) ===\n\n" + blocks.map { $0["text"] ?? "" }.joined(separator: "\n\n")
                }.joined(separator: "\n\n")
                try output.write(to: url, atomically: true, encoding: .utf8)
            }
            status = "Файл сохранён: \(url.lastPathComponent)"
        } catch { errorMessage = error.localizedDescription }
    }

    private func markdown(_ block: [String: String]) -> String {
        let text = block["text"] ?? ""
        switch block["kind"] {
        case "heading": return "### \(text.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces))"
        case "list": return text.split(separator: "\n").map { line in
            let value = String(line).trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("-") || value.hasPrefix("—") || value.hasPrefix("•") ? value : "- \(value)"
        }.joined(separator: "\n")
        default: return text
        }
    }
}

private extension OCRMode {
    var workerKey: String {
        switch self { case .vl: return "vl"; case .structure: return "structure"; case .hybrid: return "hybrid" }
    }
}

enum ExportType: String, CaseIterable, Identifiable {
    case docx, txt, md
    var id: String { rawValue }
    var ext: String { rawValue }
    var utType: UTType {
        switch self {
        case .docx: return UTType(filenameExtension: "docx") ?? .data
        case .txt: return .plainText
        case .md: return UTType(filenameExtension: "md") ?? .plainText
        }
    }
}

struct ContentView: View {
    @StateObject private var model = OCRModel()
    @State private var isTargeted = false
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var showProcessedPreview = true
    @State private var zoomScale: CGFloat = 1
    @GestureState private var pinchFactor: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transition: Animation? {
        model.settings.animationsEnabled && !reduceMotion ? .easeInOut(duration: 0.18) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                queuePane
                Divider()
                previewPane
                Divider()
                textPane
            }
        }
        .frame(minWidth: 1160, minHeight: 700)
        .animation(transition, value: model.activePageID)
        .animation(transition, value: model.showingHistory)
        .onChange(of: model.activePageID) { _, _ in zoomScale = 1 }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.add([url]) } }
                }
            }
            return true
        }
        .alert("Ошибка", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
                .frame(width: 660, height: 650)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "doc.viewfinder").font(.system(size: 25, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("Lecture OCR").font(.system(size: 21, weight: .semibold))
                Text("Локальное распознавание лекций").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Picker("Модель", selection: $model.mode) {
                ForEach(OCRMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }.pickerStyle(.segmented).frame(width: 390).help(model.mode.help)
            Button { showPicker = true } label: { Label("Добавить", systemImage: "plus") }.keyboardShortcut("o", modifiers: .command)
            Button { model.recognize() } label: { Label("Распознать", systemImage: "text.viewfinder") }
                .buttonStyle(.borderedProminent).disabled(model.queue.isEmpty || model.isRunning)
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help("Настройки")
        }.padding(.horizontal, 18).padding(.vertical, 13)
    }

    private var queuePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Раздел", selection: $model.showingHistory) {
                Text("Очередь").tag(false)
                Text("История").tag(true)
            }.pickerStyle(.segmented)
            if model.showingHistory {
                if model.history.isEmpty {
                    ContentUnavailableView("История пуста", systemImage: "clock.arrow.circlepath",
                                           description: Text("Распознанные страницы появятся здесь, если в настройках включено сохранение."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selectedHistoryID) {
                        ForEach(model.history) { record in
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    .accessibilityLabel("Распознано")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.pageTitle).lineLimit(1)
                                    Text(record.savedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }.tag(record.id)
                                .contextMenu { Button("Вернуть в очередь") { model.requeueHistory(record) } }
                        }
                    }.listStyle(.inset)
                }
            } else if model.queue.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.image").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Перетащите сюда JPG, PNG, HEIC или PDF").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Выбрать файлы…") { showPicker = true }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6])).foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35)))
            } else {
                List(selection: $model.selectedID) {
                    ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 7) {
                            Image(systemName: model.hasResult(item.id) ? "checkmark.circle.fill" : (item.page == nil ? "photo" : "doc.richtext"))
                                .foregroundStyle(model.hasResult(item.id) ? Color.green : Color.secondary)
                                .contentTransition(.symbolEffect(.replace))
                                .accessibilityLabel(model.hasResult(item.id) ? "Распознано" : "Не распознано")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName).lineLimit(1)
                                Text("\(index + 1) из \(model.queue.count)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 2)
                            Button { model.move(item, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.plain).disabled(index == 0).help("Переместить вверх")
                            Button { model.move(item, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.plain).disabled(index == model.queue.count - 1).help("Переместить вниз")
                            Button { model.remove(item) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Убрать из очереди")
                        }.tag(item.id)
                    }
                }.listStyle(.inset)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if model.isRunning || model.progress > 0 {
                ProgressView(value: model.progress).accessibilityLabel("Прогресс распознавания")
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }.padding(14).frame(width: 255)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Фото страницы").font(.headline)
                Spacer()
                if let item = model.previewItem, model.pagePreviewImages[item.id] != nil {
                    Picker("Снимок", selection: $showProcessedPreview) {
                        Text("Улучшенный").tag(true)
                        Text("Оригинал").tag(false)
                    }.pickerStyle(.segmented).frame(width: 165)
                }
            }
            if let item = model.previewItem { Text(item.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let item = model.previewItem, let image = previewImage(for: item) {
                GeometryReader { geometry in
                    let fitted = fit(image.size, into: geometry.size)
                    let scale = min(4, max(1, zoomScale * pinchFactor))
                    let imageSize = CGSize(width: fitted.width * scale, height: fitted.height * scale)
                    let contentWidth = max(geometry.size.width, imageSize.width)
                    let contentHeight = max(geometry.size.height, imageSize.height)
                    ScrollView([.horizontal, .vertical]) {
                        ZStack {
                            Color(nsColor: .windowBackgroundColor)
                            Image(nsImage: image).resizable().frame(width: imageSize.width, height: imageSize.height)
                            if showProcessedPreview, model.pagePreviewImages[item.id] != nil,
                               let box = model.previewHighlight, box.count == 4 {
                                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.15))
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 2))
                                    .frame(width: max(2, imageSize.width * box[2]), height: max(2, imageSize.height * box[3]))
                                    .position(x: (contentWidth - imageSize.width) / 2 + imageSize.width * (box[0] + box[2] / 2),
                                              y: (contentHeight - imageSize.height) / 2 + imageSize.height * (box[1] + box[3] / 2))
                            }
                        }
                        .frame(width: contentWidth, height: contentHeight)
                        .animation(transition, value: model.activePageID)
                        .animation(transition, value: zoomScale)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .simultaneousGesture(MagnifyGesture()
                        .updating($pinchFactor) { value, state, _ in state = value.magnification }
                        .onEnded { value in setZoom(zoomScale * value.magnification) })
                    .overlay {
                        if model.isMovingArchive {
                            ProgressView("Переношу библиотеку…").padding(12)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            } else {
                ContentUnavailableView("Выберите страницу", systemImage: "photo", description: Text("Исходное фото появится здесь"))
            }
            HStack(spacing: 8) {
                Button { setZoom(zoomScale - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Уменьшить масштаб").disabled(zoomScale <= 1)
                Text("\(Int(zoomScale * 100))% от вписанного").font(.caption.monospacedDigit())
                    .contentTransition(.numericText()).frame(minWidth: 90)
                Button { setZoom(zoomScale + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Увеличить масштаб").disabled(zoomScale >= 4)
                Button("Вписать") { setZoom(1) }.help("Показать всю страницу")
            }.buttonStyle(.borderless)
            Text(showProcessedPreview
                 ? "Наведите курсор на текст для подсветки; масштабируйте кнопками или жестом трекпада."
                 : "Показан исходный снимок; переключитесь на «Улучшенный», чтобы видеть подсветку области.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(width: 335)
    }

    private var textPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Распознанный текст").font(.headline)
                    Text(model.mode.help).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    ForEach(ExportType.allCases) { kind in Button("Экспорт в .\(kind.ext)") { model.export(kind) } }
                } label: { Label("Экспорт…", systemImage: "square.and.arrow.up") }.disabled(!model.hasResults)
            }
            if model.activeHasResult, let item = model.activeItem {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text(item.displayName).font(.caption).foregroundStyle(.secondary)
                        ForEach(model.activeBlocks) { block in
                            FormattedBlockView(block: block,
                                onChange: { model.edit(item.id, blockID: block.id, text: $0) },
                                onHover: { active in model.hover(block: active ? block.id : nil) })
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                        }
                    }.padding(.vertical, 6)
                }
            } else {
                ContentUnavailableView(model.activeItem == nil ? "Выберите страницу" : "Страница ещё не распознана",
                                       systemImage: "text.alignleft",
                                       description: Text(model.activeItem == nil ? "Результат появится здесь" : "Нажмите «Распознать», чтобы получить текст этой страницы."))
            }
            if model.showingHistory, let record = model.activeHistoryRecord {
                Button { model.requeueHistory(record) } label: { Label("Вернуть в очередь", systemImage: "tray.and.arrow.down") }
                    .buttonStyle(.bordered)
            }
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(transition) { zoomScale = min(4, max(1, value)) }
    }

    private func fit(_ size: CGSize, into target: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return target }
        let scale = min(target.width / size.width, target.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func previewImage(for item: QueueItem) -> NSImage? {
        if showProcessedPreview, let image = model.pagePreviewImages[item.id] { return image }
        if let pageIndex = item.page, let pdf = PDFDocument(url: item.url), let page = pdf.page(at: pageIndex) {
            let bounds = page.bounds(for: .mediaBox)
            return page.thumbnail(of: CGSize(width: bounds.width * 1.5, height: bounds.height * 1.5), for: .mediaBox)
        }
        return NSImage(contentsOf: item.url)
    }
}

struct SettingsView: View {
    @ObservedObject var model: OCRModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Настройки").font(.title2.weight(.semibold))
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Form {
                Section("История") {
                    Toggle("Сохранять исходники и распознанный текст", isOn: $model.settings.keepHistory)
                    Stepper("Хранить до \(model.settings.historyLimit) страниц", value: $model.settings.historyLimit,
                            in: 10...5000, step: 50)
                        .disabled(!model.settings.keepHistory)
                        .onChange(of: model.settings.historyLimit) { _, _ in model.pruneHistory() }
                    Text("При уменьшении лимита удаляются самые старые записи истории вместе с их копиями страниц.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Папка библиотеки…") { chooseArchiveFolder() }.disabled(model.isMovingArchive)
                        Spacer()
                        Text(model.archiveRoot.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(2).textSelection(.enabled).truncationMode(.middle)
                    }
                    Text("Удаление строки из очереди не удаляет страницу из истории. Отключение сохранения влияет только на новые страницы.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Модели") {
                    HStack {
                        Button("Папка с моделями…") { chooseModelFolder() }
                        Spacer()
                        Text("\(availableModelFolders) из 8 знакомых папок")
                            .font(.caption).foregroundStyle(availableModelFolders > 0 ? Color.secondary : Color.orange)
                    }
                    Text(model.modelDirectory.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled).truncationMode(.middle)
                    Text("Выбери папку с подпапками моделей на Mac или внешнем диске. При выборе папки PaddleX/official_models она распознаётся автоматически.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Распознавание") {
                    Picker("Режим по умолчанию", selection: $model.settings.defaultMode) {
                        ForEach(OCRMode.allCases) { mode in Text(mode.rawValue).tag(mode.rawValue) }
                    }
                    .onChange(of: model.settings.defaultMode) { _, value in
                        model.mode = OCRMode(rawValue: value) ?? .hybrid
                    }
                }
                Section("Интерфейс") {
                    Toggle("Анимировать смену страниц и состояний", isOn: $model.settings.animationsEnabled)
                    if reduceMotion {
                        Label("macOS включает «Уменьшить движение»; переходы останутся спокойными.", systemImage: "figure.walk")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Перенос") {
                    HStack {
                        Button("Экспортировать резервную копию…") { model.exportBackup() }
                        Button("Импортировать резервную копию…") { model.importBackup() }
                    }
                    HStack {
                        Button("Экспортировать настройки…") { model.exportSettings() }
                        Button("Импортировать настройки…") { model.importSettings() }
                    }
                    Text("ZIP-копия объединяется с текущей историей. JSON переносит только настройки.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .padding(20)
    }

    private var availableModelFolders: Int {
        let known = ["PP-DocLayoutV3", "PP-LCNet_x1_0_doc_ori", "UVDoc", "PaddleOCR-VL-1.6",
                     "PP-OCRv5_mobile_det", "eslav_PP-OCRv5_mobile_rec",
                     "PP-OCRv6_medium_rec_cyrillic_onnx", "cyrillic_PP-OCRv5_mobile_rec"]
        return known.filter { FileManager.default.fileExists(atPath: model.modelDirectory.appendingPathComponent($0).path) }.count
    }

    private func chooseArchiveFolder() {
        let panel = NSOpenPanel()
        panel.title = "Расположение библиотеки Lecture OCR"
        panel.prompt = "Выбрать папку"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.moveArchive(to: url) }
    }

    private func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.title = "Папка с локальными OCR-моделями"
        panel.prompt = "Выбрать папку"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.setModelDirectory(url) }
    }
}

struct FormattedBlockView: View {
    var block: OCRBlock
    var onChange: (String) -> Void
    var onHover: (Bool) -> Void
    @State private var isEditing = false

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: Binding(get: { block.text }, set: onChange))
                    .font(font).frame(minHeight: estimatedHeight).padding(4)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.35)))
                    .onTapGesture(count: 2) { isEditing = false }
            } else {
                Text(displayText).font(font).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    .background(Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle()).onTapGesture(count: 2) { isEditing = true }
                    .onHover(perform: onHover)
            }
        }
    }

    private var displayText: String {
        if block.kind == "list" && !block.text.trimmingCharacters(in: .whitespaces).hasPrefix("—") && !block.text.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
            return "• " + block.text
        }
        return block.text
    }

    private var font: Font {
        switch block.kind {
        case "heading": return .system(size: 17, weight: .semibold)
        case "list": return .system(size: 14)
        default: return .system(size: 14)
        }
    }

    private var estimatedHeight: CGFloat {
        let lines = max(1, block.text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let wraps = max(1, block.text.count / 54 + 1)
        return CGFloat(max(lines, wraps)) * 22 + 10
    }
}

@main struct LectureOCRApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.titleBar)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
