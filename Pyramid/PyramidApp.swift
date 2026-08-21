import SwiftUI
import SwiftData

@main
struct PyramidApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var store = ChatStore()
    @StateObject private var worldBook = WorldBookStore()
    @StateObject private var presets = PresetStore()
    @StateObject private var characters = CharacterStore()
    @StateObject private var displayRegexes = DisplayRegexStore()

    @Environment(\.scenePhase) private var scenePhase

    /// SwiftData 容器（foundation only）。当前阶段没有任何 store / view 真正消费它，
    /// 注入的目的是让编译期校验 schema、并在磁盘上准备好 store 文件供后续迁移使用。
    /// 完整数据迁移见 `docs/MIGRATION_TO_SWIFTDATA.md`。
    private let modelContainer: ModelContainer = PersistenceController.shared

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
        .modelContainer(modelContainer)
    }
}
