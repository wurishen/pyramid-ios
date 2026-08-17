import Foundation
import SwiftUI

/// 纯展示层：把存储的原始 `content` 加工成可显示的 `AttributedString`。
/// 流水线：原始 → 显示用正则 → 隐藏标签剥离 → Markdown / 纯文本 → HTML 降级。
/// 任何阶段都 **不** 写回 `message.content`；复制/编辑/重新生成/发送 API 始终使用原始文本。
enum MessageRenderer {
    struct Inputs {
        let raw: String
        let role: ChatMessage.Role
        let settings: AppSettings
        let preset: Preset?
        let displayRegexes: [DisplayRegex]
    }

    /// 渲染入口。预解析失败时返回等价纯文本（不抛错）。
    static func render(_ inputs: Inputs) -> AttributedString {
        let raw = inputs.raw
        let stage1 = applyDisplayRegex(to: raw, role: inputs.role, preset: inputs.preset, all: inputs.displayRegexes)
        let stage2 = stripHideTags(stage1, settings: inputs.settings)
        let stage3 = stage2.isEmpty ? " " : stage2
        if markdownEnabled(settings: inputs.settings, preset: inputs.preset) {
            return markdown(stage3)
        } else {
            return plain(stage3)
        }
    }

    /// 「显示用正则」只对助手消息起作用；空 pattern / 非法 pattern / 关闭条目一律跳过。
    private static func applyDisplayRegex(
        to text: String,
        role: ChatMessage.Role,
        preset: Preset?,
        all: [DisplayRegex]
    ) -> String {
        guard role == .assistant else { return text }
        let allowed = preset?.displayRegexIds ?? []
        let byID: [UUID: DisplayRegex] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        // 顺序：先用预设里指定的那批（按预设顺序），再追加「全启用且未指定」的正则作为兜底。
        var ordered: [DisplayRegex] = []
        var seen = Set<UUID>()
        for id in allowed {
            if let r = byID[id], r.enabled, !seen.contains(id) {
                ordered.append(r); seen.insert(id)
            }
        }
        for r in all where r.enabled && !seen.contains(r.id) {
            ordered.append(r); seen.insert(r.id)
        }
        var result = text
        for regex in ordered {
            guard let pattern = try? NSRegularExpression(
                pattern: regex.pattern,
                options: [.dotMatchesLineSeparators]
            ) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: regex.replacement
            )
        }
        return result
    }

    /// 按设置里的隐藏标签列表剥离 `<tag>...</tag>` 及其变体。
    /// 失败（pattern 编译失败 / 文本未变化）时原样返回，绝不抛错。
    private static func stripHideTags(_ text: String, settings: AppSettings) -> String {
        guard settings.hideTagStripEnabled else { return text }
        let tags = settings.hideTags
        guard !tags.isEmpty else { return text }
        var result = text
        for tag in tags {
            let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            // 匹配 <tag>...</tag>、<tag attr="...">...</tag>、</tag>（容错开启）。
            let pattern = "(?is)<\\s*/?\\s*" + NSRegularExpression.escapedPattern(for: cleaned) +
                "\\b[^>]*>.*?<\\s*/?\\s*" + NSRegularExpression.escapedPattern(for: cleaned) + "\\s*\\*>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        return result
    }

    private static func markdownEnabled(settings: AppSettings, preset: Preset?) -> Bool {
        if let preset, !preset.useGlobalMarkdown {
            return preset.enableMarkdown
        }
        return settings.enableMarkdown
    }

    /// Markdown 渲染：先 AttributedString(markdown:) 解析失败时降级为剥离 HTML 后的纯文本。
    private static func markdown(_ text: String) -> AttributedString {
        if var attr = try? AttributedString(markdown: text) {
            // 链接走 openURL；保持与 MarkdownTextView 行为一致。
            attr.environment(\.openURL, OpenURLAction { url in
                UIApplication.shared.open(url)
                return .handled
            })
            return attr
        }
        return plain(stripHTMLTags(text))
    }

    private static func plain(_ text: String) -> AttributedString {
        AttributedString(stripHTMLTags(text))
    }

    /// 兜底：把所有 `<...>` 标签（包括未闭合的）剥掉，避免出现残留 HTML 字符。
    private static func stripHTMLTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
