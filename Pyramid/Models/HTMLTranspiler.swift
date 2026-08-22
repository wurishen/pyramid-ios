import Foundation

/// P8：HTML / Script 表达 → 通用 `RenderNode` 的**纯静态分析转译器**。
///
/// **硬边界（与 §13 已知限制并列）**：
/// - **不执行任何 JavaScript**。`$('body').load(...)` 之类的脚本只被解析为文本，绝不调用。
/// - **不引入 WKWebView / JavaScriptCore / SFSafariViewController**。无浏览器执行环境。
/// - **不发起任何网络请求**。`load(url)` / `<iframe src>` / `<script src>` / `<link href>`
///   一律只表达为 `ExternalResourceIR`，从不真正下载。
/// - **不修改 `message.content`**。解析失败 / 不识别一律降级为 `.text(原文)` 或
///   `.htmlScript(residual)`（残段内仍含原始 HTML 原文），保证用户复制 / 编辑 / 重新生成
///   看到的内容与模型原始输出一致。
/// - **不创建业务组件**：输出只允许映射到**通用**原语（`text` / `container` /
///   `image` / `link` / `button` / `input` / `select` / `externalResource` / `script`）。
///   绝不创建 `PhoneView` / `StatusCard` / `CharacterPanel` / `HPComponent` 等。
/// - **不建立第二套状态系统**：变量绑定复用 `VariableStore` / `MacroSegment` 现有通路。
///
/// **HTML 标签分类**（按本层处理策略）：
/// | 标签 | 策略 |
/// |---|---|
/// | `div` / `span` / `p` / `section` / `article` / `header` / `footer` / `main` / `aside` | `.htmlContainer`（容器）|
/// | `img` | `.htmlImage(src:alt:)`（**只展示意图，不下载**） |
/// | `a` | `.htmlLink(label:href:)`（**只展示意图，不跳转**） |
/// | `button` | 安全可推导的 `onclick` → `.nativeAction`；否则 `.htmlScript(residual)` |
/// | `input` | 有 `bind` / `path` 属性 → `.nativeControl(.input)`；否则 `.text(原文)` |
/// | `select` | 有 `bind` / `path` + 至少一个 `<option>` → `.nativeControl(.select)`；否则 `.htmlScript(residual)` |
/// | `script`（含内容） | `.htmlScript(residual)`（**永不执行** body）|
/// | `script src=...`（自闭合） | `.htmlExternalResource(.script, url)` |
/// | `iframe` | `.htmlExternalResource(.iframe, url)` |
/// | `object` / `embed` | `.htmlExternalResource(.object, url)` |
/// | `link` | `.htmlExternalResource(.link, url)` |
/// | `style`（含内容） | `.htmlScript(residual)`（CSS 不渲染为样式，避免视觉侧信道）|
/// | `details` | `.htmlContainer`（summary 当标题） |
/// | 其他未知标签 | 容器内含 `.text(原文)`（保真）|
///
/// **`<script>` 静态意图分析**（只分析、不执行）：
/// 1. `document.querySelector("…")` / `$("…")` —— 读出 selector 字面量
/// 2. `el.textContent = "…"` / `.innerText = …` —— 读出赋值表达式右值
/// 3. `el.classList.add("…")` / `.remove("…")` —— toggle 意图
/// 4. `el.value = "…"` —— input 赋值
/// 5. `setAttribute("data-xxx", "…")` —— 派生 → NativeAction.updateVariable
///
/// 任何超出上述模式的写法（链式赋值、闭包、异步、动态拼接、`eval`、`Function(...)`）
/// → 整段 `.htmlScript(residual)`，原始脚本内容完整保留在 residual 内。
///
/// **外部资源识别**：
/// - `<script src="https://…">` → `.htmlExternalResource(.script, url)`
/// - `<iframe src="…">` → `.htmlExternalResource(.iframe, url)`
/// - `<link href="…" rel="stylesheet">` → `.htmlExternalResource(.link, url)`
/// - `<img src="https://…">` → 允许展示为 `.htmlImage`，**但** URL 仍记录在 IR 字段里，renderer
///   决定是否加载（默认不加载）
/// - 脚本中的 `$(...).load("https://…")` / `fetch("…")` / `XMLHttpRequest("…")` →
///   `.htmlExternalResource(.remoteCall, url)`
///
/// URL 必须是 http / https / data(image|texthtml) / relative；其他 scheme（如 `javascript:` /
/// `file:` / `vbscript:`）一律强制降级为 residual（XSS 风险）。
enum HTMLTranspiler {

