import Foundation

/// Resolves the App Group container shared by the app and the widget extension.
///
/// The identifier is never hard-coded: it comes from the `SlateAppGroupID` Info.plist key,
/// which Xcode fills in from `SLATE_APP_GROUP_ID` in `Config/Slate.xcconfig`. The same build
/// setting feeds the entitlements, so the two can't drift apart. On iOS it is
/// `group.<prefix>`; on macOS it is `<TeamID>.<prefix>`.
nonisolated enum AppGroup {
    static let infoPlistKey = "SlateAppGroupID"

    static var identifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
              !value.isEmpty,
              !value.contains("$(") // Unexpanded build setting means a misconfigured build.
        else { return nil }
        return value
    }

    /// The library folder inside the shared container, or `nil` if the App Group is unavailable
    /// (for example, the entitlement is missing because the build wasn't signed).
    static var libraryRootURL: URL? {
        guard let identifier,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else { return nil }
        return container.appending(path: "Slate", directoryHint: .isDirectory)
    }
}
