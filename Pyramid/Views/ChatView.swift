import SwiftUI
import UIKit

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var settings: AppSettings
    @State private var showSessions = false
    @State private var editingMessage: ChatMessage?
    @State private var messageToDelete: ChatMessage?
    @State private var regenerateMessage: ChatMessage?
    @State private var showCopiedFeedback = false
    @FocusState private var inputFocused: Bool

    init(settings: AppSettings, store: ChatStore, worldBook: WorldBookStore) {
        self.store = store
        self.worldBook = worldBook
        self.settings = settings
        _viewModel = StateObject(wrappedValue: ChatViewModel(settings: settings, store: store, worldBook: worldBook))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
            messageList
            inputBar
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
            SessionListView(store: store, worldBook: worldBook)
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

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.messages.isEmpty {
                        Text("发送一条消息开始对话")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { _, message in
                        MessageBubble(
                            message: message,
                            isSending: viewModel.isSending,
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
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("输入消息…", text: $viewModel.input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
            Button {
                viewModel.send()
                inputFocused = false
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(
                viewModel.isSending
                    || viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding()
        .background(.bar)
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.red)
            .padding(.horizontal)
            .padding(.top, 4)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var isSending = false
    var onCopy: () -> Void = {}
    var onEdit: () -> Void = {}
    var onRegenerate: () -> Void = {}
    var onDelete: () -> Void = {}

    private static let collapseThreshold = 800
    @State private var expanded = false

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }
            Group {
                if message.role == .assistant {
                    assistantContent
                } else {
                    Text(message.content)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.role == .user ? Color.accentColor : Color(.secondarySystemBackground))
            .foregroundStyle(message.role == .user ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
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
            if message.role == .assistant {
                Spacer(minLength: 48)
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
        ChatView(settings: AppSettings(), store: ChatStore(), worldBook: WorldBookStore())
    }
}
