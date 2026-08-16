import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var presets: PresetStore
    @ObservedObject var characters: CharacterStore
    @State private var showQuickSwitcher = false
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            ChatView(settings: settings, store: store, worldBook: worldBook, presets: presets, characters: characters)
                .opacity(selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(selectedTab == 0)
            SettingsView(settings: settings, worldBook: worldBook, store: store, presets: presets, characters: characters)
                .opacity(selectedTab == 1 ? 1 : 0)
                .allowsHitTesting(selectedTab == 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            CustomTabBar(selectedTab: $selectedTab) {
                showQuickSwitcher = true
            }
        }
        .dismissKeyboardOnOutsideTap()
        .sheet(isPresented: $showQuickSwitcher) {
            QuickSwitcherView(store: store, characters: characters, dismissTab: { showQuickSwitcher = false })
        }
    }
}

/// 自定义底部 Tab 栏。原生 tabItem 不支持长按手势与触觉反馈，
/// 因此改为自定义实现：聊天按钮点按切页、长按触发切换会话网格。
struct CustomTabBar: View {
    @Binding var selectedTab: Int
    var onChatLongPress: () -> Void
    @GestureState private var chatPressing = false

    var body: some View {
        HStack(spacing: 0) {
            chatButton
            settingsButton
        }
        .padding(.top, 6)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var chatButton: some View {
        Button {
            selectedTab = 0
        } label: {
            tabLabel("bubble.left.and.bubble.right", "聊天", active: selectedTab == 0)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(TabBarButtonStyle())
        .scaleEffect(chatPressing ? 0.82 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.55), value: chatPressing)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .updating($chatPressing) { value, state, _ in state = value }
                .onEnded { _ in
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onChatLongPress()
                }
        )
        .accessibilityLabel("聊天，长按切换会话")
    }

    private var settingsButton: some View {
        Button {
            selectedTab = 1
        } label: {
            tabLabel("gearshape", "设置", active: selectedTab == 1)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(TabBarButtonStyle())
        .accessibilityLabel("设置")
    }

    private func tabLabel(_ icon: String, _ title: String, active: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
            Text(title)
                .font(.caption2)
        }
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct TabBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}

struct QuickSwitcherView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var characters: CharacterStore
    var dismissTab: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
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
                                    size: 48
                                )
                                Text(session.title)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
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
        .presentationDetents([.medium, .large])
    }
}