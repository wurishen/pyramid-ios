import SwiftUI
import UniformTypeIdentifiers

struct PresetListView: View {
    @ObservedObject var store: PresetStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var displayRegexes: DisplayRegexStore
    @State private var editingPreset: Preset?
    @State private var showImporter = false
    @State private var importError: String?
    @State private var importSuccess: String?

    var body: some View {
        List {
            if store.presets.isEmpty {
                Text("还没有预设，点右上角 + 新建。")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.presets) { preset in
                Button {
                    editingPreset = preset
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.name)
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            if let model = preset.modelName, !model.isEmpty {
                                Text(model)
                            }
                            if let prompt = preset.systemPrompt, !prompt.isEmpty {
                                Text("自定义提示")
                            }
                            if let bookID = preset.worldBookId,
                               let book = worldBook.books.first(where: { $0.id == bookID }) {
                                Text(book.title)
                            }
                            if let t = preset.temperature {
                                Text("T=\(t, specifier: "%.2f")")
                            }
                            if let p = preset.topP {
                                Text("p=\(p, specifier: "%.2f")")
                            }
                            if let m = preset.maxTokens {
                                Text("≤\(m)")
                            }
                            if let flag = preset.enableMarkdown {
                                Text(flag ? "MD开" : "MD关")
                            }
                            if !preset.displayRegexIds.isEmpty {
                                Text("正则×\(preset.displayRegexIds.count)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: deletePresets)
        }
        .navigationTitle("预设管理")
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入预设", systemImage: "square.and.arrow.down")
                }
                Button {
                    editingPreset = Preset(name: "")
                } label: {
                    Label("新建", systemImage: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: importContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("导入失败", isPresented: importErrorBinding) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("导入完成", isPresented: importSuccessBinding) {
            Button("好", role: .cancel) { importSuccess = nil }
        } message: {
            Text(importSuccess ?? "")
        }
        .sheet(item: $editingPreset) { preset in
            PresetEditView(
                preset: preset,
                worldBook: worldBook,
                displayRegexes: displayRegexes
            ) { updated in
                store.upsert(updated)
            }
        }
    }

    /// SillyTavern OpenAI 预设 JSON 导入：文件名作预设名，prompts/prompt_order
    /// 拼系统提示词，采样标量直接映射。失败弹错误（含角色卡误投提示）。
    /// 与世界书导入同一套宽类型列表：iCloud / 部分网盘导出的 JSON 常缺 UTI 标注，
    /// 只放行 `.json` 会让文件在选择器里灰掉无法勾选（真机已踩坑）。
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

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        do {
            let data = try ImportSupport.readImportedData(from: url)
            let name = url.deletingPathExtension().lastPathComponent
            let presets = try ImportSupport.parsePresets(from: data, fallbackName: name)
            for preset in presets {
                store.upsert(preset)
            }
            importSuccess = "已导入 \(presets.count) 个预设：\(presets.map(\.name).joined(separator: "、"))"
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )
    }

    private var importSuccessBinding: Binding<Bool> {
        Binding(
            get: { importSuccess != nil },
            set: { if !$0 { importSuccess = nil } }
        )
    }

    private func deletePresets(at offsets: IndexSet) {
        let ids = offsets.map { store.presets[$0].id }
        for id in ids {
            store.delete(id)
        }
    }
}

struct PresetEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var displayRegexes: DisplayRegexStore
    private let preset: Preset
    private let onSave: (Preset) -> Void

    @State private var name: String
    @State private var modelName: String
    @State private var systemPrompt: String
    @State private var worldBookId: UUID?
    @State private var temperatureText: String
    @State private var topPText: String
    @State private var maxTokensText: String
    @State private var hasSampling: Bool
    /// 三态: nil = 沿用全局, true = 强制开, false = 强制关。
    @State private var markdownPolicy: MarkdownPolicy
    @State private var selectedRegexIDs: Set<UUID>

    enum MarkdownPolicy: Hashable {
        case useGlobal, on, off
    }

    init(
        preset: Preset,
        worldBook: WorldBookStore,
        displayRegexes: DisplayRegexStore,
        onSave: @escaping (Preset) -> Void
    ) {
        self.preset = preset
        self.worldBook = worldBook
        self.displayRegexes = displayRegexes
        self.onSave = onSave
        _name = State(initialValue: preset.name)
        _modelName = State(initialValue: preset.modelName ?? "")
        _systemPrompt = State(initialValue: preset.systemPrompt ?? "")
        _worldBookId = State(initialValue: preset.worldBookId)
        _temperatureText = State(initialValue: preset.temperature.map { String(format: "%.2f", $0) } ?? "")
        _topPText = State(initialValue: preset.topP.map { String(format: "%.2f", $0) } ?? "")
        _maxTokensText = State(initialValue: preset.maxTokens.map(String.init) ?? "")
        _hasSampling = State(initialValue: preset.temperature != nil || preset.topP != nil || preset.maxTokens != nil)
        switch preset.enableMarkdown {
        case .some(true):
            _markdownPolicy = State(initialValue: .on)
        case .some(false):
            _markdownPolicy = State(initialValue: .off)
        case .none:
            _markdownPolicy = State(initialValue: .useGlobal)
        }
        _selectedRegexIDs = State(initialValue: Set(preset.displayRegexIds))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("预设信息") {
                    TextField("名称", text: $name)
                }
                Section("模型") {
                    TextField("模型名（留空使用全局）", text: $modelName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("系统提示词") {
                    TextField("系统提示词（可留空）", text: $systemPrompt, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("世界书绑定") {
                    Picker("绑定世界书", selection: $worldBookId) {
                        Text("不绑定").tag(Optional<UUID>.none)
                        ForEach(worldBook.books) { book in
                            Text(book.title).tag(Optional(book.id))
                        }
                    }
                }
                Section {
                    Toggle("覆盖采样参数", isOn: $hasSampling)
                    if hasSampling {
                        TextField("温度 (0-2)", text: $temperatureText)
                            .keyboardType(.decimalPad)
                        TextField("Top P (0-1)", text: $topPText)
                            .keyboardType(.decimalPad)
                        TextField("最大输出 token", text: $maxTokensText)
                            .keyboardType(.numberPad)
                        Text("任一字段留空则不覆盖。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("采样参数")
                } footer: {
                    Text("开启后会随下次请求一起发到后端；未填写的字段维持原值。")
                }
                Section {
                    Picker("Markdown 渲染", selection: $markdownPolicy) {
                        Text("沿用全局").tag(MarkdownPolicy.useGlobal)
                        Text("强制开启").tag(MarkdownPolicy.on)
                        Text("强制关闭").tag(MarkdownPolicy.off)
                    }
                } header: {
                    Text("渲染")
                } footer: {
                    Text("仅影响气泡显示，永远不修改消息原文。")
                }
                Section {
                    if displayRegexes.regexes.isEmpty {
                        Text("还没有显示用正则。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(displayRegexes.regexes) { regex in
                            Toggle(regex.name.isEmpty ? regex.pattern : regex.name, isOn: binding(for: regex.id))
                        }
                        Text("未勾选任何正则 = 应用所有启用中的正则。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("关联的显示用正则")
                }
            }
            .navigationTitle(preset.name.isEmpty ? "新建预设" : "编辑预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let enableMarkdown: Bool?
                        switch markdownPolicy {
                        case .useGlobal: enableMarkdown = nil
                        case .on: enableMarkdown = true
                        case .off: enableMarkdown = false
                        }
                        onSave(
                            Preset(
                                id: preset.id,
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                modelName: trimmedOrNil(modelName),
                                systemPrompt: trimmedOrNil(systemPrompt),
                                worldBookId: worldBookId,
                                temperature: hasSampling ? parseDouble(temperatureText) : nil,
                                topP: hasSampling ? parseDouble(topPText) : nil,
                                maxTokens: hasSampling ? parseInt(maxTokensText) : nil,
                                enableMarkdown: enableMarkdown,
                                displayRegexIds: orderedSelectedRegexIDs()
                            )
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func binding(for regexID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedRegexIDs.contains(regexID) },
            set: { isOn in
                if isOn { selectedRegexIDs.insert(regexID) }
                else { selectedRegexIDs.remove(regexID) }
            }
        )
    }

    /// 保持原始正则列表的顺序，方便用户在 UI 上看到稳定的顺序。
    private func orderedSelectedRegexIDs() -> [UUID] {
        displayRegexes.regexes
            .map(\.id)
            .filter { selectedRegexIDs.contains($0) }
    }

    private func trimmedOrNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private func parseInt(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }
}

#Preview {
    NavigationStack {
        PresetListView(
            store: PresetStore(),
            worldBook: WorldBookStore(),
            displayRegexes: DisplayRegexStore()
        )
    }
}
