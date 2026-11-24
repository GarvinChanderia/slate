import CoreGraphics
import Foundation

/// Decodes images for display, always off the main thread, with an in-memory cache.
///
/// Grid thumbnails are already ~400 px JPEGs, so decoding them is cheap; the cache keeps scrolling
/// back up from re-decoding. Viewer images are downsampled from the original to screen size.
nonisolated final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    /// Long edge for full-screen viewing: sharp on Retina displays and at moderate zoom without
    /// decoding a 48 MP original at full size.
    static let viewerMaxPixelSize = 3072

    // NSCache is thread-safe, which is what makes the @unchecked Sendable above sound.
    private let thumbnails = NSCache<NSURL, CGImage>()
    private let viewerImages = NSCache<NSURL, CGImage>()

    private init() {
        thumbnails.countLimit = 600
        viewerImages.countLimit = 6
    }

    func cachedThumbnail(at url: URL) -> CGImage? {
        thumbnails.object(forKey: url as NSURL)
    }

    func cachedViewerImage(at url: URL) -> CGImage? {
        viewerImages.object(forKey: url as NSURL)
    }

    func thumbnail(at url: URL) async -> CGImage? {
        if let cached = cachedThumbnail(at: url) { return cached }
        guard let image = await ImageProcessor.loadImage(at: url, maxPixelSize: ImageProcessor.thumbnailMaxPixelSize) else {
            return nil
        }
        thumbnails.setObject(image, forKey: url as NSURL)
        return image
    }

    func viewerImage(at url: URL) async -> CGImage? {
        if let cached = cachedViewerImage(at: url) { return cached }
        guard let image = await ImageProcessor.loadImage(at: url, maxPixelSize: Self.viewerMaxPixelSize) else {
            return nil
        }
        viewerImages.setObject(image, forKey: url as NSURL)
        return image
    }

    func removeAll() {
        thumbnails.removeAllObjects()
        viewerImages.removeAllObjects()
    }
}