    // MARK: - 公共入口

    /// 给一段文本（含 0+ 个 HTML 元素 / Script 块）做静态分析，产出一组 RenderNode。
    ///
    /// - 纯文本片段（无 HTML 标签）→ `[.text(input)]`
    /// - 含 HTML 元素 → 按上表分类；不安全 / 未知部分保留原文
    /// - 含 `<script>` / `<style>` → `.htmlScript(residual)`，原文完整保留
    /// - 含远程 `load()` / `iframe src` / 等等 → `.htmlExternalResource(…)`
    ///
    /// 任何解析失败 / 不识别都降级为 `.text(input)`，**不丢一个字**。
    static func transpile(_ input: String) -> [RenderNode] {
        guard !input.isEmpty else { return [] }
        let tokens = tokenize(input)
        // 没有任何 HTML 标记 → 委托给 analyzeTextSegment（可能含 jQuery load / 宏）
        guard tokens.contains(where: { $0.kind != .text && $0.kind != .comment && $0.kind != .doctype }) else {
            return analyzeTextSegment(input)
        }
        return buildNodes(from: tokens)
    }

    /// 便捷包装：把一段 HTML 整体作为单个 htmlContainer 返回（用于替换整个文本节点）。
    static func transpileAsBlock(_ input: String) -> RenderNode {
        let nodes = transpile(input)
        if nodes.count == 1, case .text = nodes[0] {
            return nodes[0]
        }
        return .htmlContainer(children: nodes)
    }

    // MARK: - Token

    fileprivate enum TokenKind {
        case text
        case openTag
        case closeTag
        case selfClosingTag
        case comment
        case doctype
        case cdata
    }

    fileprivate struct Token {
        var kind: TokenKind
        var raw: String
        var tagName: String
        var attrs: [String: String]
        var textContent: String
    }

    // MARK: - Tokenizer

    fileprivate static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        let ns = input as NSString
        var cursor = 0
        let length = ns.length
        var textStart = 0

        while cursor < length {
            let ltRange = ns.range(of: "<", range: NSRange(location: cursor, length: length - cursor))
            guard ltRange.location != NSNotFound else { break }

            if ltRange.location > textStart {
                let chunk = ns.substring(with: NSRange(location: textStart, length: ltRange.location - textStart))
                if !chunk.isEmpty {
                    tokens.append(Token(kind: .text, raw: chunk, tagName: "", attrs: [:], textContent: chunk))
                }
            }

            let gtRange = ns.range(of: ">", range: NSRange(location: ltRange.location, length: length - ltRange.location))
            if gtRange.location == NSNotFound {
                let tail = ns.substring(from: textStart)
                if !tail.isEmpty {
                    tokens.append(Token(kind: .text, raw: tail, tagName: "", attrs: [:], textContent: tail))
                }
                return tokens
            }

            let rawTag = ns.substring(with: NSRange(location: ltRange.location, length: gtRange.location - ltRange.location + 1))
            let inner = String(rawTag.dropFirst().dropLast())

            if rawTag.hasPrefix("<!--") {
                tokens.append(Token(kind: .comment, raw: rawTag, tagName: "", attrs: [:], textContent: ""))
                cursor = gtRange.location + 1
                textStart = cursor
                continue
            }
            if rawTag.lowercased().hasPrefix("<!doctype") {
                tokens.append(Token(kind: .doctype, raw: rawTag, tagName: "", attrs: [:], textContent: ""))
                cursor = gtRange.location + 1
                textStart = cursor
                continue
            }
            if inner.hasPrefix("![CDATA[") {
                tokens.append(Token(kind: .cdata, raw: rawTag, tagName: "", attrs: [:], textContent: ""))
                cursor = gtRange.location + 1
                textStart = cursor
                continue
            }

            if inner.hasPrefix("/") {
                let name = String(inner.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
                if !name.isEmpty {
                    tokens.append(Token(kind: .closeTag, raw: rawTag, tagName: name, attrs: [:], textContent: ""))
                } else {
                    tokens.append(Token(kind: .text, raw: rawTag, tagName: "", attrs: [:], textContent: rawTag))
                }
                cursor = gtRange.location + 1
                textStart = cursor
                continue
            }

            let (name, attrs) = parseTagHead(inner)
            if rawTag.hasSuffix("/>") || isVoidTag(name) {
                tokens.append(Token(kind: .selfClosingTag, raw: rawTag, tagName: name, attrs: attrs, textContent: ""))
            } else {
                tokens.append(Token(kind: .openTag, raw: rawTag, tagName: name, attrs: attrs, textContent: ""))
            }
            cursor = gtRange.location + 1
            textStart = cursor
        }

        if textStart < length {
            let tail = ns.substring(from: textStart)
            if !tail.isEmpty {
                tokens.append(Token(kind: .text, raw: tail, tagName: "", attrs: [:], textContent: tail))
            }
        }
        return tokens
    }

