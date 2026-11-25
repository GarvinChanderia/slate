import Foundation

/// `LibraryStore` backed by plain files in a directory (normally the App Group container).
///
/// Layout under `rootURL`:
/// ```
/// index.json            metadata for all items (written atomically)
/// Originals/<id>.<ext>  imported file, byte-for-byte copy
/// Thumbnails/<id>.jpg   ~400 px grid thumbnail
/// Widget/<id>.jpg       ≤1200 px widget image
/// ```
/// Only the app writes; the widget extension creates its own instance and only reads.
/// The actor serialises index mutations; heavy work (copying, decoding, encoding) runs in
/// `@concurrent` functions, so several imports can process in parallel.
actor FileLibraryStore: LibraryStore {
    nonisolated let rootURL: URL
    private var cachedItems: [LibraryItem]?
    /// Imports whose files are being written but aren't in the index yet.
    private var inFlightIDs: Set<UUID> = []

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// The store in the shared App Group container.
    static func appGroup() throws(LibraryError) -> FileLibraryStore {
        guard let root = AppGroup.libraryRootURL else { throw .containerUnavailable }
        return FileLibraryStore(rootURL: root)
    }

    // MARK: Paths

    nonisolated var indexURL: URL { rootURL.appending(path: "index.json") }

    nonisolated func directoryURL(for variant: ImageVariant) -> URL {
        switch variant {
        case .original: rootURL.appending(path: "Originals", directoryHint: .isDirectory)
        case .thumbnail: rootURL.appending(path: "Thumbnails", directoryHint: .isDirectory)
        case .widget: rootURL.appending(path: "Widget", directoryHint: .isDirectory)
        }
    }

    nonisolated func fileURL(for item: LibraryItem, variant: ImageVariant) -> URL {
        fileURL(for: item.id, fileExtension: variant == .original ? item.originalFileExtension : "jpg", variant: variant)
    }

    private nonisolated func fileURL(for id: UUID, fileExtension: String, variant: ImageVariant) -> URL {
        directoryURL(for: variant).appending(path: "\(id.uuidString).\(fileExtension)")
    }

    // MARK: Reading

    func items() throws -> [LibraryItem] {
        if let cachedItems { return cachedItems }
        let items = try readIndex()
        cachedItems = items
        return items
    }

    private func readIndex() throws(LibraryError) -> [LibraryItem] {
        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw LibraryError.wrapping(error, filename: nil)
        }
        do {
            return try Self.decoder.decode(Index.self, from: data).items
        } catch {
            throw .fileSystem(filename: nil, reason: "The library index is damaged (\(error.localizedDescription)).")
        }
    }

    // MARK: Writing

    func importImage(at sourceURL: URL, filename: String? = nil) async throws -> LibraryItem {
        let filename = filename ?? sourceURL.lastPathComponent
        let info = try ImageProcessor.inspect(sourceURL, filename: filename)
        try createDirectories()
        try checkFreeSpace(forCopying: sourceURL)

        let id = UUID()
        inFlightIDs.insert(id)
        defer { inFlightIDs.remove(id) }
        let originalURL = fileURL(for: id, fileExtension: info.fileExtension, variant: .original)
        let thumbnailURL = fileURL(for: id, fileExtension: "jpg", variant: .thumbnail)
        let widgetURL = fileURL(for: id, fileExtension: "jpg", variant: .widget)

        do {
            // Both calls suspend the actor, letting other imports run concurrently.
            try await Self.copyFile(from: sourceURL, to: originalURL, filename: filename)
            try await ImageProcessor.writeDerivatives(from: originalURL, filename: filename,
                                                      widgetURL: widgetURL, thumbnailURL: thumbnailURL)

            let item = LibraryItem(id: id, filename: filename, originalFileExtension: info.fileExtension,
                                   importDate: .now, pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight,
                                   isFavorite: false)
            var items = try self.items()
            items.append(item)
            items.sort { $0.importDate > $1.importDate }
            try writeIndex(items)
            return item
        } catch {
            // Leave nothing behind for a failed import.
            for url in [originalURL, thumbnailURL, widgetURL] {
                try? FileManager.default.removeItem(at: url)
            }
            throw LibraryError.wrapping(error, filename: filename)
        }
    }

    func delete(_ ids: Set<LibraryItem.ID>) throws {
        var items = try self.items()
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        // Update the index first so the widget never picks an item whose files are gone.
        try writeIndex(items)
        for item in removed {
            for variant in ImageVariant.allCases {
                try? FileManager.default.removeItem(at: fileURL(for: item, variant: variant))
            }
        }
    }

    func setFavorite(_ isFavorite: Bool, for id: LibraryItem.ID) throws {
        var items = try self.items()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isFavorite = isFavorite
        try writeIndex(items)
    }

    @discardableResult
    func removeOrphanedFiles() throws -> Int {
        let known = Set(try items().map(\.id.uuidString) + inFlightIDs.map(\.uuidString))
        var removed = 0
        for variant in ImageVariant.allCases {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directoryURL(for: variant), includingPropertiesForKeys: nil)) ?? []
            for url in urls where !known.contains(url.deletingPathExtension().lastPathComponent) {
                if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        return removed
    }

    // MARK: Helpers

    private struct Index: Codable {
        var version = 1
        var items: [LibraryItem]
    }

    // Dates use the default (Double) encoding: unlike ISO 8601 it round-trips exactly.
    private nonisolated static let decoder = JSONDecoder()

    private func writeIndex(_ items: [LibraryItem]) throws(LibraryError) {
        do {
            let data = try JSONEncoder().encode(Index(items: items))
            try data.write(to: indexURL, options: .atomic)
            cachedItems = items
        } catch {
            throw LibraryError.wrapping(error, filename: nil)
        }
    }

    private func createDirectories() throws(LibraryError) {
        do {
            for variant in ImageVariant.allCases {
                try FileManager.default.createDirectory(at: directoryURL(for: variant), withIntermediateDirectories: true)
            }
        } catch {
            throw LibraryError.wrapping(error, filename: nil)
        }
    }

    /// Fails early with `.diskFull` instead of half-writing files. The margin covers the
    /// derivatives (well under 1 MB each) plus headroom for the system.
    private func checkFreeSpace(forCopying sourceURL: URL) throws(LibraryError) {
        let sourceSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let margin: Int64 = 20 * 1024 * 1024
        if let available = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           available > 0, available < Int64(sourceSize) + margin {
            throw .diskFull
        }
    }

    @concurrent
    private static func copyFile(from source: URL, to destination: URL, filename: String) async throws(LibraryError) {
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw LibraryError.wrapping(error, filename: filename)
        }
    }
}
