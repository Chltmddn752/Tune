import SwiftData
import SwiftUI

@main
struct TuneApp: App {
    private let container: ModelContainer
    @State private var player = PlayerEngine.shared
    @State private var importer = LibraryImporter()
    @State private var router = Router()
    @AppStorage(SettingsKey.theme) private var theme: ThemeOption = .system
    @AppStorage(SettingsKey.accent) private var accent: AccentOption = .pink
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppGroup.migrateFallbackIfNeeded()
        do {
            container = try ModelContainer(
                for: Track.self, Album.self, Artist.self, Playlist.self, PlaylistEntry.self, PlayEvent.self, LyricsCache.self,
                WishItem.self
            )
        } catch {
            // 저장소가 깨졌으면 새로 만든다.
            let config = ModelConfiguration(isStoredInMemoryOnly: false)
            try? FileManager.default.removeItem(at: config.url)
            container = try! ModelContainer(
                for: Track.self, Album.self, Artist.self, Playlist.self, PlaylistEntry.self, PlayEvent.self, LyricsCache.self,
                WishItem.self
            )
        }
        PlayerEngine.shared.attach(context: container.mainContext)
        PlaybackCommandRouter.handler = { command in
            PlayerEngine.shared.handle(command)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(player)
                .environment(importer)
                .environment(router)
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
                .onOpenURL { url in
                    if url.scheme == "tune" {
                        router.showPlayer = true
                    } else if url.isFileURL {
                        Task { await importer.importPicked([url], context: container.mainContext) }
                    }
                }
                .task {
                    LibraryMaintenance.splitCombinedArtists(context: container.mainContext)
                    LibraryMaintenance.normalizeUnicode(context: container.mainContext)
                    LibraryMaintenance.mergeSplitAlbums(context: container.mainContext)
                    importer.clearUnplayable()
                    await importer.scanDocuments(context: container.mainContext)
                    await importer.refreshIncompleteTracks(context: container.mainContext)
                    LibraryMaintenance.mergeSplitAlbums(context: container.mainContext)
                    LibraryMatcher.pruneWishlist(context: container.mainContext)
                    importer.startWatching(context: container.mainContext)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task {
                            await importer.scanDocuments(context: container.mainContext)
                            importer.startWatching(context: container.mainContext)
                        }
                    case .background:
                        importer.stopWatching()
                    default:
                        break
                    }
                }
        }
        .modelContainer(container)
    }
}
