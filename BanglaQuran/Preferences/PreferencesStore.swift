import Foundation
import Combine

final class PreferencesStore: ObservableObject {
    struct Reciter: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    struct Narrator: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    enum ArabicScript: String, CaseIterable, Codable, Identifiable {
        case indoPak
        case uthmani

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .indoPak:
                return NSLocalizedString("arabic_script_indo_pak", comment: "Indo-Pak script option")
            case .uthmani:
                return NSLocalizedString("arabic_script_uthmani", comment: "Uthmani script option")
            }
        }

        var apiEditionCode: String {
            switch self {
            case .indoPak:
                return "ar.quran-indopak"
            case .uthmani:
                return "ar.quran-uthmani"
            }
        }
    }

    @Published var selectedArabicReciter: Reciter {
        didSet { persist() }
    }

    @Published var selectedBanglaNarrator: Narrator {
        didSet { persist() }
    }

    @Published var selectedArabicScript: ArabicScript {
        didSet { persist() }
    }

    @Published var showBanglaText: Bool {
        didSet { persist() }
    }

    @Published var autoDownloadNextAyahOnWiFi: Bool {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let storageKey = "com.quranbanglaplayer.preferences.v1"
    private var cancellables: Set<AnyCancellable> = []

    let availableArabicReciters: [Reciter]
    let availableBanglaNarrators: [Narrator]
    let availableArabicScripts: [ArabicScript]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.availableArabicReciters = [
            Reciter(id: "default", displayName: NSLocalizedString("reciter_default", comment: "Default Arabic reciter")),
            Reciter(id: "mishary_rashid", displayName: "Mishary Rashid")
        ]
        self.availableBanglaNarrators = [
            Narrator(id: "azure_pradeep", displayName: NSLocalizedString("narrator_ai_bangla_male", comment: "AI Bangla male narrator")),
            Narrator(id: "default", displayName: NSLocalizedString("narrator_default", comment: "Default Bangla narrator")),
            Narrator(id: "abu_rushd", displayName: "Abu Rushd")
        ]
        self.availableArabicScripts = ArabicScript.allCases

        if let data = defaults.data(forKey: storageKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            self.selectedArabicReciter = availableArabicReciters.first(where: { $0.id == snapshot.selectedArabicReciterId }) ?? availableArabicReciters[0]
            self.selectedBanglaNarrator = availableBanglaNarrators.first(where: { $0.id == snapshot.selectedBanglaNarratorId }) ?? availableBanglaNarrators[0]
            self.selectedArabicScript = snapshot.selectedArabicScript.flatMap { ArabicScript(rawValue: $0) } ?? .indoPak
            self.showBanglaText = snapshot.showBanglaText
            self.autoDownloadNextAyahOnWiFi = snapshot.autoDownloadNextAyahOnWiFi
        } else {
            self.selectedArabicReciter = availableArabicReciters[0]
            self.selectedBanglaNarrator = availableBanglaNarrators[0]
            self.selectedArabicScript = .indoPak
            self.showBanglaText = true
            self.autoDownloadNextAyahOnWiFi = false
        }
    }

    func reset() {
        selectedArabicReciter = availableArabicReciters[0]
        selectedBanglaNarrator = availableBanglaNarrators[0]
        selectedArabicScript = .indoPak
        showBanglaText = true
        autoDownloadNextAyahOnWiFi = false
        persist()
    }

    private func persist() {
        let snapshot = Snapshot(selectedArabicReciterId: selectedArabicReciter.id,
                                selectedBanglaNarratorId: selectedBanglaNarrator.id,
                                selectedArabicScript: selectedArabicScript.rawValue,
                                showBanglaText: showBanglaText,
                                autoDownloadNextAyahOnWiFi: autoDownloadNextAyahOnWiFi)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private struct Snapshot: Codable {
        let selectedArabicReciterId: String
        let selectedBanglaNarratorId: String
        let selectedArabicScript: String?
        let showBanglaText: Bool
        let autoDownloadNextAyahOnWiFi: Bool
    }
}
