import Foundation

/// 把 RenderEngine 处理后的 cleanedText 切成 RenderTree。
///
/// 支持的块（解析顺序：先 P3 新增，再 P1 的 `<status>`）：
/// 1. `<StatusPlaceHolderImpl/>` —— `.statusPlaceholder(statData)`，statData 是当前会话
///    整棵 `JSONValue` 变量树（顶层应为 `.object`；其它形态也容错透传）。
/// 2. `<UpdateVariable>…</UpdateVariable>`（canonical 拼写：单 `<`，酒馆 / MVU 源码一致）
///    —— 应用 patch 写入 VariableStore，然后输出 `.variableUpdate(summary)`；
///    解析失败降级为 `.text(整段含标签)`。`<<UpdateVariable>>…<</UpdateVariable>>` 是历史遗留拼写，
///    作为 fallback 兼容旧数据（参见 `docs/ST_SOURCE_CONCLUSIONS.md` / `docs/ST_OPEN_QUESTIONS.md` 附录）。
/// 3. `<status>...</status>` —— `.status(hp:affection:)`，与 P1 同。
///
/// **容错策略**（与 P1 同：「不能导致整条消息消失」）：
/// 1. 单块解析失败 → 该块降级为 `.text(原文)`，其余块正常处理。
/// 2. 整体结构错乱 → 整个 input 作为单 `.text` 节点返回。
/// 3. **永不抛错**：任何异常路径都返回有效 RenderTree，最坏 `[.text(input)]`。
///
/// **测试策略**：核心用 closure-based `parse(_:statData:applyPatches:)` —— 仅依赖 Foundation，
/// 可在 Linux SPM 上驱动。生产 `parse(_:variableStore:sessionId:)` 把 VariableStore 转译成两个闭包，
/// 走 SwiftUI / UserDefaults 持久化路径。
enum RenderNodeParser {

    // MARK: - 生产入口

    /// 解析输入字符串为 RenderTree。
    /// - Parameters:
    ///   - input: 已过 DisplayRegex / HideTags 的文本。
    ///   - variableStore: 可选；提供时本解析器会把 UpdateVariable 块 apply 到该 session。
    ///   - sessionId: 与 variableStore 配合使用；nil → UpdateVariable 块降级为 `.text`。
    /// - Returns: 永不 nil（构造失败也降级为单节点）。
    static func parse(
        _ input: String,
        variableStore: VariableStore? = nil,
        sessionId: UUID? = nil
    ) -> RenderTree {
        if let store = variableStore, let sid = sessionId {
            return parse(
                input,
                statData: { store.raw(forSession: sid) },
                applyPatches: { ops in try store.apply(ops, to: sid) }
            )
        }
        return parse(
            input,
            statData: { .object([:]) },
            applyPatches: { _ in throw NSError(domain: "RenderNodeParser", code: 0) }
        )
    }

    // MARK: - 测试入口（closure-based）

    /// 纯 Foundation 解析入口。让 SPM / Linux 单测不依赖 SwiftUI ObservableObject 也能驱动。
    /// - Parameters:
    ///   - input: 已过 DisplayRegex / HideTags 的文本。
    ///   - statData: 返回当前会话的整棵 `JSONValue` 变量树（用于 statusPlaceholder 节点）。
    ///     UI 走 `NativeDisplayModelProjector.project(statData:)` 投影；**不**拍平。
    ///   - applyPatches: 把 JSON Patch ops 应用到当前会话，返回 applied 计数。
    ///     抛错时该块降级为 `.text`（不丢内容）。
    static func parse(
        _ input: String,
        statData: () -> JSONValue,
        applyPatches: ([JSONPatchOperation]) throws -> Int
    ) -> RenderTree {
        // 第一遍：识别 P3 新增块（StatusPlaceHolderImpl / UpdateVariable），按位置插入节点。
        // 第二遍：在剩余的 `.text` 节点里识别 P1 `<status>` 块，递归切分。
        // 这种 pass 设计避免用一个 union 正则同时匹配三类块带来的 group index 混乱。
        let firstPass = parseP3Blocks(input, statData: statData, applyPatches: applyPatches)
        // 第二遍：对每个 .text 节点再走 P1 的 status 解析
        let finalNodes = firstPass.nodes.flatMap { node -> [RenderNode] in
            if case let .text(s) = node {
                return parseStatusBlocks(in: s)
            }
            return [node]
        }
        if finalNodes.isEmpty {
            return RenderTree(nodes: [.text(input)])
        }
        return RenderTree(nodes: finalNodes)
    }

