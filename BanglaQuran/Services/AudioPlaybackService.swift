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

    private enum BanglaPlaybackMode {
        case tts
        case streaming
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
    private let aiSpeechService = AzureBanglaSpeechService()

    private let speechSynthesizer = AVSpeechSynthesizer()
    private lazy var speechDelegate = SpeechDelegate(owner: self)
    private var cachedBanglaVoice: AVSpeechSynthesisVoice?
    private var isSpeechPaused: Bool = false
    private var currentUtterance: AVSpeechUtterance?
    private var banglaPlaybackMode: BanglaPlaybackMode = .tts

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
        speechSynthesizer.delegate = speechDelegate
    }

    deinit {
        MainActor.assumeIsolated {
            removeTimeObserver()
            NotificationCenter.default.removeObserver(self)
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }

    func toggleTrack() async {
        let nextTrack: AudioTrack = currentTrack == .arabicRecitation ? .banglaTranslation : .arabicRecitation
        await setTrack(nextTrack)
    }

    func setTrack(_ track: AudioTrack) async {
        guard track != currentTrack else { return }
        let wasPlaying = isPlaying
        currentTrack = track

        guard let surah = currentSurah, let ayah = currentAyah else { return }

        guard wasPlaying else {
            if track == .banglaTranslation {
                stopArabicPlayback()
            } else {
                stopBanglaPlayback()
            }
            updateNowPlayingInfo()
            return
        }

        let resumeTime: TimeInterval? = nil

        await play(surah: surah,
                   ayah: ayah,
                   track: track,
                   startTime: resumeTime,
                   userInitiated: true)

        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying {
            pauseCurrentPlayback()
        } else {
            resumeCurrentPlayback()
        }
        updateNowPlayingInfo()
    }

    func playNextAyah() async {
        guard let surah = currentSurah,
              let ayah = currentAyah,
              let ayat = try? await loadAyat(for: surah.id) else { return }
        let nextNumber = ayah.numberInSurah + 1
        guard let nextAyah = ayat.first(where: { $0.numberInSurah == nextNumber }) else {
            if currentTrack == .banglaTranslation {
                stopBanglaPlayback()
            } else {
                player?.pause()
            }
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
            switch track {
            case .arabicRecitation:
                try await startArabicPlayback(surah: surah, ayah: ayah, startTime: startTime)
            case .banglaTranslation:
                try await startBanglaPlayback(surah: surah, ayah: ayah)
            }

            currentSurah = surah
            currentAyah = ayah
            currentTrack = track
            progressStore.markInProgress(surahId: surah.id, ayahNumber: ayah.numberInSurah, percentage: 0)
            let resumePosition = track == .arabicRecitation ? (startTime ?? 0) : 0
            progressStore.updateResumePoint(PlaybackResumePoint(surahId: surah.id,
                                                                ayahNumber: ayah.numberInSurah,
                                                                track: track,
                                                                position: resumePosition,
                                                                updatedAt: Date()))
            autoDownloadNextAyahIfNeeded(for: surah, currentAyahNumber: ayah.numberInSurah, track: track)
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
            MainActor.assumeIsolated {
                self.elapsedTime = time.seconds
                self.updateDurations()
                self.evaluateCompletion()
                self.updateNowPlayingElapsed()
            }
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
        let isPlayable = try await asset.load(.isPlayable)
        guard isPlayable else {
            throw PlaybackError.failedToCreatePlayerItem
        }
        return AVPlayerItem(asset: asset)
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.allowAirPlay, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.resumeCurrentPlayback()
            self?.updateNowPlayingInfo()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pauseCurrentPlayback()
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

    private func autoDownloadNextAyahIfNeeded(for surah: Surah, currentAyahNumber: Int, track: AudioTrack) {
        guard preferences.autoDownloadNextAyahOnWiFi,
              track == .arabicRecitation else { return }
        let nextAyahNumber = currentAyahNumber + 1
        guard nextAyahNumber <= surah.ayahCount else { return }
        let key = DownloadManager.DownloadKey(surahId: surah.id, ayahNumber: nextAyahNumber, track: track)
        if downloadManager.localURL(for: key) == nil {
            downloadManager.downloadAyah(surahId: surah.id,
                                          ayahNumber: nextAyahNumber,
                                          track: track,
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

    private func pauseCurrentPlayback() {
        if currentTrack == .banglaTranslation {
            switch banglaPlaybackMode {
            case .tts:
                if speechSynthesizer.isSpeaking {
                    speechSynthesizer.pauseSpeaking(at: .immediate)
                    isSpeechPaused = true
                }
            case .streaming:
                player?.pause()
            }
        } else {
            player?.pause()
        }
        isPlaying = false
    }

    private func resumeCurrentPlayback() {
        if currentTrack == .banglaTranslation {
            switch banglaPlaybackMode {
            case .tts:
                if isSpeechPaused {
                    speechSynthesizer.continueSpeaking()
                    isSpeechPaused = false
                    isPlaying = true
                }
            case .streaming:
                guard let player else { return }
                player.play()
                isPlaying = true
            }
        } else {
            guard let player else { return }
            player.play()
            isPlaying = true
        }
    }

    private func startArabicPlayback(surah: Surah, ayah: Ayah, startTime: TimeInterval?) async throws {
        stopBanglaPlayback()
        let item = try await makePlayerItem(for: surah.id, ayahNumber: ayah.numberInSurah, track: .arabicRecitation)
        setupPlayer(with: item)
        if let startTime, let player {
            await player.seek(to: CMTime(seconds: startTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
            elapsedTime = startTime
        } else {
            elapsedTime = 0
        }
        player?.play()
        isPlaying = true
    }

    private func startBanglaPlayback(surah: Surah, ayah: Ayah) async throws {
        stopArabicPlayback()
        stopBanglaPlayback()

        let content = prepareBanglaNarration(for: ayah)
        guard content.hasAnySegment else {
            throw PlaybackError.missingAyah
        }

        if shouldUseAIMaleVoice(), aiSpeechService.isConfigured {
            do {
                let combined = normalizeBanglaText(content.combinedText)
                let audioURL = try await aiSpeechService.synthesize(text: combined,
                                                                     surahId: surah.id,
                                                                     ayahNumber: ayah.numberInSurah)
                banglaPlaybackMode = .streaming
                let asset = AVURLAsset(url: audioURL)
                let isPlayable = try await asset.load(.isPlayable)
                guard isPlayable else {
                    throw PlaybackError.failedToCreatePlayerItem
                }
                let item = AVPlayerItem(asset: asset)
                setupPlayer(with: item)
                player?.play()
                isPlaying = true
                isSpeechPaused = false
                elapsedTime = 0
                return
            } catch {
                #if DEBUG
                print("AI Bangla narration failed, falling back to system TTS: \(error)")
                #endif
            }
        }

        banglaPlaybackMode = .tts
        isSpeechPaused = false
        elapsedTime = 0
        duration = 0

        if let bismillah = content.bismillahSegment {
            let preface = makeBanglaUtterance(for: bismillah)
            if content.translationSegment == nil {
                currentUtterance = preface
            }
            speechSynthesizer.speak(preface)
        }

        if let translation = content.translationSegment {
            let utterance = makeBanglaUtterance(for: translation)
            currentUtterance = utterance
            speechSynthesizer.speak(utterance)
            isPlaying = true
        } else if content.bismillahSegment != nil {
            isPlaying = true
        }
    }

    private func shouldUseAIMaleVoice() -> Bool {
        preferences.selectedBanglaNarrator.id == "azure_pradeep"
    }

    private func prepareBanglaNarration(for ayah: Ayah) -> BanglaNarrationSegments {
        let normalizedTranslation = ayah.banglaText.map { normalizeBanglaText($0) }
        let normalizedBismillah = ayah.banglaBismillah.map { normalizeBanglaText($0) }

        let translation: String?
        if let normalizedTranslation, !normalizedTranslation.isEmpty {
            translation = normalizedTranslation
        } else {
            translation = nil
        }

        let bismillah: String?
        if let normalizedBismillah, !normalizedBismillah.isEmpty {
            bismillah = normalizedBismillah
        } else {
            bismillah = nil
        }

        return BanglaNarrationSegments(bismillahSegment: bismillah,
                                       translationSegment: translation)
    }

    private func makeBanglaUtterance(for text: String) -> AVSpeechUtterance {
        let normalizedText = normalizeBanglaText(text)
        let utterance = AVSpeechUtterance(string: normalizedText)
        if let voice = preferredBanglaVoice() {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.46
        utterance.pitchMultiplier = 0.85
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.05
        return utterance
    }

    private func preferredBanglaVoice() -> AVSpeechSynthesisVoice? {
        if let cachedBanglaVoice {
            return cachedBanglaVoice
        }

        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("bn") }
        if let best = voices.max(by: { score(for: $0) < score(for: $1) }) {
            cachedBanglaVoice = best
            return best
        }

        let fallback = AVSpeechSynthesisVoice(language: "bn-BD") ?? AVSpeechSynthesisVoice(language: "bn-IN")
        cachedBanglaVoice = fallback
        return fallback
    }

    private func score(for voice: AVSpeechSynthesisVoice) -> Int {
        var total = 0
        if voice.language == "bn-BD" { total += 100 }
        if voice.language == "bn-IN" { total += 90 }
        if voice.quality == .premium { total += 25 }
        else if voice.quality == .enhanced { total += 10 }
        let lowercaseName = voice.name.lowercased()
        if lowercaseName.contains("lalon") { total += 15 }
        if lowercaseName.contains("sameer") { total += 10 }
        if lowercaseName.contains("sadaf") { total += 8 }
        if #available(iOS 17.0, *), voice.gender == .male {
            total += 20
        }
        return total
    }

    private let banglaPronunciationOverrides: [(pattern: String, replacement: String)] = [
        ("﷽", "বিসমিল্লাহির রহমানির রহিম"),
        ("ﷺ", "সাল্লাল্লাহু আলাইহি ওয়াসাল্লাম"),
        ("ﷻ", "তাবারক ওয়াতা'আলা"),
        ("আল্লাহ্‌", "আল্লাহ"),
        ("আল্লাহ্", "আল্লাহ"),
        ("\n", " ")
    ]

    private func normalizeBanglaText(_ text: String) -> String {
        var normalized = text
        for override in banglaPronunciationOverrides {
            normalized = normalized.replacingOccurrences(of: override.pattern, with: override.replacement)
        }
        while normalized.contains("  ") {
            normalized = normalized.replacingOccurrences(of: "  ", with: " ")
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stopArabicPlayback() {
        removeTimeObserver()
        if let currentItem = player?.currentItem {
            NotificationCenter.default.removeObserver(self,
                                                      name: .AVPlayerItemDidPlayToEndTime,
                                                      object: currentItem)
        }
        player?.pause()
        player = nil
        elapsedTime = 0
        duration = 0
    }

    private func stopBanglaPlayback() {
        switch banglaPlaybackMode {
        case .tts:
            if speechSynthesizer.isSpeaking || isSpeechPaused {
                speechSynthesizer.stopSpeaking(at: .immediate)
            }
        case .streaming:
            removeTimeObserver()
            if let currentItem = player?.currentItem {
                NotificationCenter.default.removeObserver(self,
                                                          name: .AVPlayerItemDidPlayToEndTime,
                                                          object: currentItem)
            }
            player?.pause()
            player = nil
        }
        currentUtterance = nil
        isSpeechPaused = false
        banglaPlaybackMode = .tts
        elapsedTime = 0
        duration = 0
    }

    fileprivate func handleSpeechDidStart(utterance: AVSpeechUtterance) {
        guard currentTrack == .banglaTranslation else { return }
        isPlaying = true
        elapsedTime = 0
        duration = 0
        updateNowPlayingInfo()
    }

    fileprivate func handleSpeechWillSpeak(range: NSRange, utterance: AVSpeechUtterance) {
        guard currentTrack == .banglaTranslation,
              let surah = currentSurah,
              let ayah = currentAyah,
              let targetUtterance = currentUtterance,
              utterance == targetUtterance else { return }
        let totalUTF16Count = utterance.speechString.utf16.count
        if totalUTF16Count > 0 {
            let spoken = range.location + range.length
            let progress = Double(spoken) / Double(totalUTF16Count)
            progressStore.markInProgress(surahId: surah.id, ayahNumber: ayah.numberInSurah, percentage: progress)
        }
    }

    fileprivate func handleSpeechDidFinish(utterance: AVSpeechUtterance) {
        guard currentTrack == .banglaTranslation,
              let surah = currentSurah,
              let ayah = currentAyah,
              let targetUtterance = currentUtterance,
              utterance == targetUtterance else { return }
        isPlaying = false
        currentUtterance = nil
        progressStore.markCompleted(surahId: surah.id, ayahNumber: ayah.numberInSurah)
        updateNowPlayingInfo()
        Task { await playNextAyah() }
    }

    fileprivate func handleSpeechDidCancel(utterance: AVSpeechUtterance) {
        guard currentTrack == .banglaTranslation else { return }
        if let targetUtterance = currentUtterance, utterance == targetUtterance {
            currentUtterance = nil
        }
        isPlaying = false
        updateNowPlayingInfo()
    }
}

private struct BanglaNarrationSegments {
    let bismillahSegment: String?
    let translationSegment: String?

    var hasAnySegment: Bool {
        (bismillahSegment?.isEmpty == false) || (translationSegment?.isEmpty == false)
    }

    var combinedText: String {
        let parts = [bismillahSegment, translationSegment].compactMap { segment -> String? in
            guard let segment, !segment.isEmpty else { return nil }
            return segment
        }
        return parts.joined(separator: "। ")
    }
}

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    weak var owner: AudioPlaybackService?

    init(owner: AudioPlaybackService) {
        self.owner = owner
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak owner] in
            owner?.handleSpeechDidStart(utterance: utterance)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor [weak owner] in
            owner?.handleSpeechWillSpeak(range: characterRange, utterance: utterance)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak owner] in
            owner?.handleSpeechDidFinish(utterance: utterance)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak owner] in
            owner?.handleSpeechDidCancel(utterance: utterance)
        }
    }
}
