import Foundation

/// Metadata for one image in the library. The image files themselves live on disk,
/// addressed through `LibraryStore.fileURL(for:variant:)`.
nonisolated struct LibraryItem: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    /// The name the file had when it was imported (display only).
    var filename: String
    /// Extension of the stored original, e.g. `heic`, `jpg`, `png`.
    var originalFileExtension: String
    var importDate: Date
    /// Pixel size with EXIF orientation applied (i.e. as displayed).
    var pixelWidth: Int
    var pixelHeight: Int
    /// Unused in v1; reserved for a favorites filter.
    var isFavorite: Bool

    /// Width divided by height, used for masonry layout before the thumbnail has loaded.
    var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

/// The files stored for each item.
nonisolated enum ImageVariant: String, CaseIterable, Sendable {
    /// The imported file, byte-for-byte.
    case original
    /// ~400 px JPEG for the library grid.
    case thumbnail
    /// ≤1200 px JPEG; the only variant the widget extension ever reads.
    case widget
}
