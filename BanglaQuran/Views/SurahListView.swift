import SwiftUI

struct SurahListView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var viewModel: SurahListViewModel
    @EnvironmentObject private var playbackViewModel: PlaybackViewModel
    @EnvironmentObject private var preferencesViewModel: PreferencesViewModel

    @State private var showingPreferences = false
    @State private var showingFilterOptions = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.errorMessage != nil {
                    ErrorStateView(message: viewModel.errorMessage ?? "", retry: {
                        Task { await viewModel.load() }
                    })
                } else {
                    listContent
                }
            }
            .navigationTitle(NSLocalizedString("surah_list_title", comment: "Surah list title"))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    filterMenu
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingPreferences = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(NSLocalizedString("preferences_button_accessibility", comment: "Preferences button"))
                }
            }
            .searchable(text: $viewModel.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: NSLocalizedString("surah_search_placeholder", comment: "Search placeholder"))
            .task {
                await viewModel.load()
            }
            .safeAreaInset(edge: .bottom) {
                if playbackViewModel.hasActiveItem {
                    MiniPlayerView()
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                        .environmentObject(playbackViewModel)
                }
            }
        }
        .sheet(isPresented: $showingPreferences) {
            NavigationStack {
                PreferencesView()
                    .environmentObject(preferencesViewModel)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(NSLocalizedString("close_label", comment: "Close button")) {
                                showingPreferences = false
                            }
                        }
                    }
            }
        }
    }

    private var listContent: some View {
        List {
            if let continueItem = viewModel.continueListening {
                Section {
                    Button {
                        viewModel.resumePlayback()
                    } label: {
                        ContinueListeningRow(item: continueItem)
                    }
                }
            }
            Section {
                ForEach(viewModel.rows) { row in
                    NavigationLink {
                        SurahDetailView(viewModel: environment.makeDetailViewModel(for: row.surah))
                            .environmentObject(playbackViewModel)
                    } label: {
                        SurahRowView(row: row)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Button(NSLocalizedString("filter_all_label", comment: "Filter all")) {
                viewModel.revelationFilter = nil
            }
            ForEach(RevelationType.allCases) { type in
                Button(type.localizedName) {
                    viewModel.revelationFilter = type
                }
            }
        } label: {
            if let filter = viewModel.revelationFilter {
                Label(filter.localizedName, systemImage: "line.3.horizontal.decrease.circle")
            } else {
                Label(NSLocalizedString("filter_all_label", comment: "Filter all"), systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        .accessibilityLabel(NSLocalizedString("revelation_filter_accessibility", comment: "Filter menu accessibility label"))
    }
}

private struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
            Button(NSLocalizedString("retry_label", comment: "Retry label"), action: retry)
        }
        .padding()
    }
}

private struct ContinueListeningRow: View {
    let item: SurahListViewModel.ContinueListeningItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("continue_listening_title", comment: "Continue listening title"))
                    .font(.headline)
                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct SurahRowView: View {
    let row: SurahListViewModel.SurahRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(row.surah.id). \(row.surah.englishName)")
                    .font(.headline)
                Spacer()
                Text(row.surah.revelationType.localizedName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
            }
            Text(row.surah.arabicName)
                .font(.title3)
            if let bangla = row.surah.banglaName {
                Text(bangla)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(row.progress.localizedSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: NSLocalizedString("surah_ayah_count_format", comment: "Ayah count format"), row.surah.ayahCount))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}
