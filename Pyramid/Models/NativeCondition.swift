import Foundation

/// 通用条件谓词：对变量树某 JSON Pointer 做安全比较。
///
/// **零业务语义**：路径与操作数都是 data；不存在 HP / 好感度 等字段名分支。
/// **不执行脚本**：只有指针查表 + 标量比较，无表达式语言、无 JS。
struct NativePredicate: Equatable, Sendable {
    enum Op: String, Sendable {
        case eq, ne, gt, gte, lt, lte
        /// 路径存在（任意值，含 null）。
        case exists
        case notExists = "notexists"
        /// 通用真值：非 null 且按类型非空 / 非零 / 非 false。
        case truthy
        /// 存在且为「空」（null / 空串 / 空数组 / 空对象）；路径缺失 → false。
        case isEmpty = "isempty"
        /// 存在且有内容；路径缺失 → false。
        case nonEmpty = "nonempty"
    }

    let path: String
    let op: Op
    /// 比较操作数（六个比较 op 必需；exists / notExists / truthy 为 nil）。
    let operand: JSONValue?

    /// 从小写 attr 字典构建。缺 path / path 非指针 / op 非法 / 比较 op 缺 value → nil，
    /// 调用方把整段降级为原文（residual）。
    init?(attrs: [String: String]) {
        guard let p = attrs["path"], p.hasPrefix("/"),
              let rawOp = attrs["op"], !rawOp.isEmpty else {
            return nil
        }
        let lowered = rawOp.lowercased()
        // 别名：ge/le → gte/lte。
        let resolved = Op(rawValue: lowered)
            ?? (lowered == "ge" ? .gte : nil)
            ?? (lowered == "le" ? .lte : nil)
        guard let op = resolved else { return nil }
        self.path = p
        self.op = op
        switch op {
        case .eq, .ne, .gt, .gte, .lt, .lte:
            guard let rawValue = attrs["value"], !rawValue.isEmpty,
                  let scalar = RenderNodeParser.parseActionScalar(rawValue) else {
                return nil
            }
            self.operand = scalar
        case .exists, .notExists, .truthy, .isEmpty, .nonEmpty:
            self.operand = nil
        }
    }

    init(path: String, op: Op, operand: JSONValue?) {
        self.path = path
        self.op = op
        self.operand = operand
    }

    func evaluate(in tree: JSONValue) -> Bool {
        let current = JSONPointerResolver.value(at: path, in: tree)
        switch op {
        case .exists:
            return current != nil
        case .notExists:
            return current == nil
        case .truthy:
            guard let v = current else { return false }
            switch v {
            case .null: return false
            case .bool(let b): return b
            case .int(let i): return i != 0
            case .double(let d): return d != 0 && !d.isNaN
            case .string(let s): return !s.isEmpty
            case .array(let a): return !a.isEmpty
            case .object(let o): return !o.isEmpty
            }
        case .isEmpty:
            guard let v = current else { return false }
            switch v {
            case .null: return true
            case .string(let s): return s.isEmpty
            case .array(let a): return a.isEmpty
            case .object(let o): return o.isEmpty
            default: return false
            }
        case .nonEmpty:
            guard let v = current else { return false }
            switch v {
            case .null: return false
            case .string(let s): return !s.isEmpty
            case .array(let a): return !a.isEmpty
            case .object(let o): return !o.isEmpty
            default: return true
            }
        case .eq:
            guard let current else { return false }
            return Self.isEqual(current, operand)
        case .ne:
            // 路径缺失时「不等」无从谈起 → false（宁可隐藏也不误显示）。
            guard let current else { return false }
            return !Self.isEqual(current, operand)
        case .gt:
            return ordering(current) == .greater
        case .gte:
            let o = ordering(current)
            return o == .greater || o == .equal
        case .lt:
            return ordering(current) == .less
        case .lte:
            let o = ordering(current)
            return o == .less || o == .equal
        }
    }

    // MARK: 比较语义

    private enum Ordering { case less, equal, greater }

    /// 相等：数值互通（int/double），其余走 `JSONValue` 结构相等。
    private static func isEqual(_ lhs: JSONValue?, _ rhs: JSONValue?) -> Bool {
        guard let lhs, let rhs else { return false }
        if let a = numeric(lhs), let b = numeric(rhs) {
            return a == b
        }
        return lhs == rhs
    }

