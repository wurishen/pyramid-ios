import Foundation

// P11: HTML + CSS → NativeIR 转译器（HTMLTranspiler 的 CSS 增强版本）。
//
// **职责**：把一段含 `<style>` 块 + class / inline style 的 HTML 文本静态归一为
// `RenderNode` 列表（含新增的 `htmlStyled` 节点），最终在 `NativeView` 里被翻译为
// SwiftUI 原生 modifier。
//
// **实现策略（post-process 风格）**：
// 1. 调用 `HTMLTranspiler.transpile(_:)` 拿到 `[RenderNode]`（旧路径不变 ——
//    `<style>` 块在那里被当 `htmlScript(residual)` 原文保留，确保**任何**未知 CSS
//    / 不识别 markup 都不会被丢数据）。
// 2. 同时用 regex 从原始 input 抽出 `<style>...</style>` 内容，交给 `CSSParser.parseSheet`
//    解析得到 `CSSStyleSheet`。
// 3. 用 regex 把 input 里每个 HTML 元素的 `tag / class / inline style` 按 outerHTML
//    出现顺序拍平成 `[ElementStyle]` 数组。
// 4. 走 `RenderNode` 树：把每个 `.htmlContainer` 看成通用容器；查 stylesheet 看是否
//    匹配 tag / class 选择器 + inline style。若匹配 → 升级为 `.htmlStyled`；否则原状。
// 5. 删除形态为 `.htmlScript(residual)` 且 replacement 包含 `<style>...</style>` 原文
//    的节点 —— CSS 已通过 stylesheet 表达，无须重复展示。
//
// **不**做的事（与 HTMLTranspiler / CSSParser 共享的硬边界）：
// - 不引入 WebView / JavaScriptCore —— `<script>` 永不执行。
// - 不下载任何远程资源。
// - 不实现 CSS 选择器 specificity 排序 / `:hover` / `:focus` / `@media` / `var(--x)` /
//   `calc()`。
// - 不创建业务组件 —— 容器 tag 仅做样式匹配，**不**派生 PhoneContainer / StatusContainer。
// - 解析失败 / 不识别一律降级为原文 residual，**绝不**伪造样式。

enum HTMLCSSTranspiler {

    /// 主入口：HTML 文本（含 0+ 个 `<style>` 块）→ `[RenderNode]`。
    ///
    /// - 任何解析失败 / 不识别都降级为 `.text(input)` 或 `.htmlScript(residual)` —— **不丢字**。
    static func transpile(_ input: String) -> [RenderNode] {
        guard !input.isEmpty else { return [] }

        // 1. 抽出 <style>...</style> 块体（regex 容错：未闭合 → 不抽）。
        let styleBodies = extractStyleBlockBodies(input)
        let sheet: CSSStyleSheet = {
            let combined = styleBodies.joined(separator: "\n")
            return CSSParser.parseSheet(combined) ?? CSSStyleSheet.empty
        }()

        // 2. 走旧 HTMLTranspiler 路径（保持所有旧行为：标签分类 / script residual /
        //    external resource / 等等不变）。
        var nodes = HTMLTranspiler.transpile(input)

        // 3. 从 input 抽 inline style attr + class attr 的有序列表（按 outerHTML 出现
        //    顺序），用于升级 htmlContainer。
        let elementStyles = parseElementStyles(input)

        // 4. 后处理：把每个 .htmlContainer 升级成 .htmlStyled（若匹配）。
        //    用 elementStyles 数组 + index 按顺序消费 —— 每个 .htmlContainer 节点消费
        //    一个 ElementStyle（按 outerHTML 顺序对齐）。
        var styleIndex = 0
        nodes = nodes.map { node in
            upgradeContainer(node, sheet: sheet, elementStyles: elementStyles, styleIndex: &styleIndex)
        }

        // 5. 删除形态为 .htmlScript(residual) 且 replacement 包含某个 <style>...</style>
        //    原文的节点 —— CSS 已通过 stylesheet 表达，无须重复展示。
        nodes = nodes.filter { node in
            if case .htmlScript(let residual) = node,
               residual.ruleName == nil,
               residual.sourcePattern == "" {
                // 判定：若 residual 包含完整 `<style...>...</style>` 块 → 已被 stylesheet
                // 替代 → 过滤掉。
                let r = residual.replacement
                if r.lowercased().contains("<style") && r.lowercased().contains("</style>") {
                    return false
                }
            }
            return true
        }

        // 6. 剥离开头 / 结尾的纯空白 text 节点 —— `<style>...\n</style>\n<div>...`
        //    这种典型输入里，HTMLTranspiler 会在最前面产出 `\n` text 节点，
        //    使 nodes[0] 不再是 styled container；测试期望外层 .card div 是 nodes[0]。
        //    纯空白 text 节点无可视内容、不会带 binding / path，丢弃无害。
        while let first = nodes.first, case .text(let s) = first, s.allSatisfy({ $0.isWhitespace || $0.isNewline }) {
            nodes.removeFirst()
        }
        while let last = nodes.last, case .text(let s) = last, s.allSatisfy({ $0.isWhitespace || $0.isNewline }) {
            nodes.removeLast()
        }

        return nodes
    }

