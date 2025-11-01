import Foundation
import Combine

@MainActor
final class ListeningProgressStore: ObservableObject {
    @Published private(set) var snapshot: Snapshot

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileURL: URL
    private let queue = DispatchQueue(label: "ListeningProgressStore.persistence", qos: .background)

    init(fileManager: FileManager = .default) {
        encoder.outputFormatting = [.prettyPrinted]
        if let directory = try? fileManager.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true) {
            fileURL = directory.appendingPathComponent("listening_progress.json")
        } else {
            fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("listening_progress.json")
        }

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? decoder.decode(Snapshot.self, from: data) {
            snapshot = loaded
        } else {
            snapshot = Snapshot()
        }
    }

    func status(for surahId: Int, ayahNumber: Int) -> AyahProgressState {
        let key = makeKey(surahId: surahId, ayah: ayahNumber)
        if let existing = snapshot.ayahProgress[key] {
            return existing
        }
        return AyahProgressState()
    }

    func markInProgress(surahId: Int, ayahNumber: Int, percentage: Double) {
        update(surahId: surahId, ayahNumber: ayahNumber, status: .inProgress, percentage: percentage)
    }

    func markCompleted(surahId: Int, ayahNumber: Int) {
        update(surahId: surahId, ayahNumber: ayahNumber, status: .completed, percentage: 1)
    }

    func markNotStarted(surahId: Int, ayahNumber: Int) {
        update(surahId: surahId, ayahNumber: ayahNumber, status: .notStarted, percentage: 0)
    }

    func progress(for surah: Surah) -> SurahProgressSnapshot {
        let allKeys = snapshot.ayahProgress.filter { key, _ in key.hasPrefix("\(surah.id):") }
        let completed = allKeys.values.filter { $0.status == .completed }.count
        let inProgress = allKeys.values.filter { $0.status == .inProgress }.count
        return SurahProgressSnapshot(completedAyahCount: completed,
                                     totalAyahCount: surah.ayahCount,
                                     inProgressCount: inProgress)
    }

    func updateResumePoint(_ point: PlaybackResumePoint) {
        snapshot.resumePoint = point
        persist()
    }

    func resumePoint() -> PlaybackResumePoint? {
        snapshot.resumePoint
    }

    func reset() {
        snapshot = Snapshot()
        persist()
    }

    private func update(surahId: Int, ayahNumber: Int, status: AyahPlaybackStatus, percentage: Double) {
        let key = makeKey(surahId: surahId, ayah: ayahNumber)
        let normalized = min(max(percentage, 0), 1)
        snapshot.ayahProgress[key] = AyahProgressState(status: status, percentage: normalized, lastUpdated: Date())
        persist()
    }

    private func makeKey(surahId: Int, ayah: Int) -> String {
        "\(surahId):\(ayah)"
    }

    private func persist() {
        let snapshot = self.snapshot
        queue.async { [encoder, fileURL] in
            do {
                let data = try encoder.encode(snapshot)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                #if DEBUG
                print("Failed to persist progress: \(error)")
                #endif
            }
        }
    }

    struct Snapshot: Codable {
        var ayahProgress: [String: AyahProgressState]
        var resumePoint: PlaybackResumePoint?

        init(ayahProgress: [String: AyahProgressState] = [:], resumePoint: PlaybackResumePoint? = nil) {
            self.ayahProgress = ayahProgress
            self.resumePoint = resumePoint
        }
    }
}
