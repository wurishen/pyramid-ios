import Foundation

/// 宏展开：在「送入 API 的文本」上替换 `{{user}}` `{{char}}` 及其大小写变体。
/// 不改写存储的 `message.content`；也不在显示阶段起作用（显示走 MessageRenderer）。
enum MacroExpander {
    static func expand(_ text: String, user: String, char: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        // 顺序无关：四个 token 各自替换，且对 user/char 用同一函数避免分支。
        out = replace(out, token: "user", with: user)
        out = replace(out, token: "char", with: char)
        return out
    }

    /// 匹配 `{{user}}` / `{{User}}` / `{{USER}}` 等大小写不敏感变体；整体替换。
    private static func replace(_ text: String, token: String, with value: String) -> String {
        // 用 NSRegularExpression 一次性匹配三种大小写。
        let pattern = "(?i)\\{\\{\\s*" + token + "\\s*\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        // `withTemplate:` 会把 `$N` 解释成捕获组反向引用、`\X` 解释成转义序列 —— 宏值
        // 里的 `$1` / `\d` 等是字面量，必须先转义成 `$$` / `\\`，否则原样字符会被吞掉。
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: escapedReplacement(value)
        )
    }

    /// 单遍转义：避免先 `\` 后 `$` 替换时把刚插好的 `$$` 二次加 `$`。
    private static func escapedReplacement(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for c in value {
            switch c {
            case "$":  out.append("$$")
            case "\\": out.append("\\\\")
            default:   out.append(c)
            }
        }
        return out
    }
}
