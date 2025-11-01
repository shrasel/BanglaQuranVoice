import Foundation
import Combine

@MainActor
final class PreferencesViewModel: ObservableObject {
    @Published var selectedArabicReciter: PreferencesStore.Reciter {
        didSet { store.selectedArabicReciter = selectedArabicReciter }
    }

    @Published var selectedBanglaNarrator: PreferencesStore.Narrator {
        didSet { store.selectedBanglaNarrator = selectedBanglaNarrator }
    }

    @Published var selectedArabicScript: PreferencesStore.ArabicScript {
        didSet { store.selectedArabicScript = selectedArabicScript }
    }

    @Published var showBanglaText: Bool {
        didSet { store.showBanglaText = showBanglaText }
    }

    @Published var autoDownloadNextAyahOnWiFi: Bool {
        didSet { store.autoDownloadNextAyahOnWiFi = autoDownloadNextAyahOnWiFi }
    }

    private let store: PreferencesStore
    private let progressStore: ListeningProgressStore
    private let downloadManager: DownloadManager

    var availableArabicReciters: [PreferencesStore.Reciter] { store.availableArabicReciters }
    var availableBanglaNarrators: [PreferencesStore.Narrator] { store.availableBanglaNarrators }
    var availableArabicScripts: [PreferencesStore.ArabicScript] { store.availableArabicScripts }

    init(store: PreferencesStore,
         progressStore: ListeningProgressStore,
         downloadManager: DownloadManager) {
        self.store = store
        self.progressStore = progressStore
        self.downloadManager = downloadManager
        self.selectedArabicReciter = store.selectedArabicReciter
        self.selectedBanglaNarrator = store.selectedBanglaNarrator
        self.selectedArabicScript = store.selectedArabicScript
        self.showBanglaText = store.showBanglaText
        self.autoDownloadNextAyahOnWiFi = store.autoDownloadNextAyahOnWiFi
    }

    func resetProgress() {
        progressStore.reset()
    }

    func clearDownloads(for surahId: Int) {
        downloadManager.deleteDownloads(for: surahId)
    }
}
