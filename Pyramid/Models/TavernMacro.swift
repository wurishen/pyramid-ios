import Foundation

// MARK: - JSON Pointer 只读解析

/// RFC 6901 JSON Pointer 的只读取值。与 `JSONPatchApplier`（写路径）平行，
/// 供 Macro Binding / Condition 谓词共享；处理 `~0` / `~1` 转义。
/// **零业务语义**：路径只是树形地址，不解释任何字段名。
enum JSONPointerResolver {
    /// 按指针取值。path 必须以 `/` 开头；中间缺失 / 类型不匹配 → nil。
    static func value(at path: String, in tree: JSONValue) -> JSONValue? {
        guard path.hasPrefix("/") else { return nil }
        var current = tree
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        for rawSegment in segments {
            // RFC 6901：先解 ~1 → /，再解 ~0 → ~。
            let token = rawSegment
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            switch current {
            case .object(let dict):
                guard let next = dict[token] else { return nil }
                current = next
            case .array(let arr):
                guard let index = Int(token), index >= 0, index < arr.count else { return nil }
                current = arr[index]
            default:
                return nil
            }
        }
        return current
    }
}

// MARK: - 宏表达模型

/// 单个 `{{…}}` token 的结构化解析结果（**只解析、不执行**）。
enum MacroExpression: Equatable, Sendable {
    /// 非宏文本。
    case literal(String)
    /// 变量引用：`{{getvar::path}}` —— path 已规范化为 JSON Pointer；
    /// raw 是原文（变量缺失时的 fallback）。
    case variableReference(path: String, raw: String)
    /// 无法识别的宏 —— 渲染时**逐字保留**原文，绝不删除 / 置空。
    case unrecognized(raw: String)
}

/// 绑定点的求值结果。`unresolved` 携带原文 —— 变量不存在 / 值无法内联时的 residual。
enum MacroValue: Equatable, Sendable {
    case resolved(String)
    case unresolved(raw: String)
}

/// 一个变量引用绑定：解析一次，之后可对**任意当前**变量树反复求值。
/// 变量更新只需重新求值（便宜），无需重新解析表达式。
struct MacroBinding: Equatable, Sendable {
    /// 规范化后的 JSON Pointer（裸名自动补根：`金币` → `/金币`）。
    let path: String
    /// 原文 token，如 `{{getvar::/区域/房间/计数}}`。
    let raw: String

    /// 对当前变量树求值。缺失 / null / 数组 / 对象等无法内联的形态 → `.unresolved(原文)`。
    func value(in tree: JSONValue) -> MacroValue {
        guard let v = JSONPointerResolver.value(at: path, in: tree),
              let text = MacroRenderer.format(v) else {
            return .unresolved(raw: raw)
        }
        return .resolved(text)
    }
}

/// 一段文本经宏解析后的**有序**片段 —— 解析产物（可缓存），与具体变量值解耦。
enum MacroSegment: Equatable, Sendable {
    case literal(String)
    case binding(MacroBinding)
}

// MARK: - 解析器

/// Tavern 宏解析器：把含 `{{…}}` 的文本切成有序 `MacroSegment`。
///
/// **识别范围**（本期）：`{{getvar::path}}` —— 大小写不敏感、空白容忍；
/// 裸名参数规范化为根级 JSON Pointer。其余一切宏（`{{setvar}}` / `{{user}}` /
/// `{{roll:…}}` / 自造语法 …）→ `.unrecognized`，原文逐字保留。
///
/// **硬性边界**：
/// - 不执行任何表达式 / 脚本 —— 只做 token 切分 + 指针查表。
/// - 未配对的 `{{` 是普通文本；嵌套花括号按最内层完整 token 处理，外层残余保真。
enum TavernMacroParser {
    private static let tokenPattern = "\\{\\{([^{}]*)\\}\\}"

    static func containsMacroToken(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: tokenPattern), !text.isEmpty else {
            return false
        }
        return regex.firstMatch(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length)
        ) != nil
    }

    /// 文本 → 有序片段。无宏 → `[.literal(text)]`（保持调用方零开销直通）。
    static func parse(_ text: String) -> [MacroSegment] {
        guard let regex = try? NSRegularExpression(pattern: tokenPattern),
              !text.isEmpty else {
            return [.literal(text)]
        }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return [.literal(text)] }

        var segments: [MacroSegment] = []
        var cursor = 0
        for m in matches where m.range.location >= cursor {
            if m.range.location > cursor {
                appendLiteral(
                    ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)),
                    to: &segments
                )
            }
            let rawToken = ns.substring(with: m.range)
            let inner = ns.substring(with: m.range(at: 1))
            segments.append(segment(forMacro: inner, raw: rawToken))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            appendLiteral(ns.substring(from: cursor), to: &segments)
        }
        return segments.isEmpty ? [.literal(text)] : segments
    }

    // MARK: 内部

    /// 单个 token → 片段。仅 `getvar` 进 binding；其它一律 unrecognized 保真。
    private static func segment(forMacro inner: String, raw: String) -> MacroSegment {
        guard let sep = inner.range(of: "::") else {
            return .literal(raw)
        }
        let name = inner[..<sep.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
        let arg = inner[sep.upperBound...].trimmingCharacters(in: .whitespaces)
        guard name == "getvar", !arg.isEmpty else {
            return .literal(raw)
        }
        let path = arg.hasPrefix("/") ? arg : "/" + arg
        return .binding(MacroBinding(path: path, raw: raw))
    }

    /// 相邻字面量合并（保证片段表示唯一）。
    private static func appendLiteral(_ s: String, to segments: inout [MacroSegment]) {
        if case .literal(let last)? = segments.last {
            segments[segments.count - 1] = .literal(last + s)
        } else if !s.isEmpty {
            segments.append(.literal(s))
        }
    }
}

// MARK: - 求值

/// 把宏片段对当前变量树求值为显示文本。
/// unresolved（缺失 / 无法内联）→ **原文回退**，绝不静默删除。
enum MacroRenderer {
    /// 变量值的通用内联文本化。null / array / object 无法合理内联 → nil（调用方回退原文）。
    static func format(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    static func render(segments: [MacroSegment], tree: JSONValue) -> String {
        segments.map { seg -> String in
            switch seg {
            case .literal(let s):
                return s
            case .binding(let binding):
                switch binding.value(in: tree) {
                case .resolved(let text): return text
                case .unresolved(let raw): return raw
                }
            }
        }.joined()
    }
}