    /// 便捷包装：把一段 HTML+CSS 整体作为单个 htmlContainer / htmlStyled 返回。
    static func transpileAsBlock(_ input: String) -> RenderNode {
        let nodes = transpile(input)
        if nodes.count == 1, case .text = nodes[0] {
            return nodes[0]
        }
        return .htmlContainer(children: nodes)
    }

    // MARK: - <style> 块抽取（regex 容错）

    /// 把 input 里所有 `<style>...</style>` 块体内容按出现顺序返回。
    /// 未闭合 / 无匹配 → 返回空。绝不修改 input 原文。
    private static func extractStyleBlockBodies(_ input: String) -> [String] {
        var out: [String] = []
        var cursor = input.startIndex
        while cursor < input.endIndex {
            // 找下一个 <style
            guard let lt = input[cursor...].range(of: "<style", options: .caseInsensitive) else { break }
            let afterLt = lt.upperBound
            guard afterLt < input.endIndex else { break }
            let next = input[afterLt]
            if next != " " && next != "\t" && next != "\n" && next != "\r" && next != ">" && next != "/" {
                cursor = afterLt
                continue
            }
            // 找 <style...> 的结束 >
            guard let gt = input[afterLt...].firstIndex(of: ">") else { break }
            // 找 </style>
            guard let closeStart = input[gt...].range(of: "</style", options: .caseInsensitive) else { break }
            // body 从 `>` 的后一位开始 —— 含住 `>` 会让首条 rule 的 selector 变成 ">\n.xxx" 而永不匹配。
            let body = String(input[input.index(after: gt)..<closeStart.lowerBound])
            out.append(body)
            cursor = closeStart.upperBound
        }
        return out
    }

