import SwiftUI

struct WorldBookEditView: View {
    private let entry: WorldBookEntry
    private let onSave: (WorldBookEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var content: String
    @State private var keywordsText: String
    @State private var isConstant: Bool
    @State private var priority: Int
    @State private var matchMode: WorldBookMatchMode

    init(entry: WorldBookEntry, onSave: @escaping (WorldBookEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _title = State(initialValue: entry.title)
        _content = State(initialValue: entry.content)
        _keywordsText = State(initialValue: entry.keywords.joined(separator: "，"))
        _isConstant = State(initialValue: entry.isConstant)
        _priority = State(initialValue: entry.priority)
        _matchMode = State(initialValue: entry.matchMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标题") {
                    TextField("条目标题", text: $title)
                }
                Section("内容") {
                    TextEditor(text: $content)
                        .frame(minHeight: 120)
                }
                Section("关键词") {
                    TextField("关键词（逗号分隔）", text: $keywordsText)
                        .autocorrectionDisabled()
                    Text("包含：消息中含任一关键词即触发；全词：按词边界整词匹配。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("行为") {
                    Toggle("常驻（总是注入）", isOn: $isConstant)
                    Stepper("优先级：\(priority)", value: $priority, in: -10...10)
                }
                Section("匹配方式") {
                    Picker("匹配方式", selection: $matchMode) {
                        Text("包含（默认）").tag(WorldBookMatchMode.contains)
                        Text("全词匹配").tag(WorldBookMatchMode.exact)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(entry.title.isEmpty ? "新建条目" : "编辑条目")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func save() {
        let keywords = keywordsText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var updated = entry
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.content = content
        updated.keywords = keywords
        updated.isConstant = isConstant
        updated.priority = priority
        updated.matchMode = matchMode
        onSave(updated)
        dismiss()
    }
}

#Preview {
    WorldBookEditView(entry: WorldBookEntry()) { _ in }
}
