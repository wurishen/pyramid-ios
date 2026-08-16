import SwiftUI

struct SessionListView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var presets: PresetStore
    @ObservedObject var characters: CharacterStore
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
                            HStack(spacing: 10) {
                                let char = characters.character(for: session.characterId)
                                AvatarView(
                                    imageData: char?.avatarData,
                                    name: char?.name ?? session.title,
                                    size: 40
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(session.title)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        if let char {
                                            Text(char.name)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if hasCustomSystemPrompt(session) {
                                            Text("自定义提示")
                                                .font(.caption2)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                                .foregroundStyle(Color.accentColor)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    HStack(spacing: 4) {
                                        if let lastMsg = session.messages.last {
                                            Text(lastMsg.content)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Text("·")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                        Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                detailSession = session
                            } label: {
                                Label("详情", systemImage: "gearshape")
                            }
                            .tint(.blue)
                        }
                    }
                    .onDelete(perform: deleteSessions)
                } footer: {
                    Text("左滑可设置角色卡、世界书、系统提示词。")
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
                characters: characters,
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
        presets: PresetStore(),
        characters: CharacterStore()
    )
}
