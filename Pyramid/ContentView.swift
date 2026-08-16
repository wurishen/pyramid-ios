import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var presets: PresetStore

    var body: some View {
        TabView {
            ChatView(settings: settings, store: store, worldBook: worldBook, presets: presets)
                .tabItem {
                    Label("聊天", systemImage: "bubble.left.and.bubble.right")
                }
            SettingsView(settings: settings, worldBook: worldBook, store: store, presets: presets)
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
        .dismissKeyboardOnOutsideTap()
    }
}
