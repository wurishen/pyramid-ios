import SwiftUI
import UniformTypeIdentifiers

struct WorldBookView: View {
    @ObservedObject var store: WorldBookStore
    @ObservedObject var settings: AppSettings
    @State private var viewingBookID: UUID
    @State private var editingEntry: WorldBookEntry?
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var pendingImportData: Data?
    @State private var showImportModeDialog = false
    @State private var importErrorMessage: String?

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
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    ShareLink(
                        item: JSONFileDocument(text: store.exportJSON(books: [currentBook])),
                        preview: SharePreview("世界书：\(currentBook.title)", image: Image(systemName: "book"))
                    )
                    ShareLink(
                        item: JSONFileDocument(text: store.exportJSON(books: store.books)),
                        preview: SharePreview("全部世界书", image: Image(systemName: "books.vertical"))
                    )
                    Divider()
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("导入导出")
                Button {
                    editingEntry = WorldBookEntry()
                } label: {
                    Label("新建", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            handleImportResult(result)
        }
        .confirmationDialog(
            "如何导入？",
            isPresented: $showImportModeDialog,
            titleVisibility: .visible
        ) {
            Button("合并（按 id 去重）") { performImport(mode: .merge) }
            Button("覆盖", role: .destructive) { performImport(mode: .overwrite) }
            Button("取消", role: .cancel) { pendingImportData = nil }
        } message: {
            Text("覆盖将替换当前全部世界书。")
        }
        .alert("导入失败", isPresented: importErrorBinding) {
            Button("好", role: .cancel) { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
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

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                pendingImportData = data
                showImportModeDialog = true
            } catch {
                importErrorMessage = "无法读取文件：\(error.localizedDescription)"
            }
        }
    }

    private func performImport(mode: WorldBookImportMode) {
        guard let data = pendingImportData else { return }
        pendingImportData = nil
        do {
            try store.importBooks(from: data, mode: mode)
            if mode == .overwrite {
                viewingBookID = store.globalBook.id
            }
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        let ids = offsets.map { filteredEntries[$0].id }
        for id in ids {
            store.deleteEntry(id, in: currentBook.id)
        }
    }
}

struct JSONFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

#Preview {
    NavigationStack {
        WorldBookView(store: WorldBookStore(), settings: AppSettings())
    }
}
