import SwiftUI
import UIKit

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var presets: PresetStore
    @ObservedObject var characters: CharacterStore
    @State private var showSessions = false
    @State private var editingMessage: ChatMessage?
    @State private var messageToDelete: ChatMessage?
    @State private var regenerateMessage: ChatMessage?
    @State private var showCopiedFeedback = false
    @State private var showRolePicker = false
    @State private var pendingRole: Character?
    @State private var showRoleAction = false
    @State private var showDuplicateAlert = false
    @FocusState private var inputFocused: Bool
    @State private var lastSessionID: UUID?

    init(settings: AppSettings, store: ChatStore, worldBook: WorldBookStore, presets: PresetStore, characters: CharacterStore) {
        self.store = store
        self.worldBook = worldBook
        self.settings = settings
        self.presets = presets
        self.characters = characters
        _viewModel = StateObject(wrappedValue: ChatViewModel(settings: settings, store: store, worldBook: worldBook, characters: characters, presets: presets))
    }

    private var currentCharacter: Character? {
        characters.character(for: store.currentSession?.characterId)
    }

    var body: some View {
        chatScreen
    }

    private var chatScreen: some View {
        chatScreenDialogs
            .sheet(isPresented: $showSessions, content: sessionsSheet)
            .sheet(isPresented: $showRolePicker, content: rolePickerSheet)
            .sheet(item: $editingMessage, content: editMessageSheet)
            .confirmationDialog(
                "应用到当前会话？",
                isPresented: $showRoleAction,
                titleVisibility: .visible
            ) {
                roleActionButtons
            } message: {
                Text("选择「绑定到当前会话」会替换本对话的角色；选择「新建对话窗」会新开一个对话。")
            }
            .alert(
                "该角色已有对话窗",
                isPresented: $showDuplicateAlert
            ) {
                duplicateAlertButtons
            } message: {
                Text("该角色已绑定其他对话窗，仍要新建一个吗？")
            }
            .confirmationDialog(
                "删除这条消息？",
                isPresented: deleteDialogBinding,
                titleVisibility: .visible
            ) {
                deleteMessageButtons
            } message: {
                Text("删除后无法恢复。")
            }
            .confirmationDialog(
                "重新生成回复？",
                isPresented: regenerateDialogBinding,
                titleVisibility: .visible
            ) {
                regenerateMessageButtons
            } message: {
                Text("将删除该回复及其后的所有消息，并重新请求。")
            }
    }

    private var chatScreenDialogs: some View {
        chatContent
            .navigationTitle(store.currentSession?.title ?? "Pyramid")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { chatToolbar }
            .overlay(alignment: .bottom) { copiedFeedbackOverlay }
            .onAppear { handleAppear() }
            .onChange(of: store.currentSessionID) { oldValue, newID in
                viewModel.handleSessionChange(previousID: oldValue, newID: newID)
                lastSessionID = newID
            }
            .onChange(of: viewModel.input) { _, _ in
                viewModel.persistDraft()
            }
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
            sessionBar()
            messageList
            if settings.showContextHint {
                contextHintBar
            }
            inputBar
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSessions = true
            } label: {
                Image(systemName: "text.bubble")
            }
            .accessibilityLabel("会话列表")
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                Button {
                    copyAllToPasteboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(viewModel.messages.isEmpty)
                .accessibilityLabel("复制本会话全部对话")
                AvatarView(
                    imageData: settings.userAvatarData.isEmpty ? nil : settings.userAvatarData,
                    name: settings.userName.isEmpty ? "我" : settings.userName,
                    size: 26
                )
                .accessibilityLabel("当前用户")
            }
        }
    }

    @ViewBuilder
    private func sessionsSheet() -> some View {
        SessionListView(store: store, worldBook: worldBook, settings: settings, presets: presets, characters: characters)
    }

    @ViewBuilder
    private func rolePickerSheet() -> some View {
        RolePickerView(characters: characters.characters) { role in
            handleRoleSelection(role)
        }
    }

    @ViewBuilder
    private func editMessageSheet(_ message: ChatMessage) -> some View {
        EditMessageSheet(initialText: message.content) { text in
            viewModel.editMessage(message, newContent: text)
        }
    }

    @ViewBuilder
    private var copiedFeedbackOverlay: some View {
        if showCopiedFeedback {
            Text("已复制本会话全部对话")
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 8)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var roleActionButtons: some View {
        if let role = pendingRole {
            Button("绑定到当前会话") {
                if let sid = store.currentSessionID { store.setCharacter(role.id, for: sid) }
                pendingRole = nil
            }
            Button("新建对话窗") {
                if store.sessions.contains(where: { $0.characterId == role.id && $0.id != store.currentSessionID }) {
                    showDuplicateAlert = true
                } else {
                    createSession(with: role)
                    pendingRole = nil
                }
            }
            Button("取消", role: .cancel) { pendingRole = nil }
        }
    }

    @ViewBuilder
    private var duplicateAlertButtons: some View {
        if let role = pendingRole {
            Button("仍要新建") {
                createSession(with: role)
                pendingRole = nil
            }
            Button("取消", role: .cancel) { pendingRole = nil }
        }
    }

    @ViewBuilder
    private var deleteMessageButtons: some View {
        Button("删除", role: .destructive) {
            if let message = messageToDelete {
                viewModel.deleteMessage(message)
            }
            messageToDelete = nil
        }
        Button("取消", role: .cancel) { messageToDelete = nil }
    }

    @ViewBuilder
    private var regenerateMessageButtons: some View {
        Button("重新生成") {
            if let message = regenerateMessage,
               let index = viewModel.messages.firstIndex(where: { $0.id == message.id }) {
                viewModel.regenerate(at: index)
            }
            regenerateMessage = nil
        }
        Button("取消", role: .cancel) { regenerateMessage = nil }
    }

    private func sessionBar() -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                AvatarView(
                    imageData: currentCharacter?.avatarData,
                    name: currentCharacter?.name ?? "未绑定角色",
                    size: 28
                )
                Text(currentCharacter?.name ?? "未绑定角色")
                    .font(.subheadline)
                    .fontWeight(currentCharacter == nil ? .regular : .medium)
                    .foregroundStyle(currentCharacter == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前角色")
            Spacer()
            Button {
                showRolePicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                    Text("切换")
                        .font(.footnote)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换绑定角色")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func handleRoleSelection(_ role: Character?) {
        if let role {
            pendingRole = role
            showRoleAction = true
        } else {
            if let sid = store.currentSessionID {
                store.setCharacter(nil, for: sid)
            }
        }
    }

    private func createSession(with role: Character) {
        let session = store.createSession()
        store.setCharacter(role.id, for: session.id)
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { messageToDelete != nil },
            set: { if !$0 { messageToDelete = nil } }
        )
    }

    private var regenerateDialogBinding: Binding<Bool> {
        Binding(
            get: { regenerateMessage != nil },
            set: { if !$0 { regenerateMessage = nil } }
        )
    }

    private var conversationText: String {
        viewModel.messages.map { message in
            "\(message.role == .user ? "用户" : "助手")：\n\(message.content)"
        }
        .joined(separator: "\n\n")
    }

    private var contextCharacterCount: Int {
        viewModel.trimmedContextCharacterCount
    }

    private var contextHintBar: some View {
        let count = contextCharacterCount
        let over = count > settings.contextLimit
        return HStack(spacing: 4) {
            if over {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
            }
            Text("\(count / 1000)k")
                .font(.caption2.monospacedDigit())
            if over {
                Text("长")
                    .font(.caption2)
                    .bold()
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(over ? Color.orange : Color.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(.bar)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: settings.compactMode ? 6 : 12) {
                    if viewModel.messages.isEmpty {
                        Text("还没有消息，打个招呼开始对话吧")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                        MessageBubble(
                            message: message,
                            floorNumber: index + 1,
                            isSending: viewModel.isSending,
                            compact: settings.compactMode,
                            showTimestamp: settings.showTimestamps,
                            showAvatar: settings.showAvatars,
                            userAvatarData: settings.userAvatarData,
                            onCopy: { UIPasteboard.general.string = message.content },
                            onEdit: { editingMessage = message },
                            onRegenerate: { regenerateMessage = message },
                            onDelete: { messageToDelete = message }
                        )
                    }
                    if viewModel.isSending {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    if settings.showInjectionIndicator,
                       viewModel.lastInjectedCount > 0,
                       viewModel.messages.last?.role == .assistant {
                        Text("已注入世界书 \(viewModel.lastInjectedCount) 条")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, -4)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.scrollVersion) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("输入消息…", text: $viewModel.input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
            if viewModel.isSending {
                Button {
                    viewModel.cancelCurrent()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("停止生成")
            } else {
                Button {
                    viewModel.send()
                    inputFocused = false
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .background(.bar)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white)
                .lineLimit(3)
            Spacer(minLength: 0)
            if viewModel.lastFailedUserMessageID != nil {
                Button("重试") {
                    viewModel.retryLastFailed()
                }
                .font(.footnote.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.2), in: Capsule())
            }
            Button {
                viewModel.errorMessage = nil
                viewModel.lastFailedUserMessageID = nil
                viewModel.lastFailedReason = nil
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("关闭错误提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red)
    }

    private func handleAppear() {
        if lastSessionID != store.currentSessionID {
            viewModel.handleSessionChange(previousID: lastSessionID, newID: store.currentSessionID)
            lastSessionID = store.currentSessionID
        }
    }

    private func copyAllToPasteboard() {
        UIPasteboard.general.string = conversationText
        withAnimation { showCopiedFeedback = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showCopiedFeedback = false }
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(
            settings: AppSettings(),
            store: ChatStore(),
            worldBook: WorldBookStore(),
            presets: PresetStore(),
            characters: CharacterStore()
        )
    }
}
