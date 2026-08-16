import SwiftUI

struct SessionListView: View {
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
                }
                .onDelete(perform: deleteSessions)
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
    }

    private func deleteSessions(at offsets: IndexSet) {
        let ids = offsets.map { store.sessions[$0].id }
        for id in ids {
            store.delete(id)
        }
    }
}

#Preview {
    SessionListView(store: ChatStore())
}
