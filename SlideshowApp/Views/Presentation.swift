import SwiftUI

enum FullScreen {
    /// On iOS, full-screen content is a separate presentation and must host its own dialogs;
    /// on macOS it's an overlay in the same window, so the library's dialogs suffice.
    #if os(iOS)
    static let hostsOwnDialogs = true
    #else
    static let hostsOwnDialogs = false
    #endif
}

extension View {
    /// Full-screen presentation: a `fullScreenCover` on iOS; on macOS, an overlay that fills the
    /// (single) window and hides its toolbar, so it works the same in windowed and full-screen mode.
    func fullScreenPresentation<Content: View>(isPresented: Binding<Bool>,
                                               @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        overlay {
            if isPresented.wrappedValue {
                content()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPresented.wrappedValue)
        .toolbarVisibility(isPresented.wrappedValue ? .hidden : .automatic, for: .windowToolbar)
        #endif
    }

    /// The delete confirmation and error alert. Attached both to the library and to full-screen
    /// content, because on iOS a dialog can't be shown from beneath a full-screen cover;
    /// `isActive` makes sure only the frontmost one presents.
    func libraryDialogs(model: LibraryModel, isActive: Bool) -> some View {
        modifier(LibraryDialogs(model: model, isActive: isActive))
    }
}

private struct LibraryDialogs: ViewModifier {
    @Bindable var model: LibraryModel
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .confirmationDialog(deleteTitle, isPresented: isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task { await model.confirmPendingDeletion() }
                }
                Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
            } message: {
                Text("This removes them from Slate and its widgets. Originals in Photos or Files aren't affected.")
            }
            .alert(alertTitle, isPresented: isShowingAlert, presenting: model.alert) { _ in
                Button("OK") { model.alert = nil }
            } message: { alert in
                Text(alert.message)
            }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { isActive && model.pendingDeletion != nil },
                set: { if !$0 { model.pendingDeletion = nil } })
    }

    private var isShowingAlert: Binding<Bool> {
        Binding(get: { isActive && model.alert != nil },
                set: { if !$0 { model.alert = nil } })
    }

    private var alertTitle: String { model.alert?.title ?? "" }

    private var deleteTitle: String {
        let count = model.pendingDeletion?.count ?? 0
        return count == 1 ? "Delete this image?" : "Delete \(count) images?"
    }
}
