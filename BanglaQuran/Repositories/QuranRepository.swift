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

    private let manifestFileName = "surahs_manifest"
    private let fileExtension = "json"
    private let decoder = JSONDecoder()
    private var surahCache: [Surah] = []
    private var ayahCache: [Int: [Ayah]] = [:]
    private let cacheQueue = DispatchQueue(label: "ManifestQuranRepository.cache", qos: .userInitiated)

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
        }
        return surahs
    }

    func loadAyat(for surahId: Int) async throws -> [Ayah] {
        if let cached = cacheQueue.sync(execute: { ayahCache[surahId] }) {
            return cached
        }
        let surahs = try await loadSurahs()
        guard let surah = surahs.first(where: { $0.id == surahId }) else {
            throw NSError(domain: "ManifestQuranRepository", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing surah metadata"])
        }
        let ayat = (1...surah.ayahCount).map { index in
            Ayah(surahId: surah.id,
                 numberInSurah: index,
                 arabicText: "Surah \(surah.arabicName) - Ayah \(index)",
                 banglaText: surah.banglaName.map { "\($0) - আয়াত \(index)" })
        }
        cacheQueue.async { [weak self] in
            self?.ayahCache[surahId] = ayat
        }
        return ayat
    }

    func audioURL(for track: AudioTrack, surahId: Int, ayahNumber: Int) -> URL {
        let trackFolder: String
        switch track {
        case .arabicRecitation:
            trackFolder = "arabic"
        case .banglaTranslation:
            trackFolder = "bangla"
        }
        let formattedSurah = String(format: "%03d", surahId)
        let formattedAyah = String(format: "%03d", ayahNumber)
        let urlString = "https://cdn.quranbanglaplayer.example/\(trackFolder)/\(formattedSurah)/\(formattedAyah).mp3"
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
        return try decoder.decode(Manifest.self, from: data)
    }
}