    /// 排序比较：数值对（int/double 互通）或字符串字典序；不可比 → nil → 全部排序谓词为 false。
    private func ordering(_ current: JSONValue?) -> Ordering? {
        guard let current, let operand else { return nil }
        if let a = Self.numeric(current), let b = Self.numeric(operand) {
            if a < b { return .less }
            if a > b { return .greater }
            return .equal
        }
        if case .string(let a) = current, case .string(let b) = operand {
            switch a.compare(b) {
            case .orderedAscending: return .less
            case .orderedDescending: return .greater
            case .orderedSame: return .equal
            }
        }
        return nil
    }

    private static func numeric(_ v: JSONValue) -> Double? {
        switch v {
        case .int(let i): return Double(i)
        case .double(let d): return d.isFinite ? d : nil
        default: return nil
        }
    }
}

/// `<NativeIf path="…" op="…" value?="…">body</NativeIf>` 的声明式条件原语。
///
/// Pyramid 自有原语家族（与 `<NativeAction>` / `<NativeInput>` 同源）：
/// - 谓词成立 → body 进入渲染流（可含嵌套 token / 宏，由 parser 递归处理）；
/// - 不成立 → 分支隐藏；
/// - **任何解析失败**（缺属性 / 未知 op / 形状畸形 / 超出嵌套深度）→ 整段降级 `.text(原文)` 保真。
enum NativeConditionParser {
    /// 最大嵌套深度（防病态嵌套；超限按畸形保真）。
    static let maxDepth = 8

    private static let tokenPattern = "(?is)<NativeIf\\b[^>]*>|</NativeIf\\s*>"
    private static let openPattern = "(?is)^<NativeIf\\b([^>]*)>"

    /// 提取开标签属性串 + body —— **配平扫描**：逐 token 计数开 / 闭标签，
    /// 深度归零的闭合才是本块的闭合（正确处理嵌套同名标签）。
    /// 无配对闭合 / 开标签不在开头 → nil（调用方整段原文保真）。
    static func extract(_ raw: String) -> (attrsString: String, body: String)? {
        guard let openRegex = try? NSRegularExpression(pattern: openPattern),
              let tokenRegex = try? NSRegularExpression(pattern: tokenPattern) else {
            return nil
        }
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let open = openRegex.firstMatch(in: raw, options: [], range: full),
              open.range.location == 0 else {
            return nil
        }
        let bodyStart = open.range.location + open.range.length
        var depth = 0
        let scanRange = NSRange(location: bodyStart, length: ns.length - bodyStart)
        for m in tokenRegex.matches(in: raw, options: [], range: scanRange) {
            if ns.substring(with: m.range).hasPrefix("</") {
                depth -= 1
                if depth < 0 {
                    let bodyRange = NSRange(location: bodyStart, length: m.range.location - bodyStart)
                    return (ns.substring(with: open.range(at: 1)), ns.substring(with: bodyRange))
                }
            } else {
                depth += 1
            }
        }
        return nil
    }

    /// 在整段输入里找出所有**配平完成**的 `<NativeIf>…</NativeIf>` 区间（含嵌套外层整体）。
    /// 未配对的开 / 闭标签不产出区间 —— 留在文本流逐字保真。
    static func balancedRanges(in input: String) -> [NSRange] {
        guard let tokenRegex = try? NSRegularExpression(pattern: tokenPattern) else { return [] }
        let ns = input as NSString
        var ranges: [NSRange] = []
        var openLocation: Int?
        var depth = 0
        for m in tokenRegex.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length)) {
            if ns.substring(with: m.range).lowercased().hasPrefix("<nativeif") {
                if openLocation == nil { openLocation = m.range.location }
                depth += 1
            } else if openLocation != nil {
                depth -= 1
                if depth == 0 {
                    ranges.append(NSRange(
                        location: openLocation!,
                        length: m.range.location + m.range.length - openLocation!
                    ))
                    openLocation = nil
                }
            }
        }
        return ranges
    }

    /// 属性串 → 小写 key 字典（与 RenderNodeParser.tokenAttributes 同一规则）。
    static func attributes(from string: String) -> [String: String] {
        guard let attrRegex = try? NSRegularExpression(pattern: "([A-Za-z_][\\w-]*)\\s*=\\s*\"([^\"]*)\"") else {
            return [:]
        }
        let ns = string as NSString
        var attrs: [String: String] = [:]
        for m in attrRegex.matches(
            in: string,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ) {
            attrs[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: m.range(at: 2))
        }
        return attrs
    }
}

// MARK: - 组合条件（NOT / AND / OR）

