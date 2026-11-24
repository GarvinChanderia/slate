import Foundation
import Observation
import PhotosUI
import SwiftUI
import WidgetKit

/// Something the user asked to import.
nonisolated enum ImportSource: Sendable {
    /// A file URL. `securityScoped` is true for URLs from `fileImporter`; `isTemporary` marks
    /// copies we made ourselves (drag and drop) that should be removed afterwards.
    case file(URL, securityScoped: Bool, isTemporary: Bool)
    case photo(PhotosPickerItem)
}

struct ImportProgress: Equatable {
    var total: Int
    var completed = 0
    var failed = 0
}

/// What the single full-screen presentation is showing. Using one slot (rather than separate
/// viewer and slideshow covers) lets the viewer switch to a slideshow without a dismiss/present race.
enum FullScreenMode: Equatable {
    case viewer(LibraryItem.ID)
    case slideshow(startingAt: LibraryItem.ID?)
}

struct AlertContent: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// App-wide state: the item list, import/delete actions, and presentation state shared by the
/// views and the menu commands. All storage goes through `LibraryStore`.
@Observable
final class LibraryModel {
    private(set) var items: [LibraryItem] = []
    private(set) var hasLoaded = false
    /// Set when the library can't be opened at all (e.g. App Group misconfigured).
    private(set) var unavailableError: LibraryError?
    private(set) var importProgress: ImportProgress?

    var alert: AlertContent?
    var isSelecting = false
    var selection: Set<LibraryItem.ID> = []
    /// Items awaiting delete confirmation.
    var pendingDeletion: Set<LibraryItem.ID>?

    var isFileImporterPresented = false
    var isPhotosPickerPresented = false
    var fullScreen: FullScreenMode?

    let store: (any LibraryStore)?

    /// Simultaneous imports; each holds at most one large decode in memory.
    private let maxConcurrentImports = 3

    init(store: (any LibraryStore)?, unavailableError: LibraryError? = nil) {
        self.store = store
        self.unavailableError = unavailableError
    }

    /// The model backed by the App Group container.
    static func live() -> LibraryModel {
        do {
            return LibraryModel(store: try FileLibraryStore.appGroup())
        } catch {
            return LibraryModel(store: nil, unavailableError: error)
        }
    }

    // MARK: Loading

    func load() async {
        guard let store else { return }
        do {
            items = try await store.items()
            try await store.removeOrphanedFiles()
        } catch {
            alert = AlertContent(title: "Couldn't Load Library", message: error.localizedDescription)
        }
        hasLoaded = true
    }

    func fileURL(for item: LibraryItem, variant: ImageVariant) -> URL? {
        store?.fileURL(for: item, variant: variant)
    }

    // MARK: Import

    var isImporting: Bool { importProgress != nil }

    func importImages(from sources: [ImportSource]) async {
        guard let store, !sources.isEmpty, !isImporting else { return }
        importProgress = ImportProgress(total: sources.count)
        var failures: [String] = []

        await withTaskGroup(of: Result<LibraryItem, LibraryError>.self) { group in
            var pending = sources.makeIterator()
            func addNext() -> Bool {
                guard let source = pending.next() else { return false }
                group.addTask { await Self.importOne(source, into: store) }
                return true
            }
            for _ in 0..<maxConcurrentImports {
                guard addNext() else { break }
            }

            for await result in group {
                switch result {
                case .success(let item):
                    items.insert(item, at: 0)
                    importProgress?.completed += 1
                case .failure(let error):
                    failures.append(error.localizedDescription)
                    importProgress?.failed += 1
                }
                _ = addNext()
            }
        }

        // Re-read so the order exactly matches the store after concurrent imports.
        if let stored = try? await store.items() { items = stored }
        importProgress = nil
        WidgetCenter.shared.reloadAllTimelines()

        if !failures.isEmpty {
            let shown = failures.prefix(5).joined(separator: "\n\n")
            let more = failures.count > 5 ? "\n\n…and \(failures.count - 5) more." : ""
            let imported = sources.count - failures.count
            alert = AlertContent(
                title: failures.count == 1 ? "1 Image Couldn't Be Imported" : "\(failures.count) Images Couldn't Be Imported",
                message: (imported > 0 ? "\(imported) imported successfully.\n\n" : "") + shown + more)
        }
    }

