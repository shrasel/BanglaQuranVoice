import Foundation
import AVFoundation
import MediaPlayer
import Combine

@MainActor
final class AudioPlaybackService: NSObject, ObservableObject {
    enum PlaybackError: Error {
        case missingAyah
        case failedToCreatePlayerItem
    }

    @Published private(set) var currentSurah: Surah?
    @Published private(set) var currentAyah: Ayah?
    @Published private(set) var currentTrack: AudioTrack = .arabicRecitation
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []

    private let repository: QuranRepositoryProtocol
    private let preferences: PreferencesStore
    private let progressStore: ListeningProgressStore
    private let downloadManager: DownloadManager

    private var ayahCache: [Int: [Ayah]] = [:]

    init(repository: QuranRepositoryProtocol,
         preferences: PreferencesStore,
         progressStore: ListeningProgressStore,
         downloadManager: DownloadManager) {
        self.repository = repository
        self.preferences = preferences
        self.progressStore = progressStore
        self.downloadManager = downloadManager
        super.init()
        configureAudioSession()
        configureRemoteCommands()
    }

    deinit {
        MainActor.assumeIsolated {
            removeTimeObserver()
            NotificationCenter.default.removeObserver(self)
        }
    }

    func toggleTrack() async {
        let nextTrack: AudioTrack = currentTrack == .arabicRecitation ? .banglaTranslation : .arabicRecitation
        await setTrack(nextTrack)
    }

    func setTrack(_ track: AudioTrack) async {
        guard track != currentTrack else { return }
        let wasPlaying = isPlaying
        let resumeTime = player?.currentTime().seconds ?? 0
        currentTrack = track

        guard let surah = currentSurah, let ayah = currentAyah else { return }

        await play(surah: surah,
                   ayah: ayah,
                   track: track,
                   startTime: resumeTime,
                   userInitiated: true)

        if !wasPlaying {
            player?.pause()
            isPlaying = false
            updateNowPlayingInfo()
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        updateNowPlayingInfo()
    }

    func playNextAyah() async {
        guard let surah = currentSurah,
              let ayah = currentAyah,
              let ayat = try? await loadAyat(for: surah.id) else { return }
        let nextNumber = ayah.numberInSurah + 1
        guard let nextAyah = ayat.first(where: { $0.numberInSurah == nextNumber }) else {
            player?.pause()
            isPlaying = false
            updateNowPlayingInfo()
            return
        }
        await play(surah: surah, ayah: nextAyah, track: currentTrack, startTime: 0, userInitiated: true)
    }

    func playPreviousAyah() async {
        guard let surah = currentSurah,
              let ayah = currentAyah,
              let ayat = try? await loadAyat(for: surah.id) else { return }
        let previousNumber = max(1, ayah.numberInSurah - 1)
        guard let previousAyah = ayat.first(where: { $0.numberInSurah == previousNumber }) else {
            return
        }
        await play(surah: surah, ayah: previousAyah, track: currentTrack, startTime: 0, userInitiated: true)
    }

    func play(surah: Surah, ayah: Ayah, track: AudioTrack, startTime: TimeInterval? = nil, userInitiated: Bool) async {
        do {
            let ayat = try await loadAyat(for: surah.id)
            guard ayat.contains(where: { $0.id == ayah.id }) else {
                throw PlaybackError.missingAyah
            }
            let item = try await makePlayerItem(for: surah.id, ayahNumber: ayah.numberInSurah, track: track)
            setupPlayer(with: item)
            currentSurah = surah
            currentAyah = ayah
            currentTrack = track
            if let startTime, let player {
                await player.seek(to: CMTime(seconds: startTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
            }
            player?.play()
            isPlaying = true
            progressStore.markInProgress(surahId: surah.id, ayahNumber: ayah.numberInSurah, percentage: 0)
            progressStore.updateResumePoint(PlaybackResumePoint(surahId: surah.id,
                                                                ayahNumber: ayah.numberInSurah,
                                                                track: track,
                                                                position: startTime ?? 0,
                                                                updatedAt: Date()))
            autoDownloadNextAyahIfNeeded(for: surah, currentAyahNumber: ayah.numberInSurah)
            updateNowPlayingInfo()
        } catch {
            print("Failed to start playback: \(error)")
        }
    }

    private func setupPlayer(with item: AVPlayerItem) {
        removeTimeObserver()
        if player == nil {
            player = AVPlayer(playerItem: item)
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(handleItemDidFinish(_:)),
                                                   name: .AVPlayerItemDidPlayToEndTime,
                                                   object: item)
        } else {
            NotificationCenter.default.removeObserver(self,
                                                      name: .AVPlayerItemDidPlayToEndTime,
                                                      object: player?.currentItem)
            player?.replaceCurrentItem(with: item)
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(handleItemDidFinish(_:)),
                                                   name: .AVPlayerItemDidPlayToEndTime,
                                                   object: item)
        }
        addTimeObserver()
        updateDurations()
    }

    private func addTimeObserver() {
        guard let player else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.elapsedTime = time.seconds
            self.updateDurations()
            self.evaluateCompletion()
            self.updateNowPlayingElapsed()
        }
    }

