import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Full-screen, auto-advancing slideshow with adjustable interval and shuffle.
/// Each next image is decoded before the cross-fade, so transitions never show a spinner.
struct SlideshowView: View {
    let model: LibraryModel
    let startID: LibraryItem.ID?

    @AppStorage("slideshow.interval") private var interval: Double = 5
    @AppStorage("slideshow.shuffle") private var shuffle = false

    @State private var order: [LibraryItem] = []
    @State private var position = 0
    @State private var image: CGImage?
    @State private var isPaused = false
    @State private var showsControls = true
    @State private var hideControlsTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool
    #if os(macOS)
    @State private var enteredFullScreen = false
    @State private var displaySleepActivity: (any NSObjectProtocol)?
    #endif

    static let intervals: [Double] = [3, 5, 10, 15, 30, 60]

    var body: some View {
        ZStack {
            Color.black
            if let image, order.indices.contains(position) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .id(order[position].id)
                    .transition(.opacity)
                    .accessibilityLabel(order[position].filename)
            } else if order.isEmpty {
                Text("No images").foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .onTapGesture { toggleControls() }
        .overlay(alignment: .bottom) {
            if showsControls { controls.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.space) { isPaused.toggle(); return .handled }
        .onKeyPress(.leftArrow) { Task { await advance(by: -1) }; return .handled }
        .onKeyPress(.rightArrow) { Task { await advance(by: 1) }; return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        // Restarts whenever playback settings change; cancelled automatically on dismiss.
        .task(id: PlaybackKey(interval: interval, isPaused: isPaused, position: position)) {
            guard !isPaused, order.count > 1 else { return }
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await advance(by: 1)
        }
        .task { await start() }
        .onChange(of: shuffle) { _, _ in rebuildOrder(keeping: order.indices.contains(position) ? order[position].id : nil) }
        .onChange(of: model.items) { _, _ in rebuildOrder(keeping: order.indices.contains(position) ? order[position].id : nil) }
        .onAppear {
            isFocused = true
            scheduleControlsHide()
            setSystemSleepDisabled(true)
        }
        .onDisappear {
            hideControlsTask?.cancel()
            setSystemSleepDisabled(false)
            #if os(macOS)
            if enteredFullScreen { NSApp.keyWindow?.toggleFullScreen(nil) }
            #endif
        }
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
        .libraryDialogs(model: model, isActive: FullScreen.hostsOwnDialogs)
    }

    private struct PlaybackKey: Equatable {
        let interval: Double
        let isPaused: Bool
        let position: Int
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 16) {
            Button("Close", systemImage: "xmark") { close() }
                .keyboardShortcut(.cancelAction)

            Divider().frame(height: 24)

            Button("Previous", systemImage: "backward.fill") { Task { await advance(by: -1) } }
            Button(isPaused ? "Play" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill") { isPaused.toggle() }
            Button("Next", systemImage: "forward.fill") { Task { await advance(by: 1) } }

            Divider().frame(height: 24)

            Menu {
                Picker("Interval", selection: $interval) {
                    ForEach(Self.intervals, id: \.self) { seconds in
                        Text(Duration.seconds(seconds), format: .units(allowed: [.seconds, .minutes], width: .wide))
                            .tag(seconds)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("\(Int(interval))s", systemImage: "timer")
                    .labelStyle(.titleAndIcon)
            }
            .menuIndicator(.hidden)
            .fixedSize()

            Toggle(isOn: $shuffle) {
                Label("Shuffle", systemImage: "shuffle")
            }
            .toggleStyle(.button)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: .capsule)
        .environment(\.colorScheme, .dark)
        .padding(.bottom, 30)
        .onHover { hovering in
            if hovering { hideControlsTask?.cancel() } else { scheduleControlsHide() }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() }
        if showsControls { scheduleControlsHide() }
    }

    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.4)) { showsControls = false }
        }
    }

    // MARK: Playback

    private func start() async {
        rebuildOrder(keeping: startID)
        if order.indices.contains(position) {
            image = await loadImage(for: order[position])
        }
        #if os(macOS)
        if let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            enteredFullScreen = true
        }
        #endif
    }

    /// Builds the play order (library order or shuffled) and positions it at `id` if present.
    private func rebuildOrder(keeping id: LibraryItem.ID?) {
        var items = model.items
        if shuffle {
            items.shuffle()
            // Start the shuffled order with the current image so it doesn't jump.
            if let id, let index = items.firstIndex(where: { $0.id == id }) {
                items.swapAt(0, index)
            }
        }
        order = items
        position = id.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        if order.isEmpty { close() }
    }

    private func advance(by delta: Int) async {
        guard !order.isEmpty else { return }
        var next = position + delta
        if next >= order.count {
            next = 0
            if shuffle {
                let last = order[position].id
                order.shuffle()
                // Avoid showing the same image twice in a row across the reshuffle.
                if order.count > 1, order[0].id == last { order.swapAt(0, 1) }
            }
        } else if next < 0 {
            next = order.count - 1
        }
        let nextImage = await loadImage(for: order[next])
        withAnimation(.easeInOut(duration: 0.8)) {
            position = next
            image = nextImage
        }
    }

    private func loadImage(for item: LibraryItem) async -> CGImage? {
        guard let url = model.fileURL(for: item, variant: .original) else { return nil }
        return await ImageLoader.shared.viewerImage(at: url)
    }

    private func close() {
        model.closeFullScreen()
    }

    /// Keeps the screen awake while the slideshow plays.
    private func setSystemSleepDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #elseif os(macOS)
        if disabled, displaySleepActivity == nil {
            displaySleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Slideshow")
        } else if !disabled, let activity = displaySleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            displaySleepActivity = nil
        }
        #endif
    }
}
