import SwiftUI

struct SessionListView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
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
                                Text(session.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
            SessionDetailView(store: store, worldBook: worldBook, sessionID: session.id)
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        let ids = offsets.map { store.sessions[$0].id }
        for id in ids {
            store.delete(id)
        }
    }
}

#Preview {
    SessionListView(store: ChatStore(), worldBook: WorldBookStore())
}
