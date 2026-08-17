import SwiftUI

@main
struct PyramidApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var store = ChatStore()
    @StateObject private var worldBook = WorldBookStore()
    @StateObject private var presets = PresetStore()
    @StateObject private var characters = CharacterStore()
    @StateObject private var displayRegexes = DisplayRegexStore()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(
                settings: settings,
                store: store,
                worldBook: worldBook,
                presets: presets,
                characters: characters,
                displayRegexes: displayRegexes
            )
            .onChange(of: scenePhase) { _, newPhase in
                // 离开前台前强制 flush 节流中的 save，避免 OS kill 时丢数据。
                if newPhase == .background || newPhase == .inactive {
                    store.flushPendingSave()
                }
            }
        }
    }
}
