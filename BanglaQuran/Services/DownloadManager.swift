import Foundation
import Combine

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    enum Status {
        case idle
        case queued
        case downloading(progress: Double)
        case finished(localURL: URL, bytes: Int64)
        case failed(error: Error)
    }

    struct DownloadKey: Hashable, Codable {
        let surahId: Int
        let ayahNumber: Int
        let track: AudioTrack
    }

    struct Record: Identifiable {
        let key: DownloadKey
        var status: Status

        var id: DownloadKey { key }
    }

    @Published private(set) var records: [DownloadKey: Record] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.quranbanglaplayer.downloads")
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = false
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private let repository: QuranRepositoryProtocol
    private let preferencesStore: PreferencesStore
    private let progressStore: ListeningProgressStore
    private let fileManager: FileManager
    private let persistenceURL: URL
    private var taskToKey: [Int: DownloadKey] = [:]

    init(repository: QuranRepositoryProtocol,
         preferencesStore: PreferencesStore,
         progressStore: ListeningProgressStore,
         fileManager: FileManager = .default) {
        self.repository = repository
        self.preferencesStore = preferencesStore
        self.progressStore = progressStore
        self.fileManager = fileManager

        let base = (try? fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.persistenceURL = base.appendingPathComponent("downloads-state.json")
        super.init()
        restore()
    }

    func prepareLocalURL(for key: DownloadKey) -> URL {
        let base = (try? fileManager.url(for: .cachesDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("QuranBanglaPlayer/Audio", isDirectory: true)
        if !fileManager.fileExists(atPath: folder.path) {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let fileName = "\(key.track.analyticsName)-\(String(format: "%03d", key.surahId))-\(String(format: "%03d", key.ayahNumber)).mp3"
        return folder.appendingPathComponent(fileName, isDirectory: false)
    }

    func localURL(for key: DownloadKey) -> URL? {
        let prepared = prepareLocalURL(for: key)
        return fileManager.fileExists(atPath: prepared.path) ? prepared : nil
    }

    func downloadAyah(surahId: Int, ayahNumber: Int, track: AudioTrack, autoDownload: Bool = false) {
        guard track == .arabicRecitation else { return }
        let key = DownloadKey(surahId: surahId, ayahNumber: ayahNumber, track: track)
        if let existing = records[key], case .finished = existing.status {
            return
        }
        let remoteURL = repository.audioURL(for: track, surahId: surahId, ayahNumber: ayahNumber)
        var request = URLRequest(url: remoteURL)
        if autoDownload {
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false
        } else {
            request.allowsExpensiveNetworkAccess = true
            request.allowsConstrainedNetworkAccess = true
        }
        let task = session.downloadTask(with: request)
        records[key] = Record(key: key, status: .queued)
        task.taskDescription = try? String(data: JSONEncoder().encode(key), encoding: .utf8)
        task.resume()
        taskToKey[task.taskIdentifier] = key
        persist()
    }

    func downloadSurahFully(surah: Surah, track: AudioTrack) {
        guard track == .arabicRecitation else { return }
        for ayah in 1...surah.ayahCount {
            downloadAyah(surahId: surah.id, ayahNumber: ayah, track: track)
        }
    }

    func deleteDownloads(for surahId: Int) {
        let keys = records.keys.filter { $0.surahId == surahId }
        for key in keys {
            removeFile(for: key)
            records[key] = nil
        }
        persist()
    }

    private func removeFile(for key: DownloadKey) {
        let url = prepareLocalURL(for: key)
        try? fileManager.removeItem(at: url)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let saved = try? JSONDecoder().decode([DownloadKey].self, from: data) else {
            return
        }
        for key in saved {
            if let url = localURL(for: key) {
                records[key] = Record(key: key, status: .finished(localURL: url, bytes: fileSize(at: url)))
            }
        }
    }

    private func persist() {
        let keys = records.compactMap { entry -> DownloadKey? in
            switch entry.value.status {
            case .finished:
                return entry.key
            default:
                return nil
            }
        }
        if let data = try? JSONEncoder().encode(keys) {
            try? data.write(to: persistenceURL, options: .atomic)
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription,
              let data = description.data(using: .utf8),
              let key = try? JSONDecoder().decode(DownloadKey.self, from: data) else {
            return
        }
        Task { @MainActor in
            let destination = self.prepareLocalURL(for: key)
            do {
                if self.fileManager.fileExists(atPath: destination.path) {
                    try self.fileManager.removeItem(at: destination)
                }
                try self.fileManager.moveItem(at: location, to: destination)
                let bytes = self.fileSize(at: destination)
                self.records[key] = Record(key: key, status: .finished(localURL: destination, bytes: bytes))
                self.persist()
            } catch {
                self.records[key] = Record(key: key, status: .failed(error: error))
            }
            self.taskToKey[downloadTask.taskIdentifier] = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0,
              let description = downloadTask.taskDescription,
              let data = description.data(using: .utf8),
              let key = try? JSONDecoder().decode(DownloadKey.self, from: data) else {
            return
        }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.records[key] = Record(key: key, status: .downloading(progress: progress))
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        if let description = task.taskDescription,
           let data = description.data(using: .utf8),
           let key = try? JSONDecoder().decode(DownloadKey.self, from: data) {
            Task { @MainActor in
                self.records[key] = Record(key: key, status: .failed(error: error))
                self.taskToKey[task.taskIdentifier] = nil
            }
        }
    }
}