/// 通用条件表达式 —— 叶子谓词 + 布尔组合子。**间接枚举**支持任意嵌套。
///
/// **零业务语义**：叶子只含 JSON Pointer + 比较符；不存在 HP / 好感度 等字段名分支。
/// **安全**：只有查表 + 标量比较，无表达式语言、无脚本执行。
indirect enum NativeCondition: Equatable, Sendable {
    /// 叶子：单条路径谓词。
    case predicate(NativePredicate)
    case not(NativeCondition)
    /// AND —— 全部成立才成立；空数组恒 true（单位元）。
    case all([NativeCondition])
    /// OR —— 任一成立即成立；空数组恒 false（单位元）。
    case any([NativeCondition])

    func evaluate(in tree: JSONValue) -> Bool {
        switch self {
        case .predicate(let p):
            return p.evaluate(in: tree)
        case .not(let inner):
            return !inner.evaluate(in: tree)
        case .all(let sub):
            return sub.allSatisfy { $0.evaluate(in: tree) }
        case .any(let sub):
            return sub.contains { $0.evaluate(in: tree) }
        }
    }

    /// 本条件引用的全部 JSON Pointer（依赖记录：仅这些路径变化才需要重算）。
    var dependencies: Set<String> {
        switch self {
        case .predicate(let p):
            return [p.path]
        case .not(let inner):
            return inner.dependencies
        case .all(let sub), .any(let sub):
            return sub.reduce(into: Set<String>()) { $0.formUnion($1.dependencies) }
        }
    }
}

/// `<NativeIf>` 的**解析一次**产物：条件 + 预解析双分支 + 原文。
///
/// 分支内容在解析期递归切成 `RenderNode`（可含 Text / Container / 宏绑定 /
/// Input / Select / Button / 嵌套 Condition）；**求值发生在显示期**对当前变量树
/// 执行 —— VariableStore 变化 → 重算 → 分支切换，无需重发消息、无需重新解析。
struct NativeConditionNode: Equatable, Sendable {
    let condition: NativeCondition
    /// 原始 token（residual 溯源 / 调试）。
    let raw: String
    let whenTrue: [RenderNode]
    let whenFalse: [RenderNode]

    /// 对当前变量树选择应显示的分支。纯函数 —— UI / 测试共用同一判定。
    func activeBranch(in tree: JSONValue) -> (nodes: [RenderNode], isTrue: Bool) {
        condition.evaluate(in: tree) ? (whenTrue, true) : (whenFalse, false)
    }
}

// MARK: - 结构化条件 token 解析

/// 结构化条件语法（与 `<NativeAction>` 同族的声明式原语，非 HTML / 无 JS）：
///
/// ```xml
/// <NativeIf>
///   <NativeAll>
///     <NativeWhen path="/state/a" op="gt" value="1"/>
///     <NativeAny>
///       <NativeWhen path="/state/b" op="eq" value="true"/>
///       <NativeNot><NativeWhen path="/state/c" op="ne" value="0"/></NativeNot>
///     </NativeAny>
///   </NativeAll>
///   <NativeThen>true 分支内容</NativeThen>
///   <NativeElse>false 分支内容</NativeElse>
/// </NativeIf>
/// ```
///
/// 兼容第六阶段叶形态：`<NativeIf path op value?>body[<NativeElse/>body]</NativeIf>`。
enum NativeConditionTokenParser {
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    /// 自闭合或空 body 配对的 `<Tag …/>` 叶子属性。
    static func leafAttrs(_ raw: String, tag: String) -> [String: String]? {
        guard let shape = regex("(?is)^<\(tag)\\b([^>]*?)/?\\s*>\\s*(?:</\(tag)\\s*>)?$"),
              let m = shape.firstMatch(in: raw, options: [], range: NSRange(location: 0, length: (raw as NSString).length)),
              m.range(at: 1).location != NSNotFound else {
            return nil
        }
        return NativeConditionParser.attributes(from: (raw as NSString).substring(with: m.range(at: 1)))
    }

    /// 第一个配平的 `<Tag …>…</Tag>` 块（同名嵌套安全）。返回 body 与整体 range。
    static func firstBalancedBlock(in string: String, tag: String) -> (body: String, range: NSRange)? {
        guard let tokenRegex = regex("(?is)<\(tag)\\b[^>]*>|</\(tag)\\s*>") else { return nil }
        let ns = string as NSString
        var openRange: NSRange?
        var depth = 0
        for m in tokenRegex.matches(in: string, options: [], range: NSRange(location: 0, length: ns.length)) {
            if ns.substring(with: m.range).lowercased().hasPrefix("<\(tag.lowercased())") {
                if openRange == nil { openRange = m.range }
                depth += 1
            } else if openRange != nil {
                depth -= 1
                if depth == 0 {
                    let open = openRange!
                    let bodyRange = NSRange(location: open.location + open.length,
                                            length: m.range.location - (open.location + open.length))
                    return (ns.substring(with: bodyRange),
                            NSRange(location: open.location,
                                    length: m.range.location + m.range.length - open.location))
                }
            }
        }
        return nil
    }

