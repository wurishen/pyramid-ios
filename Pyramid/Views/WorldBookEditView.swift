import SwiftUI

struct WorldBookEditView: View {
    private let entry: WorldBookEntry
    private let onSave: (WorldBookEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var content: String
    @State private var keywordsText: String
    @State private var secondaryKeywordsText: String
    @State private var isConstant: Bool
    @State private var priority: Int
    @State private var matchMode: WorldBookMatchMode
    @State private var hasCustomScanDepth: Bool
    @State private var scanDepthValue: Int
    @State private var probability: Int
    @State private var insertionPosition: WorldBookInsertionPosition

    init(entry: WorldBookEntry, onSave: @escaping (WorldBookEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _title = State(initialValue: entry.title)
        _content = State(initialValue: entry.content)
        _keywordsText = State(initialValue: entry.keywords.joined(separator: "，"))
        _secondaryKeywordsText = State(initialValue: entry.secondaryKeywords.joined(separator: "，"))
        _isConstant = State(initialValue: entry.isConstant)
        _priority = State(initialValue: entry.priority)
        _matchMode = State(initialValue: entry.matchMode)
        _hasCustomScanDepth = State(initialValue: entry.scanDepth != nil)
        _scanDepthValue = State(initialValue: entry.scanDepth ?? WorldBookService.defaultScanDepth)
        _probability = State(initialValue: entry.probability)
        _insertionPosition = State(initialValue: entry.insertionPosition)
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
                    TextField("次要关键词（逗号分隔，可选）", text: $secondaryKeywordsText)
                        .autocorrectionDisabled()
                    Text("主关键词命中后，次要关键词还需至少命中一个才触发。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("行为") {
                    Toggle("常驻（总是注入）", isOn: $isConstant)
                    Stepper("优先级：\(priority)", value: $priority, in: -10...10)
                    Toggle("自定义扫描深度", isOn: $hasCustomScanDepth)
                    if hasCustomScanDepth {
                        Stepper("扫描最近 \(scanDepthValue) 条", value: $scanDepthValue, in: 1...20)
                    } else {
                        Text("扫描最近 \(WorldBookService.defaultScanDepth) 条（默认）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Stepper("触发概率：\(probability)%", value: $probability, in: 0...100)
                }
                Section("插入位置") {
                    Picker("插入位置", selection: $insertionPosition) {
                        Text("系统提示前").tag(WorldBookInsertionPosition.beforeSystem)
                        Text("系统提示后（默认）").tag(WorldBookInsertionPosition.afterSystem)
                        Text("历史之后").tag(WorldBookInsertionPosition.afterHistory)
                    }
                    .pickerStyle(.segmented)
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
        let split = { (text: String) -> [String] in
            text
                .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        var updated = entry
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.content = content
        updated.keywords = split(keywordsText)
        updated.secondaryKeywords = split(secondaryKeywordsText)
        updated.isConstant = isConstant
        updated.priority = priority
        updated.matchMode = matchMode
        updated.scanDepth = hasCustomScanDepth ? scanDepthValue : nil
        updated.probability = probability
        updated.insertionPosition = insertionPosition
        onSave(updated)
        dismiss()
    }
}

#Preview {
    WorldBookEditView(entry: WorldBookEntry()) { _ in }
}
