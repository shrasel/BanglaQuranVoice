import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var playbackViewModel: PlaybackViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playbackViewModel.title)
                        .font(.headline)
                        .lineLimit(1)
                    if !playbackViewModel.subtitle.isEmpty {
                        Text(playbackViewModel.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    playbackViewModel.toggleTrack()
                } label: {
                    Text(playbackViewModel.currentTrack.localizedToggleLabel)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                }
                .accessibilityLabel(NSLocalizedString("toggle_track_accessibility", comment: "Toggle track accessibility"))
            }

            ProgressView(value: playbackViewModel.progress)
                .tint(.accentColor)

            HStack(spacing: 32) {
                Button(action: playbackViewModel.previous) {
                    Image(systemName: "backward.fill")
                }
                .accessibilityLabel(NSLocalizedString("previous_ayah_button", comment: "Previous ayah button"))

                Button(action: playbackViewModel.togglePlayPause) {
                    Image(systemName: playbackViewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .accessibilityLabel(playbackViewModel.isPlaying ? NSLocalizedString("pause_button_label", comment: "Pause button") : NSLocalizedString("play_button_label", comment: "Play button"))

                Button(action: playbackViewModel.next) {
                    Image(systemName: "forward.fill")
                }
                .accessibilityLabel(NSLocalizedString("next_ayah_button", comment: "Next ayah button"))
            }
            .font(.title3)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
    }
}