    /// 把一段结构化文本解析为 `NativeCondition`。任何畸形 → nil（调用方整段 residual）。
    ///
    /// 递归下降：`<NativeWhen/>` 叶子；`<NativeAll>/<NativeAny>/<NativeNot>` 配平块组合；
    /// 块之间的裸文本一律非法（防静默吞内容）。
    static func condition(from string: String) -> NativeCondition? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if let attrs = leafAttrs(trimmed, tag: "NativeWhen"), let p = NativePredicate(attrs: attrs) {
            return .predicate(p)
        }
        for (tag, builder) in [("NativeAll", NativeCondition.all), ("NativeAny", NativeCondition.any)] {
            if trimmed.hasPrefix("<\(tag)") {
                guard let block = balancedSelfBlock(trimmed, tag: tag) else { return nil }
                let children = splitTopLevel(block)
                guard !children.isEmpty else { return nil }
                var parsed: [NativeCondition] = []
                for child in children {
                    guard let c = condition(from: child) else { return nil }
                    parsed.append(c)
                }
                return builder(parsed)
            }
        }
        if trimmed.hasPrefix("<NativeNot") {
            guard let block = balancedSelfBlock(trimmed, tag: "NativeNot") else { return nil }
            return condition(from: block).map { .not($0) }
        }
        return nil
    }

    /// `<Tag …>…</Tag>` 且块占满整个输入（配平）；否则 nil。返回 body。
    private static func balancedSelfBlock(_ raw: String, tag: String) -> String? {
        guard let tokenRegex = regex("(?is)<\(tag)\\b[^>]*>|</\(tag)\\s*>") else { return nil }
        let ns = raw as NSString
        guard let first = tokenRegex.firstMatch(in: raw, options: [], range: NSRange(location: 0, length: ns.length)),
              first.range.location == 0 else {
            return nil
        }
        var depth = 0
        for m in tokenRegex.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length)) {
            if ns.substring(with: m.range).lowercased().hasPrefix("<\(tag.lowercased())") {
                depth += 1
            } else {
                depth -= 1
                if depth == 0 {
                    // 必须恰好吃满输入。
                    guard m.range.location + m.range.length == ns.length else { return nil }
                    let open = first.range
                    let bodyRange = NSRange(location: open.location + open.length,
                                            length: m.range.location - (open.location + open.length))
                    return ns.substring(with: bodyRange)
                }
            }
        }
        return nil
    }

    /// 按顶层 token 切分子块（嵌套深度归零处切分）。纯空白间隙跳过；
    /// 非空白裸文本保留为独立片段 —— 上层解析该片段必然失败 → 整段 residual（严格非法信号）。
    static func splitTopLevel(_ string: String) -> [String] {
        guard let tokenRegex = regex("(?is)<Native(?:When|All|Any|Not)\\b[^>]*>|</Native(?:All|Any|Not)\\s*>") else {
            return []
        }
        let ns = string as NSString
        var pieces: [String] = []
        var depth = 0
        var pieceStart = 0

        func flushGap(_ upTo: Int) {
            guard upTo > pieceStart else { return }
            let gap = ns.substring(with: NSRange(location: pieceStart, length: upTo - pieceStart))
            if !gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pieces.append(gap)
            }
        }

        for m in tokenRegex.matches(in: string, options: [], range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            let low = tok.lowercased()
            let isClose = low.hasPrefix("</")
            // 自闭合叶子：`<NativeWhen …/>`。配对形 `<NativeWhen…></NativeWhen>` 走开/闭计数。
            let isSelfClosing = !isClose && tok.hasSuffix("/>")
            if isClose {
                depth -= 1
                if depth == 0 {
                    pieces.append(ns.substring(with: NSRange(location: pieceStart,
                                                             length: m.range.location + m.range.length - pieceStart)))
                    pieceStart = m.range.location + m.range.length
                }
            } else if isSelfClosing {
                if depth == 0 {
                    flushGap(m.range.location)
                    pieces.append(tok)
                    pieceStart = m.range.location + m.range.length
                }
            } else {
                if depth == 0 {
                    flushGap(m.range.location)
                    pieceStart = m.range.location
                }
                depth += 1
            }
        }
        if depth != 0 { return [] }
        flushGap(ns.length)
        return pieces
    }
}
