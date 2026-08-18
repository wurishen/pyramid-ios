import Foundation

/// `MessageRenderer.applyDisplayRegex` 的纯算法核心，单独抽出来便于在 Linux / SPM 上
/// 直接测试。**没有任何渲染层副作用，不写缓存、不调 SwiftUI / os，也不依赖 Pyramid 模型**。
///
/// `MessageRenderer.applyDisplayRegex` 仍保留原有的 `OSAllocatedUnfairLock` 编译缓存；
/// 它负责把 `Preset.displayRegexIds` 和 `ChatMessage.Role` 折算成下面这两个 primitive，
/// 然后委托到本 helper 完成排序 + 替换。算法行为与 MessageRenderer.swift 中原有实现
/// 完全一致，集中到这里方便被测试独立验证。
///
/// 规则：
/// - 只对 `isAssistant == true` 生效；其他直接原样返回。
/// - `enabled == false` / 编译失败的规则跳过。
/// - 执行顺序：先按 `presetDisplayRegexIds` 指定顺序（命中且 enabled），再追加所有
///   其他 enabled 但未出现过的条目。重复 ID 自动去重。
/// - 模式直接喂给 `NSRegularExpression`，inline flag group（如 `(?i)`）由
///   `SillyTavernFlagMapper` 在导入阶段注入；这里不做 flags 翻译。
enum MessageRendererCore {
    /// 把 `[DisplayRegex]` 按预设优先级排序 + 去重 + 过滤，返回最终执行序列。
    static func orderedRegexes(
        presetDisplayRegexIds: [UUID],
        all: [DisplayRegex]
    ) -> [DisplayRegex] {
        let byID: [UUID: DisplayRegex] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var ordered: [DisplayRegex] = []
        var seen = Set<UUID>()
        for id in presetDisplayRegexIds {
            if let r = byID[id], r.enabled, !seen.contains(id) {
                ordered.append(r); seen.insert(id)
            }
        }
        for r in all where r.enabled && !seen.contains(r.id) {
            ordered.append(r); seen.insert(r.id)
        }
        return ordered
    }

    /// 对一段文本应用「预设过滤后的 DisplayRegex 序列」。非助手消息直接返回原文。
    /// 每条规则用 `NSRegularExpression(pattern: options: [.dotMatchesLineSeparators])`
    /// 替换 —— 与 MessageRenderer.swift 内的 .dotMatchesLineSeparators 一致。
    static func apply(
        text: String,
        isAssistant: Bool,
        presetDisplayRegexIds: [UUID],
        all: [DisplayRegex]
    ) -> String {
        guard isAssistant else { return text }
        let ordered = orderedRegexes(presetDisplayRegexIds: presetDisplayRegexIds, all: all)
        guard !ordered.isEmpty else { return text }
        var result = text
        for regex in ordered {
            guard let compiled = try? NSRegularExpression(
                pattern: regex.pattern,
                options: [.dotMatchesLineSeparators]
            ) else { continue }
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
}