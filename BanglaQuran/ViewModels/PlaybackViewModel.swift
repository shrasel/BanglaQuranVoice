import Foundation
import Combine

@MainActor
final class PlaybackViewModel: ObservableObject {
    @Published private(set) var title: String = ""
    @Published private(set) var subtitle: String = ""
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentTrack: AudioTrack = .arabicRecitation
    @Published private(set) var hasActiveItem: Bool = false

    private let service: AudioPlaybackService
    private var cancellables: Set<AnyCancellable> = []

    init(playbackService: AudioPlaybackService) {
        self.service = playbackService

        playbackService.$currentSurah
            .combineLatest(playbackService.$currentAyah)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] surah, ayah in
                self?.updateLabels(surah: surah, ayah: ayah)
            }
            .store(in: &cancellables)

        playbackService.$isPlaying
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPlaying)

        playbackService.$elapsedTime
            .combineLatest(playbackService.$duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] elapsed, duration in
                guard duration > 0 else {
                    self?.progress = 0
                    return
                }
                self?.progress = min(max(elapsed / duration, 0), 1)
            }
            .store(in: &cancellables)

        playbackService.$currentTrack
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentTrack)
    }

    func togglePlayPause() {
        service.togglePlayPause()
    }

    func next() {
        Task { await service.playNextAyah() }
    }

    func previous() {
        Task { await service.playPreviousAyah() }
    }

    func toggleTrack() {
        Task { await service.toggleTrack() }
    }

    private func updateLabels(surah: Surah?, ayah: Ayah?) {
        guard let surah, let ayah else {
            title = NSLocalizedString("no_track_selected", comment: "Placeholder for no track playing")
            subtitle = ""
            hasActiveItem = false
            return
        }
        title = "\(surah.arabicName)"
        subtitle = String(format: NSLocalizedString("mini_player_subtitle_format", comment: "Mini player subtitle"), surah.englishName, ayah.numberInSurah)
        hasActiveItem = true
    }
}
