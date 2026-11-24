import AppIntents
import WidgetKit

/// Per-widget settings, edited via "Edit Widget".
struct SlideshowIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Slideshow"
    static let description = IntentDescription("Rotates through the images in your Slate library.")

    @Parameter(title: "Change Image", default: .oneHour)
    var interval: RotationInterval

    @Parameter(title: "Order", default: .shuffle)
    var order: SlideOrder

    @Parameter(title: "Image Fit", default: .fill)
    var fit: ImageFit

    static var parameterSummary: some ParameterSummary {
        Summary("Change image \(\.$interval), \(\.$order), \(\.$fit)")
    }
}

// Raw values are persisted in widget configurations: never rename or reuse them.

enum RotationInterval: String, AppEnum {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case threeHours
    case daily

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Interval"
    static let caseDisplayRepresentations: [RotationInterval: DisplayRepresentation] = [
        .fifteenMinutes: "Every 15 Minutes",
        .thirtyMinutes: "Every 30 Minutes",
        .oneHour: "Every Hour",
        .threeHours: "Every 3 Hours",
        .daily: "Daily",
    ]

    var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .threeHours: 3 * 60 * 60
        case .daily: 24 * 60 * 60
        }
    }

    /// Timeline length: enough entries to rotate for hours or days without the app running,
    /// while keeping the timeline small (12 h, 24 h, 2 days, 5 days, and 30 days respectively).
    var entryCount: Int {
        switch self {
        case .fifteenMinutes, .thirtyMinutes, .oneHour: 48
        case .threeHours: 40
        case .daily: 30
        }
    }
}

enum SlideOrder: String, AppEnum {
    case shuffle
    case newestFirst

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Order"
    static let caseDisplayRepresentations: [SlideOrder: DisplayRepresentation] = [
        .shuffle: "Shuffle",
        .newestFirst: "Newest First",
    ]
}

enum ImageFit: String, AppEnum {
    case fill
    case fit

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Image Fit"
    static let caseDisplayRepresentations: [ImageFit: DisplayRepresentation] = [
        .fill: "Fill",
        .fit: "Fit",
    ]
}
