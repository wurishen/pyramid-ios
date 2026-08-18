import Foundation

/// 渲染入口：把「原始消息 + 上下文」加工成独立的 `Result`，与 raw 解耦。
///
/// 关键不变量：
/// - **不修改 raw**：`render` 是纯函数，每次调用基于 raw 重新计算。
/// - **可重复调用**：相同 (raw, context) → 相同 Result（`Result: Equatable`）。
/// - **可独立使用**：`Result` 是值类型，传给 SwiftUI 视图后视图按值相等自动 diff，
///   context 改变 → 新 Result → SwiftUI 自动重绘。raw 始终是消息源文本。
///
/// 流水线：raw → 显示用正则（仅助手） → 隐藏标签剥离 → `Result.cleanedText`。
enum RenderEngine {
    struct Context: Equatable, Sendable {
        let isAssistant: Bool
        let presetDisplayRegexIds: [UUID]
        let allDisplayRegexes: [DisplayRegex]
        let hideTagStripEnabled: Bool
        let hideTags: [String]
        let markdownEnabled: Bool
    }

    struct Result: Equatable, Sendable {
        let cleanedText: String
        let markdownEnabled: Bool
    }

    /// 纯函数：不持有状态，不修改 raw，可重复调用。
    /// 不持有缓存；调用方（视图层）按需复用上一次的 Result。
    static func render(raw: String, context: Context) -> Result {
        let afterRegex = MessageRendererCore.apply(
            text: raw,
            isAssistant: context.isAssistant,
            presetDisplayRegexIds: context.presetDisplayRegexIds,
            all: context.allDisplayRegexes
        )
        let afterHideTags = stripHideTags(
            afterRegex,
            enabled: context.hideTagStripEnabled,
            tags: context.hideTags
        )
        return Result(
            cleanedText: afterHideTags,
            markdownEnabled: context.markdownEnabled
        )
    }

    /// 算法与 `MessageRenderer.stripHideTags` 相同；放这里让 RenderEngine 不依赖 MessageRenderer。
    private static func stripHideTags(_ text: String, enabled: Bool, tags: [String]) -> String {
        guard enabled else { return text }
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return text }
        let pattern = "(?is)<\\s*/?\\s*(?:" + cleaned.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") +
            ")\\b[^>]*>.*?<\\s*/?\\s*(?:" + cleaned.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
