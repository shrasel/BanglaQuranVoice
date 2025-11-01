import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var viewModel: PreferencesViewModel

    var body: some View {
        Form {
            Section(header: Text(NSLocalizedString("preferences_playback_section", comment: "Playback section header"))) {
                Picker(NSLocalizedString("arabic_reciter_picker", comment: "Arabic reciter picker"), selection: $viewModel.selectedArabicReciter) {
                    ForEach(viewModel.availableArabicReciters) { reciter in
                        Text(reciter.displayName).tag(reciter)
                    }
                }
                Picker(NSLocalizedString("bangla_narrator_picker", comment: "Bangla narrator picker"), selection: $viewModel.selectedBanglaNarrator) {
                    ForEach(viewModel.availableBanglaNarrators) { narrator in
                        Text(narrator.displayName).tag(narrator)
                    }
                }
                Toggle(NSLocalizedString("auto_download_toggle", comment: "Auto download toggle"), isOn: $viewModel.autoDownloadNextAyahOnWiFi)
            }

            Section(header: Text(NSLocalizedString("preferences_display_section", comment: "Display section header"))) {
                Toggle(NSLocalizedString("show_bangla_text_toggle", comment: "Show Bangla text toggle"), isOn: $viewModel.showBanglaText)
            }

            Section {
                Button(role: .destructive) {
                    viewModel.resetProgress()
                } label: {
                    Text(NSLocalizedString("reset_progress_button", comment: "Reset progress button"))
                }
            }
        }
        .navigationTitle(NSLocalizedString("preferences_title", comment: "Preferences title"))
    }
}
