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
            Button {
                viewModel.send()
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

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }
            Text(message.content)
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
