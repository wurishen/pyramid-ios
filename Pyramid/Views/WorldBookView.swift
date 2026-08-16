import SwiftUI
import UniformTypeIdentifiers

struct WorldBookView: View {
    @ObservedObject var store: WorldBookStore
    @ObservedObject var settings: AppSettings
    @State private var viewingBookID: UUID
    @State private var editingEntry: WorldBookEntry?
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var pendingImportContent: WorldBookImportContent?
    @State private var pendingImportContents: [WorldBookImportContent] = []
    @State private var pendingImportFileNames: [String] = []
    @State private var pendingImportIndex = 0
    @State private var pendingImportFileName: String?
    @State private var showImportModeDialog = false
    @State private var importErrorMessage: String?
    @State private var importSuccessMessage: String?
    @State private var exportFileURL: URL?
    @State private var exportTitle = ""

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
                HStack {
                    Picker("世界书", selection: $viewingBookID) {
                        ForEach(store.books) { book in
                            Text(book.title).tag(book.id)
                        }
                    }
                    if store.books.count > 1 {
                        Button {
                            store.deleteBook(viewingBookID)
                            viewingBookID = store.globalBook.id
                        } label: {
                            Label("删除", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
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
                    Button {
                        exportTitle = currentBook.title.isEmpty ? "当前世界书" : currentBook.title
                        exportFileURL = store.writeExport(books: [currentBook], suffix: "current")
                    } label: {
                        Label("导出当前世界书", systemImage: "book")
                    }
                    Button {
                        exportTitle = "全部世界书"
                        exportFileURL = store.writeExport(books: store.books, suffix: "all")
                    } label: {
                        Label("导出全部世界书", systemImage: "books.vertical")
                    }
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
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importContentTypes, allowsMultipleSelection: true) { result in
            handleImportResult(result)
        }
        .confirmationDialog(
            "如何导入？",
            isPresented: $showImportModeDialog,
            titleVisibility: .visible
        ) {
            if let content = pendingImportContent {
                if content.isSillyTavern {
                    Button("新建世界书（\(importTitleSuggestion)）") {
                        let count = content.entries.count
                        let book = store.createBook(title: importTitleSuggestion, entries: content.entries)
                        viewingBookID = book.id
                        advanceImportQueue()
                        showImportSuccess("已导入 \(count) 条")
                    }
                    Button("合并到当前世界书") {
                        let count = store.mergeEntries(content.entries, into: currentBook.id)
                        advanceImportQueue()
                        showImportSuccess("已导入 \(count) 条")
                    }
                    Button("覆盖当前世界书条目", role: .destructive) {
                        let count = store.overwriteEntries(content.entries, in: currentBook.id)
                        advanceImportQueue()
                        showImportSuccess("已导入 \(count) 条")
                    }
                    Button("取消", role: .cancel) { cancelImportQueue() }
                } else {
                    Button("合并（按 id 去重）") {
                        let count = store.importBooks(content.books, mode: .merge)
                        advanceImportQueue()
                        showImportSuccess("已导入 \(count) 条")
                    }
                    Button("覆盖", role: .destructive) {
                        let count = store.importBooks(content.books, mode: .overwrite)
                        viewingBookID = store.globalBook.id
                        advanceImportQueue()
                        showImportSuccess("已导入 \(count) 条")
                    }
                    Button("取消", role: .cancel) { cancelImportQueue() }
                }
            }
        } message: {
            if let content = pendingImportContent {
                let remaining = pendingImportContents.count - pendingImportIndex - 1
                let suffix = remaining > 0 ? "（还有 \(remaining) 个文件待处理）" : ""
                if content.isSillyTavern {
                    Text("识别为酒馆（SillyTavern）世界书，共 \(content.entries.count) 条条目。合并会追加到当前世界书并按内容去重；覆盖会替换当前世界书的全部条目。\(suffix)")
                } else {
                    Text("覆盖将替换当前全部世界书。\(suffix)")
                }
            }
        }
        .alert("导入失败", isPresented: importErrorBinding) {
            Button("好", role: .cancel) { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
        .alert("导入完成", isPresented: importSuccessBinding) {
            Button("好", role: .cancel) { importSuccessMessage = nil }
        } message: {
            Text(importSuccessMessage ?? "")
        }
        .sheet(isPresented: exportSheetBinding) {
            if let url = exportFileURL {
                ExportShareSheet(url: url, title: exportTitle)
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

    private var exportSheetBinding: Binding<Bool> {
        Binding(
            get: { exportFileURL != nil },
            set: { if !$0 { exportFileURL = nil } }
        )
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )
    }

    private var importSuccessBinding: Binding<Bool> {
        Binding(
            get: { importSuccessMessage != nil },
            set: { if !$0 { importSuccessMessage = nil } }
        )
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else {
                importErrorMessage = "未选择任何文件"
                return
            }
            pendingImportContents = []
            pendingImportFileNames = []
            pendingImportIndex = 0
            for url in urls {
                do {
                    let data = try Self.readImportedData(from: url)
                    let content = try store.parseImportData(data)
                    pendingImportContents.append(content)
                    pendingImportFileNames.append(url.deletingPathExtension().lastPathComponent)
                } catch {
                    importErrorMessage = error.localizedDescription
                    return
                }
            }
            DispatchQueue.main.async { [self] in
                self.showNextImportDialog()
            }
        }
    }

    /// fileImporter 返回的是 security-scoped URL，须先 start/stop 访问，再拷贝到临时目录读取，
    /// 直接 `Data(contentsOf:)` 在真机上可能因权限/iCloud 占位文件失败。
    private static func readImportedData(from url: URL) throws -> Data {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
            return try Data(contentsOf: tempURL)
        } catch {
            throw error
        } finally {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func showNextImportDialog() {
        guard pendingImportIndex < pendingImportContents.count else { return }
        pendingImportContent = pendingImportContents[pendingImportIndex]
        pendingImportFileName = pendingImportFileNames[pendingImportIndex]
        showImportModeDialog = true
    }

    private var importContentTypes: [UTType] {
        [
            .json,
            .text,
            .plainText,
            .data,
            .item,
            UTType(filenameExtension: "json", conformingTo: .data) ?? .json,
        ]
    }

    private var importTitleSuggestion: String {
        if let name = pendingImportFileName, !name.isEmpty {
            return name
        }
        if let name = pendingImportContent?.suggestedTitle, !name.isEmpty {
            return name
        }
        return "世界书 \(store.books.count + 1)"
    }

    private func deleteEntries(at offsets: IndexSet) {
        let ids = offsets.map { filteredEntries[$0].id }
        for id in ids {
            store.deleteEntry(id, in: currentBook.id)
        }
    }

    private func advanceImportQueue() {
        pendingImportContent = nil
        pendingImportIndex += 1
        showNextImportDialog()
    }

    private func cancelImportQueue() {
        pendingImportContent = nil
        pendingImportContents = []
        pendingImportFileNames = []
        pendingImportIndex = 0
    }

    private func showImportSuccess(_ message: String) {
        importSuccessMessage = message
    }
}

struct ExportShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let title: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("「\(title)」已生成，点击右上角分享导出。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("导出世界书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: url, preview: SharePreview("世界书", image: Image(systemName: "book")))
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        WorldBookView(store: WorldBookStore(), settings: AppSettings())
    }
}
