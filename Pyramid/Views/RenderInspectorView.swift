import SwiftUI

/// RenderEngine 调试覆盖层：长按消息卡片时弹出，展示 raw → cleaned 的转换细节。
///
/// 设计原则：
/// - **只读展示**：不修改 raw / context / Result，只是把已经算好的信息可视化。
/// - **Dev-only**：不暴露 inspect API 给普通用户；通过长按手势进入，避免误触。
/// - **不依赖 Xcode**：开发机 / 真机都能用，不需要挂 lldb / view debugger。
struct RenderInspectorView: View {
    let raw: String
    let result: RenderEngine.Result
    let context: RenderEngine.Context

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statsSection
                    section("原文 (raw)", text: raw, copyable: true)
                    section("处理后 (cleaned)", text: result.cleanedText, copyable: true)
                    nodesSection
                    regexSection
                    hideTagsSection
                }
                .padding()
            }
            .navigationTitle("Render Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 统计

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("统计").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("原文长度: \(raw.count) 字符")
                Text("处理后长度: \(result.cleanedText.count) 字符")
                Text("差异: \(raw.count - result.cleanedText.count) 字符")
                Text("Markdown: \(result.markdownEnabled ? "启用" : "禁用")")
                Text("作用对象: \(context.isAssistant ? "助手消息" : "用户消息")")
            }
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - 文本段

    private func section(_ title: String, text: String, copyable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text.isEmpty ? "(空)" : text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - 命中的 regex

    private var matchedRegexes: [DisplayRegex] {
        guard context.isAssistant else { return [] }
        let ordered = MessageRendererCore.orderedRegexes(
            presetDisplayRegexIds: context.presetDisplayRegexIds,
            all: context.allDisplayRegexes
        )
        return ordered.filter { regex in
            guard let compiled = try? NSRegularExpression(
                pattern: regex.pattern,
                options: [.dotMatchesLineSeparators]
            ) else { return false }
            let range = NSRange(raw.startIndex..., in: raw)
            let replaced = compiled.stringByReplacingMatches(
                in: raw, options: [], range: range, withTemplate: regex.replacement
            )
            return replaced != raw
        }
    }

    private var regexSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("命中的 DisplayRegex（\(matchedRegexes.count) 条）").font(.caption).foregroundStyle(.secondary)
            if matchedRegexes.isEmpty {
                Text("(无)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(matchedRegexes) { regex in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(regex.name).font(.body.weight(.medium))
                            Text("pattern: \(regex.pattern)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("replacement: \(regex.replacement.isEmpty ? "(空)" : regex.replacement)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    // MARK: - 隐藏标签

    private var nodesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RenderNode 树（\(result.tree.nodes.count) 个节点）").font(.caption).foregroundStyle(.secondary)
            if result.tree.nodes.isEmpty {
                Text("(空)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(result.tree.nodes.enumerated()), id: \.offset) { idx, node in
                        nodeRow(idx: idx, node: node)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func nodeRow(idx: Int, node: RenderNode) -> some View {
        switch node {
        case let .text(s):
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .text (\(s.count) 字符)").font(.caption.weight(.medium))
                Text(s.isEmpty ? "(空)" : s)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .status(hp, affection):
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .status").font(.caption.weight(.medium))
                Text("HP: \(hp) · 好感度: \(affection)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .statusPlaceholder(statData):
            // 调试视图：把整棵 statData 树拍扁成「key=value」列表（仅展示用，不影响投影）。
            // 树空 → 提示「等待变量」；绝不补造"时间/位置"等假字段。
            let flat = StatDataSummary.summarize(statData)
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .statusPlaceholder (\(flat.count) 变量)").font(.caption.weight(.medium))
                if flat.isEmpty {
                    Text("(空 — 等待变量)").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text(flat.map { "\($0.path)=\($0.value)" }.joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .variableUpdate(summary):
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .variableUpdate (\(summary.appliedCount) 条)").font(.caption.weight(.medium))
                Text(summary.affectedPaths.isEmpty ? "(无 path 变更)" : summary.affectedPaths.joined(separator: ", "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .statusFields(fields):
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .statusFields (\(fields.count) 字段)").font(.caption.weight(.medium))
                Text(fields.map { "\($0.label)=\($0.value)" }.joined(separator: ", "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .deferredResidual(residual):
            // 调试视图：deferred 层残留块（原文保留，仅截断展示）。
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .deferredResidual\(residual.ruleName.map { " · \($0)" } ?? "")")
                    .font(.caption.weight(.medium))
                Text(residual.replacement.isEmpty ? "(空)" : residual.replacement)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .nativeAction(label, action):
            // 调试视图：交互原语 —— label + 动作摘要。
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .nativeAction").font(.caption.weight(.medium))
                Text("\"\(label)\" → \(actionDebugSummary(action))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .nativeControl(control):
            // 调试视图：输入控件 —— kind + path + 选项数。
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .nativeControl (\(control.kind == .input ? "input" : "select"))")
                    .font(.caption.weight(.medium))
                Text(control.options.isEmpty
                     ? control.path
                     : "\(control.path) · \(control.options.map { $0.label ?? $0.value }.joined(separator: "|"))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        case let .macroText(segments):
            // 调试视图：宏绑定文本 —— 片段数 + 各片段摘要（绑定显示 path，字面量截断展示）。
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .macroText (\(segments.count) 段)").font(.caption.weight(.medium))
                let summary = segments.map { seg -> String in
                    switch seg {
                    case .literal(let s): return "\"\(s.prefix(24))\""
                    case .binding(let b): return "getvar→\(b.path)"
                    }
                }.joined(separator: " + ")
                Text(summary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .condition(node):
            // 调试视图：条件分支 —— 原文截断 + 依赖路径 + 双分支节点数。
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .condition (T:\(node.whenTrue.count)/F:\(node.whenFalse.count))")
                    .font(.caption.weight(.medium))
                Text(node.raw.prefix(60).replacingOccurrences(of: "\n", with: " "))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                Text("deps: \(node.condition.dependencies.sorted().joined(separator: ", "))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .htmlContainer(children):
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .htmlContainer (\(children.count) 子节点)").font(.caption.weight(.medium))
                Text("HTML 容器（非业务组件）").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .htmlImage(src, alt):
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .htmlImage").font(.caption.weight(.medium))
                Text("src: \(src)").font(.system(.caption, design: .monospaced)).lineLimit(1)
                if let alt { Text("alt: \(alt)").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .htmlLink(label, href):
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .htmlLink").font(.caption.weight(.medium))
                Text("\"\(label)\" → \(href)").font(.system(.caption, design: .monospaced)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .htmlScript(residual):
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .htmlScript (未执行)").font(.caption.weight(.medium))
                Text(residual.replacement.prefix(80)).font(.system(.caption, design: .monospaced)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .htmlExternalResource(ir):
            VStack(alignment: .leading, spacing: 2) {
                Text("[\(idx)] .htmlExternalResource (\(ir.kind.rawValue) · 未加载)")
                    .font(.caption.weight(.medium))
                Text(ir.url).font(.system(.caption, design: .monospaced)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func actionDebugSummary(_ action: NativeAction) -> String {
        switch action {
        case let .updateVariable(path, value):
            return "updateVariable \(path) = \(value)"
        case let .toggle(path):
            return "toggle \(path)"
        case let .navigate(target):
            return "navigate \(target)"
        case let .custom(key, payload):
            return "custom \(key) [\(payload.count) 项]"
        }
    }

    private var hideTagsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("隐藏标签剥离").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("启用: \(context.hideTagStripEnabled ? "是" : "否")")
                Text("标签列表: \(context.hideTags.isEmpty ? "(空)" : context.hideTags.joined(separator: ", "))")
            }
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Debug fallback summary

/// Debug 用：把 `statData` 整棵 JSON 树拍扁成 `path + value` 列表，仅供 RenderInspector 展示。
/// 不影响 `NativeDisplayModelProjector.project(statData:)` 主路径——主路径按树投影、保留嵌套。
/// 树空 → 返回 `[]`（UI 显示「等待变量」），不补造任何"时间/位置"等假字段。
private enum StatDataSummary {
    struct Entry: Equatable {
        var path: String
        var value: String
    }

    static func summarize(_ value: JSONValue) -> [Entry] {
        guard case .object(let dict) = value else { return [] }
        return flatten(dict, prefix: "")
    }

    private static func flatten(_ dict: [String: JSONValue], prefix: String) -> [Entry] {
        var out: [Entry] = []
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            let path = prefix.isEmpty ? "/\(key)" : "\(prefix)/\(key)"
            switch value {
            case .object(let nested):
                out.append(contentsOf: flatten(nested, prefix: path))
            case .array:
                out.append(Entry(path: path, value: "[数组]"))
            case .null:
                out.append(Entry(path: path, value: "—"))
            default:
                out.append(Entry(path: path, value: formatInline(value)))
            }
        }
        return out
    }

    private static func formatInline(_ v: JSONValue) -> String {
        switch v {
        case .null: return "—"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array, .object: return "(?)"
        }
    }
}

// MARK: - SwiftUI Preview

#Preview("Render Inspector - with regex + hide tags") {
    RenderInspectorView(
        raw: "Hello <System>World</System>{{hello}} **bold**",
        result: RenderEngine.render(
            raw: "Hello <System>World</System>{{hello}} **bold**",
            context: RenderEngine.Context(
                isAssistant: true,
                presetDisplayRegexIds: [UUID()],
                allDisplayRegexes: [
                    DisplayRegex(
                        id: UUID(),
                        name: "World → Pyramid",
                        pattern: "World",
                        replacement: "Pyramid",
                        enabled: true
                    )
                ],
                hideTagStripEnabled: true,
                hideTags: ["System"],
                markdownEnabled: true
            )
        ),
        context: RenderEngine.Context(
            isAssistant: true,
            presetDisplayRegexIds: [UUID()],
            allDisplayRegexes: [
                DisplayRegex(
                    id: UUID(),
                    name: "World → Pyramid",
                    pattern: "World",
                    replacement: "Pyramid",
                    enabled: true
                )
            ],
            hideTagStripEnabled: true,
            hideTags: ["System"],
            markdownEnabled: true
        )
    )
}

#Preview("Render Inspector - user message (no regex)") {
    RenderInspectorView(
        raw: "用户消息原文",
        result: RenderEngine.render(
            raw: "用户消息原文",
            context: RenderEngine.Context(
                isAssistant: false,
                presetDisplayRegexIds: [],
                allDisplayRegexes: [],
                hideTagStripEnabled: false,
                hideTags: [],
                markdownEnabled: true
            )
        ),
        context: RenderEngine.Context(
            isAssistant: false,
            presetDisplayRegexIds: [],
            allDisplayRegexes: [],
            hideTagStripEnabled: false,
            hideTags: [],
            markdownEnabled: true
        )
    )
}

#Preview("Render Inspector - with status block") {
    RenderInspectorView(
        raw: "你推开酒馆的木门。\n\n<status>\nHP: 80\n好感度: 65\n</status>\n\n老板抬头看了你一眼。",
        result: RenderEngine.render(
            raw: "你推开酒馆的木门。\n\n<status>\nHP: 80\n好感度: 65\n</status>\n\n老板抬头看了你一眼。",
            context: RenderEngine.Context(
                isAssistant: true,
                presetDisplayRegexIds: [],
                allDisplayRegexes: [],
                hideTagStripEnabled: false,
                hideTags: [],
                markdownEnabled: true
            )
        ),
        context: RenderEngine.Context(
            isAssistant: true,
            presetDisplayRegexIds: [],
            allDisplayRegexes: [],
            hideTagStripEnabled: false,
            hideTags: [],
            markdownEnabled: true
        )
    )
}
