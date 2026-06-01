//
//  ShelfStore.swift
//  PingIsland
//
//  Local file shelf used by the island panel.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum ShelfItemKind: String, Codable, Equatable {
    case folder
    case image
    case pdf
    case document
    case spreadsheet
    case presentation
    case code
    case archive
    case file

    var label: String {
        switch self {
        case .folder: return "Folder"
        case .image: return "Image"
        case .pdf: return "PDF"
        case .document: return "Document"
        case .spreadsheet: return "Sheet"
        case .presentation: return "Deck"
        case .code: return "Code"
        case .archive: return "Archive"
        case .file: return "File"
        }
    }
}

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    let originalName: String
    let storedPath: String
    let originalPath: String?
    let kind: ShelfItemKind
    let addedAt: Date
    let fileSize: Int64?

    nonisolated var storedURL: URL {
        URL(fileURLWithPath: storedPath)
    }
}

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var lastError: String?

    private let fileManager = FileManager.default
    private let metadataFileName = "shelf-items.json"
    private let swiftUIDragCachePrefix = "com.apple.SwiftUI.Drag-"

    private lazy var shelfDirectory: URL = {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Jade Cub", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
    }()

    private lazy var metadataURL: URL = {
        shelfDirectory.appendingPathComponent(metadataFileName)
    }()

    private init() {
        load()
        cleanupSwiftUIDragCaches()
    }

    @discardableResult
    func addItemProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                guard let url = Self.fileURL(from: item) else { return }
                Task { @MainActor [weak self] in
                    self?.addFiles([url])
                }
            }
        }

        return !fileProviders.isEmpty
    }

    func addFiles(_ urls: [URL]) {
        do {
            try ensureShelfDirectory()

            for url in urls {
                try addFile(url)
            }

            save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.storedURL)
    }

    func revealInFinder(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.storedURL])
    }

    func copyPath(_ item: ShelfItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.storedPath, forType: .string)
    }

    func copyItemsToPasteboard(_ copiedItems: [ShelfItem]) {
        let urls = copiedItems
            .map(\.storedURL)
            .filter { fileManager.fileExists(atPath: $0.path) }

        guard !urls.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        pasteboard.setPropertyList(urls.map(\.path), forType: .init("NSFilenamesPboardType"))
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func copyItemToPasteboard(_ item: ShelfItem) {
        copyItemsToPasteboard([item])
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()

        let storedURL = item.storedURL
        Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: storedURL.path) else { return }
            do {
                try FileManager.default.removeItem(at: storedURL)
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func clear() {
        let currentItems = items
        items.removeAll()
        save()

        Task.detached(priority: .utility) {
            for item in currentItems where FileManager.default.fileExists(atPath: item.storedPath) {
                try? FileManager.default.removeItem(at: item.storedURL)
            }
        }
    }

    func scheduleDragCacheCleanup() {
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            await self?.cleanupSwiftUIDragCaches()
        }
    }

    private func addFile(_ url: URL) throws {
        let sourceURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !isShelfManagedFile(sourceURL) else { return }

        let destinationURL = shelfDirectory.appendingPathComponent(uniqueStoredName(for: sourceURL))

        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let item = ShelfItem(
            id: UUID(),
            originalName: sourceURL.lastPathComponent,
            storedPath: destinationURL.path,
            originalPath: sourceURL.path,
            kind: kind(for: sourceURL),
            addedAt: Date(),
            fileSize: fileSize(for: destinationURL)
        )

        items.insert(item, at: 0)
    }

    private func isShelfManagedFile(_ url: URL) -> Bool {
        let sourcePath = url.standardizedFileURL.path
        let shelfPath = shelfDirectory.standardizedFileURL.path
        return sourcePath == shelfPath || sourcePath.hasPrefix(shelfPath + "/")
    }

    private func load() {
        do {
            try ensureShelfDirectory()
            guard fileManager.fileExists(atPath: metadataURL.path) else { return }

            let data = try Data(contentsOf: metadataURL)
            let decoded = try JSONDecoder().decode([ShelfItem].self, from: data)
            items = decoded.filter { fileManager.fileExists(atPath: $0.storedPath) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func save() {
        do {
            try ensureShelfDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func cleanupSwiftUIDragCaches() {
        guard let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let cacheItems = try? fileManager.contentsOfDirectory(
                at: cachesURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for cacheURL in cacheItems where cacheURL.lastPathComponent.hasPrefix(swiftUIDragCachePrefix) {
            try? fileManager.removeItem(at: cacheURL)
        }
    }

    private func ensureShelfDirectory() throws {
        try fileManager.createDirectory(at: shelfDirectory, withIntermediateDirectories: true)
    }

    private func uniqueStoredName(for url: URL) -> String {
        let safeName = url.lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(UUID().uuidString)-\(safeName)"
    }

    private func kind(for url: URL) -> ShelfItemKind {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return .folder
        }

        let ext = url.pathExtension.lowercased()

        if ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"].contains(ext) {
            return .image
        }
        if ext == "pdf" {
            return .pdf
        }
        if ["doc", "docx", "txt", "rtf", "md", "pages"].contains(ext) {
            return .document
        }
        if ["xls", "xlsx", "csv", "tsv", "numbers"].contains(ext) {
            return .spreadsheet
        }
        if ["ppt", "pptx", "key"].contains(ext) {
            return .presentation
        }
        if ["swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "json", "yaml", "yml", "html", "css"].contains(ext) {
            return .code
        }
        if ["zip", "rar", "7z", "tar", "gz", "dmg"].contains(ext) {
            return .archive
        }
        return .file
    }

    private func fileSize(for url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
            return nil
        }
        return values.fileSize.map(Int64.init)
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let nsURL = item as? NSURL {
            return nsURL as URL
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        return nil
    }
}
