import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Tests for `FileLibraryStore`. The Shared folder is compiled directly into this bundle, so the
/// tests don't need a host app or App Group entitlement; each test uses its own temp directory.
struct LibraryStoreTests {
    let workDirectory: URL
    let store: FileLibraryStore

    init() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SlateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        store = FileLibraryStore(rootURL: workDirectory.appending(path: "Library", directoryHint: .isDirectory))
    }

    // MARK: Import

    @Test func importCopiesOriginalAndGeneratesDerivatives() async throws {
        let source = try makeImageFile(named: "beach.jpg", width: 3000, height: 2000, type: .jpeg)

        let item = try await store.importImage(at: source, filename: nil)

        #expect(item.filename == "beach.jpg")
        #expect(item.pixelWidth == 3000)
        #expect(item.pixelHeight == 2000)
        #expect(item.isFavorite == false)

        let originalURL = store.fileURL(for: item, variant: .original)
        #expect(try Data(contentsOf: originalURL) == Data(contentsOf: source), "Original must be a byte-for-byte copy")

        let thumbnailSize = try pixelSize(of: store.fileURL(for: item, variant: .thumbnail))
        #expect(max(thumbnailSize.width, thumbnailSize.height) == ImageProcessor.thumbnailMaxPixelSize)
        #expect(thumbnailSize.width > thumbnailSize.height, "Aspect ratio is preserved")

        let widgetURL = store.fileURL(for: item, variant: .widget)
        let widgetSize = try pixelSize(of: widgetURL)
        #expect(max(widgetSize.width, widgetSize.height) == ImageProcessor.widgetMaxPixelSize)
        #expect(try imageType(of: widgetURL) == .jpeg)

        #expect(try await store.items() == [item])
    }

    @Test func importSurvivesDeletionOfSource() async throws {
        let source = try makeImageFile(named: "photo.png", width: 800, height: 600, type: .png)
        let item = try await store.importImage(at: source, filename: nil)

        try FileManager.default.removeItem(at: source)

        for variant in ImageVariant.allCases {
            #expect(FileManager.default.fileExists(atPath: store.fileURL(for: item, variant: variant).path()))
        }
        #expect(item.originalFileExtension == "png")
    }

    @Test func smallImagesAreNotUpscaled() async throws {
        let source = try makeImageFile(named: "small.png", width: 300, height: 200, type: .png)
        let item = try await store.importImage(at: source, filename: nil)

        let widgetSize = try pixelSize(of: store.fileURL(for: item, variant: .widget))
        #expect(widgetSize.width == 300 && widgetSize.height == 200)
    }

    @Test func exifRotationSwapsRecordedPixelSize() async throws {
        // Orientation 6 = rotated 90° clockwise: a 400×300 sensor image displays as 300×400.
        let source = try makeImageFile(named: "rotated.jpg", width: 400, height: 300, type: .jpeg, orientation: 6)
        let item = try await store.importImage(at: source, filename: nil)

        #expect(item.pixelWidth == 300)
        #expect(item.pixelHeight == 400)
        let thumbnailSize = try pixelSize(of: store.fileURL(for: item, variant: .thumbnail))
        #expect(thumbnailSize.height > thumbnailSize.width, "Derivatives are stored upright")
    }

    @Test func itemsAreSortedNewestFirstAndPersisted() async throws {
        let first = try await store.importImage(at: makeImageFile(named: "a.jpg", width: 50, height: 50, type: .jpeg), filename: nil)
        let second = try await store.importImage(at: makeImageFile(named: "b.jpg", width: 50, height: 50, type: .jpeg), filename: "Custom.jpg")

        #expect(try await store.items().map(\.id) == [second.id, first.id])
        #expect(second.filename == "Custom.jpg")

        let reopened = FileLibraryStore(rootURL: store.rootURL)
        #expect(try await reopened.items() == store.items())
    }

    @Test func concurrentImportsAreAllRecorded() async throws {
        let sources = try (0..<8).map { try makeImageFile(named: "img\($0).jpg", width: 600, height: 400, type: .jpeg) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { _ = try await store.importImage(at: source, filename: nil) }
            }
            try await group.waitForAll()
        }

        #expect(try await store.items().count == sources.count)
        #expect(try await FileLibraryStore(rootURL: store.rootURL).items().count == sources.count)
    }

    // MARK: Errors

    @Test func corruptImageIsRejectedAndLeavesNoFiles() async throws {
        let source = workDirectory.appending(path: "broken.jpg")
        try Data("definitely not a jpeg".utf8).write(to: source)

        await #expect(throws: LibraryError.corruptImage(filename: "broken.jpg")) {
            try await store.importImage(at: source, filename: nil)
        }
        #expect(try await store.items().isEmpty)
        #expect(try storedFileCount() == 0)
    }

    /// A file cut off inside its header can't be decoded at all. (ImageIO's downsampler tolerates
    /// files truncated later in the pixel data; see "Known limits" in the README.)
    @Test(arguments: [UTType.jpeg, .png])
    func truncatedImageIsRejected(type: UTType) async throws {
        let name = "truncated.\(type.preferredFilenameExtension ?? "img")"
        let source = try makeImageFile(named: name, width: 1000, height: 1000, type: type)
        let data = try Data(contentsOf: source)
        try data.prefix(64).write(to: source)

        await #expect(throws: LibraryError.self) {
            try await store.importImage(at: source, filename: nil)
        }
        #expect(try storedFileCount() == 0)
    }

    @Test func unsupportedFormatIsRejected() async throws {
        let source = try makeImageFile(named: "anim.gif", width: 20, height: 20, type: .gif)

        await #expect(throws: LibraryError.unsupportedFormat(filename: "anim.gif")) {
            try await store.importImage(at: source, filename: nil)
        }
        #expect(try await store.items().isEmpty)
    }

    @Test func diskFullErrorsAreRecognised() {
        let cocoa = CocoaError(.fileWriteOutOfSpace)
        #expect(LibraryError.wrapping(cocoa, filename: "x") == .diskFull)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(LibraryError.wrapping(posix, filename: "x") == .diskFull)
    }

    // MARK: Delete

    @Test func deleteRemovesOriginalAndAllDerivatives() async throws {
        let keep = try await store.importImage(at: makeImageFile(named: "keep.jpg", width: 500, height: 500, type: .jpeg), filename: nil)
        let doomed = try await store.importImage(at: makeImageFile(named: "doomed.png", width: 500, height: 500, type: .png), filename: nil)

        try await store.delete([doomed.id])

        for variant in ImageVariant.allCases {
            #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: doomed, variant: variant).path()))
            #expect(FileManager.default.fileExists(atPath: store.fileURL(for: keep, variant: variant).path()))
        }
        #expect(try await store.items() == [keep])
        #expect(try await FileLibraryStore(rootURL: store.rootURL).items() == [keep])
        #expect(try storedFileCount() == ImageVariant.allCases.count)
    }

    @Test func multiDeleteEmptiesLibrary() async throws {
        var ids: Set<UUID> = []
        for index in 0..<3 {
            ids.insert(try await store.importImage(at: makeImageFile(named: "\(index).jpg", width: 100, height: 100, type: .jpeg), filename: nil).id)
        }

        try await store.delete(ids)

        #expect(try await store.items().isEmpty)
        #expect(try storedFileCount() == 0)
    }

    @Test func removeOrphanedFilesKeepsIndexedItems() async throws {
        let item = try await store.importImage(at: makeImageFile(named: "a.jpg", width: 100, height: 100, type: .jpeg), filename: nil)
        let orphan = store.directoryURL(for: .widget).appending(path: "\(UUID().uuidString).jpg")
        try Data([0]).write(to: orphan)

        #expect(try await store.removeOrphanedFiles() == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path()))
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: item, variant: .widget).path()))
    }

    @Test func favoriteIsPersisted() async throws {
        let item = try await store.importImage(at: makeImageFile(named: "a.jpg", width: 100, height: 100, type: .jpeg), filename: nil)
        try await store.setFavorite(true, for: item.id)
        #expect(try await FileLibraryStore(rootURL: store.rootURL).items().first?.isFavorite == true)
    }

    // MARK: Helpers

    private func makeImageFile(named name: String, width: Int, height: Int, type: UTType, orientation: Int? = nil) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
        let image = try #require(context.makeImage())

        let url = workDirectory.appending(path: name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixelSize(of url: URL) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try #require(properties[kCGImagePropertyPixelWidth] as? Int),
                try #require(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    private func imageType(of url: URL) throws -> UTType? {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return (CGImageSourceGetType(source) as String?).flatMap(UTType.init)
    }

    /// Total files across Originals/, Thumbnails/, and Widget/.
    private func storedFileCount() throws -> Int {
        try ImageVariant.allCases.reduce(0) { count, variant in
            let directory = store.directoryURL(for: variant)
            guard FileManager.default.fileExists(atPath: directory.path()) else { return count }
            return count + (try FileManager.default.contentsOfDirectory(atPath: directory.path()).count)
        }
    }
}