    // MARK: - 第一遍：P3 新增块

    private static func parseP3Blocks(
        _ input: String,
        statData: () -> JSONValue,
        applyPatches: ([JSONPatchOperation]) throws -> Int
    ) -> RenderTree {
        let placeholderPattern = "(?is)<StatusPlaceHolderImpl\\s*/?>"
        // canonical：单 `<UpdateVariable>`（酒馆 / MVU 源码一致）；
        // fallback：双 `<<UpdateVariable>>` 是早期 Pyramid 代码遗留的拼写，兼容旧数据。
        // 闭合标签同样两种都吃，避免外层把 `>` 切成游离 .text 节点。
        let updatePattern =
            "(?is)<UpdateVariable\\b[^>]*>[\\s\\S]*?</UpdateVariable>" +
            "|<<UpdateVariable[^>]*>>[\\s\\S]*?<</UpdateVariable>>"

        guard let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern),
              let updateRegex = try? NSRegularExpression(pattern: updatePattern) else {
            return RenderTree(nodes: [.text(input)])
        }

        let nsInput = input as NSString
        let fullRange = NSRange(location: 0, length: nsInput.length)

        // 收集所有匹配（带类型标记）并按位置排序
        struct Hit {
            var range: NSRange
            var kind: Kind
            enum Kind { case placeholder, update }
        }
        var hits: [Hit] = []
        for m in placeholderRegex.matches(in: input, options: [], range: fullRange) {
            hits.append(Hit(range: m.range, kind: .placeholder))
        }
        for m in updateRegex.matches(in: input, options: [], range: fullRange) {
            hits.append(Hit(range: m.range, kind: .update))
        }
        hits.sort { $0.range.location < $1.range.location }

        if hits.isEmpty {
            return RenderTree(nodes: [.text(input)])
        }

