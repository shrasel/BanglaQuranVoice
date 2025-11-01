import Foundation
import Combine

@MainActor
final class ProgressViewModel: ObservableObject {
    @Published private(set) var snapshot: ListeningProgressStore.Snapshot

    private let store: ListeningProgressStore
    private var cancellables: Set<AnyCancellable> = []

    init(store: ListeningProgressStore) {
        self.store = store
        self.snapshot = store.snapshot

        store.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.snapshot = snapshot
            }
            .store(in: &cancellables)
    }

    func status(for surahId: Int, ayahNumber: Int) -> AyahProgressState {
        store.status(for: surahId, ayahNumber: ayahNumber)
    }

    func progress(for surah: Surah) -> SurahProgressSnapshot {
        store.progress(for: surah)
    }
}
