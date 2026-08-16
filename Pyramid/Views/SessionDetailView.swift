import SwiftUI

struct SessionDetailView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    let sessionID: UUID

    private var session: ChatSession? {
        store.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        Form {
            Section("世界书绑定") {
                Picker("绑定世界书", selection: binding) {
                    Text("不绑定（使用全局）").tag(Optional<UUID>.none)
                    ForEach(worldBook.books) { book in
                        Text(book.title).tag(Optional(book.id))
                    }
                }
                Text("绑定的会话只使用该书做关键词匹配注入；未绑定时回退到全局世界书。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("系统提示词") {
                TextEditor(text: systemPromptBinding)
                    .frame(minHeight: 100)
                Text("留空则使用全局系统提示词。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("会话信息") {
                LabeledContent("创建时间", value: session?.createdAt.formatted(date: .abbreviated, time: .shortened) ?? "—")
                LabeledContent("消息数", value: "\(session?.messages.count ?? 0)")
            }
        }
        .navigationTitle(session?.title ?? "会话详情")
    }

    private var binding: Binding<UUID?> {
        Binding(
            get: { store.sessions.first { $0.id == sessionID }?.worldBookId },
            set: { store.setWorldBook($0, for: sessionID) }
        )
    }

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { store.sessions.first { $0.id == sessionID }?.systemPrompt ?? "" },
            set: { store.setSystemPrompt($0, for: sessionID) }
        )
    }
}

#Preview {
    NavigationStack {
        SessionDetailView(store: ChatStore(), worldBook: WorldBookStore(), sessionID: UUID())
    }
}
