import Foundation
import Combine

@MainActor
final class SurahDetailViewModel: ObservableObject {
    struct AyahItem: Identifiable {
        let ayah: Ayah
        var status: AyahProgressState
        var isCurrent: Bool
        var isActivelyPlaying: Bool

        var id: String { ayah.id }
    }

    struct DownloadSummary {
        let downloadedCount: Int
        let totalCount: Int
        let totalBytes: Int64

        var formattedCount: String {
            String.localizedStringWithFormat(NSLocalizedString("downloaded_count_format", comment: "Downloaded ayah count"), downloadedCount, totalCount)
        }

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        }
    }

    @Published private(set) var ayat: [AyahItem] = []
    @Published private(set) var currentTrack: AudioTrack = .arabicRecitation
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSurahActive: Bool = false
    @Published private(set) var isSurahPlaying: Bool = false
    @Published private(set) var focusedAyahId: String?
    @Published var showBanglaText: Bool
    @Published private(set) var downloadSummary: DownloadSummary

    let surah: Surah

    private let repository: QuranRepositoryProtocol
    private let playbackService: AudioPlaybackService
    private let progressStore: ListeningProgressStore
    private let preferencesStore: PreferencesStore
    private let downloadManager: DownloadManager
    private var cancellables: Set<AnyCancellable> = []

    init(surah: Surah,
         repository: QuranRepositoryProtocol,
         playbackService: AudioPlaybackService,
         progressStore: ListeningProgressStore,
         preferencesStore: PreferencesStore,
         downloadManager: DownloadManager) {
        self.surah = surah
        self.repository = repository
        self.playbackService = playbackService
        self.progressStore = progressStore
        self.preferencesStore = preferencesStore
        self.downloadManager = downloadManager
        self.showBanglaText = preferencesStore.showBanglaText
        self.downloadSummary = DownloadSummary(downloadedCount: 0, totalCount: surah.ayahCount, totalBytes: 0)

        Publishers.CombineLatest3(playbackService.$currentSurah,
                                   playbackService.$currentAyah,
                                   playbackService.$isPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] surah, ayah, isPlaying in
                self?.updatePlaybackState(currentSurah: surah, currentAyah: ayah, isPlaying: isPlaying)
            }
            .store(in: &cancellables)

        playbackService.$currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                self?.currentTrack = track
            }
            .store(in: &cancellables)

        progressStore.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatuses()
            }
            .store(in: &cancellables)

        preferencesStore.$showBanglaText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                self?.showBanglaText = newValue
            }
            .store(in: &cancellables)

        refreshDownloadSummary()

        downloadManager.$records
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshDownloadSummary()
            }
            .store(in: &cancellables)
    }

    var downloadsEnabled: Bool {
        currentTrack == .arabicRecitation
    }

    var openingBismillahArabic: String? {
        guard surah.showsOpeningBismillah else { return nil }
        return NSLocalizedString("bismillah_arabic_text", comment: "Arabic Bismillah header")
    }

    var openingBismillahBangla: String? {
        guard surah.showsOpeningBismillah else { return nil }
        if let firstItem = ayat.first(where: { $0.ayah.numberInSurah == 1 }),
           let trimmed = firstItem.ayah.banglaBismillah?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return NSLocalizedString("bismillah_bangla_text", comment: "Bangla Bismillah header")
    }

    func load(force: Bool = false) async {
        guard force || ayat.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let ayahModels = try await repository.loadAyat(for: surah.id)
            ayat = ayahModels.map { model in
                AyahItem(ayah: model,
                         status: progressStore.status(for: surah.id, ayahNumber: model.numberInSurah),
                         isCurrent: false,
                         isActivelyPlaying: false)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectTrack(_ track: AudioTrack) async {
        guard currentTrack != track else { return }
        currentTrack = track
        await playbackService.setTrack(track)
    }

    func handlePrimaryAction() async {
        if isSurahActive {
            playbackService.togglePlayPause()
            return
        }
        await playFromBeginning()
    }

    func playFromBeginning() async {
        if ayat.isEmpty {
            await load(force: true)
        }
        guard let first = ayat.first else { return }
        await playbackService.play(surah: surah,
                                   ayah: first.ayah,
                                   track: currentTrack,
                                   startTime: 0,
                                   userInitiated: true)
    }

    func restartSurah() async {
        await playFromBeginning()
    }

    func handleAyahTapped(_ item: AyahItem) async {
        let isSameAyah = isSurahActive && playbackService.currentAyah?.id == item.ayah.id
        if isSameAyah {
            playbackService.togglePlayPause()
        } else {
            await playbackService.play(surah: surah,
                                       ayah: item.ayah,
                                       track: currentTrack,
                                       startTime: 0,
                                       userInitiated: true)
        }
    }

    func markAsUnplayed(_ item: AyahItem) {
        progressStore.markNotStarted(surahId: surah.id, ayahNumber: item.ayah.numberInSurah)
    }

    func downloadAyah(_ item: AyahItem) {
        guard downloadsEnabled else { return }
        downloadManager.downloadAyah(surahId: surah.id, ayahNumber: item.ayah.numberInSurah, track: currentTrack)
    }

    func downloadSurah(track: AudioTrack) {
        guard track == .arabicRecitation else { return }
        downloadManager.downloadSurahFully(surah: surah, track: track)
    }

    func downloadCurrentTrack() {
        guard downloadsEnabled else { return }
        downloadManager.downloadSurahFully(surah: surah, track: currentTrack)
    }

    var primaryButtonTitle: String {
        if isSurahPlaying {
            return NSLocalizedString("pause_surah_button_label", comment: "Pause the currently playing surah")
        }
        if isSurahActive {
            return NSLocalizedString("resume_surah_button_label", comment: "Resume the paused surah")
        }
        return NSLocalizedString("play_surah_button_label", comment: "Play the surah from the beginning")
    }

    var primaryButtonIconName: String {
        if isSurahPlaying {
            return "pause.circle.fill"
        }
        return "play.circle.fill"
    }

    var showRestartButton: Bool {
        isSurahActive && !ayat.isEmpty
    }

    func removeDownloads() {
        downloadManager.deleteDownloads(for: surah.id)
    }

    func toggleBanglaVisibility(_ visible: Bool) {
        preferencesStore.showBanglaText = visible
    }

    private func refreshStatuses() {
        ayat = ayat.map { item in
            AyahItem(ayah: item.ayah,
                     status: progressStore.status(for: surah.id, ayahNumber: item.ayah.numberInSurah),
                     isCurrent: item.isCurrent,
                     isActivelyPlaying: item.isCurrent ? isSurahPlaying : false)
        }
    }

    private func refreshDownloadSummary() {
        let finished = downloadManager.records.values.compactMap { record -> Int64? in
            guard record.key.surahId == surah.id,
                  record.key.track == .arabicRecitation else { return nil }
            if case let .finished(_, bytes) = record.status {
                return bytes
            }
            return nil
        }
        let bytes = finished.reduce(0, +)
        downloadSummary = DownloadSummary(downloadedCount: finished.count,
                                          totalCount: surah.ayahCount,
                                          totalBytes: bytes)
    }

    private func updatePlaybackState(currentSurah: Surah?, currentAyah: Ayah?, isPlaying: Bool) {
        let isActive = currentSurah?.id == surah.id
        isSurahActive = isActive
        isSurahPlaying = isActive && isPlaying
        focusedAyahId = isActive ? currentAyah?.id : nil

        ayat = ayat.map { item in
            let status = progressStore.status(for: surah.id, ayahNumber: item.ayah.numberInSurah)
            let isCurrent = isActive && item.ayah.id == currentAyah?.id
            let activelyPlaying = isCurrent ? isSurahPlaying : false
            return AyahItem(ayah: item.ayah,
                            status: status,
                            isCurrent: isCurrent,
                            isActivelyPlaying: activelyPlaying)
        }
    }
}
