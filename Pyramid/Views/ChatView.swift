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
        .onAppear {
            if lastSessionID != store.currentSessionID {
                viewModel.handleSessionChange(previousID: lastSessionID, newID: store.currentSessionID)
                lastSessionID = store.currentSessionID
            }
        }
        .onChange(of: store.currentSessionID) { oldValue, newValue in
            viewModel.handleSessionChange(previousID: oldValue, newValue: newValue)
            lastSessionID = newValue
        }
        .onChange(of: viewModel.input) { _, _ in
            viewModel.persistDraft()
        }
        .navigationTitle(store.currentSession?.title ?? "Pyramid")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
                        UIPasteboard.general.string = conversationText
                        withAnimation { showCopiedFeedback = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showCopiedFeedback = false }
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(viewModel.messages.isEmpty)
                    .accessibilityLabel("复制本会话全部对话")
                    // 用户头像放右侧 — 酒馆（SillyTavern）风格：你本人始终在右。
                    AvatarView(
                        imageData: settings.userAvatarData.isEmpty ? nil : settings.userAvatarData,
                        name: settings.userName.isEmpty ? "我" : settings.userName,
                        size: 26
                    )
                    .accessibilityLabel("当前用户")
                }
            }
        }
        .overlay(alignment: .bottom) {
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
        .sheet(isPresented: $showSessions) {
            SessionListView(store: store, worldBook: worldBook, settings: settings, presets: presets, characters: characters)
        }
        .sheet(isPresented: $showRolePicker) {
            RolePickerView(characters: characters.characters) { role in
                handleRoleSelection(role)
            }
        }
        .confirmationDialog(
            "应用到当前会话？",
            isPresented: $showRoleAction,
            titleVisibility: .visible
        ) {
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
        } message: {
            Text("选择「绑定到当前会话」会替换本对话的角色；选择「新建对话窗」会新开一个对话。")
        }
        .alert("该角色已有对话窗", isPresented: $showDuplicateAlert) {
            if let role = pendingRole {
                Button("仍要新建") {
                    createSession(with: role)
                    pendingRole = nil
                }
                Button("取消", role: .cancel) { pendingRole = nil }
            }
        } message: {
            Text("该角色已绑定其他对话窗，仍要新建一个吗？")
        }
        .sheet(item: $editingMessage) { message in
            EditMessageSheet(initialText: message.content) { text in
                viewModel.editMessage(message, newContent: text)
            }
        }
        .confirmationDialog(
            "删除这条消息？",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let message = messageToDelete {
                    viewModel.deleteMessage(message)
                }
                messageToDelete = nil
            }
            Button("取消", role: .cancel) { messageToDelete = nil }
        } message: {
            Text("删除后无法恢复。")
        }
        .confirmationDialog(
            "重新生成回复？",
            isPresented: regenerateDialogBinding,
            titleVisibility: .visible
        ) {
            Button("重新生成") {
                if let message = regenerateMessage,
                   let index = viewModel.messages.firstIndex(where: { $0.id == message.id }) {
                    viewModel.regenerate(at: index)
                }
                regenerateMessage = nil
            }
            Button("取消", role: .cancel) { regenerateMessage = nil }
        } message: {
            Text("将删除该回复及其后的所有消息，并重新请求。")
        }
    }

    private func sessionBar() -> some View {
        HStack(spacing: 12) {
            // 左侧：当前角色卡头像 + 名称（不可点，仅展示）。
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
            // 右侧：切换绑定角色按钮（点开 RolePickerView）。
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
}

struct RolePickerView: View {
    let characters: [Character]
    var onSelect: (Character?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    dismiss()
                    onSelect(nil)
                } label: {
                    Label("不绑定角色", systemImage: "person.crop.circle.badge.minus")
                }
                if characters.isEmpty {
                    Text("还没有角色卡，请在「设置 → 角色卡」中新建或导入。")
                        .foregroundStyle(.secondary)
                }
                ForEach(characters) { character in
                    Button {
                        dismiss()
                        onSelect(character)
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(imageData: character.avatarData, name: character.name, size: 32)
                            Text(character.name.isEmpty ? "未命名" : character.name)
                                .foregroundStyle(.primary)
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
        .presentationDetents([.medium, .large])
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var floorNumber: Int = 0
    var isSending = false
    var compact = false
    var showTimestamp = false
    var showAvatar = false
    var userAvatarData: Data? = nil
    var onCopy: () -> Void = {}
    var onEdit: () -> Void = {}
    var onRegenerate: () -> Void = {}
    var onDelete: () -> Void = {}

    private static let collapseThreshold = 800
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 48)
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if message.role == .assistant {
                        Text("\(floorNumber)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    bubbleContent
                }
                HStack(spacing: 6) {
                    if message.role == .user {
                        if let createdAt = message.createdAt, showTimestamp {
                            Text(createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text("\(floorNumber)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        if let createdAt = message.createdAt, showTimestamp {
                            Text(createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            if message.role == .user {
                if showAvatar {
                    AvatarView(imageData: userAvatarData, name: "我", size: 28)
                }
            } else {
                Spacer(minLength: 48)
            }
        }
    }

    private var bubbleContent: some View {
        Group {
            if message.role == .assistant {
                assistantContent
            } else {
                Text(message.content)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 4 : 8)
        .background(message.role == .user ? Color.accentColor : Color(.systemGray5))
        .foregroundStyle(message.role == .user ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 14))
        .contextMenu {
            Button(action: onCopy) {
                Label("复制", systemImage: "doc.on.doc")
            }
            if !isSending {
                Button(action: onEdit) {
                    Label("编辑", systemImage: "pencil")
                }
                if message.role == .assistant {
                    Button(action: onRegenerate) {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private var assistantContent: some View {
        let isLong = message.content.count > Self.collapseThreshold
        return VStack(alignment: .leading, spacing: 6) {
            MarkdownTextView(text: expanded ? message.content : collapsedContent)
            if isLong {
                Button(expanded ? "收起" : "展开") {
                    withAnimation { expanded.toggle() }
                }
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var collapsedContent: String {
        guard message.content.count > Self.collapseThreshold else { return message.content }
        let end = message.content.index(message.content.startIndex, offsetBy: Self.collapseThreshold)
        return String(message.content[..<end]) + "…"
    }
}

struct MarkdownTextView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownParser.blocks(from: text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            UIApplication.shared.open(url)
            return .handled
        })
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let string):
            Text(attributed(string))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(items[index].prefix)
                            .foregroundStyle(.secondary)
                        Text(attributed(items[index].content))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func attributed(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string)) ?? AttributedString(string)
    }
}

private enum MarkdownBlock: Hashable {
    case paragraph(String)
    case codeBlock(String)
    case list([MarkdownListItem])
}

private struct MarkdownListItem: Hashable {
    let prefix: String
    let content: String
}

private enum MarkdownParser {
    static func blocks(from text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if line.hasPrefix("```") {
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                continue
            }

            if let item = listItem(from: line) {
                var items = [item]
                index += 1
                while index < lines.count, let next = listItem(from: lines[index]) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count {
                let next = lines[index]
                if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if next.hasPrefix("```") { break }
                if listItem(from: next) != nil { break }
                paragraphLines.append(next)
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        return blocks
    }

    private static func listItem(from line: String) -> MarkdownListItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return MarkdownListItem(
                prefix: "•",
                content: String(trimmed.dropFirst(2))
            )
        }

        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let numberPart = trimmed[trimmed.startIndex..<dotIndex]
        guard !numberPart.isEmpty, numberPart.allSatisfy({ $0.isNumber }) else { return nil }
        let afterDotIndex = trimmed.index(after: dotIndex)
        let afterDot = trimmed[afterDotIndex...]
        guard afterDot.first == " " else { return nil }
        return MarkdownListItem(
            prefix: String(trimmed[trimmed.startIndex...dotIndex]) + " ",
            content: String(afterDot)
        )
    }
}

struct EditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    private let onSave: (String) -> Void

    init(initialText: String, onSave: @escaping (String) -> Void) {
        _text = State(initialValue: initialText)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("编辑消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
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
