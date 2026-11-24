import SwiftUI

@main
struct SlateApp: App {
    @State private var model = LibraryModel.live()

    var body: some Scene {
        #if os(macOS)
        // A single window, no sidebar; reopened from the Window menu if closed.
        Window("Slate", id: "library") {
            LibraryView(model: model)
                .frame(minWidth: 480, minHeight: 360)
        }
        .defaultSize(width: 1100, height: 750)
        .commands { SlateCommands(model: model) }
        #else
        WindowGroup {
            LibraryView(model: model)
        }
        .commands { SlateCommands(model: model) } // iPad hardware keyboard
        #endif
    }
}

/// Menu bar commands (macOS) and hardware-keyboard shortcuts (iPad).
struct SlateCommands: Commands {
    let model: LibraryModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import…") { model.isFileImporterPresented = true }
                .keyboardShortcut("o")
                .disabled(!canImport)
            Button("Import from Photos…") { model.isPhotosPickerPresented = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!canImport)
        }

        CommandMenu("Library") {
            Button(model.isSelecting ? "Done Selecting" : "Select") {
                if model.isSelecting { model.endSelecting() } else { model.isSelecting = true }
            }
            .keyboardShortcut("e")
            .disabled(model.items.isEmpty || model.fullScreen != nil)

            Button("Delete") { model.requestDelete(deletionTargets) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(deletionTargets.isEmpty)

            Divider()

            Button("Start Slideshow") {
                if case .viewer(let id) = model.fullScreen { model.startSlideshow(from: id) } else { model.startSlideshow() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(model.items.isEmpty)
        }
    }

    private var canImport: Bool {
        model.store != nil && !model.isImporting
    }

    /// The visible image in the viewer, otherwise the grid selection.
    private var deletionTargets: Set<LibraryItem.ID> {
        switch model.fullScreen {
        case .viewer(let id): [id]
        case .slideshow: []
        case nil: model.isSelecting ? model.selection : []
        }
    }
}
