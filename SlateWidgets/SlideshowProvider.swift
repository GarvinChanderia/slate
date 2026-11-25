import Foundation
import WidgetKit

struct SlideEntry: TimelineEntry {
    enum Content {
        /// A library image. Only the URL is stored: the image is decoded when the entry is
        /// rendered, so a 48-entry timeline never holds 48 decoded bitmaps in memory.
        case image(id: UUID, url: URL)
        /// Bundled sample, for the widget gallery and placeholders.
        case sample
        case emptyLibrary
        case unavailable
    }

    let date: Date
    let content: Content
    var fit: ImageFit = .fill

    var showsLibraryImage: Bool {
        if case .image = content { true } else { false }
    }
}

/// Builds a long timeline of upcoming images from the shared library. Reads only `index.json`
/// and returns URLs of the widget-sized derivatives; originals are never touched.
struct SlideshowProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SlideEntry {
        SlideEntry(date: .now, content: .sample)
    }

    func snapshot(for configuration: SlideshowIntent, in context: Context) async -> SlideEntry {
        let entry = await makeEntries(for: configuration, family: context.family, count: 1).first
            ?? SlideEntry(date: .now, content: .emptyLibrary)
        // The widget gallery shows the sample image until the library has something to show.
        if context.isPreview && !entry.showsLibraryImage {
            return SlideEntry(date: .now, content: .sample, fit: configuration.fit)
        }
        return entry
    }

    func timeline(for configuration: SlideshowIntent, in context: Context) async -> Timeline<SlideEntry> {
        let count = Self.entryCount(for: configuration.interval, displaySize: context.displaySize)
        let entries = await makeEntries(for: configuration, family: context.family, count: count)
        guard entries.first?.showsLibraryImage == true else {
            // Nothing to rotate. The app reloads all timelines after every import.
            return Timeline(entries: entries, policy: .never)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    /// How many entries fit in one timeline for a widget of `displaySize` points.
    ///
    /// WidgetKit renders every entry up front and archives the bitmaps; if the archive passes
    /// roughly 10 MB, chronod rejects the reload ("too large timeline archive"), leaves the widget
    /// on a blank placeholder, and backs off retries for 15+ minutes. Each photo entry measured
    /// ~0.5 bytes per pixel (48 Large entries on a Retina Mac = 11 MB), so the count is capped to
    /// keep the archive near `archiveBudget`, leaving headroom for photos that compress poorly.
    static func entryCount(for interval: RotationInterval, displaySize: CGSize) -> Int {
        #if os(iOS)
        let scale = 3.0
        #else
        let scale = 2.0
        #endif
        let archiveBudget = 4.0 * 1024 * 1024
        let bytesPerEntry = max(displaySize.width * displaySize.height * scale * scale * 0.5, 1)
        let fitting = Int(archiveBudget / bytesPerEntry)
        return min(interval.entryCount, max(fitting, 3))
    }

    private func makeEntries(for configuration: SlideshowIntent, family: WidgetFamily, count: Int) async -> [SlideEntry] {
        let now = Date.now
        let store: FileLibraryStore
        let items: [LibraryItem]
        do {
            store = try FileLibraryStore.appGroup()
            items = try await store.items()
        } catch {
            return [SlideEntry(date: now, content: .unavailable)]
        }
        guard !items.isEmpty else {
            return [SlideEntry(date: now, content: .emptyLibrary)]
        }

        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let schedule = RotationSchedule(
            interval: configuration.interval.seconds,
            order: configuration.order == .shuffle ? .shuffle : .newestFirst,
            itemIDs: items.map(\.id),
            shuffleSalt: RotationSchedule.stableHash(String(describing: family)))

        return schedule.entries(startingAt: now, count: count).compactMap { slot in
            guard let item = itemsByID[slot.itemID] else { return nil }
            return SlideEntry(date: slot.date,
                              content: .image(id: item.id, url: store.fileURL(for: item, variant: .widget)),
                              fit: configuration.fit)
        }
    }
}
