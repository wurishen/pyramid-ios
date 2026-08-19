import Foundation

/// 把 RenderEngine 处理后的 cleanedText 切成 RenderTree。
///
/// 第一阶段只识别 `<status>...</status>` 块，解析其内部的 `HP: <整数>` 与
/// `好感度: <整数>` 两行；其余文本保持为 `.text` 节点。
///
/// **容错策略**（必须满足"不能导致整条消息消失"）：
/// 1. 单个 `<status>` 块解析失败（HP 缺 / 非整数 / 好感度缺 / 块为空）→ 该块降级为 `.text(<原文>)`，
///    其余块正常处理。
/// 2. 整体结构错乱（如正则本身编译失败）→ 整个 input 作为单个 `.text` 节点返回。
/// 3. **永不抛错**：任何异常路径都返回有效 RenderTree，最坏情况是 `[.text(input)]`。
enum RenderNodeParser {

    /// 解析输入字符串为 RenderTree。
    /// - Parameter input: 已经过 DisplayRegex / HideTags 处理的文本。
    /// - Returns: 永不 nil（构造失败也降级为单节点）。
    static func parse(_ input: String) -> RenderTree {
        // 1. 整体正则找 <status>...</status> 块（非贪婪、跨行匹配）
        // 2. 块之间文本 → .text
        // 3. 块内容 → 尝试解析为 .status；失败则降级为 .text(整段含标签)
        let pattern = "(?is)<status\\b[^>]*>(.*?)</status\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return RenderTree(nodes: [.text(input)])
        }
        let nsInput = input as NSString
        let fullRange = NSRange(location: 0, length: nsInput.length)
        let matches = regex.matches(in: input, options: [], range: fullRange)

        // 没有任何 status 块 → 整个 input 作为单 .text 节点
        if matches.isEmpty {
            return RenderTree(nodes: [.text(input)])
        }

        var nodes: [RenderNode] = []
        var cursor = 0  // 字节偏移（NSString 语义）

        for match in matches {
            // 块前的文本
            if match.range.location > cursor {
                let prefixRange = NSRange(location: cursor, length: match.range.location - cursor)
                let prefix = nsInput.substring(with: prefixRange)
                if !prefix.isEmpty {
                    nodes.append(.text(prefix))
                }
            }

            // 块本身
            let rawBlock = "<status>" + nsInput.substring(with: match.range(at: 1)) + "</status>"
            if let status = parseStatusBlock(nsInput.substring(with: match.range(at: 1))) {
                nodes.append(.status(hp: status.hp, affection: status.affection))
            } else {
                // 块解析失败 → 降级为 .text（含标签的原始块）
                nodes.append(.text(rawBlock))
            }

            cursor = match.range.location + match.range.length
        }

        // 最后一块之后的尾巴
        if cursor < nsInput.length {
            let tail = nsInput.substring(from: cursor)
            if !tail.isEmpty {
                nodes.append(.text(tail))
            }
        }

        // 极端情况：所有节点都被降级（不太可能，但稳妥起见）→ 整体降级
        if nodes.isEmpty {
            return RenderTree(nodes: [.text(input)])
        }
        return RenderTree(nodes: nodes)
    }

    /// 解析 `<status>` 块内的 `HP: <整数>` + `好感度: <整数>` 两行。
    /// - Returns: 成功返回 (hp, affection)；任一缺失 / 非整数 / 解析错误 → nil。
    static func parseStatusBlock(_ block: String) -> (hp: Int, affection: Int)? {
        let lines = block
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var hp: Int?
        var affection: Int?

        for line in lines {
            // 匹配 "<key>: <value>"，key 是 HP 或 好感度（中文冒号也兼容）
            guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "HP":
                if let v = Int(value) { hp = v }
            case "好感度":
                if let v = Int(value) { affection = v }
            default:
                break
            }
        }

        guard let h = hp, let a = affection else { return nil }
        return (hp: h, affection: a)
    }
}