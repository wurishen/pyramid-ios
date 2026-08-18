import Foundation

/// SillyTavern 风格 Regex Script 的最小兼容层。
///
/// 第一阶段只支持**静态**字段，不执行 JavaScript：
/// - `regex` / `findRegex` —— 模式
/// - `replacement` / `replaceString` —— 替换串
/// - `flags` —— JavaScript 正则 flag（g/i/m/s 等）
/// - `enabled` / `disabled` —— 启用开关
/// - `name` / `scriptName` —— 名称（可选）
///
/// 输出：一条或多条 `DisplayRegex`。导入器保留 JSON 数组顺序作为执行顺序；
/// `enabled = false` 的脚本跳过；非空 pattern 才能编译成功才能产出 DisplayRegex。
///
/// 作用域：当前 Pyramid 只暴露 `assistantDisplayPre`（与 MessageRenderer.applyDisplayRegex
/// 的生效范围一致）。SillyTavern 的 placement / depth / minDepth / maxDepth 等复杂字段
/// 第一阶段不解释；如果未来需要 user / system prompt 等其他 scope，扩展 `DisplayRegex.Scope`
/// + MessageRenderer.applyDisplayRegex 即可，本层无需改动。
///
/// flags 处理：JS 正则 flags 通过 `(?i)(?m)(?s)` 内联 flag group 前缀嵌入到 pattern
/// 头部。这样不需要修改 `DisplayRegex`（保留字段稳定）也不需要修改 MessageRenderer
/// 编译缓存（NSRegularExpression 直接识别 inline flag group）。
struct SillyTavernRegexScript: Codable, Equatable {
    var name: String?
    var regex: String
    var replacement: String
    var flags: String?
    /// 三态：true/false/nil（缺省）。nil 在 convert 时按 true 处理。
    var enabled: Bool?

    enum CodingKeys: String, CodingKey {
        // 标准化字段
        case name
        case regex
        case replacement
        case flags
        case enabled
        // SillyTavern 别名（输入端兼容）
        case scriptName
        case findRegex
        case replaceString
        case disabled
    }

    init(
        name: String? = nil,
        regex: String,
        replacement: String,
        flags: String? = nil,
        enabled: Bool? = nil
    ) {
        self.name = name
        self.regex = regex
        self.replacement = replacement
        self.flags = flags
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // name: name / scriptName
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .scriptName)

        // regex: regex / findRegex —— 二者都缺则解码失败
        if let v = try c.decodeIfPresent(String.self, forKey: .regex) {
            regex = v
        } else if let v = try c.decodeIfPresent(String.self, forKey: .findRegex) {
            regex = v
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "SillyTavern 脚本缺少 regex/findRegex 字段"
            ))
        }

        // replacement: replacement / replaceString
        // 两次 decodeIfPresent 都可能抛错，先各自抓出来再做 ??（?? 不传播 throw）
        let r1 = try c.decodeIfPresent(String.self, forKey: .replacement)
        let r2 = try c.decodeIfPresent(String.self, forKey: .replaceString)
        replacement = r1 ?? r2 ?? ""

        // flags
        flags = try c.decodeIfPresent(String.self, forKey: .flags)

        // enabled: enabled / !disabled
        if let e = try c.decodeIfPresent(Bool.self, forKey: .enabled) {
            enabled = e
        } else if let d = try c.decodeIfPresent(Bool.self, forKey: .disabled) {
            enabled = !d
        } else {
            enabled = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(regex, forKey: .regex)
        try c.encode(replacement, forKey: .replacement)
        try c.encodeIfPresent(flags, forKey: .flags)
        try c.encodeIfPresent(enabled, forKey: .enabled)
    }
}

/// 解析 + 转换。一次性把 SillyTavern JSON 数据转成 Pyramid 的 [DisplayRegex]。
enum SillyTavernScriptImporter {
    enum ImportError: Error, LocalizedError {
        case invalidJSON(String)
        var errorDescription: String? {
            switch self {
            case .invalidJSON(let s): return "SillyTavern 脚本 JSON 不合法：\(s)"
            }
        }
    }

    /// 把 JSON 数据解析并转换为 [DisplayRegex]。
    /// 接受单条对象或数组；保留输入顺序；enabled=false 的跳过；pattern 非法或空 的跳过。
    /// 输入完全无法解析为 SillyTavernRegexScript 时抛 `invalidJSON`。
    static func importScripts(from data: Data) throws -> [DisplayRegex] {
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([SillyTavernRegexScript].self, from: data) {
            return array.compactMap(convert)
        }
        if let single = try? decoder.decode(SillyTavernRegexScript.self, from: data) {
            return convert(single).map { [$0] } ?? []
        }
        throw ImportError.invalidJSON("既不是对象也不是数组")
    }

    /// 单条转换。enabled=false / 空 pattern / pattern 无法编译 → 返回 nil。
    static func convert(_ script: SillyTavernRegexScript) -> DisplayRegex? {
        guard script.enabled ?? true else { return nil }
        let trimmedPattern = script.regex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else { return nil }
        let finalPattern = SillyTavernFlagMapper.applyFlags(script.flags, to: trimmedPattern)
        // 模式必须能编译 —— 与 DisplayRegex.validate 同样的 .dotMatchesLineSeparators 基准
        if (try? NSRegularExpression(pattern: finalPattern, options: [.dotMatchesLineSeparators])) == nil {
            return nil
        }
        let trimmedName = script.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DisplayRegex(
            name: trimmedName.isEmpty ? "(SillyTavern 导入)" : trimmedName,
            pattern: finalPattern,
            replacement: script.replacement,
            enabled: true
        )
    }
}

/// SillyTavern JS 正则 flags → NSRegularExpression inline flag group 前缀。
///
/// 支持的 flags：
/// - `g`：NSRegularExpression 本身就���局匹配，无需额外设置
/// - `i`：`(?i)` 启用大小写不敏感
/// - `m`：`(?m)` 多行模式（`^` / `$` 匹配行边界）
/// - `s`：`(?s)` 单行模式（`.` 匹配换行）
///
/// 不支持的 flags（静默忽略）：`u`（unicode）、`y`（sticky）、`x`（extended）。
/// 忽略策略：不抛错；导入脚本会在测试时被识别为「未知 flag 不生效」但仍可执行。
enum SillyTavernFlagMapper {
    static func applyFlags(_ flags: String?, to pattern: String) -> String {
        let group = inlineGroup(for: flags)
        guard !group.isEmpty else { return pattern }
        return "(?\(group))" + pattern
    }

    /// 内部测试用：返回排序后的 inline flag group（如 "ims"）；空表示无。
    static func inlineGroup(for flags: String?) -> String {
        var chars: [Swift.Character] = []
        guard let flags = flags else { return "" }
        for ch in flags {
            switch ch {
            case "i", "m", "s":
                if !chars.contains(ch) { chars.append(ch) }
            case "g":
                continue
            default:
                continue
            }
        }
        return String(chars)
    }
}