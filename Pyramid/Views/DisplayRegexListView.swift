import SwiftUI
import UniformTypeIdentifiers

struct DisplayRegexListView: View {
    @ObservedObject var store: DisplayRegexStore
    @State private var editing: DisplayRegexEditing?
    @State private var showImporter = false
    @State private var importError: String?
    @State private var importSuccess: String?

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
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入 SillyTavern 正则", systemImage: "square.and.arrow.down")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    editing = DisplayRegexEditing()
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
        .sheet(item: $editing) { editing in
            DisplayRegexEditView(
                editing: editing,
                onSave: { result in
                    store.upsert(result)
                }
            )
        }
    }

    /// ST Regex Script JSON 导入（单条对象或数组）。停用 / promptOnly /
    /// 非显示 placement 的脚本由 importer 过滤；全部被过滤时提示无可导入项。
    /// 与世界书导入同一套宽类型列表（缺 UTI 标注的 JSON 才能被勾选）。
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
            let regexes = try SillyTavernScriptImporter.importScripts(from: data)
            guard !regexes.isEmpty else {
                importError = "文件里没有可导入的显示用正则（已停用 / 仅提示词 / 非显示作用域的脚本会被跳过）"
                return
            }
            for regex in regexes {
                store.upsert(regex)
            }
            importSuccess = "已导入 \(regexes.count) 条正则脚本"
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
                        do {
                            try DisplayRegex.validate(pattern: editing.pattern)
                            onSave(editing.toRegex())
                            dismiss()
                        } catch {
                            validationError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
