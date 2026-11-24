import SwiftUI

/// Full-screen image viewer: horizontal paging (swipe / trackpad / arrow keys), pinch or
/// double-tap to zoom, and delete/slideshow actions.
struct ViewerView: View {
    let model: LibraryModel

    @State private var scrolledID: LibraryItem.ID?
    @State private var zoomedID: LibraryItem.ID?
    @State private var showsChrome = true
    @FocusState private var isFocused: Bool

    init(model: LibraryModel, initialID: LibraryItem.ID) {
        self.model = model
        _scrolledID = State(initialValue: initialID)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(model.items) { item in
                    ZoomableImageView(
                        originalURL: model.fileURL(for: item, variant: .original),
                        placeholderURL: model.fileURL(for: item, variant: .thumbnail),
                        isZoomed: zoomBinding(for: item.id),
                        onSingleTap: { withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() } }
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                    .accessibilityLabel(item.filename)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrolledID)
        .scrollDisabled(zoomedID != nil)
        .scrollIndicators(.hidden)
        .background(.black)
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if showsChrome { chrome.transition(.opacity) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) { step(by: -1); return .handled }
        .onKeyPress(.rightArrow) { step(by: 1); return .handled }
        .onKeyPress(.escape) { model.closeFullScreen(); return .handled }
        .onAppear { isFocused = true }
        .onChange(of: scrolledID) { _, id in
            // Keep the model in sync so menu commands (Delete, Slideshow) act on the visible image.
            if let id, model.fullScreen != .viewer(id) { model.fullScreen = .viewer(id) }
        }
        .onChange(of: model.fullScreen) { _, mode in
            // After a delete the model moves to a neighbouring image.
            if case .viewer(let id) = mode, id != scrolledID { scrolledID = id }
        }
        #if os(iOS)
        .statusBarHidden(!showsChrome)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        #endif
        .libraryDialogs(model: model, isActive: FullScreen.hostsOwnDialogs)
    }

    private var currentIndex: Int? {
        model.items.firstIndex { $0.id == scrolledID }
    }

    private var chrome: some View {
        HStack(spacing: 12) {
            Button("Close", systemImage: "xmark") { model.closeFullScreen() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if let currentIndex {
                VStack(spacing: 2) {
                    Text(model.items[currentIndex].filename)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(currentIndex + 1) of \(model.items.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Slideshow", systemImage: "play.fill") { model.startSlideshow(from: scrolledID) }
            Button("Delete", systemImage: "trash", role: .destructive) {
                if let scrolledID { model.requestDelete([scrolledID]) }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private func step(by delta: Int) {
        guard zoomedID == nil, let currentIndex else { return }
        let target = currentIndex + delta
        guard model.items.indices.contains(target) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            scrolledID = model.items[target].id
        }
    }

    private func zoomBinding(for id: LibraryItem.ID) -> Binding<Bool> {
        Binding(get: { zoomedID == id },
                set: { isZoomed in
                    if isZoomed { zoomedID = id } else if zoomedID == id { zoomedID = nil }
                })
    }
}

/// One page of the viewer. Shows the cached grid thumbnail instantly, then a screen-sized
/// decode of the original (done off the main thread).
struct ZoomableImageView: View {
    let originalURL: URL?
    let placeholderURL: URL?
    @Binding var isZoomed: Bool
    var onSingleTap: () -> Void = {}

    @State private var image: CGImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let maxScale: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(.rect)
                .gesture(magnifyGesture(in: geometry.size))
                .gesture(panGesture(in: geometry.size), isEnabled: scale > 1)
                .onTapGesture(count: 2) { toggleZoom() }
                .onTapGesture(count: 1) { onSingleTap() }
        }
        .task(id: originalURL) { await load() }
        .onChange(of: scale) { _, newValue in
            let zoomed = newValue > 1.01
            if zoomed != isZoomed { isZoomed = zoomed }
        }
        .onDisappear { resetZoom(animated: false) }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
        } else if failed {
            ContentUnavailableView("Image Unavailable", systemImage: "exclamationmark.triangle")
                .environment(\.colorScheme, .dark)
        } else {
            ProgressView().tint(.white)
        }
    }

    private func load() async {
        if let placeholderURL, image == nil {
            image = ImageLoader.shared.cachedThumbnail(at: placeholderURL)
        }
        guard let originalURL else { failed = true; return }
        if let full = await ImageLoader.shared.viewerImage(at: originalURL) {
            image = full
        } else if image == nil {
            failed = true
        }
    }

    // MARK: Gestures

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(committedScale * value.magnification, 0.8), maxScale)
                offset = clamped(committedOffset, in: size)
            }
            .onEnded { _ in
                if scale <= 1 {
                    resetZoom(animated: true)
                } else {
                    committedScale = scale
                    committedOffset = offset
                }
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clamped(CGSize(width: committedOffset.width + value.translation.width,
                                        height: committedOffset.height + value.translation.height), in: size)
            }
            .onEnded { _ in committedOffset = offset }
    }

    /// Keeps the zoomed image covering the frame instead of panning off into black.
    private func clamped(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }

    private func toggleZoom() {
        if scale > 1 {
            resetZoom(animated: true)
        } else {
            withAnimation(.spring(duration: 0.3)) {
                scale = 2.5
                committedScale = 2.5
            }
        }
    }

    private func resetZoom(animated: Bool) {
        withAnimation(animated ? .spring(duration: 0.3) : nil) {
            scale = 1
            committedScale = 1
            offset = .zero
            committedOffset = .zero
        }
    }
}
