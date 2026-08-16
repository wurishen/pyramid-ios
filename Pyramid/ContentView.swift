import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ChatStore

    var body: some View {
        TabView {
            ChatView(settings: settings, store: store)
                .tabItem {
                    Label("聊天", systemImage: "bubble.left.and.bubble.right")
                }
            SettingsView(settings: settings)
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
    }
}
