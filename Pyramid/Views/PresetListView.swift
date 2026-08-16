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

    init(preset: Preset, worldBook: WorldBookStore, onSave: @escaping (Preset) -> Void) {
        self.preset = preset
        self.worldBook = worldBook
        self.onSave = onSave
        _name = State(initialValue: preset.name)
        _modelName = State(initialValue: preset.modelName ?? "")
        _systemPrompt = State(initialValue: preset.systemPrompt ?? "")
        _worldBookId = State(initialValue: preset.worldBookId)
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
                                worldBookId: worldBookId
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
}

#Preview {
    NavigationStack {
        PresetListView(store: PresetStore(), worldBook: WorldBookStore())
    }
}
