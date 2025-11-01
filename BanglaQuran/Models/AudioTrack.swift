import Foundation

enum AudioTrack: String, CaseIterable, Codable, Identifiable {
    case arabicRecitation
    case banglaTranslation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .arabicRecitation:
            return NSLocalizedString("track_arabic_recitation", comment: "Arabic recitation track label")
        case .banglaTranslation:
            return NSLocalizedString("track_bangla_translation", comment: "Bangla translation track label")
        }
    }

    var localizedToggleLabel: String {
        switch self {
        case .arabicRecitation:
            return NSLocalizedString("toggle_arabic_label", comment: "Short label for Arabic track")
        case .banglaTranslation:
            return NSLocalizedString("toggle_bangla_label", comment: "Short label for Bangla track")
        }
    }

    var analyticsName: String {
        switch self {
        case .arabicRecitation: return "arabic"
        case .banglaTranslation: return "bangla"
        }
    }
}
