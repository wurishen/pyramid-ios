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
        // iOS 系统长按桌面 App 的反馈：缩放到 ~0.92 + 蒙白 + 触觉 + 中心放大动画。
        // 比单纯 scaleEffect 更接近系统的"按下"手感。
        .scaleEffect(chatPressing ? 0.92 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(chatPressing ? 0.18 : 0))
                .padding(.horizontal, 24)
                .padding(.vertical, 2)
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: chatPressing)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .updating($chatPressing) { value, state, _ in
                    if value && !state {
                        // 长按刚触发时立即给一个 strong 触觉，模拟 iOS 主屏 App 弹起的触感
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    }
                    state = value
                }
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

/// 长按聊天按钮弹出的会话网格。
/// 顶部长条栏放当前角色卡头像（居中）+ 右侧「选择角色卡」按钮。
/// 下方是带角色头像的圆形气泡网格，气泡下方显示会话名。
struct QuickSwitcherView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var characters: CharacterStore
    var dismissTab: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showCharacterPicker = false
    @State private var pendingCharacter: Character?
    @State private var showDuplicateAlert = false

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 14)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topBar
                grid
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("切换会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showCharacterPicker) {
            CharacterPickerSheet(characters: characters.characters) { character in
                handleCharacterPick(character)
            }
        }
        .alert("已有同角色对话", isPresented: $showDuplicateAlert) {
            if let char = pendingCharacter {
                if let existing = existingSession(for: char) {
                    Button("打开已有") {
                        store.select(existing.id)
                        pendingCharacter = nil
                        dismiss()
                        dismissTab()
                    }
                }
                Button("仍要新建") {
                    store.createSession(character: char)
                    pendingCharacter = nil
                    dismiss()
                    dismissTab()
                }
                Button("取消", role: .cancel) { pendingCharacter = nil }
            }
        } message: {
            if let char = pendingCharacter {
                Text("「\(char.name)」已绑定到其他对话。可以打开已有对话，或继续新建一个。")
            } else {
                Text("该角色已绑定到其他对话。")
            }
        }
    }

    /// 顶部长条栏：当前角色卡头像居中 + 右侧「+ 选择角色卡」按钮。
    private var topBar: some View {
        HStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 56, height: 56)
                AvatarView(
                    imageData: currentCharacter?.avatarData,
                    name: currentCharacter?.name ?? "未绑定",
                    size: 48
                )
            }
            .opacity(currentCharacter == nil ? 0.55 : 1.0)
            Spacer()
            Button {
                showCharacterPicker = true
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 22, weight: .medium))
                    Text("选择角色卡")
                        .font(.caption2)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var currentCharacter: Character? {
        characters.character(for: store.currentSession?.characterId)
    }

    private var grid: some View {
        ScrollView {
            if store.sessions.isEmpty {
                Text("暂无对话，点右上角「选择角色卡」开始。")
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(store.sessions) { session in
                        Button {
                            store.select(session.id)
                            dismiss()
                            dismissTab()
                        } label: {
                            bubbleCell(for: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
    }

    private func bubbleCell(for session: ChatSession) -> some View {
        let char = characters.character(for: session.characterId)
        let label = displayTitle(for: session, character: char)
        let isCurrent = session.id == store.currentSessionID
        return VStack(spacing: 6) {
            ZStack {
                if isCurrent {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2.5)
                        .frame(width: 70, height: 70)
                }
                Circle()
                    .fill(Color.accentColor.opacity(isCurrent ? 0.22 : 0.15))
                    .frame(width: 66, height: 66)
                AvatarView(
                    imageData: char?.avatarData,
                    name: char?.name ?? label,
                    size: 56
                )
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.accentColor, in: Circle())
                        .offset(x: 24, y: -24)
                }
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(1)
                .frame(maxWidth: 88)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
    }

    /// 气泡下方的会话标签。
    /// 优先级: 显式标题（非「新会话」占位）→ 角色名 → 「新会话」。
    /// 旧版本只读 `session.title`，遇到首条消息还没写入的会话就会显示空 / 截断后的「…」。
    private func displayTitle(for session: ChatSession, character: Character?) -> String {
        let trimmed = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != "新会话" {
            return trimmed
        }
        if let name = character?.name, !name.isEmpty {
            return name
        }
        return "新会话"
    }

    private func handleCharacterPick(_ character: Character) {
        if store.hasOtherSession(for: character.id, excluding: UUID()) {
            pendingCharacter = character
            showDuplicateAlert = true
        } else {
            store.createSession(character: character)
            dismiss()
            dismissTab()
        }
    }

    private func existingSession(for character: Character) -> ChatSession? {
        store.sessions.first { $0.characterId == character.id }
    }
}

/// 角色卡选择器（只列已存在角色卡，不提供新建/编辑入口）。
struct CharacterPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let characters: [Character]
    var onPick: (Character) -> Void

    var body: some View {
        NavigationStack {
            List {
                if characters.isEmpty {
                    Text("还没有角色卡，先到「设置 → 角色卡」新建。")
                        .foregroundStyle(.secondary)
                }
                ForEach(characters) { character in
                    Button {
                        onPick(character)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(imageData: character.avatarData, name: character.name, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(character.name.isEmpty ? "未命名" : character.name)
                                    .foregroundStyle(.primary)
                                if !character.description.isEmpty {
                                    Text(character.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("选择角色卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