    private func updateDurations() {
        if let seconds = player?.currentItem?.duration.seconds, seconds.isFinite {
            duration = seconds
        } else {
            duration = 0
        }
    }

    private func removeTimeObserver() {
        guard let player, let timeObserver else { return }
        player.removeTimeObserver(timeObserver)
        self.timeObserver = nil
    }

    private func evaluateCompletion() {
        guard let surah = currentSurah,
              let ayah = currentAyah,
              duration > 0 else { return }
        let progress = elapsedTime / duration
        progressStore.markInProgress(surahId: surah.id, ayahNumber: ayah.numberInSurah, percentage: progress)
        if progress >= 0.95 {
            progressStore.markCompleted(surahId: surah.id, ayahNumber: ayah.numberInSurah)
        }
        progressStore.updateResumePoint(PlaybackResumePoint(surahId: surah.id,
                                                            ayahNumber: ayah.numberInSurah,
                                                            track: currentTrack,
                                                            position: elapsedTime,
                                                            updatedAt: Date()))
    }

    private func loadAyat(for surahId: Int) async throws -> [Ayah] {
        if let cached = ayahCache[surahId] {
            return cached
        }
        let ayat = try await repository.loadAyat(for: surahId)
        ayahCache[surahId] = ayat
        return ayat
    }

    private func makePlayerItem(for surahId: Int, ayahNumber: Int, track: AudioTrack) async throws -> AVPlayerItem {
        let key = DownloadManager.DownloadKey(surahId: surahId, ayahNumber: ayahNumber, track: track)
        let url = downloadManager.localURL(for: key) ?? repository.audioURL(for: track, surahId: surahId, ayahNumber: ayahNumber)
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        guard asset.isPlayable else {
            throw PlaybackError.failedToCreatePlayerItem
        }
        return item
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.allowAirPlay, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            self?.isPlaying = true
            self?.updateNowPlayingInfo()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            self?.isPlaying = false
            self?.updateNowPlayingInfo()
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { await self?.playNextAyah() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { await self?.playPreviousAyah() }
            return .success
        }
    }

    private func autoDownloadNextAyahIfNeeded(for surah: Surah, currentAyahNumber: Int) {
        guard preferences.autoDownloadNextAyahOnWiFi else { return }
        let nextAyahNumber = currentAyahNumber + 1
        guard nextAyahNumber <= surah.ayahCount else { return }
        let key = DownloadManager.DownloadKey(surahId: surah.id, ayahNumber: nextAyahNumber, track: currentTrack)
        if downloadManager.localURL(for: key) == nil {
            downloadManager.downloadAyah(surahId: surah.id,
                                          ayahNumber: nextAyahNumber,
                                          track: currentTrack,
                                          autoDownload: true)
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        if let ayah = currentAyah, let surah = currentSurah {
            info[MPMediaItemPropertyTitle] = "\(surah.arabicName) – \(ayah.numberInSurah)"
            info[MPMediaItemPropertyArtist] = currentTrack == .arabicRecitation ? preferences.selectedArabicReciter.displayName : preferences.selectedBanglaNarrator.displayName
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    @objc
    private func handleItemDidFinish(_ notification: Notification) {
        guard let surah = currentSurah,
              let ayah = currentAyah else { return }
        progressStore.markCompleted(surahId: surah.id, ayahNumber: ayah.numberInSurah)
        Task { [weak self] in
            await self?.playNextAyah()
        }
    }
}
