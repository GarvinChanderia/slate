import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image decoding, downsampling, and encoding built on ImageIO, shared by the app, the widget,
/// and the tests. Nothing here touches UIKit/AppKit, so it's identical on iOS and macOS.
nonisolated enum ImageProcessor {
    static let supportedTypes: [UTType] = [.heic, .heif, .jpeg, .png]
    static let thumbnailMaxPixelSize = 400
    static let widgetMaxPixelSize = 1200

    struct SourceInfo: Sendable {
        let type: UTType
        /// Pixel size with EXIF orientation applied.
        let pixelWidth: Int
        let pixelHeight: Int

        /// Extension used for the stored original.
        var fileExtension: String {
            switch type {
            case .jpeg: "jpg"
            case .png: "png"
            case .heif: "heif"
            default: "heic"
            }
        }
    }

    /// Validates that `url` is a readable HEIC/JPEG/PNG and returns its type and display size.
    static func inspect(_ url: URL, filename: String) throws(LibraryError) -> SourceInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier)
        else {
            // ImageIO couldn't identify the bytes at all. If the name claims an image type we
            // support, the file is damaged; otherwise it's simply not an image we handle.
            if let claimed = UTType(filenameExtension: url.pathExtension),
               supportedTypes.contains(where: { claimed.conforms(to: $0) }) {
                throw .corruptImage(filename: filename)
            }
            throw .unsupportedFormat(filename: filename)
        }
        guard supportedTypes.contains(where: { type.conforms(to: $0) }) else {
            throw .unsupportedFormat(filename: filename)
        }
        guard CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            throw .corruptImage(filename: filename)
        }
        // Orientations 5–8 rotate the image by 90°, swapping the displayed width and height.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let isRotated = (5...8).contains(orientation)
        return SourceInfo(type: type,
                          pixelWidth: isRotated ? height : width,
                          pixelHeight: isRotated ? width : height)
    }

    /// Decodes a downsampled, upright image. Decoding is forced here (not lazily at draw time),
    /// so call this off the main thread in the app.
    static func downsampledImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return downsampledImage(from: source, maxPixelSize: maxPixelSize)
    }

    static func downsampledImage(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Async wrapper that always runs on the global concurrent executor, never the caller's actor.
    @concurrent
    static func loadImage(at url: URL, maxPixelSize: Int) async -> CGImage? {
        downsampledImage(at: url, maxPixelSize: maxPixelSize)
    }

    /// Encodes `image` as JPEG data.
    static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Writes the widget-sized and thumbnail JPEGs for the image at `sourceURL`.
    /// Runs on the global concurrent executor so imports never block the caller's actor.
    @concurrent
    static func writeDerivatives(from sourceURL: URL, filename: String, widgetURL: URL, thumbnailURL: URL) async throws(LibraryError) {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let widgetImage = downsampledImage(from: source, maxPixelSize: widgetMaxPixelSize),
              // A truncated JPEG still decodes (grey-filled) but reports unexpected EOF afterwards.
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let widgetData = jpegData(from: widgetImage, quality: 0.85)
        else {
            throw .corruptImage(filename: filename)
        }
        // The thumbnail is derived from the small JPEG rather than the original: far cheaper
        // than decoding a 48 MP HEIC a second time, and visually identical at 400 px.
        guard let widgetSource = CGImageSourceCreateWithData(widgetData as CFData, nil),
              let thumbnail = downsampledImage(from: widgetSource, maxPixelSize: thumbnailMaxPixelSize),
              let thumbnailData = jpegData(from: thumbnail, quality: 0.8)
        else {
            throw .corruptImage(filename: filename)
        }
        do {
            try widgetData.write(to: widgetURL, options: .atomic)
            try thumbnailData.write(to: thumbnailURL, options: .atomic)
        } catch {
            throw LibraryError.wrapping(error, filename: filename)
        }
    }
}
