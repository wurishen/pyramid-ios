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
        let nsText = NSMutableString(string: text)
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length)
        )
        // 从后往前：避免先替换前段导致后续 range 偏移。`replaceCharacters` 把 `with` 当
        // 纯字面量 —— 不解释 `$N` / `\X`，所以宏值里的 `$1\d` 保持原样。
        for match in matches.reversed() {
            nsText.replaceCharacters(in: match.range, with: value)
        }
        return nsText as String
    }
}
