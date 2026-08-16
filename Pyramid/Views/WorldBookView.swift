import SwiftUI

struct WorldBookView: View {
    @ObservedObject var store: WorldBookStore
    @ObservedObject var settings: AppSettings
    @State private var editingEntry: WorldBookEntry?

    var body: some View {
        List {
            Section {
                Toggle("启用世界书", isOn: $settings.worldBookEnabled)
            }
            Section("条目（\(store.entries.count)）") {
                if store.entries.isEmpty {
                    Text("暂无条目，点右上角 + 新建")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.entries) { entry in
                    Button {
                        editingEntry = entry
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.title.isEmpty ? "未命名" : entry.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if entry.isConstant {
                                    Text("常驻")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(entry.content)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text("关键词：\(entry.keywords.joined(separator: "、"))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete(perform: deleteEntries)
            }
        }
        .navigationTitle("世界书")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    editingEntry = WorldBookEntry()
                } label: {
                    Label("新建", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingEntry) { entry in
            WorldBookEditView(entry: entry) { updated in
                if store.entries.contains(where: { $0.id == updated.id }) {
                    store.update(updated)
                } else {
                    store.add(updated)
                }
            }
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        let ids = offsets.map { store.entries[$0].id }
        for id in ids {
            store.delete(id)
        }
    }
}

#Preview {
    NavigationStack {
        WorldBookView(store: WorldBookStore(), settings: AppSettings())
    }
}
