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
    ///   - depth: `<NativeIf>` 递归深度（防病态嵌套；生产入口恒为 0）。
    static func parse(
        _ input: String,
        statData: () -> JSONValue,
        applyPatches: ([JSONPatchOperation]) throws -> Int,
        depth: Int = 0
    ) -> RenderTree {
        // 第一遍：识别 P3 新增块（StatusPlaceHolderImpl / UpdateVariable / NativeIf），按位置插入节点。
        // 第二遍：在剩余的 `.text` 节点里识别 P1 `<status>` 块，递归切分。
        // 第三遍：对仍为 `.text` 的节点做宏切分（含 `{{…}}` 才转 macroText，否则保持 .text 直通）。
        let firstPass = parseP3Blocks(input, statData: statData, applyPatches: applyPatches, depth: depth)
        // 第二遍：对每个 .text 节点再走 P1 的 status 解析；第三遍：宏切分。
        let finalNodes = firstPass.nodes.flatMap { node -> [RenderNode] in
            if case let .text(s) = node {
                return parseStatusBlocks(in: s).flatMap { statusNode -> [RenderNode] in
                    guard case let .text(t) = statusNode,
                          TavernMacroParser.containsMacroToken(t) else {
                        return [statusNode]
                    }
                    return [.macroText(TavernMacroParser.parse(t))]
                }
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
        applyPatches: ([JSONPatchOperation]) throws -> Int,
        depth: Int = 0
    ) -> RenderTree {
        let placeholderPattern = "(?is)<StatusPlaceHolderImpl\\s*/?>"
        // canonical：单 `<UpdateVariable>`（酒馆 / MVU 源码一致）；
        // fallback：双 `<<UpdateVariable>>` 是早期 Pyramid 代码遗留的拼写，兼容旧数据。
        // 闭合标签同样两种都吃，避免外层把 `>` 切成游离 .text 节点。
        let updatePattern =
            "(?is)<UpdateVariable\\b[^>]*>[\\s\\S]*?</UpdateVariable>" +
            "|<<UpdateVariable[^>]*>>[\\s\\S]*?<</UpdateVariable>>"
        // 只命中「完整合法形态」（自闭合 / 空 body 配对）。带 body 或裸开标签的畸形
        // token 不命中 —— 整段留在文本流里逐字可见，绝不会被拆散。
        let actionPattern =
            "(?is)" +
            "(<NativeAction|<NativeInput|<NativeSelect)\\b[^>]*>\\s*</(?:NativeAction|NativeInput|NativeSelect)\\s*>" +
            "|<(?:NativeAction|NativeInput|NativeSelect)\\b[^>]*/>"
        // `<NativeIf …>…</NativeIf>`：非贪婪首个闭合。命中后由 NativeConditionParser
        // 做严格形状 + 属性校验；不命中（畸形 / 无闭合）留在文本流逐字保真。
        let conditionPattern = "(?is)<NativeIf\\b[^>]*>[\\s\\S]*?</NativeIf\\s*>"

        guard let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern),
              let updateRegex = try? NSRegularExpression(pattern: updatePattern),
              let actionRegex = try? NSRegularExpression(pattern: actionPattern),
              let conditionRegex = try? NSRegularExpression(pattern: conditionPattern) else {
            return RenderTree(nodes: [.text(input)])
        }

        let nsInput = input as NSString
        let fullRange = NSRange(location: 0, length: nsInput.length)

        // 收集所有匹配（带类型标记）并按位置排序
        struct Hit {
            var range: NSRange
            var kind: Kind
            enum Kind { case placeholder, update, action, condition }
        }
        var hits: [Hit] = []
        for m in placeholderRegex.matches(in: input, options: [], range: fullRange) {
            hits.append(Hit(range: m.range, kind: .placeholder))
        }
        for m in updateRegex.matches(in: input, options: [], range: fullRange) {
            hits.append(Hit(range: m.range, kind: .update))
        }
        for m in actionRegex.matches(in: input, options: [], range: fullRange) {
            hits.append(Hit(range: m.range, kind: .action))
        }
        for m in conditionRegex.matches(in: input, options: [], range: fullRange) {
            hits.append(Hit(range: m.range, kind: .condition))
        }
        hits.sort { $0.range.location < $1.range.location }

        if hits.isEmpty {
            return RenderTree(nodes: [.text(input)])
        }

        var nodes: [RenderNode] = []
        var cursor = 0
        for hit in hits where hit.range.location >= cursor {
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
            case .action:
                if rawBlock.lowercased().hasPrefix("<nativeaction") {
                    nodes.append(parseNativeActionBlock(rawBlock))
                } else {
                    nodes.append(parseNativeControlBlock(rawBlock))
                }
            case .condition:
                // 条件块：成立 → body 递归解析后的节点序列；隐藏 → 空 text 占位
                // （防整树为空触发「整体回退原文」把隐藏内容复活）；畸形 → 原文保真。
                nodes.append(
                    contentsOf: parseConditionBlock(
                        rawBlock,
                        statData: statData,
                        applyPatches: applyPatches,
                        depth: depth
                    )
                )
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

    /// `<NativeIf path op value?>body</NativeIf>` —— 通用条件原语。
    /// 成立 → body 以 depth+1 递归走完整解析（可嵌套 token / 宏）；
    /// 隐藏 → `.text("")` 占位；任何解析失败 / 超深 → `.text(整段)` 保真。
    private static func parseConditionBlock(
        _ raw: String,
        statData: @autoclosure () -> JSONValue,
        applyPatches: ([JSONPatchOperation]) throws -> Int,
        depth: Int
    ) -> [RenderNode] {
        guard depth < NativeConditionParser.maxDepth,
              let (attrsString, body) = NativeConditionParser.extract(raw),
              let predicate = NativePredicate(attrs: NativeConditionParser.attributes(from: attrsString)) else {
            return [.text(raw)]
        }
        guard predicate.evaluate(in: statData()) else {
            return [.text("")]
        }
        let childTree = parse(body, statData: statData, applyPatches: applyPatches, depth: depth + 1)
        return childTree.nodes.isEmpty ? [.text("")] : childTree.nodes
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

    // MARK: - NativeAction

    /// `<NativeAction label="…" kind="updateVariable|toggle" path="/a/b" value="…"/>`。
    ///
    /// Pyramid 定义的声明式交互原语（非 HTML / 无 JS / 无 CSS）：
    /// - `label` 必填非空（UI 按钮文案）
    /// - `kind=updateVariable`：必填 `path` + `value`；value 解析为 JSON 标量
    ///   （整数 → 小数 → true/false → 字符串，依次尝试）
    /// - `kind=toggle`：必填 `path`；目标必须是 bool（执行期由 dispatcher 校验）
    /// - 自闭合与「空 body 配对」两种形态都接受；**带非空 body 的配对形态不识别**
    ///   （整段降级 `.text(原文)` —— 不静默吞掉 body）
    /// - 任何属性缺失 / 未知 kind / value 非标量 → `.text(raw)`，绝不丢内容、不崩溃
    static func parseNativeActionBlock(_ raw: String) -> RenderNode {
        guard let attrs = tokenAttributes(raw, tag: "NativeAction") else {
            return .text(raw)
        }
        guard let label = attrs["label"], !label.isEmpty,
              let kind = attrs["kind"], !kind.isEmpty,
              let path = attrs["path"], path.hasPrefix("/") else {
            return .text(raw)
        }
        switch kind.lowercased() {
        case "updatevariable":
            guard let rawValue = attrs["value"], !rawValue.isEmpty,
                  let value = parseActionScalar(rawValue) else {
                return .text(raw)
            }
            return .nativeAction(label: label, action: .updateVariable(path: path, value: value))
        case "toggle":
            return .nativeAction(label: label, action: .toggle(path: path))
        default:
            return .text(raw)
        }
    }

    /// `<NativeInput label? placeholder? path="/a"/>` / `<NativeSelect label? path="/a" values="v1,v2" labels?="甲,乙"/>`。
    ///
    /// 通用输入控件（零业务语义）：
    /// - `path` 必填且必须以 `/` 开头（JSON Pointer）
    /// - input：提交时把字符串写入 path；placeholder 可选
    /// - select：`values` 必填（逗号分隔，逐项 trim 后不得为空）；`labels` 可选
    ///   （与 values 按序 zip，缺省项显示 value 本身）
    /// - 只认自闭合 / 空 body 配对；畸形 → `.text(原文)` 保真
    static func parseNativeControlBlock(_ raw: String) -> RenderNode {
        let lowered = raw.lowercased()
        let tag = lowered.hasPrefix("<nativeinput") ? "NativeInput"
            : lowered.hasPrefix("<nativeselect") ? "NativeSelect" : nil
        guard let tag, let attrs = tokenAttributes(raw, tag: tag),
              let path = attrs["path"], path.hasPrefix("/") else {
            return .text(raw)
        }
        let label = attrs["label"].flatMap { $0.isEmpty ? nil : $0 }
        switch tag {
        case "NativeInput":
            let placeholder = attrs["placeholder"].flatMap { $0.isEmpty ? nil : $0 }
            return .nativeControl(NativeControl(
                kind: .input, label: label, path: path, placeholder: placeholder, options: []
            ))
        case "NativeSelect":
            guard let rawValues = attrs["values"], !rawValues.isEmpty else {
                return .text(raw)
            }
            let values = rawValues.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard !values.isEmpty, !values.contains("") else {
                return .text(raw)
            }
            let labels = attrs["labels"]?
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            let options = values.enumerated().map { (index, value) in
                NativeControlOption(value: value, label: index < labels.count && !labels[index].isEmpty ? labels[index] : nil)
            }
            return .nativeControl(NativeControl(
                kind: .select, label: label, path: path, placeholder: nil, options: options
            ))
        default:
            return .text(raw)
        }
    }

    /// 交互 token 的整体形状校验 + 属性提取。
    /// 形状：自闭合，或「空 body 配对」（`\s*</Tag>` 结尾）；group 1 = 属性串。
    /// 返回 nil 表示形状不合法（调用方降级 `.text(原文)`）。
    private static func tokenAttributes(_ raw: String, tag: String) -> [String: String]? {
        let shapePattern = "(?is)^<\(tag)\\b([^>]*?)/?\\s*>\\s*(?:</\(tag)\\s*>)?$"
        guard let shapeRegex = try? NSRegularExpression(pattern: shapePattern),
              let attrRegex = try? NSRegularExpression(pattern: "([A-Za-z_][\\w-]*)\\s*=\\s*\"([^\"]*)\"") else {
            return nil
        }
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = shapeRegex.firstMatch(in: raw, options: [], range: full),
              m.range(at: 1).location != NSNotFound else {
            return nil
        }
        let attrsString = ns.substring(with: m.range(at: 1))
        var attrs: [String: String] = [:]
        let attrNS = attrsString as NSString
        for am in attrRegex.matches(in: attrsString, options: [], range: NSRange(location: 0, length: attrNS.length)) {
            let key = attrNS.substring(with: am.range(at: 1)).lowercased()
            attrs[key] = attrNS.substring(with: am.range(at: 2))
        }
        return attrs
    }

    /// JSON 标量解析：整数 → 小数 → bool → 字符串。数组 / 对象不是合法动作值。
    static func parseActionScalar(_ s: String) -> JSONValue? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let i = Int(trimmed) { return .int(i) }
        if let d = Double(trimmed), d.isFinite { return .double(d) }
        switch trimmed.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: break
        }
        guard !trimmed.isEmpty, trimmed != "null" else { return nil }
        return .string(trimmed)
    }
}