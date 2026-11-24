import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The single main screen: masonry grid (or empty state), toolbar, importers, and the
/// full-screen viewer/slideshow presentations.
struct LibraryView: View {
    @Bindable var model: LibraryModel
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var isDropTargeted = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Slate")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbarContent }
        }
        .safeAreaInset(edge: .bottom) {
            if let progress = model.importProgress {
                ImportProgressBanner(progress: progress)
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.importProgress)
        .dropDestination(for: ImportedImageFile.self) { files, _ in
            guard !files.isEmpty, model.store != nil else { return false }
            model.importDroppedFiles(files)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $model.isFileImporterPresented,
                      allowedContentTypes: ImageProcessor.supportedTypes,
                      allowsMultipleSelection: true) { result in
            model.handleFileImporterResult(result)
        }
        .photosPicker(isPresented: $model.isPhotosPickerPresented,
                      selection: $pickerSelection,
                      maxSelectionCount: nil,
                      selectionBehavior: .ordered,
                      matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: pickerSelection) { _, newValue in
            guard !newValue.isEmpty else { return }
            model.importPhotos(newValue)
            pickerSelection = []
        }
        .libraryDialogs(model: model, isActive: model.fullScreen == nil || !FullScreen.hostsOwnDialogs)
        .fullScreenPresentation(isPresented: isFullScreenPresented) {
            switch model.fullScreen {
            case .viewer(let id):
                ViewerView(model: model, initialID: id)
            case .slideshow(let startID):
                SlideshowView(model: model, startID: startID)
            case nil:
                Color.black
            }
        }
        .task { await model.load() }
        .onOpenURL { model.open($0) }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let error = model.unavailableError {
            ContentUnavailableView("Library Unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(error.localizedDescription))
        } else if !model.hasLoaded {
            ProgressView()
        } else if model.items.isEmpty {
            EmptyLibraryView(model: model)
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            AdaptiveMasonry(model: model)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        #if os(macOS)
        .onDeleteCommand {
            if model.isSelecting { model.requestDelete(model.selection) }
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAll() }
        #endif
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.isSelecting {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { model.endSelecting() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(model.selection.count == model.items.count ? "Deselect All" : "Select All") {
                    if model.selection.count == model.items.count { model.selection = [] } else { model.selectAll() }
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    model.requestDelete(model.selection)
                }
                .disabled(model.selection.isEmpty)
                .help("Delete selected images")
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.items.isEmpty {
                    Button("Select") { model.isSelecting = true }
                    Button("Slideshow", systemImage: "play.fill") { model.startSlideshow() }
                    .help("Start slideshow")
                }
                AddImagesMenu(model: model)
            }
        }
    }

    // MARK: Bindings

    private var isFullScreenPresented: Binding<Bool> {
        Binding(get: { model.fullScreen != nil },
                set: { if !$0 { model.closeFullScreen() } })
    }
}

/// Picks a column count from the available width.
private struct AdaptiveMasonry: View {
    let model: LibraryModel
    @State private var columnCount = 3

    var body: some View {
        MasonryGrid(items: model.items, columnCount: columnCount, spacing: 8) { item in
            ThumbnailCell(item: item,
                          url: model.fileURL(for: item, variant: .thumbnail),
                          isSelecting: model.isSelecting,
                          isSelected: model.selection.contains(item.id))
                .onTapGesture {
                    if model.isSelecting { model.toggleSelection(item.id) } else { model.showViewer(item.id) }
                }
                .contextMenu {
                    Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { model.showViewer(item.id) }
                    Button("Delete", systemImage: "trash", role: .destructive) { model.requestDelete([item.id]) }
                }
        }
        .onGeometryChange(for: Int.self) { proxy in
            // ~170 pt columns: 2 on iPhone portrait, 4–5 on iPad, more on wide Mac windows.
            max(2, Int(proxy.size.width / 170))
        } action: { columnCount = $0 }
    }
}

/// "Add" menu offering Photos and Files.
struct AddImagesMenu: View {
    let model: LibraryModel

    var body: some View {
        Menu {
            Button("From Photos…", systemImage: "photo.on.rectangle") { model.isPhotosPickerPresented = true }
            Button("From Files…", systemImage: "folder") { model.isFileImporterPresented = true }
        } label: {
            Label("Add Images", systemImage: "plus")
        }
        .disabled(model.isImporting || model.store == nil)
        .help("Add images")
    }
}

private struct ImportProgressBanner: View {
    let progress: ImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Importing \(min(progress.completed + progress.failed + 1, progress.total)) of \(progress.total)…")
                .font(.subheadline.weight(.medium))
            ProgressView(value: Double(progress.completed + progress.failed), total: Double(progress.total))
            if progress.failed > 0 {
                Text("\(progress.failed) failed")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .shadow(radius: 8, y: 2)
    }
}