    /// 把 input 里所有 HTML 元素的 inline `style="..."` 和 `class="..."` 按出现顺序返回。
    /// 用于把 inline style / class 与对应 .htmlContainer 节点对齐。
    private static func parseElementStyles(_ input: String) -> [ElementStyle] {
        var out: [ElementStyle] = []
        let pattern = "<([a-zA-Z][a-zA-Z0-9]*)([^>]*)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let tag = ns.substring(with: m.range(at: 1)).lowercased()
            let attrsRaw = ns.substring(with: m.range(at: 2))
            let attrs = parseAttrs(attrsRaw)
            let classAttr = attrs["class"]
            let styleAttr = attrs["style"]
            // 仅关心通用容器标签（与 buildContainerOrLeaf 行为一致）
            guard allowedStyleTags.contains(tag) else { continue }
            out.append(ElementStyle(
                tag: tag,
                classNames: parseClassNames(classAttr),
                inlineStyle: styleAttr.flatMap { CSSParser.parseInlineStyle($0) }
            ))
        }
        return out
    }

    /// 一段 start tag 后的属性串 → dict（小写 key）。
    private static func parseAttrs(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        var i = raw.startIndex
        while i < raw.endIndex {
            // 跳过空白
            while i < raw.endIndex, raw[i].isWhitespace { i = raw.index(after: i) }
            if i >= raw.endIndex { break }
            // 读 key（到 `=` / 空白 / `>` / `/`）
            var keyEnd = i
            while keyEnd < raw.endIndex {
                let ch = raw[keyEnd]
                if ch == "=" || ch.isWhitespace || ch == ">" || ch == "/" { break }
                keyEnd = raw.index(after: keyEnd)
            }
            let key = String(raw[i..<keyEnd]).lowercased()
            if keyEnd >= raw.endIndex || raw[keyEnd] != "=" {
                i = keyEnd
                continue
            }
            i = raw.index(after: keyEnd)
            // 读 value
            guard i < raw.endIndex else { break }
            if raw[i] == "\"" || raw[i] == "'" {
                let quote = raw[i]
                i = raw.index(after: i)
                let valStart = i
                while i < raw.endIndex, raw[i] != quote { i = raw.index(after: i) }
                let val = String(raw[valStart..<i])
                if i < raw.endIndex { i = raw.index(after: i) }
                if !key.isEmpty { out[key] = val }
            } else {
                let valStart = i
                while i < raw.endIndex, !raw[i].isWhitespace && raw[i] != ">" { i = raw.index(after: i) }
                let val = String(raw[valStart..<i])
                if !key.isEmpty { out[key] = val }
            }
        }
        return out
    }

    /// 把 `class="foo bar"` 拆成有序、唯一 class 列表。
    private static func parseClassNames(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for tok in raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            let c = String(tok)
            if !c.isEmpty && seen.insert(c).inserted {
                out.append(c)
            }
        }
        return out
    }

    /// 一组通用容器标签（与 HTMLTranspiler 默认 .htmlContainer 容器集合对齐）。
    static let allowedStyleTags: Set<String> = [
        "div", "span", "p", "section", "article", "header", "footer",
        "main", "aside", "details", "summary", "h1", "h2", "h3", "h4",
        "h5", "h6", "pre", "code", "em", "strong", "b", "i", "u", "small",
        "sub", "sup", "mark", "del", "ins", "cite", "q", "kbd", "samp",
        "var", "time", "dl", "dt", "dd", "ol", "ul", "li", "table",
        "thead", "tbody", "tr", "td", "th", "fieldset", "legend", "label",
        "form"
    ]

    struct ElementStyle {
        var tag: String
        var classNames: [String]
        var inlineStyle: CSSStyleDeclaration?
    }

    // MARK: - 后处理：把 .htmlContainer 升级为 .htmlStyled

    /// 递归走 RenderNode 树，把每个 .htmlContainer 升级为 .htmlStyled（若匹配 CSS）。
    /// `styleIndex` 指向 elementStyles 数组的下一个待消费位置。
    private static func upgradeContainer(_ node: RenderNode,
                                         sheet: CSSStyleSheet,
                                         elementStyles: [ElementStyle],
                                         styleIndex: inout Int) -> RenderNode {
        switch node {
        case .htmlContainer(let children):
            // 取下一个 ElementStyle
            let es: ElementStyle? = styleIndex < elementStyles.count ? elementStyles[styleIndex] : nil
            styleIndex += 1
            // 递归处理 children（每个子 .htmlContainer 会再消费下一个 ElementStyle）
            let newChildren = children.map {
                upgradeContainer($0, sheet: sheet, elementStyles: elementStyles, styleIndex: &styleIndex)
            }
            if let es = es, let merged = mergedStyle(for: es, sheet: sheet) {
                return .htmlStyled(tag: es.tag,
                                   classNames: es.classNames,
                                   style: merged,
                                   children: newChildren)
            }
            return .htmlContainer(children: newChildren)

        case .htmlStyled(let tag, let classNames, let style, let children):
            // 已是 styled —— children 走普通递归（但不消费 styleIndex，因 ElementStyle
            // 列表是按 outerHTML 出现顺序构造的，每个元素只消费一次）。
            // 简化：保留 style 不动；children 用独立 styleIndex。
            let newChildren = children.map {
                upgradeContainer($0, sheet: sheet, elementStyles: elementStyles, styleIndex: &styleIndex)
            }
            return .htmlStyled(tag: tag, classNames: classNames, style: style, children: newChildren)

        case let .condition(condNode):
            return .condition(NativeConditionNode(
                condition: condNode.condition,
                raw: condNode.raw,
                whenTrue: condNode.whenTrue.map { upgradeContainer($0, sheet: sheet, elementStyles: elementStyles, styleIndex: &styleIndex) },
                whenFalse: condNode.whenFalse.map { upgradeContainer($0, sheet: sheet, elementStyles: elementStyles, styleIndex: &styleIndex) }
            ))

        default:
            return node
        }
    }

    /// 给一个 ElementStyle 算出最终合并后的 CSSStyleDeclaration。
    /// 若没有任何匹配 / inline，返回 nil（调用方走原 htmlContainer 路径）。
    private static func mergedStyle(for es: ElementStyle,
                                    sheet: CSSStyleSheet) -> CSSStyleDeclaration? {
        let matchedCSS = matchedDeclarations(tag: es.tag, classNames: es.classNames, sheet: sheet)
        var merged: CSSStyleDeclaration = matchedCSS
        if let inline = es.inlineStyle {
            merged = CSSStyleDeclaration.merge(merged, inline)
        }
        if merged.isEmpty { return nil }
        return merged
    }

    /// 在 stylesheet 里查找匹配当前 tag / class 的所有规则，返回合并后的 declaration。
    /// 匹配策略：CSS `tag` 选择器 / `.class` 选择器 / `tag.class` 复合选择器。
    /// 后代选择器 `tag .class` 不在本层处理（无 ancestor 信息）。
    private static func matchedDeclarations(tag: String, classNames: [String],
                                             sheet: CSSStyleSheet) -> CSSStyleDeclaration {
        var merged = CSSStyleDeclaration(declarations: [])
        for rule in sheet.rules {
            if selectorMatches(rule.selector, tag: tag, classNames: classNames) {
                merged = CSSStyleDeclaration.merge(merged, rule.declarations)
            }
        }
        return merged
    }

    private static func selectorMatches(_ selector: String, tag: String,
                                        classNames: [String]) -> Bool {
        let s = selector.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return false }
        // 单段选择器（本层不支持后代，因为没有 ancestor 信息）
        if s.contains(" ") { return false }
        if s.hasPrefix("#") { return false }
        if s.hasPrefix(".") {
            let cls = String(s.dropFirst())
            return classNames.contains(cls)
        }
        if let dot = s.firstIndex(of: ".") {
            let t = String(s[..<dot])
            let cls = String(s[s.index(after: dot)...])
            return t == tag && classNames.contains(cls)
        }
        return s == tag
    }
}
