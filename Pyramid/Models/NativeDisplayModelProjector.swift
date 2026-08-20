import Foundation

/// 把 `stat_data` 变量树纯函数投影为 `NativeDisplayModel`（1→2 转换层）。
///
/// 映射规则唯一来源（禁止瞎猜）：
/// - `docs/ST_TO_NATIVE_MAPPING.md` §4.2（标量 / 对象 / 数组原语表）
/// - `docs/ST_TO_NATIVE_MAPPING.md` §4.3（深度限制）
/// - `docs/ST_FALLBACK_RULES.md` §4（`$meta` / `$internal` / 数组 / 异质等降级）
/// - `docs/ST_SOURCE_CONCLUSIONS.md` §4（MvuData / stat_data 形式）
/// - `docs/ST_OPEN_QUESTIONS.md`（已决策边界：不实现 schema、不展示 `$internal` / `$meta` 等）
///
/// **硬性边界**：
/// - 纯函数：不读 VariableStore 全局单例；输入由调用方传入。
/// - 不抛错：所有异常路径走 `residual`。
/// - 不写 UI：本层只产出数据模型；UI 接线留待后续 2→3 阶段。
/// - 不卡面特判：键名启发只匹配通用词（HP / 好感 / affection / health / 血量 / 生命 / 好感度 / favor）。
enum NativeDisplayModelProjector {

    /// 根 group 标题。文档约定：整个 `stat_data` 包成 `group("状态", children)`。
    static let rootTitle = "状态"

    /// 超过此深度的子树降级为 `residual`（含）。
    /// 依据：`ST_TO_NATIVE_MAPPING.md` §4.3 —— depth ≤ 3 正常；4 文本化；≥ 5 残值。
    static let maxDepth = 4