        var nodes: [RenderNode] = []
        var cursor = 0
        for hit in hits {
            if hit.range.location > cursor {
                let prefixRange = NSRange(location: cursor, length: hit.range.location - cursor)
                let prefix = nsInput.substring(with: prefixRange)
                if !prefix.isEmpty {
                    nodes.append(.text(prefix))
                }
            }
            let rawBlock = nsInput.substring(with: hit.range)
            switch hit.kind {
            case .placeholder:
                nodes.append(.statusPlaceholder(statData: statData()))
            case .update:
                nodes.append(parseUpdateVariableBlock(rawBlock, applyPatches: applyPatches))
            }
            cursor = hit.range.location + hit.range.length
        }
        if cursor < nsInput.length {
            let tail = nsInput.substring(from: cursor)
            if !tail.isEmpty {
                nodes.append(.text(tail))
            }
        }
        return RenderTree(nodes: nodes)
    }

    // MARK: - 第二遍：P1 <status>

    /// P1 的 status 解析：从一段 plain text 中切出 `<status>...</status>` 块。
    /// 解析规则（fast-path → generic → fallback）：
    /// 1. 块只含 `HP` + `好感度` 两个整数 → `.status(hp:affection:)`（保留旧行为）
    /// 2. 块含任意其他 / 更多字段 → `.statusFields([StatusField])`
    /// 3. 块完全没识别出任何 key/value → `.text(rawBlock)`（不丢内容）
    private static func parseStatusBlocks(in text: String) -> [RenderNode] {
        let pattern = "(?is)<status\\b[^>]*>(.*?)</status\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [.text(text)]
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: fullRange)
        if matches.isEmpty {
            return [.text(text)]
        }

        var nodes: [RenderNode] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let prefixRange = NSRange(location: cursor, length: match.range.location - cursor)
                let prefix = nsText.substring(with: prefixRange)
                if !prefix.isEmpty {
                    nodes.append(.text(prefix))
                }
            }
            let rawBlock = nsText.substring(with: match.range)
            let inner = nsText.substring(with: match.range(at: 1))
            if let status = parseStatusBlock(inner) {
                nodes.append(.status(hp: status.hp, affection: status.affection))
            } else {
                let fields = parseStatusFields(inner)
                if fields.isEmpty {
                    nodes.append(.text(rawBlock))
                } else {
                    nodes.append(.statusFields(fields))
                }
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            let tail = nsText.substring(from: cursor)
            if !tail.isEmpty {
                nodes.append(.text(tail))
            }
        }
        return nodes.isEmpty ? [.text(text)] : nodes
    }

    /// Fast-path：只识别 `HP` + `好感度` 两字段且都为整数（保留旧行为 / 旧测试）。
    static func parseStatusBlock(_ block: String) -> (hp: Int, affection: Int)? {
        let fields = parseStatusFields(block)
        guard fields.count == 2 else { return nil }
        var hp: Int?
        var affection: Int?
        for field in fields {
            switch field.label {
            case "HP":
                if let v = Int(field.value) { hp = v }
            case "好感度":
                if let v = Int(field.value) { affection = v }
            default:
                return nil
            }
        }
        guard let h = hp, let a = affection else { return nil }
        return (hp: h, affection: a)
    }

    /// 通用：从 `<status>` 块按行解析任意 `key: value` 对。
    /// - 兼容半角 `:` 与全角 `：` 冒号；忽略空行 / 仅空白行。
    /// - 不限定 key 集合 —— 模型可以输出 HP / 好感度 / 金币 / 饱腹 / 法力 等任意字段。
    /// - 字段顺序与原文一致；不会去重或重排。
    static func parseStatusFields(_ block: String) -> [StatusField] {
        let lines = block
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var fields: [StatusField] = []
        for line in lines {
            guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            fields.append(StatusField(label: key, value: value))
        }
        return fields
    }

    // MARK: - UpdateVariable

    /// `<UpdateVariable>…</UpdateVariable>` —— 解析 JSON Patch → 写 VariableStore → 摘要节点。
    /// 同时兼容历史遗留的 `<<UpdateVariable>>…<</UpdateVariable>>` 双尖括号拼写。
    /// 解析失败（JSON 畸形 / patch 全失败）→ 降级为 `.text(整段含标签)`，不丢内容。
    private static func parseUpdateVariableBlock(
        _ raw: String,
        applyPatches: ([JSONPatchOperation]) throws -> Int
    ) -> RenderNode {
        guard let inner = stripUpdateVariableBody(raw) else {
            return .text(raw)
        }
        guard let data = inner.data(using: .utf8),
              let ops = try? JSONDecoder().decode([JSONPatchOperation].self, from: data) else {
            return .text(raw)
        }
        do {
            let applied = try applyPatches(ops)
            let paths = ops.filter { !$0.isPrivatePath }.map(\.path)
            return .variableUpdate(summary: .init(
                appliedCount: applied,
                affectedPaths: paths
            ))
        } catch {
            return .text(raw)
        }
    }

    private static func stripUpdateVariableBody(_ raw: String) -> String? {
        // canonical（单 `<`，group 1 是 body）；legacy 双 `<` 兜底，body 落在 group 2。
        let pattern =
            "(?is)<UpdateVariable\\b[^>]*>([\\s\\S]*?)</UpdateVariable>" +
            "|<<UpdateVariable[^>]*>>([\\s\\S]*?)<</UpdateVariable>>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = raw as NSString
        guard let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return nil }
        // 命中 canonical → group 1；命中 legacy → group 2；group(0) 总非 -1，取实际非空的那一个。
        let g1 = m.range(at: 1)
        let g2 = m.range(at: 2)
        if g1.location != NSNotFound {
            return ns.substring(with: g1)
        }
        if g2.location != NSNotFound {
            return ns.substring(with: g2)
        }
        return nil
    }
}