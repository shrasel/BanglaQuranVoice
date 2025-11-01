import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SurahDetailView: View {
    @StateObject var viewModel: SurahDetailViewModel
    @EnvironmentObject private var playbackViewModel: PlaybackViewModel

    init(viewModel: SurahDetailViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { viewModel.showBanglaText }, set: { viewModel.toggleBanglaVisibility($0) })) {
                    Text(NSLocalizedString("toggle_bangla_text", comment: "Toggle Bangla text label"))
                }
            }

            Section(header: Text(NSLocalizedString("download_summary_section_header", comment: "Download summary header"))) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.downloadSummary.formattedCount)
                        .font(.subheadline)
                    Text(String(format: NSLocalizedString("download_summary_size_format", comment: "Download size format"), viewModel.downloadSummary.formattedSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    viewModel.removeDownloads()
                } label: {
                    Text(NSLocalizedString("delete_downloads_button", comment: "Delete downloads button"))
                }
                .disabled(viewModel.downloadSummary.downloadedCount == 0)
            }

            Section(header: Text(NSLocalizedString("ayah_section_header", comment: "Ayah section header"))) {
                ForEach(viewModel.ayat) { item in
                    AyahRowView(item: item,
                                showBanglaText: viewModel.showBanglaText,
                                playAction: {
                                    Task { await viewModel.play(ayah: item) }
                                },
                                markUnplayedAction: {
                                    viewModel.markAsUnplayed(item)
                                },
                                downloadAction: {
                                    viewModel.downloadAyah(item)
                                },
                                copyArabicAction: {
                                    #if canImport(UIKit)
                                    UIPasteboard.general.string = item.ayah.arabicText
                                    #endif
                                },
                                copyBanglaAction: {
                                    #if canImport(UIKit)
                                    if let text = item.ayah.banglaText {
                                        UIPasteboard.general.string = text
                                    }
                                    #endif
                                })
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(viewModel.surah.englishName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Button(NSLocalizedString("download_arabic_track", comment: "Download Arabic track")) {
                        viewModel.downloadSurah(track: .arabicRecitation)
                    }
                    Button(NSLocalizedString("download_bangla_track", comment: "Download Bangla track")) {
                        viewModel.downloadSurah(track: .banglaTranslation)
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .accessibilityLabel(NSLocalizedString("download_menu_accessibility", comment: "Download menu"))

                Button {
                    Task { await viewModel.toggleTrack() }
                } label: {
                    Text(viewModel.currentTrack.localizedToggleLabel)
                }
                .accessibilityLabel(NSLocalizedString("toggle_track_accessibility", comment: "Toggle track"))
            }
        }
        .task {
            await viewModel.load()
        }
    }
}

private struct AyahRowView: View {
    let item: SurahDetailViewModel.AyahItem
    let showBanglaText: Bool
    let playAction: () -> Void
    let markUnplayedAction: () -> Void
    let downloadAction: () -> Void
    let copyArabicAction: () -> Void
    let copyBanglaAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 6) {
                    Text("\(item.ayah.numberInSurah)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    statusChip
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.ayah.arabicText)
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showBanglaText, let bangla = item.ayah.banglaText {
                        Text(bangla)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        playAction()
                    } label: {
                        Label(item.isPlaying ? NSLocalizedString("pause_button_label", comment: "Pause label") : NSLocalizedString("play_button_label", comment: "Play label"), systemImage: item.isPlaying ? "pause.circle" : "play.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(item.isPlaying ? .accentColor : .secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button(NSLocalizedString("context_play_from_here", comment: "Play from here")) {
                playAction()
            }
            Button(NSLocalizedString("context_mark_unplayed", comment: "Mark as unplayed")) {
                markUnplayedAction()
            }
            Button(NSLocalizedString("context_download_ayah", comment: "Download this ayah")) {
                downloadAction()
            }
            Button(NSLocalizedString("context_copy_arabic", comment: "Copy Arabic")) {
                copyArabicAction()
            }
            if item.ayah.banglaText != nil {
                Button(NSLocalizedString("context_copy_bangla", comment: "Copy Bangla")) {
                    copyBanglaAction()
                }
            }
        }
    }

    private var statusChip: some View {
        let label: String
        let color: Color
        switch item.status.status {
        case .notStarted:
            label = NSLocalizedString("status_not_started", comment: "Not started status")
            color = .gray
        case .inProgress:
            label = NSLocalizedString("status_in_progress", comment: "In progress status")
            color = .orange
        case .completed:
            label = NSLocalizedString("status_completed", comment: "Completed status")
            color = .green
        }
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}