    /// Resolves the source to a local file and copies it into the store. Runs off the main actor.
    @concurrent
    private static func importOne(_ source: ImportSource, into store: any LibraryStore) async -> Result<LibraryItem, LibraryError> {
        switch source {
        case .file(let url, let securityScoped, let isTemporary):
            let accessing = securityScoped && url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
                if isTemporary { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            }
            return await importFile(at: url, into: store)

        case .photo(let item):
            let file: ImportedImageFile?
            do {
                file = try await item.loadTransferable(type: ImportedImageFile.self)
            } catch {
                return .failure(.fileSystem(filename: "A photo", reason: error.localizedDescription))
            }
            guard let file else {
                return .failure(.unsupportedFormat(filename: "A photo"))
            }
            defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
            return await importFile(at: file.url, into: store)
        }
    }

    private static func importFile(at url: URL, into store: any LibraryStore) async -> Result<LibraryItem, LibraryError> {
        do {
            return .success(try await store.importImage(at: url, filename: url.lastPathComponent))
        } catch {
            return .failure(LibraryError.wrapping(error, filename: url.lastPathComponent))
        }
    }

    func handleFileImporterResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            Task { await importImages(from: urls.map { .file($0, securityScoped: true, isTemporary: false) }) }
        case .failure(let error):
            alert = AlertContent(title: "Couldn't Open Files", message: error.localizedDescription)
        }
    }

    func importPhotos(_ items: [PhotosPickerItem]) {
        Task { await importImages(from: items.map { .photo($0) }) }
    }

    func importDroppedFiles(_ files: [ImportedImageFile]) {
        Task { await importImages(from: files.map { .file($0.url, securityScoped: false, isTemporary: true) }) }
    }

    // MARK: Delete

    /// Asks for confirmation before deleting; see `confirmPendingDeletion()`.
    func requestDelete(_ ids: Set<LibraryItem.ID>) {
        guard !ids.isEmpty else { return }
        pendingDeletion = ids
    }

    func confirmPendingDeletion() async {
        guard let ids = pendingDeletion, let store else { return }
        pendingDeletion = nil
        let previousItems = items
        do {
            try await store.delete(ids)
        } catch {
            alert = AlertContent(title: "Couldn't Delete", message: error.localizedDescription)
        }
        if let stored = try? await store.items() { items = stored }
        selection.subtract(ids)
        if selection.isEmpty { isSelecting = false }
        if case .viewer(let id) = fullScreen, ids.contains(id) {
            // Stay in the viewer on the next surviving image, if there is one.
            let next = previousItems.drop { $0.id != id }.first { !ids.contains($0.id) }
                ?? previousItems.last { !ids.contains($0.id) }
            fullScreen = next.map { .viewer($0.id) }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Selection & navigation

    func toggleSelection(_ id: LibraryItem.ID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func selectAll() {
        isSelecting = true
        selection = Set(items.map(\.id))
    }

    func endSelecting() {
        isSelecting = false
        selection = []
    }

    /// Handles `slate://item/<uuid>` links from the widget.
    func open(_ url: URL) {
        guard url.scheme == "slate", url.host() == "item",
              let id = UUID(uuidString: url.lastPathComponent),
              items.contains(where: { $0.id == id })
        else { return }
        fullScreen = .viewer(id)
    }

    func showViewer(_ id: LibraryItem.ID) {
        fullScreen = .viewer(id)
    }

    func startSlideshow(from id: LibraryItem.ID? = nil) {
        guard !items.isEmpty else { return }
        fullScreen = .slideshow(startingAt: id)
    }

    func closeFullScreen() {
        fullScreen = nil
    }
}

/// A file received from PhotosPicker or drag and drop, copied to a private temp folder
/// because the system deletes the provided file as soon as the handler returns.
nonisolated struct ImportedImageFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "Import-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedImageFile(url: destination)
        }
    }
}
