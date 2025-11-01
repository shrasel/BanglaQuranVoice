# BanglaQuran

BanglaQuran is a SwiftUI iOS application that helps listeners browse the full list of surahs, stream or download ayah-level recitations, and track their listening progress in Bangla. The app focuses on an accessible listening experience with quick filtering, resuming, and remote-playback controls.

## Highlights

- 🇧🇩 **Bangla-first experience** with localized strings and Bangla metadata for surahs and ayat.
- 🎧 **Dual-track playback** that lets listeners switch between Arabic recitation and Bangla narration on demand.
- ⏯️ **Persistent resume & mini player** so users can continue listening from where they left off.
- 📥 **Managed downloads** with background URLSession support and automatic next-ayah prefetching over Wi-Fi.
- 🔍 **Smart library tools** including revelation-type filters, inline search, and progress summaries for every surah.

## Requirements

- macOS with Xcode 16.0 (or newer) and the iOS 18 / Simulator 26.0 SDK installed.
- Swift 6 toolchain (enabled via new Swift concurrency and Sendable checks in the build settings).
- A simulator or device running iOS 18.0+.

> The project currently targets the `iPhone 17` simulator during CI and local builds. Update the destination if you prefer a different device.

## Project Structure

```
BanglaQuran/
├─ BanglaQuran/                 # Main app target
│  ├─ App/                      # AppEnvironment and dependency bootstrapping
│  ├─ Assets.xcassets/          # App icon & accent color
│  ├─ Models/                   # Data models (Surah, Ayah, enums)
│  ├─ Preferences/              # User defaults & settings helpers
│  ├─ Persistence/              # Listening progress persistence
│  ├─ Repositories/             # Manifest-backed Quran repository
│  ├─ Resources/                # Localized strings & JSON manifest
│  ├─ Services/                 # Audio playback & download services
│  ├─ ViewModels/               # ObservableObject view models (Swift concurrency ready)
│  └─ Views/                    # SwiftUI views for navigation, detail, preferences, etc.
├─ BanglaQuranTests/            # Unit tests (expand as features grow)
├─ BanglaQuranUITests/          # UI testing scaffolding
└─ BanglaQuran.xcodeproj/       # Xcode project & workspace files
```

## Getting Started

1. **Clone the repo**
   ```bash
   git clone https://github.com/<your-org>/BanglaQuran.git
   cd BanglaQuran
   ```
2. **Open in Xcode**
   ```bash
   open BanglaQuran.xcodeproj
   ```
3. **Select the BanglaQuran scheme** and the simulator or device you want to run on.
4. **Build & run** (⌘R) to launch the app.

### Command-line build

To verify the project builds without launching Xcode:
```bash
xcodebuild -scheme BanglaQuran \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    build
```

## Architecture Notes

- `AppEnvironment` centralizes dependency creation and injects repositories, services, and view models throughout the SwiftUI hierarchy.
- `ManifestQuranRepository` loads surah metadata from `Resources/surahs_manifest.json` and synthesizes placeholder ayah text; update this file when real content becomes available.
- `AudioPlaybackService` orchestrates `AVPlayer`, updates Now Playing metadata, manages remote command center hooks, and records listening state in `ListeningProgressStore`.
- `DownloadManager` uses a background `URLSession` to cache ayah audio locally, persisting successful downloads and restoring them on relaunch.
- View models (e.g., `SurahListViewModel`, `PlaybackViewModel`) are `@MainActor`-isolated and leverage Swift concurrency for async loading.

## Localization & Content

- Localized strings live under `Resources/en.lproj` and `Resources/bn.lproj`.
- The surah manifest (`surahs_manifest.json`) currently contains seed data. Replace it with real metadata/URLs when production-ready.
- Audio URLs are stubbed (`https://cdn.quranbanglaplayer.example/...`); configure the real CDN endpoint or integrate download authentication as needed.

## Testing

- **Unit tests:**
  ```bash
  xcodebuild test -scheme BanglaQuran -destination 'platform=iOS Simulator,name=iPhone 17'
  ```
- **UI tests:** `BanglaQuranUITests` contains launch smoke tests—expand with navigation and playback coverage when UI stabilizes.

## Troubleshooting

- **Duplicate file errors:** Ensure only one copy of `AppEnvironment.swift` is referenced in the project file if you reorganize folders.
- **ObservableObject conformance:** Import `Combine` in any file that adds new `ObservableObject` classes.
- **Concurrency warnings:** The project opts into upcoming Swift 6 checks. Wrap actor-isolated calls on the main actor or mark methods `async`/`await` accordingly when extending services.
- **Audio playback issues:** Confirm your simulator has audio output enabled, and update the CDN path if you host new files.

## Roadmap / Maintenance

- Replace placeholder ayah text with real Quranic content.
- Finish Preferences UI to cover all playback/download settings.
- Expand UI tests to cover mini player interactions and offline playback.
- Monitor Swift & iOS SDK changes—update this README when deployment targets or build tooling shift.

## Contributing

1. Create a feature branch, make changes, and add tests where relevant.
2. Run `xcodebuild` (build + tests) before submitting a pull request.
3. Update this README if you introduce new build steps, dependencies, or significant features to keep onboarding smooth.

---

Maintained with ❤️. When you add new capabilities or adjust the workflow, please revisit this document so future contributors stay in sync.
