import SwiftUI

/// Shown when the library has no images, with direct calls to action.
struct EmptyLibraryView: View {
    let model: LibraryModel

    var body: some View {
        ContentUnavailableView {
            Label("No Images Yet", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(description)
        } actions: {
            Button {
                model.isPhotosPickerPresented = true
            } label: {
                Label("Add from Photos", systemImage: "photo.on.rectangle")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                model.isFileImporterPresented = true
            } label: {
                Label("Add from Files", systemImage: "folder")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .disabled(model.isImporting)
    }

    private var description: String {
        let base = "Add images to build your library and widget slideshow. Slate keeps its own copy, so deleting the original later won't affect it."
        #if os(macOS)
        return base + "\n\nYou can also drag images into this window."
        #else
        return base
        #endif
    }
}
