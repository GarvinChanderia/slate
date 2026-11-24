import ImageIO
import SwiftUI
import WidgetKit

struct SlideshowWidget: Widget {
    static let kind = "SlateSlideshow"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SlideshowIntent.self, provider: SlideshowProvider()) { entry in
            SlideshowWidgetView(entry: entry)
        }
        .configurationDisplayName("Slideshow")
        .description("Rotates through the images in your Slate library.")
        .supportedFamilies(Self.families)
        // Photos are full-bleed; text states apply the system margins themselves.
        .contentMarginsDisabled()
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        // systemExtraLarge only appears on iPad.
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        #endif
    }
}

struct SlideshowWidgetView: View {
    let entry: SlideEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.displayScale) private var displayScale
    @Environment(\.widgetContentMargins) private var contentMargins

    var body: some View {
        GeometryReader { geometry in
            content(in: geometry.size)
        }
        .containerBackground(for: .widget) { background }
        .widgetURL(deepLink)
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        switch entry.content {
        case .image(_, let url):
            photo(at: url, size: size)
        case .sample:
            photo(at: Bundle.main.url(forResource: "SampleImage", withExtension: "jpg"), size: size)
        case .emptyLibrary:
            message(isAccessory ? "Add images in Slate" : "Add images in Slate to start your slideshow",
                    systemImage: "photo.on.rectangle.angled")
        case .unavailable:
            message("Open Slate to set up its library", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private func photo(at url: URL?, size: CGSize) -> some View {
        let fit = isAccessory ? .fill : entry.fit
        let pixelSize = CGSize(width: size.width * displayScale, height: size.height * displayScale)
        if let url, let cgImage = WidgetImage.load(url, pixelSize: pixelSize, fit: fit, verticalFocus: verticalFocus) {
            let image = Image(decorative: cgImage, scale: displayScale)
            Group {
                switch fit {
                case .fill:
                    // Already cropped to the widget's aspect ratio, so this just scales.
                    image
                        .resizable()
                        .widgetAccentedRenderingMode(.accentedDesaturated)
                        .scaledToFill()
                case .fit:
                    // Letterboxed over the image's average colour. (Blur isn't reliably applied
                    // in archived widget renders, so it isn't used here.)
                    image
                        .resizable()
                        .widgetAccentedRenderingMode(.accentedDesaturated)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(WidgetImage.averageColor(of: cgImage))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: isAccessory ? 8 : 0))
        } else {
            // The file was deleted after this timeline was built; the app reloads us shortly.
            message("Image unavailable", systemImage: "photo.badge.exclamationmark")
        }
    }

    private func message(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Group {
            if isAccessory {
                Label(text, systemImage: systemImage)
                    .font(.caption)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(family == .systemSmall ? .title2 : .largeTitle)
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(family == .systemSmall ? .caption : .subheadline)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(contentMargins) // Margins are disabled for photos, so restore them for text.
    }

    @ViewBuilder
    private var background: some View {
        switch entry.content {
        case .image, .sample:
            if isAccessory { Color.clear } else { Color.black }
        case .emptyLibrary, .unavailable:
            if isAccessory { AccessoryWidgetBackground() } else { Color("WidgetBackground") }
        }
    }

    /// The lock-screen rectangular family (iOS only).
    private var isAccessory: Bool {
        #if os(iOS)
        family == .accessoryRectangular
        #else
        false
        #endif
    }

    /// Where the crop is centred vertically when a tall image fills a wider widget. Medium is a
    /// wide strip, so it biases further up, where subjects (faces, horizons) usually sit.
    private var verticalFocus: CGFloat {
        family == .systemMedium ? 0.38 : 0.45
    }

    private var deepLink: URL? {
        if case .image(let id, _) = entry.content {
            return URL(string: "slate://item/\(id.uuidString)")
        }
        return URL(string: "slate://library")
    }
}

/// Produces the bitmap a widget displays, sized to the widget itself.
///
/// This matters for two reasons: widget extensions have a tight memory limit, and WidgetKit
/// refuses to archive images much larger than the widget (`imageTooLarge`). So the ≤1200 px
/// derivative is downsampled to the needed size and, for Fill, cropped to the widget's aspect
/// ratio, so a panorama in a small widget is never larger than the widget's pixel size.
enum WidgetImage {
    static func load(_ url: URL, pixelSize target: CGSize, fit: ImageFit, verticalFocus: CGFloat) -> CGImage? {
        guard target.width > 0, target.height > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0
        else { return nil }

        // Derivatives are stored upright, so pixel width/height are display width/height.
        let aspectRatio = width / height
        // Scale for an image normalised to height 1 (width = aspectRatio) to fill or fit the target.
        let scale = fit == .fill
            ? max(target.width / aspectRatio, target.height)
            : min(target.width / aspectRatio, target.height)
        let neededLongEdge = Int((scale * max(aspectRatio, 1)).rounded(.up))
        let maxPixelSize = min(ImageProcessor.widgetMaxPixelSize, max(neededLongEdge, 32))

        guard let image = ImageProcessor.downsampledImage(from: source, maxPixelSize: maxPixelSize) else { return nil }
        guard fit == .fill else { return image }
        return crop(image, toAspectRatio: target.width / target.height, verticalFocus: verticalFocus)
    }

    /// The mean colour of `image`, slightly darkened, for letterbox bars.
    static func averageColor(of image: CGImage) -> Color {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .black }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let darken = 0.75
        return Color(.sRGB,
                     red: Double(pixel[0]) / 255 * darken,
                     green: Double(pixel[1]) / 255 * darken,
                     blue: Double(pixel[2]) / 255 * darken)
    }

    /// Crops horizontally around the centre, vertically around `verticalFocus` (0 = top).
    static func crop(_ image: CGImage, toAspectRatio targetAspect: Double, verticalFocus: CGFloat) -> CGImage {
        let width = Double(image.width)
        let height = Double(image.height)
        let rect: CGRect
        if width / height > targetAspect {
            let cropWidth = height * targetAspect
            rect = CGRect(x: (width - cropWidth) / 2, y: 0, width: cropWidth, height: height)
        } else {
            let cropHeight = width / targetAspect
            let y = min(max(verticalFocus * height - cropHeight / 2, 0), height - cropHeight)
            rect = CGRect(x: 0, y: y, width: width, height: cropHeight)
        }
        return image.cropping(to: rect.integral) ?? image
    }
}

#Preview("Small", as: .systemSmall) {
    SlideshowWidget()
} timeline: {
    SlideEntry(date: .now, content: .sample)
    SlideEntry(date: .now, content: .emptyLibrary)
}

#Preview("Medium", as: .systemMedium) {
    SlideshowWidget()
} timeline: {
    SlideEntry(date: .now, content: .sample)
    SlideEntry(date: .now, content: .sample, fit: .fit)
}

#Preview("Large", as: .systemLarge) {
    SlideshowWidget()
} timeline: {
    SlideEntry(date: .now, content: .sample)
}

#if os(iOS)
#Preview("Lock Screen", as: .accessoryRectangular) {
    SlideshowWidget()
} timeline: {
    SlideEntry(date: .now, content: .sample)
    SlideEntry(date: .now, content: .emptyLibrary)
}
#endif
