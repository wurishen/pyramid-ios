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
        case .exists, .notExists, .truthy:
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

    /// 提取开标签属性串 + body。贪婪 body + 锚定最后一个闭合标签 ——
    /// 嵌套同名标签时外层尽量吃满，残余退化由递归 + 保真兜底。
    static func extract(_ raw: String) -> (attrsString: String, body: String)? {
        let pattern = "(?is)^<NativeIf\\b([^>]*)>([\\s\\S]*)</NativeIf\\s*>$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = raw as NSString
        guard let m = regex.firstMatch(
            in: raw,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ), m.range(at: 1).location != NSNotFound, m.range(at: 2).location != NSNotFound else {
            return nil
        }
        return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
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
