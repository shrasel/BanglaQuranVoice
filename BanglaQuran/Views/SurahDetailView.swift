import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SurahDetailView: View {
    @StateObject var viewModel: SurahDetailViewModel

    init(viewModel: SurahDetailViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                playbackSection
                displaySection
                downloadSummarySection
                if let error = viewModel.errorMessage, viewModel.ayat.isEmpty {
                    errorSection(error: error)
                }
                ayahSection
            }
            .listStyle(.plain)
            .navigationTitle(viewModel.surah.englishName)
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if viewModel.isLoading && viewModel.ayat.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground).opacity(0.8))
                }
            }
            .onChange(of: viewModel.focusedAyahId) { id in
                guard let id else { return }
                withAnimation {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
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
            }
        }
        .task {
            await viewModel.load()
        }
    }

    private var playbackSection: some View {
        Section(header: Text(NSLocalizedString("surah_playback_section_header", comment: "Playback section header"))) {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    Task { await viewModel.handlePrimaryAction() }
                } label: {
                    Label(viewModel.primaryButtonTitle, systemImage: viewModel.primaryButtonIconName)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if viewModel.showRestartButton {
                    Button {
                        Task { await viewModel.restartSurah() }
                    } label: {
                        Label(NSLocalizedString("restart_surah_button_label", comment: "Restart surah"), systemImage: "gobackward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("audio_track_picker_label", comment: "Audio track picker label"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { viewModel.currentTrack }, set: { track in
                        Task { await viewModel.selectTrack(track) }
                    })) {
                        ForEach(AudioTrack.allCases) { track in
                            Text(track.displayName).tag(track)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Button {
                    viewModel.downloadCurrentTrack()
                } label: {
                    Label(NSLocalizedString("download_current_track_button", comment: "Download current track"), systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
    }

    private var displaySection: some View {
        Section {
            Toggle(isOn: Binding(get: { viewModel.showBanglaText }, set: { viewModel.toggleBanglaVisibility($0) })) {
                Text(NSLocalizedString("toggle_bangla_text", comment: "Toggle Bangla text label"))
            }
        }
    }

    private var downloadSummarySection: some View {
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
    }

    private var ayahSection: some View {
        Section(header: Text(NSLocalizedString("ayah_section_header", comment: "Ayah section header"))) {
            ForEach(viewModel.ayat) { item in
                AyahRowView(item: item,
                            showBanglaText: viewModel.showBanglaText,
                            surahIsPlaying: viewModel.isSurahPlaying,
                            playAction: {
                                Task { await viewModel.handleAyahTapped(item) }
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
                    .id(item.id)
            }
        }
    }

    private func errorSection(error: String) -> some View {
        Section {
            VStack(spacing: 12) {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button(NSLocalizedString("retry_label", comment: "Retry")) {
                    Task { await viewModel.load(force: true) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

private struct AyahRowView: View {
    let item: SurahDetailViewModel.AyahItem
    let showBanglaText: Bool
    let surahIsPlaying: Bool
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
                        Label(buttonTitle, systemImage: buttonIcon)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(item.isActivelyPlaying ? .accentColor : .secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background {
            if item.isCurrent {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.1))
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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

    private var buttonTitle: String {
        if item.isCurrent {
            if surahIsPlaying {
                return NSLocalizedString("pause_button_label", comment: "Pause label")
            }
            return NSLocalizedString("resume_button_label", comment: "Resume label")
        }
        return NSLocalizedString("play_button_label", comment: "Play label")
    }

    private var buttonIcon: String {
        if item.isCurrent {
            return surahIsPlaying ? "pause.circle.fill" : "play.circle.fill"
        }
        return "play.circle"
    }
}
