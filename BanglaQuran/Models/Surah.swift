import Foundation

enum RevelationType: String, CaseIterable, Codable, Identifiable {
    case meccan
    case medinan

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .meccan:
            return NSLocalizedString("revelation_meccan", comment: "Meccan revelation label")
        case .medinan:
            return NSLocalizedString("revelation_medinan", comment: "Medinan revelation label")
        }
    }
}

struct Surah: Identifiable, Codable, Hashable {
    let id: Int
    let arabicName: String
    let englishName: String
    let banglaName: String?
    let revelationType: RevelationType
    let ayahCount: Int

    var displayName: String { "\(id). \(englishName)" }

    var showsOpeningBismillah: Bool {
        id != 9
    }
}

struct Ayah: Identifiable, Codable, Hashable {
    let surahId: Int
    let numberInSurah: Int
    let arabicText: String
    let banglaText: String?
    let banglaBismillah: String?

    var id: String { "\(surahId)-\(numberInSurah)" }
}

enum AyahPlaybackStatus: String, Codable {
    case notStarted
    case inProgress
    case completed
}

struct AyahProgressState: Codable {
    var status: AyahPlaybackStatus
    var percentage: Double
    var lastUpdated: Date

    init(status: AyahPlaybackStatus = .notStarted, percentage: Double = 0, lastUpdated: Date = Date()) {
        self.status = status
        self.percentage = min(max(percentage, 0), 1)
        self.lastUpdated = lastUpdated
    }
}

struct SurahProgressSnapshot {
    let completedAyahCount: Int
    let totalAyahCount: Int
    let inProgressCount: Int

    var percentage: Double {
        guard totalAyahCount > 0 else { return 0 }
        return Double(completedAyahCount) / Double(totalAyahCount)
    }

    var localizedSummary: String {
        let format = NSLocalizedString("surah_progress_format", comment: "Format for per-surah progress label")
        return String(format: format, completedAyahCount, totalAyahCount)
    }
}
