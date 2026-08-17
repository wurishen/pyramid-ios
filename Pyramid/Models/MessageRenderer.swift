import Foundation
import SwiftUI
import os

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

    // MARK: - 编译缓存（Item 3）
    //
    // 旧实现每次 render 都会重新 `NSRegularExpression(pattern:)` 编译每条 pattern：
    // 流式时每个 token 触发所有可见气泡全量重新解析，叠加 Markdown 解析是 UI 卡顿主因。
    // 现在编译结果按 (regex.id, pattern) 缓存，仅在 pattern 真变了时重编。
    // 锁是 OSAllocatedUnfairLock（iOS 16+），多线程访问安全；缓存大小被
    // DisplayRegexStore 中的条目数量天然约束，pattern 修改后旧条目会被新 pattern 覆盖。
    private static let compiledRegexCache = OSAllocatedUnfairLock<[UUID: (pattern: String, regex: NSRegularExpression)]>(initialState: [:])
    private static let compiledHideTagCache = OSAllocatedUnfairLock<(tags: [String], regex: NSRegularExpression)?>(initialState: nil)
    private static let compiledHTMLStripRegex = OSAllocatedUnfairLock<NSRegularExpression?>(initialState: nil)

    private static func compiledRegex(for displayRegex: DisplayRegex) -> NSRegularExpression? {
        compiledRegexCache.withLock { cache in
            if let cached = cache[displayRegex.id], cached.pattern == displayRegex.pattern {
                return cached.regex
            }
            guard let compiled = try? NSRegularExpression(
                pattern: displayRegex.pattern,
                options: [.dotMatchesLineSeparators]
            ) else { return nil }
            cache[displayRegex.id] = (displayRegex.pattern, compiled)
            return compiled
        }
    }

    private static func compiledHideTagRegex(tags: [String]) -> NSRegularExpression? {
        // tags 未变 → 直接返回缓存；变了 → 用最新列表重建。
        compiledHideTagCache.withLock { cache in
            if let cached = cache, cached.tags == tags {
                return cached.regex
            }
            let pattern = "(?is)<\\s*/?\\s*(?:" + tags.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") +
                ")\\b[^>]*>.*?<\\s*/?\\s*(?:" + tags.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\s*\\*>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
                cache = nil
                return nil
            }
            cache = (tags, regex)
            return regex
        }
    }

    private static func htmlStripRegex() -> NSRegularExpression? {
        compiledHTMLStripRegex.withLock { cached in
            if let cached { return cached }
            guard let compiled = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return nil }
            cached = compiled
            return compiled
        }
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

    /// 「显示用正则」只对助手消��起作用；空 pattern / 非法 pattern / 关闭条目一律跳过。
    private static func applyDisplayRegex(
        to text: String,
        role: ChatMessage.Role,
        preset: Preset?,
        all: [DisplayRegex]
    ) -> String {
        guard role == .assistant else { return text }
        let allowed = preset?.displayRegexIds ?? []
        let byID: [UUID: DisplayRegex] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        // 顺序：先用预设里指定的那批（按预设顺序���，再追加「全启用且未指定」的正则作为兜底。
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
        guard !ordered.isEmpty else { return text }
        var result = text
        for regex in ordered {
            guard let compiled = compiledRegex(for: regex) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = compiled.stringByReplacingMatches(
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
    /// Item 3: 把 N 个 tag 的多次 NSRegularExpression 编译合并为一次（用 | 串联）。
    private static func stripHideTags(_ text: String, settings: AppSettings) -> String {
        guard settings.hideTagStripEnabled else { return text }
        let cleanedTags = settings.hideTags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedTags.isEmpty else { return text }
        guard let regex = compiledHideTagRegex(tags: cleanedTags) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private static func markdownEnabled(settings: AppSettings, preset: Preset?) -> Bool {
        if let preset = preset, let flag = preset.enableMarkdown {
            return flag
        }
        return settings.enableMarkdown
    }

    /// Markdown 渲染：先 AttributedString(markdown:) 解析失败时降级为剥离 HTML 后的纯文本。
    /// 链接点击走 SwiftUI Text 自身的 OpenURLAction（与 MarkdownTextView 行为一致），
    /// 不在 AttributedString 上挂 environment（AttributedString 不支持 OpenURLAction）。
    private static func markdown(_ text: String) -> AttributedString {
        if let parsed = try? AttributedString(markdown: text) {
            return parsed
        }
        return plain(stripHTMLTags(text))
    }

    private static func plain(_ text: String) -> AttributedString {
        AttributedString(stripHTMLTags(text))
    }

    /// 兜底：把所有 `<...>` 标签（包括未闭合的）剥掉，避免出现残留 HTML 字符。
    private static func stripHTMLTags(_ text: String) -> String {
        guard let regex = htmlStripRegex() else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
