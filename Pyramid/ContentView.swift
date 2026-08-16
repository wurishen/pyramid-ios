import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var presets: PresetStore
    @ObservedObject var characters: CharacterStore
    @State private var showQuickSwitcher = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView(settings: settings, store: store, worldBook: worldBook, presets: presets, characters: characters)
                .tabItem {
                    Label("聊天", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(0)
                .onLongPressGesture(minimumDuration: 0.5) {
                    showQuickSwitcher = true
                }
            SettingsView(settings: settings, worldBook: worldBook, store: store, presets: presets, characters: characters)
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(1)
        }
        .dismissKeyboardOnOutsideTap()
        .sheet(isPresented: $showQuickSwitcher) {
            QuickSwitcherView(store: store, characters: characters, dismissTab: { showQuickSwitcher = false })
        }
    }
}

struct QuickSwitcherView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var characters: CharacterStore
    var dismissTab: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(store.sessions) { session in
                        Button {
                            store.select(session.id)
                            dismiss()
                            dismissTab()
                        } label: {
                            VStack(spacing: 6) {
                                let char = characters.character(for: session.characterId)
                                AvatarView(
                                    imageData: char?.avatarData,
                                    name: char?.name ?? session.title,
                                    size: 56
                                )
                                Text(session.title)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("切换会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        store.createSession()
                        dismiss()
                        dismissTab()
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
