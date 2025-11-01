import Foundation
import Combine

@MainActor
final class AppEnvironment: ObservableObject {
    let repository: QuranRepositoryProtocol
    let playbackService: AudioPlaybackService
    let downloadManager: DownloadManager
    let preferencesStore: PreferencesStore
    let progressStore: ListeningProgressStore

    lazy var surahListViewModel = SurahListViewModel(repository: repository,
                                                     progressStore: progressStore,
                                                     playbackService: playbackService)

    lazy var playbackViewModel = PlaybackViewModel(playbackService: playbackService)

    lazy var preferencesViewModel = PreferencesViewModel(store: preferencesStore,
                                                         progressStore: progressStore,
                                                         downloadManager: downloadManager)

    lazy var progressViewModel = ProgressViewModel(store: progressStore)

    init() {
        let preferences = PreferencesStore()
        let repository = ManifestQuranRepository(preferencesStore: preferences)
        let progress = ListeningProgressStore()
        let downloadManager = DownloadManager(repository: repository,
                                              preferencesStore: preferences,
                                              progressStore: progress)
        let playbackService = AudioPlaybackService(repository: repository,
                                                   preferences: preferences,
                                                   progressStore: progress,
                                                   downloadManager: downloadManager)
        self.repository = repository
        self.preferencesStore = preferences
        self.progressStore = progress
        self.downloadManager = downloadManager
        self.playbackService = playbackService
    }

    func makeDetailViewModel(for surah: Surah) -> SurahDetailViewModel {
        SurahDetailViewModel(surah: surah,
                             repository: repository,
                             playbackService: playbackService,
                             progressStore: progressStore,
                             preferencesStore: preferencesStore,
                             downloadManager: downloadManager)
    }
}
