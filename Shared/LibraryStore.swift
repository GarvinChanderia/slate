import Foundation

/// Storage abstraction for the image library.
///
/// The UI and the widget only talk to this protocol, so a different backend (for example one
/// that mirrors an iCloud Drive folder) can be added later without touching either.
/// Implementations must perform file IO and image processing off the main actor.
nonisolated protocol LibraryStore: Sendable {
    /// All items, newest first.
    func items() async throws -> [LibraryItem]

    /// Copies the image at `sourceURL` into the library, generating the grid thumbnail and
    /// widget derivative. The source file is never modified or referenced afterwards.
    /// - Parameter filename: Display name to record; defaults to the source's last path component.
    func importImage(at sourceURL: URL, filename: String?) async throws -> LibraryItem

    /// Removes the items and every file stored for them.
    func delete(_ ids: Set<LibraryItem.ID>) async throws

    func setFavorite(_ isFavorite: Bool, for id: LibraryItem.ID) async throws

    /// Deletes stored files that no item refers to (left behind by a crash mid-import or
    /// mid-delete). Returns the number of files removed.
    @discardableResult
    func removeOrphanedFiles() async throws -> Int

    /// Location of a stored file. Callers must not assume the file exists (it may have been
    /// deleted by another process since the item list was read).
    func fileURL(for item: LibraryItem, variant: ImageVariant) -> URL
}

/// Errors surfaced to the user. Messages are written to be shown directly in an alert.
nonisolated enum LibraryError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat(filename: String)
    case corruptImage(filename: String)
    case diskFull
    case containerUnavailable
    case fileSystem(filename: String?, reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let filename):
            "“\(filename)” isn't a supported format. Slate supports HEIC, JPEG, and PNG."
        case .corruptImage(let filename):
            "“\(filename)” couldn't be read. The file may be damaged or incomplete."
        case .diskFull:
            "There isn't enough storage space to import this image."
        case .containerUnavailable:
            "Slate's shared storage (App Group) is unavailable. Check the App Group ID and signing team in Config/Slate.xcconfig."
        case .fileSystem(let filename, let reason):
            if let filename { "“\(filename)” couldn't be saved: \(reason)" } else { "A file operation failed: \(reason)" }
        }
    }

    /// Maps a Foundation/POSIX error to a user-facing error, recognising "disk full".
    static func wrapping(_ error: any Error, filename: String?) -> LibraryError {
        if let libraryError = error as? LibraryError { return libraryError }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
            return .diskFull
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) {
            return .diskFull
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC) {
            return .diskFull
        }
        return .fileSystem(filename: filename, reason: nsError.localizedDescription)
    }
}
