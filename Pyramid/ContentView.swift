import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore

    var body: some View {
        TabView {
            ChatView(settings: settings, store: store, worldBook: worldBook)
                .tabItem {
                    Label("聊天", systemImage: "bubble.left.and.bubble.right")
                }
            SettingsView(settings: settings, worldBook: worldBook, store: store)
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
    }
}
