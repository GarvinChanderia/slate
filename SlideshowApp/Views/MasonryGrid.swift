import SwiftUI

/// Pinterest-style masonry layout: items are placed greedily into the shortest column, using
/// each item's stored aspect ratio so the layout is stable before any thumbnail loads.
///
/// Each column is its own `LazyVStack`, so only on-screen cells are created, which keeps
/// scrolling smooth with thousands of items.
struct MasonryGrid<Cell: View>: View {
    let items: [LibraryItem]
    let columnCount: Int
    let spacing: CGFloat
    @ViewBuilder let cell: (LibraryItem) -> Cell

    var body: some View {
        let columns = Self.distribute(items, into: columnCount)
        HStack(alignment: .top, spacing: spacing) {
            ForEach(columns.indices, id: \.self) { index in
                LazyVStack(spacing: spacing) {
                    ForEach(columns[index]) { item in
                        cell(item)
                    }
                }
            }
        }
    }

    /// Assigns items to columns in order, each to the currently shortest column.
    static func distribute(_ items: [LibraryItem], into columnCount: Int) -> [[LibraryItem]] {
        let count = max(1, columnCount)
        var columns = Array(repeating: [LibraryItem](), count: count)
        var heights = Array(repeating: 0.0, count: count)
        for item in items {
            // Clamp extreme panoramas/strips so one image can't dominate a column.
            let height = 1 / min(max(item.aspectRatio, 0.4), 2.5)
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[shortest].append(item)
            heights[shortest] += height
        }
        return columns
    }
}

/// One grid cell: the thumbnail at the item's aspect ratio plus a selection badge.
struct ThumbnailCell: View {
    let item: LibraryItem
    let url: URL?
    let isSelecting: Bool
    let isSelected: Bool

    @State private var image: CGImage?

    init(item: LibraryItem, url: URL?, isSelecting: Bool, isSelected: Bool) {
        self.item = item
        self.url = url
        self.isSelecting = isSelecting
        self.isSelected = isSelected
        // Show an already-decoded thumbnail immediately (no flash when scrolling back).
        _image = State(initialValue: url.flatMap { ImageLoader.shared.cachedThumbnail(at: $0) })
    }

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(min(max(item.aspectRatio, 0.4), 2.5), contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.3))
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .contentShape(.rect(cornerRadius: 8))
            .task(id: url) {
                guard image == nil, let url else { return }
                let loaded = await ImageLoader.shared.thumbnail(at: url)
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
            .accessibilityElement()
            .accessibilityLabel(item.filename)
            .accessibilityAddTraits(.isImage)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
