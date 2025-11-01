import Foundation
import Combine

@MainActor
final class SurahListViewModel: ObservableObject {
    struct SurahRow: Identifiable {
        let surah: Surah
        let progress: SurahProgressSnapshot

        var id: Int { surah.id }
    }

    struct ContinueListeningItem {
        let surah: Surah
        let ayahNumber: Int
        let track: AudioTrack
        let updatedAt: Date

        var subtitle: String {
            let format = NSLocalizedString("continue_listening_subtitle", comment: "Continue listening subtitle format")
            return String(format: format, surah.englishName, ayahNumber)
        }
    }

    @Published private(set) var rows: [SurahRow] = []
    @Published var searchText: String = ""
    @Published var revelationFilter: RevelationType?
    @Published private(set) var continueListening: ContinueListeningItem?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading: Bool = false

    private let repository: QuranRepositoryProtocol
    private let progressStore: ListeningProgressStore
    private let playbackService: AudioPlaybackService
    private var cancellables: Set<AnyCancellable> = []

    init(repository: QuranRepositoryProtocol,
         progressStore: ListeningProgressStore,
         playbackService: AudioPlaybackService) {
        self.repository = repository
        self.progressStore = progressStore
        self.playbackService = playbackService

        progressStore.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refreshRows() }
            }
            .store(in: &cancellables)

        $searchText
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refreshRows() }
            }
            .store(in: &cancellables)

        $revelationFilter
            .sink { [weak self] _ in
                Task { await self?.refreshRows() }
            }
            .store(in: &cancellables)
    }

    func load() async {
        guard rows.isEmpty else {
            await refreshRows()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await repository.loadSurahs()
            await refreshRows()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshRows() async {
        do {
            var surahs = try await repository.loadSurahs()
            if let filter = revelationFilter {
                surahs = surahs.filter { $0.revelationType == filter }
            }
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let query = searchText.lowercased()
                surahs = surahs.filter { surah in
                    surah.arabicName.lowercased().contains(query) ||
                    surah.englishName.lowercased().contains(query) ||
                    (surah.banglaName?.lowercased().contains(query) ?? false)
                }
            }
            rows = surahs.map { surah in
                let progress = progressStore.progress(for: surah)
                return SurahRow(surah: surah, progress: progress)
            }
            updateContinueListeningIfNeeded(with: surahs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateContinueListeningIfNeeded(with surahs: [Surah]) {
        guard let resume = progressStore.resumePoint(),
              let surah = surahs.first(where: { $0.id == resume.surahId }) else {
            continueListening = nil
            return
        }
        continueListening = ContinueListeningItem(surah: surah,
                                                  ayahNumber: resume.ayahNumber,
                                                  track: resume.track,
                                                  updatedAt: resume.updatedAt)
    }

    func resumePlayback() {
        guard let resume = progressStore.resumePoint(),
              let item = continueListening else { return }
        Task {
            let ayat = try await repository.loadAyat(for: item.surah.id)
            guard let ayah = ayat.first(where: { $0.numberInSurah == resume.ayahNumber }) else { return }
            await playbackService.play(surah: item.surah,
                                       ayah: ayah,
                                       track: resume.track,
                                       startTime: resume.position,
                                       userInitiated: true)
        }
    }
}
