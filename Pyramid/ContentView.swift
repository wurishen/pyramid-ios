import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var presets: PresetStore
    @ObservedObject var characters: CharacterStore
    @ObservedObject var displayRegexes: DisplayRegexStore
    @State private var showQuickSwitcher = false
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            ChatView(
                settings: settings,
                store: store,
                worldBook: worldBook,
                presets: presets,
                characters: characters,
                displayRegexes: displayRegexes
            )
            .opacity(selectedTab == 0 ? 1 : 0)
            .allowsHitTesting(selectedTab == 0)
            SettingsView(
                settings: settings,
                worldBook: worldBook,
                store: store,
                presets: presets,
                characters: characters,
                displayRegexes: displayRegexes
            )
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
        .overlay(alignment: .bottom) {
            if showQuickSwitcher {
                QuickSwitcherBubbles(
                    store: store,
                    characters: characters,
                    onDismiss: { showQuickSwitcher = false }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: showQuickSwitcher)
    }
}

/// 自定义底部 Tab 栏。原生 tabItem 不支持长按手势与触觉反馈，
/// 因此改为自定义实现：聊天按钮点按切页、长按触发悬浮气泡条。
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

/// 长按聊天 Tab 弹出的悬浮气泡条。
/// 半透明背景之上，一行圆形气泡贴在底部 Tab 上方；
/// 每个气泡 = 某会话的角色卡头像，气泡下方显示会话名。
/// 末尾是「+」气泡，用于以新角色卡建一个聊天窗。
struct QuickSwitcherBubbles: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var characters: CharacterStore
    var onDismiss: () -> Void

    @State private var showCharacterPicker = false
    @State private var pendingCharacter: Character?
    @State private var showDuplicateAlert = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // 背景蒙层：点击空白处关掉气泡条。
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            bubbleBar
                .padding(.bottom, 12) // 贴底部 Tab 上方
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
                        onDismiss()
                    }
                }
                Button("仍要新建") {
                    store.createSession(character: char)
                    pendingCharacter = nil
                    onDismiss()
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

    private var bubbleBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 14) {
                if store.sessions.isEmpty {
                    Text("还没有对话，点 + 开聊")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                } else {
                    ForEach(store.orderedSessions()) { session in
                        BubbleCell(
                            session: session,
                            character: characters.character(for: session.characterId),
                            isCurrent: session.id == store.currentSessionID,
                            onTap: {
                                store.select(session.id)
                                onDismiss()
                            }
                        )
                    }
                }
                // 末尾的「+」气泡：建新窗。
                AddBubble {
                    showCharacterPicker = true
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 60) // 抬起于 Tab 栏之上
    }

    private func handleCharacterPick(_ character: Character) {
        if store.hasOtherSession(for: character.id, excluding: UUID()) {
            pendingCharacter = character
            showDuplicateAlert = true
        } else {
            store.createSession(character: character)
            onDismiss()
        }
    }

    private func existingSession(for character: Character) -> ChatSession? {
        store.sessions.first { $0.characterId == character.id }
    }
}

/// 单个圆形气泡：头像 + 会话名（去重后的）。
private struct BubbleCell: View {
    let session: ChatSession
    let character: Character?
    let isCurrent: Bool
    var onTap: () -> Void

    private var label: String {
        let trimmed = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != "新会话" { return trimmed }
        if let name = character?.name, !name.isEmpty { return name }
        return "新会话"
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    if isCurrent {
                        Circle()
                            .stroke(Color.accentColor, lineWidth: 2.5)
                            .frame(width: 62, height: 62)
                    }
                    Circle()
                        .fill(Color.accentColor.opacity(isCurrent ? 0.22 : 0.15))
                        .frame(width: 58, height: 58)
                    AvatarView(
                        imageData: character?.avatarData,
                        name: character?.name ?? label,
                        size: 48
                    )
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: 22, y: -22)
                    }
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 80)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 末尾的「+」气泡：点击唤起角色卡选择 Sheet。
private struct AddBubble: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 58, height: 58)
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text("新建")
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: 80)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新建对话窗")
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
