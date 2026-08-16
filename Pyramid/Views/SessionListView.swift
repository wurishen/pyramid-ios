import SwiftUI

struct SessionListView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var presets: PresetStore
    @Environment(\.dismiss) private var dismiss
    @State private var detailSession: ChatSession?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.sessions) { session in
                        Button {
                            store.select(session.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(session.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if hasCustomSystemPrompt(session) {
                                        Text("自定义提示")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    Spacer(minLength: 0)
                                }
                                Text(metaText(for: session))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                detailSession = session
                            } label: {
                                Label("绑定世界书", systemImage: "book")
                            }
                            .tint(.blue)
                        }
                    }
                    .onDelete(perform: deleteSessions)
                } footer: {
                    Text("左滑可设置「绑定世界书」。")
                }
            }
            .navigationTitle("会话")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        store.createSession()
                        dismiss()
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .sheet(item: $detailSession) { session in
            SessionDetailView(
                store: store,
                worldBook: worldBook,
                settings: settings,
                presets: presets,
                sessionID: session.id
            )
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        let ids = offsets.map { store.sessions[$0].id }
        for id in ids {
            store.delete(id)
        }
    }

    private func metaText(for session: ChatSession) -> String {
        var parts = ["\(session.messages.count) 条消息"]
        if let bookTitle = boundWorldBookTitle(for: session) {
            parts.append(bookTitle)
        }
        return parts.joined(separator: " · ")
    }

    private func boundWorldBookTitle(for session: ChatSession) -> String? {
        guard let id = session.worldBookId else { return nil }
        return worldBook.books.first(where: { $0.id == id })?.title
    }

    private func hasCustomSystemPrompt(_ session: ChatSession) -> Bool {
        let prompt = session.systemPrompt ?? ""
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#Preview {
    SessionListView(
        store: ChatStore(),
        worldBook: WorldBookStore(),
        settings: AppSettings(),
        presets: PresetStore()
    )
}