    /// 把一棵 `stat_data` 树投影为 `NativeDisplayModel`。
    /// - Parameter statData: VariableStore 内部的 `JSONValue` 树（顶层应为 `.object`）。
    /// - Returns: 永不 nil；空输入 / 非 object 输入 → 单 `.text` 文本节点 + 不丢原文。
    static func project(statData: JSONValue) -> NativeDisplayModel {
        guard case .object(let dict) = statData else {
            // 顶层非对象 → 整段原文落入 residual，不丢。
            return NativeDisplayModel(
                blocks: [
                    .text("[\(rootTitle) 等待变量]")
                ],
                residual: [
                    ResidualField(path: nil, rawText: jsonDisplayText(statData), reason: "stat_data is not a plain object")
                ]
            )
        }
        var blocks: [DisplayBlock] = []
        var residual: [ResidualField] = []
        // 顶层 key 排序：保证幂等 + 跨平台一致。`$meta` / `$internal` 等直接在循环里跳过。
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            if isInternalKey(key) { continue }
            projectValue(
                key: key,
                value: value,
                depth: 1,
                path: "/\(key)",
                into: &blocks,
                residual: &residual
            )
        }
        return NativeDisplayModel(
            version: 1,
            blocks: [wrapRootGroup(blocks: blocks)],
            residual: residual
        )
    }

    /// 把 `[VariableEntry]`（已拍扁的路径列表）降级为单 .text 节点 + 残值。
    /// 这是"扁平条目"维度的最佳努力投影 —— 形态已丢，无法还原嵌套 group。
    /// 本期主要给 `statusPlaceholder` 旧路径用；建议优先 `project(statData:)`。
    static func project(entries: [VariableEntry]) -> NativeDisplayModel {
        guard !entries.isEmpty else {
            return NativeDisplayModel(
                blocks: [.text("[\(rootTitle) 等待变量]")]
            )
        }
        let fields = entries
            .sorted { $0.path < $1.path }
            .map { DisplayBlock.field(label: $0.path, value: $0.displayValue) }
        return NativeDisplayModel(
            version: 1,
            blocks: [wrapRootGroup(blocks: fields)],
            residual: []
        )
    }

    // MARK: - 内部

    /// 把根级 children 包成 `group("状态", children)`；children 空时仍给出占位 text，保证 UI 不空白。
    private static func wrapRootGroup(blocks: [DisplayBlock]) -> DisplayBlock {
        if blocks.isEmpty {
            return .group(title: rootTitle, children: [.text("[\(rootTitle) 等待变量]")])
        }
        return .group(title: rootTitle, children: blocks)
    }

    /// 是否为 MVU 内部元信息键 / 临时缓存键。命中即整棵子树跳过。
    /// 依据：`ST_SOURCE_CONCLUSIONS.md` §4 + `ST_FALLBACK_RULES.md` §4。
    private static func isInternalKey(_ key: String) -> Bool {
        switch key {
        case "$meta", "$arrayMeta", "$internal", "display_data", "delta_data":
            return true
        default:
            return false
        }
    }

    /// 标量 string → `field`；过长（> 30 字符）降级为 `section`。
    /// 文档约定：primitive string 默认 `field(label, value)`；长描述归 `section`。
    private static func projectString(key: String, value: String) -> DisplayBlock {
        if value.count > 30 {
            return .section(label: key, content: [.text(value)])
        }
        return .field(label: key, value: value)
    }

    /// 数值 → 启发式 bar / number / field。
    /// 键名启发匹配 HP / 好感 → bar(对应 kind, max=100)；其他 → `number(value, label: key)`。
    /// 不依赖 HTML / 卡片特判。
    private static func projectNumber(key: String, value: Double) -> DisplayBlock {
        if let kind = hpKeyKind(key) {
            return .bar(label: key, value: value, max: 100, kind: kind)
        }
        // 通用值：保留为 number，避免误把"金币 50"画成进度条。
        return .number(value: value, label: key)
    }

    /// 数组 → `section` 包装。
    /// 全部元素是 scalar → 多 `tag`；含 object → 递归填 children；混合支持。
    private static func projectArray(
        key: String,
        value: [JSONValue],
        depth: Int,
        path: String,
        residual: inout [ResidualField]
    ) -> DisplayBlock {
        var content: [DisplayBlock] = []
        for (index, element) in value.enumerated() {
            let elementPath = "\(path)/\(index)"
            switch element {
            case .string(let s):
                content.append(.tag(label: s, value: nil))
            case .int(let i):
                content.append(.number(value: Double(i), label: nil))
            case .double(let d):
                content.append(.number(value: d, label: nil))
            case .bool(let b):
                content.append(.tag(label: indexLabel(index), value: b ? "true" : "false"))
            case .null:
                continue // 跳过 null 元素
            case .object, .array:
                // 嵌套对象 / 数组 → 递归走相同 path，深度 +1
                projectValue(
                    key: indexLabel(index),
                    value: element,
                    depth: depth + 1,
                    path: elementPath,
                    into: &content,
                    residual: &residual
                )
            }
        }
        return .section(label: key, content: content)
    }

    /// 递归核心：
    /// - depth > maxDepth → 整段落入 residual，**不丢原文**。
    /// - depth == maxDepth 且是 object → flatten 为 text（保留子树信息）。
    /// - object → 递归展开为 `group`。
    /// - scalar → 走对应原语。
    private static func projectValue(
        key: String,
        value: JSONValue,
        depth: Int,
        path: String,
        into blocks: inout [DisplayBlock],
        residual: inout [ResidualField]
    ) {
        if depth > maxDepth {
            residual.append(ResidualField(
                path: path,
                rawText: jsonDisplayText(value),
                reason: "depth > \(maxDepth)"
            ))
            return
        }
        switch value {
        case .null:
            return // drop
        case .bool(let b):
            blocks.append(.tag(label: key, value: b ? "true" : "false"))
        case .int(let i):
            blocks.append(projectNumber(key: key, value: Double(i)))
        case .double(let d):
            blocks.append(projectNumber(key: key, value: d))
        case .string(let s):
            blocks.append(projectString(key: key, value: s))
        case .array(let arr):
            blocks.append(projectArray(key: key, value: arr, depth: depth, path: path, residual: &residual))
        case .object(let dict):
            // depth == maxDepth → 整棵 object 文本化，不展开（保留信息但视觉上不再叠加）。
            if depth == maxDepth {
                let rendered = dict
                    .sorted(by: { $0.key < $1.key })
                    .map { "\($0.key): \(jsonDisplayText($0.value))" }
                    .joined(separator: ", ")
                blocks.append(.text("\(key): \(rendered)"))
                return
            }
            var children: [DisplayBlock] = []
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                if isInternalKey(k) { continue }
                projectValue(
                    key: k,
                    value: v,
                    depth: depth + 1,
                    path: "\(path)/\(k)",
                    into: &children,
                    residual: &residual
                )
            }
            blocks.append(.group(title: key, children: children))
        }
    }

    // MARK: - 键名启发（通用词；不放角色名 / 卡面路径 / 脚本名）

    /// HP / 生命 / 血量 / health → `hp`；好感 / 好感度 / affection / favor → `affection`。
    /// 其他键名**不**自动转 bar（避免把"金币 50"画成进度条）。
    private static func hpKeyKind(_ key: String) -> BarKind? {
        let lower = key.lowercased()
        if ["hp", "生命", "血量", "health"].contains(where: { lower == $0.lowercased() }) {
            return .hp
        }
        if ["好感", "好感度", "affection", "favor"].contains(where: { lower == $0.lowercased() }) {
            return .affection
        }
        return nil
    }

    /// 数组下标的人类可读 label（仅 bool 元素用得上）。
    private static func indexLabel(_ index: Int) -> String {
        return "#\(index)"
    }

    /// 把 JSONValue 拍扁成展示文本（用于 residual / 深度超限 / 顶层非 object 兜底）。
    /// 不依赖 HTML / Foundation 之外的东西；Swift 原生 `JSONSerialization` 输出 + 手写 Int / Double / Bool 处理。
    private static func jsonDisplayText(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            // NaN / Infinity 由 JSONValue 解码层兜底展示为字符串
            return String(d)
        case .string(let s):
            return s
        case .array, .object:
            // 嵌套结构退到 JSON 序列化；序列化失败时退回占位
            guard let data = try? JSONEncoder().encode(value),
                  let s = String(data: data, encoding: .utf8) else {
                return "(unprintable)"
            }
            return s
        }
    }
}