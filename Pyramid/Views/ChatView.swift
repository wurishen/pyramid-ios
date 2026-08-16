import SwiftUI
import UIKit

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    @State private var showSessions = false
    @State private var editingMessage: ChatMessage?
    @State private var editText = ""

    init(settings: AppSettings, store: ChatStore, worldBook: WorldBookStore) {
        self.store = store
        self.worldBook = worldBook
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
        .alert("编辑消息", isPresented: editAlertBinding) {
            TextField("内容", text: $editText)
            Button("取消", role: .cancel) { editingMessage = nil }
            Button("保存") {
                if let message = editingMessage {
                    viewModel.editMessage(message, newContent: editText)
                }
                editingMessage = nil
            }
        }
    }

    private var editAlertBinding: Binding<Bool> {
        Binding(
            get: { editingMessage != nil },
            set: { if !$0 { editingMessage = nil } }
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
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                        MessageBubble(
                            message: message,
                            onCopy: { UIPasteboard.general.string = message.content },
                            onEdit: {
                                editingMessage = message
                                editText = message.content
                            },
                            onRegenerate: { viewModel.regenerate(at: index) },
                            onDelete: { viewModel.deleteMessage(message) }
                        )
                    }
                    if viewModel.isSending {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
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
            if message.role == .assistant {
                Spacer(minLength: 48)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(settings: AppSettings(), store: ChatStore(), worldBook: WorldBookStore())
    }
}
