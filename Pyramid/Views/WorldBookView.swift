import SwiftUI
import UniformTypeIdentifiers
import os

private let importLog = Logger(subsystem: "pyramid.import", category: "WorldBookView")

struct WorldBookView: View {
    @ObservedObject var store: WorldBookStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var characters: CharacterStore
    @State private var viewingBookID: UUID
    @State private var editingEntry: WorldBookEntry?
    @State private var searchText = ""
    @State private var showDocumentPicker = false
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
    @State private var showCreateBookDialog = false
    @State private var newBookName = ""
    @State private var renameTargetID: UUID?
    @State private var showRenameDialog = false
    @State private var showDeleteBookConfirm = false
    @State private var pendingImportMode: ImportScope = .globalEnabled
    @State private var pendingBindCharacter: Character?

    private enum ImportScope: String, CaseIterable, Identifiable {
        case globalEnabled = "global"
        case bindCurrentCharacter = "character"
        case inactive = "inactive"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .globalEnabled: return "全局启用（默认）"
            case .bindCurrentCharacter: return "绑定到当前角色"
            case .inactive: return "仅入库，不注入"
            }
        }
    }

    init(store: WorldBookStore, settings: AppSettings, characters: CharacterStore) {
        self.store = store
        self.settings = settings
        self.characters = characters
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
                HStack(spacing: 8) {
                    Picker("世界书", selection: $viewingBookID) {
                        ForEach(store.books) { book in
                            Text(book.title).tag(book.id)
                        }
                    }
                    if store.books.count > 1 {
                        Button {
                            renameTargetID = viewingBookID
                            newBookName = store.book(for: viewingBookID).title
                            showRenameDialog = true
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("重命名当前世界书")
                        Button {
                            showDeleteBookConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("删除当前世界书")
                    }
                }
                Toggle("全局启用", isOn: globalEnabledBinding)
                Text(scopeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    newBookName = ""
                    showCreateBookDialog = true
                } label: {
                    Label("新建世界书", systemImage: "plus.circle")
                }
            }
            Section("角色绑定") {
                Picker("绑定到角色", selection: boundCharacterBinding) {
                    Text("不绑定").tag(Optional<UUID>.none)
                    ForEach(characters.characters) { char in
                        Text(char.name.isEmpty ? "未命名" : char.name).tag(Optional(char.id))
                    }
                }
                Text("角色绑定：当前选中的世界书会与该角色一同注入；同一角色的世界书可被多个角色独立绑定。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    Menu {
                        Button {
                            pendingBindCharacter = nil
                            showDocumentPicker = true
                        } label: {
                            Label("不指定角色（按导入对话框选择）", systemImage: "person.crop.circle.dashed")
                        }
                        ForEach(characters.characters) { char in
                            Button {
                                pendingBindCharacter = char
                                showDocumentPicker = true
                            } label: {
                                Text("导入后绑到「\(char.name.isEmpty ? "未命名" : char.name)」")
                            }
                        }
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
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(
                allowedTypes: importContentTypes,
                allowsMultipleSelection: true,
                onPicked: { urls in handleImportResult(.success(urls)) },
                onCancel: {}
            )
        }
        .confirmationDialog(
            "如何导入？",
            isPresented: $showImportModeDialog,
            titleVisibility: .visible
        ) {
            if let content = pendingImportContent {
                if content.isSillyTavern {
                    Button("新建世界书（\(importTitleSuggestion)）— 全局启用") {
                        let count = content.entries.count
                        let book = store.createBook(title: importTitleSuggestion, entries: content.entries, isGloballyEnabled: true)
                        viewingBookID = book.id
                        advanceImportQueue()
                        showImportSuccess("已导入 \(count) 条")
                    }
                    if let char = pendingBindCharacter {
                        Button("新建世界书（\(importTitleSuggestion)）— 绑定到「\(char.name.isEmpty ? "未命名" : char.name)」") {
                            let count = content.entries.count
                            let book = store.createBook(title: importTitleSuggestion, entries: content.entries, isGloballyEnabled: false)
                            characters.upsert(Character(
                                id: char.id,
                                name: char.name,
                                avatarData: char.avatarData,
                                description: char.description,
                                personality: char.personality,
                                scenario: char.scenario,
                                systemPrompt: char.systemPrompt,
                                worldBookId: book.id
                            ))
                            viewingBookID = book.id
                            advanceImportQueue()
                            showImportSuccess("已导入 \(count) 条并绑到「\(char.name.isEmpty ? "未命名" : char.name)」")
                        }
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
                    Button("合并（按 id 去重，默认全局启用）") {
                        let result = store.importBooks(content.books, mode: .merge)
                        advanceImportQueue()
                        showImportSuccess("已导入 \(result.books) 本 / \(result.entries) 条")
                    }
                    if let char = pendingBindCharacter {
                        Button("合并入库并绑到「\(char.name.isEmpty ? "未命名" : char.name)」") {
                            let result = store.importBooks(content.books, mode: .merge)
                            if let first = result.firstBookID {
                                characters.upsert(Character(
                                    id: char.id,
                                    name: char.name,
                                    avatarData: char.avatarData,
                                    description: char.description,
                                    personality: char.personality,
                                    scenario: char.scenario,
                                    systemPrompt: char.systemPrompt,
                                    worldBookId: first
                                ))
                                viewingBookID = first
                            }
                            advanceImportQueue()
                            showImportSuccess("已导入 \(result.books) 本 / \(result.entries) 条（绑到「\(char.name.isEmpty ? "未命名" : char.name)」）")
                        }
                    }
                    Button("覆盖（替换全部世界书）", role: .destructive) {
                        let result = store.importBooks(content.books, mode: .overwrite)
                        viewingBookID = store.globalBook.id
                        advanceImportQueue()
                        showImportSuccess("已导入 \(result.books) 本 / \(result.entries) 条")
                    }
                    Button("取消", role: .cancel) { cancelImportQueue() }
                }
            }
        } message: {
            if let content = pendingImportContent {
                let remaining = pendingImportContents.count - pendingImportIndex - 1
                let suffix = remaining > 0 ? "（还有 \(remaining) 个文件待处理）" : ""
                if content.isSillyTavern {
                    Text("识别为酒馆（SillyTavern）世界书，共 \(content.entries.count) 条条目。\(suffix)")
                } else {
                    Text("合并按 id 去重；覆盖替换当前全部世界书。\(suffix)")
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
        .alert("新建世界书", isPresented: $showCreateBookDialog) {
            TextField("世界书名称", text: $newBookName)
            Button("创建") {
                let name = newBookName.trimmingCharacters(in: .whitespacesAndNewlines)
                let book = name.isEmpty ? store.createBook() : store.createBook(title: name)
                viewingBookID = book.id
            }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名世界书", isPresented: $showRenameDialog) {
            TextField("世界书名称", text: $newBookName)
            Button("保存") {
                if let id = renameTargetID {
                    store.renameBook(id, to: newBookName)
                }
                renameTargetID = nil
            }
            Button("取消", role: .cancel) { renameTargetID = nil }
        }
        .confirmationDialog(
            "删除世界书？",
            isPresented: $showDeleteBookConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                store.deleteBook(viewingBookID)
                viewingBookID = store.globalBook.id
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后其中的条目无法恢复。")
        }
    }

    private var exportSheetBinding: Binding<Bool> {
        Binding(
            get: { exportFileURL != nil },
            set: { if !$0 { exportFileURL = nil } }
        )
    }

    private var globalEnabledBinding: Binding<Bool> {
        Binding(
            get: { currentBook.isGloballyEnabled },
            set: { store.setGloballyEnabled($0, for: viewingBookID) }
        )
    }

    private var boundCharacterBinding: Binding<UUID?> {
        Binding(
            get: {
                characters.characters.first { $0.worldBookId == viewingBookID }?.id
            },
            set: { newID in
                if let char = characters.characters.first(where: { $0.id == newID }) {
                    characters.upsert(Character(
                        id: char.id,
                        name: char.name,
                        avatarData: char.avatarData,
                        description: char.description,
                        personality: char.personality,
                        scenario: char.scenario,
                        systemPrompt: char.systemPrompt,
                        worldBookId: viewingBookID
                    ))
                }
            }
        )
    }

    private var scopeDescription: String {
        if currentBook.isGloballyEnabled {
            return "当前作用域：全局启用，进入会话时自动随匹配注入。"
        }
        if let char = characters.characters.first(where: { $0.worldBookId == viewingBookID }) {
            return "当前作用域：仅与「\(char.name.isEmpty ? "未命名" : char.name)」绑定。仅在选用该角色时注入。"
        }
        return "当前作用域：未启用。需要在 Picker 之外的会话中手动选择或上方设开关启用。"
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
        // fileImporter 的回调可能在后台线程触发，所有 @State 修改与后续弹窗都必须在主线程，
        // 否则点「打开」后零反馈。整段放主线程保证结果一定呈到 UI。
        DispatchQueue.main.async { [self] in
            switch result {
            case .failure(let error):
                importLog.error("import callback returned failure: \(error.localizedDescription)")
                importErrorMessage = error.localizedDescription
            case .success(let urls):
                guard !urls.isEmpty else {
                    importLog.error("import callback returned no URLs")
                    importErrorMessage = "未选择任何文件"
                    return
                }
                pendingImportContents = []
                pendingImportFileNames = []
                pendingImportIndex = 0
                for url in urls {
                    do {
                        let data = try ImportSupport.readImportedData(from: url)
                        importLog.info("read \(data.count) bytes from \(url.lastPathComponent)")
                        let content = try store.parseImportData(data)
                        importLog.info("parsed \(content.books.count) book(s) / \(content.entries.count) entry(ies) from \(url.lastPathComponent)")
                        pendingImportContents.append(content)
                        pendingImportFileNames.append(url.deletingPathExtension().lastPathComponent)
                    } catch {
                        importLog.error("import failed for \(url.lastPathComponent): \(error.localizedDescription)")
                        importErrorMessage = error.localizedDescription
                        return
                    }
                }
                self.showNextImportDialog()
            }
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
        WorldBookView(store: WorldBookStore(), settings: AppSettings(), characters: CharacterStore())
    }
}
