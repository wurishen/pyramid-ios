import Foundation

/// 思维链（Chain-of-Thought）提取器：把模型输出中的 `<think>…</think>` /
/// `<thinking>…</thinking>` 块从正文剥离出来，供消息卡片以「左上角小折叠块」
/// 展示（对齐酒馆 reasoning.js 的 parseReasoningFromString 行为）。
///
/// 规则：
/// - 标签大小写不敏感；开标签允许带属性（`<think foo="1">`）。
/// - 多个已闭合块按出现顺序合并（`\n\n` 连接）。
/// - 只有开标签没有闭合（流式生成中 / 输出被截断的「掉格式」场景）→
///   开标签之后的全部内容视为思考文本，`isIncomplete = true`。
/// - 没有任何标签 → 正文原样返回，不做任何修改（包括不裁空白）。
/// - 剥离发生时，正文仅去掉因剥离产生的首尾空白。
///
/// 纯 Foundation 实现，App 与 SPM 测试共用同一份源码。
enum ThinkingParser {

    struct Result: Equatable {
        /// 提取出的思考文本（多块合并）；nil = 没有思维链内容。
        var thinking: String?
        /// 存在未闭合的思考块（流式中 / 截断）。
        var isIncomplete: Bool
        /// 剥离后的正文。
        var body: String
    }

    static func parse(_ text: String, tags: [String] = ["think", "thinking"]) -> Result {
        let names = tags
            .map { NSRegularExpression.escapedPattern(for: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty, !text.isEmpty else {
            return Result(thinking: nil, isIncomplete: false, body: text)
        }
        let alternation = "(?:" + names.joined(separator: "|") + ")"
        let nsText = text as NSString

        // 1) 已闭合块（非贪婪取最近闭合），按出现顺序收集。
        var blocks: [String] = []
        var removalRanges: [NSRange] = []
        let closedPattern = "<\(alternation)(?:\\s[^>]*)?>((?s).*?)</\(alternation)>"
        if let regex = try? NSRegularExpression(pattern: closedPattern, options: [.caseInsensitive]) {
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for match in matches where match.range.length > 0 {
                let inner = nsText.substring(with: match.range(at: 1))
                if !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(inner)
                }
                removalRanges.append(match.range)
            }
        }

        // 2) 未闭合块：在剥掉已闭合块之后的剩余文本里找最早的孤立开标签，
        //    其后全部内容视为思考（流式 / 截断兜底）。
        var remainder = removeRanges(removalRanges, from: text)
        var incomplete = false
        let openPattern = "<\(alternation)(?:\\s[^>]*)?>((?s).*)\\Z"
        if let openRegex = try? NSRegularExpression(pattern: openPattern, options: [.caseInsensitive]),
           let match = openRegex.firstMatch(
               in: remainder,
               options: [],
               range: NSRange(location: 0, length: (remainder as NSString).length)
           ) {
            let tail = (remainder as NSString).substring(with: match.range(at: 1))
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(tail)
            }
            incomplete = true
            remainder = (remainder as NSString).substring(to: match.range.location)
        }

        // 只要发生过剥离（哪怕剥掉的只是空白块）就以剩余文本为正文。
        guard !removalRanges.isEmpty || incomplete else {
            return Result(thinking: nil, isIncomplete: false, body: text)
        }
        let thinking = blocks.joined(separator: "\n\n")
        return Result(
            thinking: thinking.isEmpty ? nil : thinking,
            isIncomplete: incomplete,
            body: remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 按位置从后往前删除若干 NSRange（避免索引失效）。
    private static func removeRanges(_ ranges: [NSRange], from text: String) -> String {
        var out = text
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            guard let swiftRange = Range(range, in: out) else { continue }
            out.removeSubrange(swiftRange)
        }
        return out
    }
}
