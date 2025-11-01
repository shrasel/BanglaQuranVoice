import Foundation
import Combine

@MainActor
final class SurahDetailViewModel: ObservableObject {
    struct AyahItem: Identifiable {
        let ayah: Ayah
        var status: AyahProgressState
        var isPlaying: Bool

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

        playbackService.$currentAyah
            .combineLatest(playbackService.$currentSurah)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ayah, surah in
                Task { await self?.updateCurrentAyah(ayah: ayah, surah: surah) }
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
                Task { await self?.refreshStatuses() }
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

    func load() async {
        guard ayat.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let ayahModels = try await repository.loadAyat(for: surah.id)
            ayat = ayahModels.map { model in
                AyahItem(ayah: model,
                         status: progressStore.status(for: surah.id, ayahNumber: model.numberInSurah),
                         isPlaying: false)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func play(ayah item: AyahItem) async {
        await playbackService.play(surah: surah,
                                   ayah: item.ayah,
                                   track: currentTrack,
                                   startTime: 0,
                                   userInitiated: true)
    }

    func toggleTrack() async {
        await playbackService.toggleTrack()
    }

    func markAsUnplayed(_ item: AyahItem) {
        progressStore.markNotStarted(surahId: surah.id, ayahNumber: item.ayah.numberInSurah)
    }

    func downloadAyah(_ item: AyahItem) {
        downloadManager.downloadAyah(surahId: surah.id, ayahNumber: item.ayah.numberInSurah, track: currentTrack)
    }

    func downloadSurah(track: AudioTrack) {
        downloadManager.downloadSurahFully(surah: surah, track: track)
    }

    func removeDownloads() {
        downloadManager.deleteDownloads(for: surah.id)
    }

    func toggleBanglaVisibility(_ visible: Bool) {
        preferencesStore.showBanglaText = visible
    }

    private func updateCurrentAyah(ayah: Ayah?, surah: Surah?) async {
        guard surah?.id == self.surah.id else {
            ayat = ayat.map { AyahItem(ayah: $0.ayah, status: $0.status, isPlaying: false) }
            return
        }
        ayat = ayat.map { item in
            AyahItem(ayah: item.ayah,
                     status: progressStore.status(for: self.surah.id, ayahNumber: item.ayah.numberInSurah),
                     isPlaying: item.ayah.id == ayah?.id)
        }
    }

    private func refreshStatuses() async {
        ayat = ayat.map { item in
            AyahItem(ayah: item.ayah,
                     status: progressStore.status(for: surah.id, ayahNumber: item.ayah.numberInSurah),
                     isPlaying: item.isPlaying)
        }
    }

    private func refreshDownloadSummary() {
        let finished = downloadManager.records.values.compactMap { record -> Int64? in
            guard record.key.surahId == surah.id else { return nil }
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
}