    fileprivate static func parseTagHead(_ inner: String) -> (String, [String: String]) {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        let noSlash = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard !noSlash.isEmpty else { return ("", [:]) }
        if let split = noSlash.firstIndex(where: { $0.isWhitespace }) {
            let name = String(noSlash[..<split]).lowercased()
            let attrStr = String(noSlash[split...]).trimmingCharacters(in: .whitespaces)
            return (name, parseAttributes(attrStr))
        } else {
            return (noSlash.lowercased(), [:])
        }
    }

    fileprivate static func parseAttributes(_ s: String) -> [String: String] {
        var attrs: [String: String] = [:]
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            var keyEnd = i
            while keyEnd < s.endIndex, s[keyEnd] != "=", !s[keyEnd].isWhitespace {
                keyEnd = s.index(after: keyEnd)
            }
            guard keyEnd > i else { i = s.index(after: i); continue }
            let key = String(s[i..<keyEnd]).lowercased()
            i = keyEnd
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            if i >= s.endIndex || s[i] != "=" {
                attrs[key] = ""
                continue
            }
            i = s.index(after: i)
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            let value: String
            if s[i] == "\"" || s[i] == "'" {
                let quote = s[i]
                i = s.index(after: i)
                let start = i
                while i < s.endIndex, s[i] != quote { i = s.index(after: i) }
                value = String(s[start..<min(i, s.endIndex)])
                if i < s.endIndex { i = s.index(after: i) }
            } else {
                let start = i
                while i < s.endIndex, !s[i].isWhitespace, s[i] != ">" { i = s.index(after: i) }
                value = String(s[start..<i])
            }
            attrs[key] = decodeEntities(value)
        }
        return attrs
    }

    fileprivate static func decodeEntities(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&" {
                if let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 8 {
                    let entity = String(s[s.index(after: i)..<semi])
                    switch entity {
                    case "amp": out.append("&")
                    case "lt": out.append("<")
                    case "gt": out.append(">")
                    case "quot": out.append("\"")
                    case "apos": out.append("'")
                    case "nbsp": out.append(" ")
                    default:
                        if entity.hasPrefix("#") {
                            let body = String(entity.dropFirst())
                            let code: Int?
                            if body.lowercased().hasPrefix("x") {
                                code = Int(body.dropFirst(), radix: 16)
                            } else {
                                code = Int(body)
                            }
                            if let scalar = code, let u = Unicode.Scalar(scalar) {
                                out.append(String(u))
                            } else {
                                out.append("&" + entity + ";")
                            }
                        } else {
                            out.append("&" + entity + ";")
                        }
                    }
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    fileprivate static func isVoidTag(_ name: String) -> Bool {
        switch name {
        case "br", "hr", "img", "input", "meta", "link", "area", "base",
             "col", "embed", "source", "track", "wbr":
            return true
        default:
            return false
        }
    }

    // MARK: - 节点构建

    fileprivate static func buildNodes(from tokens: [Token]) -> [RenderNode] {
        var out: [RenderNode] = []
        var pending: [Token] = []
        var index = 0
        let total = tokens.count

        while index < total {
            let token = tokens[index]
            switch token.kind {
            case .text:
                pending.append(token)
                index += 1

            case .selfClosingTag:
                flushPending(&pending, into: &out)
                if let node = selfClosingNode(token) {
                    out.append(node)
                }
                index += 1

            case .openTag:
                flushPending(&pending, into: &out)
                let closingIdx = findMatchingClose(in: tokens, from: index + 1, tag: token.tagName)
                if closingIdx == -1 {
                    // 没找到闭合 → 整段降级为 residual（保真）。
                    // 例外：Pyramid P1/P3 保留标签（`<status>` 等）—— 它们不是 HTML 语义，
                    // 已由 RenderNodeParser.parseStatusBlocks / parseP3Blocks 先吃一遍，
                    // 此处若再降级为 unknown-tag residual，会把 `before <status>...未闭合`
                    // 这类 raw fallback 拆散成多节点，破坏 RenderNodeParserTests.test15。
                    let raw = tokens[index..<total].map(\.raw).joined()
                    if isPyramidReservedTag(token.tagName) {
                        out.append(.text(raw))
                    } else {
                        out.append(.htmlScript(residual: MessageRendererCore.DeferredResidual(
                            ruleName: nil, sourcePattern: "", replacement: raw
                        )))
                    }
                    index = total
                } else {
                    let inner = Array(tokens[(index + 1)..<closingIdx])
                    let innerNodes = buildNodes(from: inner)
                    let node = buildContainerOrLeaf(
                        openToken: token,
                        innerNodes: innerNodes,
                        innerTokens: inner,
                        closeToken: tokens[closingIdx]
                    )
                    out.append(node)
                    index = closingIdx + 1
                }

            case .closeTag:
                // 顶层出现孤立 closeTag → 当文本
                pending.append(token)
                index += 1

            case .comment, .doctype, .cdata:
                index += 1
            }
        }
        flushPending(&pending, into: &out)
        return out
    }

    fileprivate static func flushPending(_ pending: inout [Token], into out: inout [RenderNode]) {
        if !pending.isEmpty {
            let joined = pending.map { $0.textContent.isEmpty ? $0.raw : $0.textContent }.joined()
            if !joined.isEmpty {
                out.append(contentsOf: analyzeTextSegment(joined))
            }
            pending.removeAll()
        }
    }

    fileprivate static func findMatchingClose(in tokens: [Token], from start: Int, tag: String) -> Int {
        var depth = 1
        var i = start
        while i < tokens.count {
            let t = tokens[i]
            switch t.kind {
            case .openTag where t.tagName == tag: depth += 1
            case .closeTag where t.tagName == tag:
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        return -1
    }

    // MARK: - 自闭合标签 → 节点

    fileprivate static func selfClosingNode(_ token: Token) -> RenderNode? {
        let name = token.tagName
        switch name {
        case "img":
            return .htmlImage(src: token.attrs["src"] ?? "", alt: token.attrs["alt"])
        case "br":
            return .text("\n")
        case "hr":
            return .text("\n—\n")
        case "script":
            if let url = token.attrs["src"], isSafeURL(url) {
                return .htmlExternalResource(ExternalResourceIR(kind: .script, url: url, raw: token.raw))
            }
            return .htmlScript(residual: MessageRendererCore.DeferredResidual(
                ruleName: nil, sourcePattern: "", replacement: token.raw
            ))
        case "iframe":
            if let url = token.attrs["src"], isSafeURL(url) {
                return .htmlExternalResource(ExternalResourceIR(kind: .iframe, url: url, raw: token.raw))
            }
            return .htmlScript(residual: MessageRendererCore.DeferredResidual(
                ruleName: nil, sourcePattern: "", replacement: token.raw
            ))
        case "object", "embed":
            if let url = token.attrs["src"] ?? token.attrs["data"], isSafeURL(url) {
                return .htmlExternalResource(ExternalResourceIR(kind: .object, url: url, raw: token.raw))
            }
            return .htmlScript(residual: MessageRendererCore.DeferredResidual(
                ruleName: nil, sourcePattern: "", replacement: token.raw
            ))
        case "link":
            if let url = token.attrs["href"], isSafeURL(url) {
                return .htmlExternalResource(ExternalResourceIR(kind: .link, url: url, raw: token.raw))
            }
            return .htmlScript(residual: MessageRendererCore.DeferredResidual(
                ruleName: nil, sourcePattern: "", replacement: token.raw
            ))
        case "input":
            return mapInput(token)
        case "meta", "source", "track", "wbr", "col", "area", "base":
            return nil
        default:
            return .text(token.raw)
        }
    }

    // MARK: - 配对标签 → 节点

    fileprivate static func buildContainerOrLeaf(
        openToken: Token,
        innerNodes: [RenderNode],
        innerTokens: [Token],
        closeToken: Token
    ) -> RenderNode {
        let name = openToken.tagName
        let attrs = openToken.attrs

        switch name {
        case "status":
            // Pyramid P1 `<status>` 块不属于通用 HTML 语义；不要降级成 unknown-tag residual。
            // 由 RenderNodeParser.parseStatusBlocks 先吃，吃不下的（空 / 非法 body）会以
            // `.text("<status>…</status>")` 形态重新流回本层 —— 这里必须原样保留，
            // 否则 test14 / test15 这类「status 块未解析 → 整段 .text」断言会被误分类为
            // `.htmlScript(residual)` 而失败。
            return .text(rawBody(open: openToken, inner: innerTokens, close: closeToken))

        case "statusplaceholderimpl", "updatevariable",
             "nativeaction", "nativeinput", "nativeselect", "nativeif":
            // 其它 Pyramid P1/P3 保留标签 —— parseP3Blocks 漏过（body 非空 / 配对形态
            // 略有出入）时，本层也只透传 .text，绝不当 unknown HTML 标签降级。
            return .text(rawBody(open: openToken, inner: innerTokens, close: closeToken))

        case "script":
            if let url = attrs["src"], isSafeURL(url) {
                let raw = rawBody(open: openToken, inner: innerTokens, close: closeToken)
                return .htmlExternalResource(ExternalResourceIR(kind: .script, url: url, raw: raw))
            }
            let raw = rawBody(open: openToken, inner: innerTokens, close: closeToken)
            return .htmlScript(residual: MessageRendererCore.DeferredResidual(
                ruleName: nil, sourcePattern: "", replacement: raw
            ))

        case "iframe":
            if let url = attrs["src"], isSafeURL(url) {
                let raw = rawBody(open: openToken, inner: innerTokens, close: closeToken)
                return .htmlExternalResource(ExternalResourceIR(kind: .iframe, url: url, raw: raw))
            }
            let raw = rawBody(open: openToken, inner: innerTokens, close: closeToken)
            return .htmlScript(residual: MessageRendererCore.DeferredResidual(
                ruleName: nil, sourcePattern: "", replacement: raw
            ))

        case "style":
            let raw = rawBody(open: openToken, inner: innerTokens, close: closeToken)
            return .htmlScript(residual: MessageRendererCore.DeferredResidual(
                ruleName: nil, sourcePattern: "", replacement: raw
            ))

        case "a":
            let href = attrs["href"] ?? ""
            let label = extractTextFromNodes(innerNodes)
            if isSafeURL(href) {
                return .htmlLink(label: label.isEmpty ? href : label, href: href)
            }
            // 危险 URL（javascript: 等）→ 保真
            let raw = openToken.raw + innerTokens.map(\.raw).joined() + closeToken.raw
            return .htmlScript(residual: MessageRendererCore.DeferredResidual(
                ruleName: nil, sourcePattern: "", replacement: raw
            ))

        case "button":
            return mapButton(attrs: attrs, innerNodes: innerNodes, openToken: openToken, innerTokens: innerTokens, closeToken: closeToken)

        case "select":
            return mapSelect(attrs: attrs, innerNodes: innerNodes, openToken: openToken, innerTokens: innerTokens, closeToken: closeToken)

        case "option":
            return .text(extractTextFromNodes(innerNodes))

        case "p", "div", "span", "section", "article", "header", "footer",
             "aside", "main", "nav", "figure", "figcaption", "details",
             "summary", "address", "blockquote", "pre", "code", "em",
             "strong", "b", "i", "u", "small", "sub", "sup", "mark",
             "del", "ins", "cite", "q", "kbd", "samp", "var", "time",
             "dl", "dt", "dd", "ol", "ul", "li", "table", "thead",
             "tbody", "tr", "td", "th", "fieldset", "legend", "label",
             "form", "h1", "h2", "h3", "h4", "h5", "h6":
            if innerNodes.isEmpty {
                return .text("")
            }
            return .htmlContainer(children: innerNodes)

        default:
            let raw = rawBody(open: openToken, inner: innerTokens, close: closeToken)
            return .htmlScript(residual: MessageRendererCore.DeferredResidual(
                ruleName: nil, sourcePattern: "", replacement: raw
            ))
        }
    }

    /// 把 `<openToken>...</openToken>` 的完整 raw 拼回来（含 inner 内容 + 闭合标签）。
    fileprivate static func rawBody(open: Token, inner: [Token], close: Token) -> String {
        return open.raw + inner.map(\.raw).joined() + close.raw
    }

    /// 把 RenderNode 序列化的 raw（用于 a/option/button 等的保真 fallback）。
    fileprivate static func nodeRaw(_ node: RenderNode) -> String {
        switch node {
        case .text(let s): return s
        case .htmlImage(let src, let alt): return "<img src=\"\(src)\" alt=\"\(alt ?? "")\"/>"
        case .htmlLink(let label, let href): return "<a href=\"\(href)\">\(label)</a>"
        case .htmlContainer(let kids): return kids.map(nodeRaw).joined()
        case .nativeAction(let label, _): return "<button>\(label)</button>"
        case .nativeControl(let c): return c.kind == .input ? "<input/>" : "<select/>"
        case .htmlScript(let r): return r.replacement
        case .htmlExternalResource(let r): return r.raw
        case .macroText: return ""
        default: return ""
        }
    }

    fileprivate static func extractTextFromNodes(_ nodes: [RenderNode]) -> String {
        var out = ""
        for n in nodes {
            switch n {
            case .text(let s): out += s
            case .macroText(let segs):
                for seg in segs {
                    if case let .literal(s) = seg { out += s }
                }
            case .htmlContainer(let kids): out += extractTextFromNodes(kids)
            case .htmlImage(_, let alt):
                if let alt { out += alt }
            case .htmlLink(let label, _): out += label
            default: break
            }
        }
        return out
    }

    // MARK: - input / button / select 映射

    fileprivate static func mapInput(_ token: Token) -> RenderNode {
        let attrs = token.attrs
        if let path = attrs["bind"] ?? attrs["path"], path.hasPrefix("/") {
            return .nativeControl(NativeControl(
                kind: .input,
                label: attrs["label"].flatMap { $0.isEmpty ? nil : $0 },
                path: path,
                placeholder: attrs["placeholder"].flatMap { $0.isEmpty ? nil : $0 },
                options: []
            ))
        }
        return .text(token.raw)
    }

    fileprivate static func mapButton(
        attrs: [String: String],
        innerNodes: [RenderNode],
        openToken: Token,
        innerTokens: [Token],
        closeToken: Token
    ) -> RenderNode {
        let label = extractTextFromNodes(innerNodes)
        let onclickAttr = attrs["onclick"] ?? attrs["on-click"]
        if let onclickAttr, let action = ScriptIntentAnalyzer.analyzeOnclick(onclickAttr, label: label) {
            return .nativeAction(label: label.isEmpty ? "按钮" : label, action: action)
        }
        if let path = attrs["bind"] ?? attrs["path"], path.hasPrefix("/"),
           let valueStr = attrs["value"], let value = parseScalar(valueStr) {
            return .nativeAction(label: label.isEmpty ? "按钮" : label, action: .updateVariable(path: path, value: value))
        }
        if let path = attrs["bind"] ?? attrs["path"], path.hasPrefix("/"),
           (attrs["kind"]?.lowercased() ?? "") == "toggle" {
            return .nativeAction(label: label.isEmpty ? "按钮" : label, action: .toggle(path: path))
        }
        let raw = rawBody(open: openToken, inner: innerTokens, close: closeToken)
        return .htmlScript(residual: MessageRendererCore.DeferredResidual(
            ruleName: nil, sourcePattern: "", replacement: raw
        ))
    }

    fileprivate static func mapSelect(
        attrs: [String: String],
        innerNodes: [RenderNode],
        openToken: Token,
        innerTokens: [Token],
        closeToken: Token
    ) -> RenderNode {
        guard let path = attrs["bind"] ?? attrs["path"], path.hasPrefix("/") else {
            return .htmlScript(residual: MessageRendererCore.DeferredResidual(
                ruleName: nil, sourcePattern: "",
                replacement: rawBody(open: openToken, inner: innerTokens, close: closeToken)
            ))
        }
        var values: [String] = []
        for node in innerNodes {
            switch node {
            case .text(let s):
                let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { values.append(v) }
            case .htmlContainer(let kids):
                for k in kids {
                    if case let .text(s) = k {
                        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty { values.append(v) }
                    }
                }
            default:
                break
            }
        }
        guard !values.isEmpty else {
            return .htmlScript(residual: MessageRendererCore.DeferredResidual(
                ruleName: nil, sourcePattern: "",
                replacement: rawBody(open: openToken, inner: innerTokens, close: closeToken)
            ))
        }
        let options = values.map { NativeControlOption(value: $0, label: nil) }
        return .nativeControl(NativeControl(
            kind: .select,
            label: attrs["label"].flatMap { $0.isEmpty ? nil : $0 },
            path: path,
            placeholder: nil,
            options: options
        ))
    }

    // MARK: - 纯文本段分析

    fileprivate static func analyzeTextSegment(_ text: String) -> [RenderNode] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        // 静态 pattern：编译期常量、永不抛错 —— 退回到 `try?` + nil fallback。
        let loadPattern: NSRegularExpression? = {
            try? NSRegularExpression(
                pattern: #"(?i)\$\s*\(\s*["']([^"']+)["']\s*\)\s*\.load\s*\(\s*["']([^"']+)["']\s*\)|\bload\s*\(\s*["']([^"']+)["']\s*\)"#
            )
        }()
        guard let loadPattern else { return analyzeMacroAndPlain(text) }

        var out: [RenderNode] = []
        var lastEnd = 0
        for match in loadPattern.matches(in: text, options: [], range: fullRange) {
            if match.range.location > lastEnd {
                let prefix = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                out.append(contentsOf: analyzeMacroAndPlain(prefix))
            }
            var url: String?
            if match.range(at: 2).location != NSNotFound {
                url = ns.substring(with: match.range(at: 2))
            } else if match.range(at: 3).location != NSNotFound {
                url = ns.substring(with: match.range(at: 3))
            }
            if let u = url, isSafeURL(u) {
                out.append(.htmlExternalResource(ExternalResourceIR(kind: .remoteCall, url: u, raw: ns.substring(with: match.range))))
            } else {
                out.append(.text(ns.substring(with: match.range)))
            }
            lastEnd = match.range.location + match.range.length
        }
        if lastEnd < ns.length {
            let tail = ns.substring(from: lastEnd)
            out.append(contentsOf: analyzeMacroAndPlain(tail))
        }
        if out.isEmpty {
            return analyzeMacroAndPlain(text)
        }
        return out
    }

    fileprivate static func analyzeMacroAndPlain(_ text: String) -> [RenderNode] {
        if TavernMacroParser.containsMacroToken(text) {
            return [.macroText(TavernMacroParser.parse(text))]
        }
        return [.text(text)]
    }

    // MARK: - 工具

    fileprivate static func parseScalar(_ s: String) -> JSONValue? {
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

    fileprivate static func isSafeURL(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("javascript:") || lowered.hasPrefix("vbscript:") { return false }
        if lowered.hasPrefix("file:") { return false }
        if lowered.hasPrefix("data:") {
            return lowered.hasPrefix("data:image/") || lowered.hasPrefix("data:text/")
        }
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return true }
        // 相对路径：第一个 `:` 必须在第一个 `/` 之后（否则视为自定义 scheme → 拒绝）
        if let firstColon = trimmed.firstIndex(of: ":"),
           let firstSlash = trimmed.firstIndex(of: "/"),
           firstColon < firstSlash {
            return false
        }
        return true
    }

    /// Pyramid P1 / P3 保留标签 —— 不是 HTML 语义，不归 HTMLTranspiler 管。
    /// RenderNodeParser.parseStatusBlocks / parseP3Blocks 先吃，吃不下的会以 raw `.text`
    /// 形态流回本层（测试 14 / 15 等）。这些标签**绝不**应该被降级为
    /// `htmlScript(residual)`，否则会破坏测试断言。
    fileprivate static func isPyramidReservedTag(_ name: String) -> Bool {
        switch name.lowercased() {
        case "status", "statusplaceholderimpl", "updatevariable",
             "nativeaction", "nativeinput", "nativeselect", "nativeif":
            return true
        default:
            return false
        }
    }
}

// MARK: - ExternalResourceIR

/// 外部资源 IR：仅描述「存在一个远程 URL」，**永不加载**。
///
/// IR 持有原始 token 片段，UI 可选展示（不强制）；默认策略是「不加载、保留原文」。
struct ExternalResourceIR: Equatable, Sendable, Hashable {
    enum Kind: String, Equatable, Sendable, Hashable {
        case script
        case iframe
        case object
        case link
        case remoteCall
        case stylesheet
    }
    var kind: Kind
    var url: String
    var raw: String
}

// MARK: - ScriptIntentAnalyzer

/// 静态分析 `<script>` 与内联 `onclick` 里的 DOM 意图。
///
/// **只读不执行**。只识别酒馆 / MVU 常见模式。任何超出列表的写法
/// 都返回 `nil`，由调用方降级为 `.htmlScript(residual)`。
enum ScriptIntentAnalyzer {

    /// 把内联 `onclick="..."` 字符串解出一个 `NativeAction`。
    ///
    /// 支持：
    /// - `setVariable('/path', value)` / `updateVariable('/path', value)`
    /// - `toggleVariable('/path')` / `toggle('/path')`
    static func analyzeOnclick(_ onclick: String, label: String) -> NativeAction? {
        let s = onclick.trimmingCharacters(in: .whitespaces)
        if let path = matchSingleQuotedArg(afterAnyOf: ["toggleVariable", "toggle"], in: s) {
            return .toggle(path: path)
        }
        for verb in ["setVariable", "updateVariable"] {
            if let (path, value) = matchSetVariableCall(verb, in: s) {
                return .updateVariable(path: path, value: value)
            }
        }
        return nil
    }

    fileprivate static func matchSingleQuotedArg(afterAnyOf verbs: [String], in s: String) -> String? {
        for verb in verbs {
            let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: verb) +
                "\\s*\\(\\s*['\"]([^'\"]+)['\"]\\s*\\)"
            if let r = try? NSRegularExpression(pattern: pattern),
               let m = r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
                return (s as NSString).substring(with: m.range(at: 1))
            }
        }
        return nil
    }

    fileprivate static func matchSetVariableCall(_ verb: String, in s: String) -> (String, JSONValue)? {
        let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: verb) +
            "\\s*\\(\\s*['\"]([^'\"]+)['\"]\\s*,\\s*(.+?)\\s*\\)\\s*$"
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else {
            return nil
        }
        let ns = s as NSString
        let path = ns.substring(with: m.range(at: 1))
        let valueRaw = ns.substring(with: m.range(at: 2))
        let cleaned = valueRaw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard let v = HTMLTranspiler.parseScalar(cleaned) else { return nil }
        return (path, v)
    }
}