import Foundation

struct PlaybackResumePoint: Codable, Equatable {
    let surahId: Int
    let ayahNumber: Int
    let track: AudioTrack
    let position: TimeInterval
    let updatedAt: Date
}
