import SwiftUI

struct PresetListView: View {
    @ObservedObject var store: PresetStore
    @ObservedObject var worldBook: WorldBookStore
    @State private var editingPreset: Preset?

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
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    editingPreset = Preset(name: "")
                } label: {
                    Label("新建", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingPreset) { preset in
            PresetEditView(preset: preset, worldBook: worldBook) { updated in
                store.upsert(updated)
            }
        }
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

    init(preset: Preset, worldBook: WorldBookStore, onSave: @escaping (Preset) -> Void) {
        self.preset = preset
        self.worldBook = worldBook
        self.onSave = onSave
        _name = State(initialValue: preset.name)
        _modelName = State(initialValue: preset.modelName ?? "")
        _systemPrompt = State(initialValue: preset.systemPrompt ?? "")
        _worldBookId = State(initialValue: preset.worldBookId)
        _temperatureText = State(initialValue: preset.temperature.map { String(format: "%.2f", $0) } ?? "")
        _topPText = State(initialValue: preset.topP.map { String(format: "%.2f", $0) } ?? "")
        _maxTokensText = State(initialValue: preset.maxTokens.map(String.init) ?? "")
        _hasSampling = State(initialValue: preset.temperature != nil || preset.topP != nil || preset.maxTokens != nil)
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
            }
            .navigationTitle(preset.name.isEmpty ? "新建预设" : "编辑预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(
                            Preset(
                                id: preset.id,
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                modelName: trimmedOrNil(modelName),
                                systemPrompt: trimmedOrNil(systemPrompt),
                                worldBookId: worldBookId,
                                temperature: hasSampling ? parseDouble(temperatureText) : nil,
                                topP: hasSampling ? parseDouble(topPText) : nil,
                                maxTokens: hasSampling ? parseInt(maxTokensText) : nil
                            )
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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
        PresetListView(store: PresetStore(), worldBook: WorldBookStore())
    }
}
