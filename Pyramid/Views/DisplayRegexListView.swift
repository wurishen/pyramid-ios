import SwiftUI

struct DisplayRegexListView: View {
    @ObservedObject var store: DisplayRegexStore
    @State private var editing: DisplayRegexEditing?

    var body: some View {
        List {
            Section {
                if store.regexes.isEmpty {
                    Text("还没有显示用正则。点右上角 + 新建；仅作用于助手消息的「渲染前」管道。")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.regexes) { regex in
                    Button {
                        editing = DisplayRegexEditing(from: regex)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(regex.name.isEmpty ? "(未命名)" : regex.name)
                                    .foregroundStyle(.primary)
                                if !regex.enabled {
                                    Text("已停用")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(regex.pattern)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .onDelete(perform: deleteRegexes)
            } footer: {
                Text("非法的正则表达式在保存时会被拒绝（不崩溃）。勾选仅在气泡上启用，不改写消息原文。")
            }
        }
        .navigationTitle("显示用正则")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    editing = DisplayRegexEditing()
                } label: {
                    Label("新建", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { editing in
            DisplayRegexEditView(
                editing: editing,
                onSave: { result in
                    store.upsert(result)
                }
            )
        }
    }

    private func deleteRegexes(at offsets: IndexSet) {
        let ids = offsets.map { store.regexes[$0].id }
        for id in ids { store.delete(id) }
    }
}

/// 支持 `.id` 走 sheet(item:) 的包装，避免每次 `init` 都重建新 UUID。
struct DisplayRegexEditing: Identifiable {
    var id: UUID
    var name: String
    var pattern: String
    var replacement: String
    var enabled: Bool

    init(from regex: DisplayRegex) {
        self.id = regex.id
        self.name = regex.name
        self.pattern = regex.pattern
        self.replacement = regex.replacement
        self.enabled = regex.enabled
    }

    init() {
        self.id = UUID()
        self.name = ""
        self.pattern = ""
        self.replacement = ""
        self.enabled = true
    }

    func toRegex() -> DisplayRegex {
        DisplayRegex(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            pattern: pattern,
            replacement: replacement,
            enabled: enabled
        )
    }
}

struct DisplayRegexEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var editing: DisplayRegexEditing
    let onSave: (DisplayRegex) -> Void
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("名称（仅显示用）", text: $editing.name)
                }
                Section {
                    TextField("正则表达式", text: $editing.pattern, axis: .vertical)
                        .lineLimit(1...6)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("匹配")
                } footer: {
                    Text("作用于助手消息的「渲染前」管道。原 . 表示任意字符含换行。")
                }
                Section("替换为") {
                    TextField("替换字符串", text: $editing.replacement, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.callout.monospaced())
                }
                Section {
                    Toggle("启用", isOn: $editing.enabled)
                }
                if let err = validationError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(editing.name.isEmpty ? "新建正则" : "编辑正则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        switch DisplayRegex.validate(pattern: editing.pattern) {
                        case .success:
                            onSave(editing.toRegex())
                            dismiss()
                        case .failure(let msg):
                            validationError = msg
                        }
                    }
                    .disabled(editing.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        DisplayRegexListView(store: DisplayRegexStore())
    }
}
