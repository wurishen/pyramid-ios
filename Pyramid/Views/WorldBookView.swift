import SwiftUI

struct WorldBookView: View {
    @ObservedObject var store: WorldBookStore
    @ObservedObject var settings: AppSettings
    @State private var viewingBookID: UUID
    @State private var editingEntry: WorldBookEntry?
    @State private var searchText = ""

    init(store: WorldBookStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        _viewingBookID = State(initialValue: store.globalBook.id)
    }

    private var currentBook: WorldBook {
        store.book(for: viewingBookID)
    }

    private var filteredEntries: [WorldBookEntry] {
        guard !searchText.isEmpty else { return currentBook.entries }
        let query = searchText.lowercased()
        return currentBook.entries.filter { entry in
            entry.title.lowercased().contains(query)
                || entry.keywords.contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("启用世界书", isOn: $settings.worldBookEnabled)
            }
            Section("当前世界书") {
                Picker("世界书", selection: $viewingBookID) {
                    ForEach(store.books) { book in
                        Text(book.title).tag(book.id)
                    }
                }
                Button {
                    let book = store.createBook()
                    viewingBookID = book.id
                } label: {
                    Label("新建世界书", systemImage: "plus.circle")
                }
            }
            Section("条目（\(filteredEntries.count)）") {
                if filteredEntries.isEmpty {
                    Text(searchText.isEmpty ? "暂无条目，点右上角 + 新建" : "没有匹配的条目")
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredEntries) { entry in
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
        .searchable(text: $searchText, prompt: "搜索标题或关键词")
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
                if currentBook.entries.contains(where: { $0.id == updated.id }) {
                    store.update(updated, in: currentBook.id)
                } else {
                    store.add(updated, to: currentBook.id)
                }
            }
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        let ids = offsets.map { filteredEntries[$0].id }
        for id in ids {
            store.deleteEntry(id, in: currentBook.id)
        }
    }
}

#Preview {
    NavigationStack {
        WorldBookView(store: WorldBookStore(), settings: AppSettings())
    }
}
