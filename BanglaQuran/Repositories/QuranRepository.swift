import Foundation
import Combine

protocol QuranRepositoryProtocol {
    func loadSurahs() async throws -> [Surah]
    func loadAyat(for surahId: Int) async throws -> [Ayah]
    func audioURL(for track: AudioTrack, surahId: Int, ayahNumber: Int) -> URL
    func prefetchAyatMetadata(for surahId: Int) async
}

final class ManifestQuranRepository: QuranRepositoryProtocol {
    private struct Manifest: Codable {
        let surahs: [SurahEntry]
    }

    private struct SurahEntry: Codable {
        let id: Int
        let arabicName: String
        let englishName: String
        let banglaName: String?
        let revelationType: RevelationType
        let ayahCount: Int
    }

    private struct SurahAPIResponse: Decodable {
        let data: SurahData
    }

    private struct SurahData: Decodable {
        let number: Int
        let ayahs: [APIAyah]
    }

    private struct APIAyah: Decodable {
        let numberInSurah: Int
        let text: String
    }

    private let manifestFileName = "surahs_manifest"
    private let fileExtension = "json"
    private let manifestDecoder = JSONDecoder()
    private var surahCache: [Surah] = []
    private var ayahCache: [Int: [Ayah]] = [:]
    private var ayahOffsets: [Int: Int] = [:]
    private var selectedArabicScript: PreferencesStore.ArabicScript
    private let cacheQueue = DispatchQueue(label: "ManifestQuranRepository.cache", qos: .userInitiated)
    private let session: URLSession
    private let fileManager: FileManager
    private let ayahCacheDirectory: URL
    private var cancellables: Set<AnyCancellable> = []

    init(preferencesStore: PreferencesStore? = nil,
         session: URLSession = .shared,
         fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
        self.selectedArabicScript = preferencesStore?.selectedArabicScript ?? .indoPak
        let baseDirectory: URL
        if let caches = try? fileManager.url(for: .cachesDirectory,
                                             in: .userDomainMask,
                                             appropriateFor: nil,
                                             create: true) {
            baseDirectory = caches
        } else {
            baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        }

        let directory = baseDirectory.appendingPathComponent("QuranBanglaPlayer/AyahCache", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.ayahCacheDirectory = directory

        preferencesStore?.$selectedArabicScript
            .removeDuplicates()
            .sink { [weak self] script in
                self?.handleArabicScriptChange(script)
            }
            .store(in: &cancellables)
    }

    func loadSurahs() async throws -> [Surah] {
        if let cached = cacheQueue.sync(execute: { surahCache.isEmpty ? nil : surahCache }) {
            return cached
        }
        let manifest = try await loadManifest()
        let surahs = manifest.surahs.map { entry in
            Surah(id: entry.id,
                  arabicName: entry.arabicName,
                  englishName: entry.englishName,
                  banglaName: entry.banglaName,
                  revelationType: entry.revelationType,
                  ayahCount: entry.ayahCount)
        }
        cacheQueue.async { [weak self] in
            self?.surahCache = surahs
            self?.ayahOffsets = Self.buildOffsets(from: surahs)
        }
        return surahs
    }

    func loadAyat(for surahId: Int) async throws -> [Ayah] {
        if let cached = cacheQueue.sync(execute: { ayahCache[surahId] }) {
            return cached
        }

        if let diskCached = loadCachedAyat(surahId: surahId) {
            cacheQueue.async { [weak self] in
                self?.ayahCache[surahId] = diskCached
            }
            return diskCached
        }

        let surahs = try await loadSurahs()
        guard let surah = surahs.first(where: { $0.id == surahId }) else {
            throw NSError(domain: "ManifestQuranRepository", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing surah metadata"])
        }

        let arabicEdition = cacheQueue.sync { selectedArabicScript.apiEditionCode }

        async let arabicTask = fetchAyat(surahId: surah.id, edition: arabicEdition)
        async let banglaTask = fetchAyat(surahId: surah.id, edition: "bn.bengali")

        let (arabicAyat, banglaAyat) = try await (arabicTask, banglaTask)
        let banglaMap = Dictionary(uniqueKeysWithValues: banglaAyat.map { ($0.numberInSurah, $0.text) })

        let ayat = arabicAyat.map { arabic -> Ayah in
            let translation = banglaMap[arabic.numberInSurah]
            let extraction = Self.extractBanglaBismillah(from: translation,
                                                         surahId: surah.id,
                                                         ayahNumber: arabic.numberInSurah)
            return Ayah(surahId: surah.id,
                        numberInSurah: arabic.numberInSurah,
                        arabicText: arabic.text,
                        banglaText: extraction.cleanedTranslation,
                        banglaBismillah: extraction.bismillah)
        }

        cacheQueue.async { [weak self] in
            self?.ayahCache[surahId] = ayat
        }
        persistAyatToDisk(ayat, surahId: surah.id)
        return ayat
    }

    func audioURL(for track: AudioTrack, surahId: Int, ayahNumber: Int) -> URL {
        let offsets = cacheQueue.sync { ayahOffsets }
        let baseIndex = offsets[surahId] ?? 0
        let globalAyah = baseIndex + ayahNumber
        guard globalAyah > 0 else {
            return URL(fileURLWithPath: "/dev/null")
        }

        let reciterCode: String
        switch track {
        case .arabicRecitation:
            reciterCode = "ar.alafasy"
        case .banglaTranslation:
            reciterCode = "bn.bengali"
        }

        let urlString = "https://cdn.islamic.network/quran/audio/64/\(reciterCode)/\(globalAyah).mp3"
        return URL(string: urlString) ?? URL(fileURLWithPath: "/dev/null")
    }

    func prefetchAyatMetadata(for surahId: Int) async {
        _ = try? await loadAyat(for: surahId)
    }

    private func loadManifest() async throws -> Manifest {
        guard let url = Bundle.main.url(forResource: manifestFileName, withExtension: fileExtension) else {
            throw NSError(domain: "ManifestQuranRepository", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing manifest asset"])
        }
        let data = try Data(contentsOf: url)
        return try manifestDecoder.decode(Manifest.self, from: data)
    }

    private func fetchAyat(surahId: Int, edition: String) async throws -> [APIAyah] {
        guard let url = URL(string: "https://api.alquran.cloud/v1/surah/\(surahId)/\(edition)") else {
            throw NSError(domain: "ManifestQuranRepository", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid API URL"])
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "ManifestQuranRepository", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to load surah data"])
        }
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SurahAPIResponse.self, from: data)
        return decoded.data.ayahs
    }

    private func persistAyatToDisk(_ ayat: [Ayah], surahId: Int) {
        let url = ayahCacheDirectory.appendingPathComponent("surah-\(surahId).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(ayat)
            try data.write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("Failed to persist ayat for surah \(surahId): \(error)")
            #endif
        }
    }

    private func loadCachedAyat(surahId: Int) -> [Ayah]? {
        let url = ayahCacheDirectory.appendingPathComponent("surah-\(surahId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode([Ayah].self, from: data)
    }

    private static func buildOffsets(from surahs: [Surah]) -> [Int: Int] {
        var offsets: [Int: Int] = [:]
        var runningTotal = 0
        for surah in surahs.sorted(by: { $0.id < $1.id }) {
            offsets[surah.id] = runningTotal
            runningTotal += surah.ayahCount
        }
        return offsets
    }

    private func handleArabicScriptChange(_ script: PreferencesStore.ArabicScript) {
        cacheQueue.async { [weak self] in
            guard let self else { return }
            guard self.selectedArabicScript != script else { return }
            self.selectedArabicScript = script
            self.ayahCache.removeAll()
            self.clearAyahDiskCache()
        }
    }

    private func clearAyahDiskCache() {
        let urls = (try? fileManager.contentsOfDirectory(at: ayahCacheDirectory,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
        for url in urls where url.pathExtension == "json" {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func extractBanglaBismillah(from original: String?,
                                               surahId: Int,
                                               ayahNumber: Int) -> (cleanedTranslation: String?, bismillah: String?) {
        guard var text = original?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return (nil, nil)
        }

        text = text.replacingOccurrences(of: "﷽", with: "")

        let shouldInclude = ayahNumber == 1
        guard shouldInclude else {
            return (text.isEmpty ? nil : text, nil)
        }

        let canonical = "বিসমিল্লাহির রহমানির রহিম"
        let variations: [String] = [
            canonical,
            "বিসমিল্লাহির রাহমানির রহিম",
            "বিসমিল্লাহির রাহমানির রাহীম",
            "বিসমিল্লাহির রহমানির রাহীম",
            "বিসমিল্লাহির রহমানির রাহীম।",
            "বিসমিল্লাহির রাহমানির রহিম।"
        ]

        let trimmingCharacters = CharacterSet(charactersIn: "।!,:;—–- ")

        for variation in variations {
            if text.hasPrefix(variation) {
                let remainder = text.dropFirst(variation.count).trimmingCharacters(in: trimmingCharacters)
                return (remainder.isEmpty ? nil : String(remainder), variation)
            }
        }

        // Some editions omit Bismillah entirely for Surah 9 only. For all others, inject canonical phrase.
        if surahId != 9 {
            let remainder = text.trimmingCharacters(in: trimmingCharacters)
            return (remainder.isEmpty ? nil : remainder, canonical)
        }

        return (text.isEmpty ? nil : text, nil)
    }
}
