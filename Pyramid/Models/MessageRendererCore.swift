import Foundation

/// 渲染管线的纯算法核心（显示用正则排序 + 替换），单独抽出来便于在 Linux / SPM 上
/// 直接测试。**没有任何渲染层副作用，不写缓存、不调 SwiftUI / os，也不依赖 Pyramid 模型**。
///
/// `RenderEngine`（iOS 端）持有原 `OSAllocatedUnfairLock` 编译缓存，负责把
/// `Preset.displayRegexIds` 和 `ChatMessage.Role` 折算成下面这两个 primitive，
/// 然后委托到本 helper 完成排序 + 替换。算法集中到这里方便被测试独立验证。
///
/// 规则：
/// - 只对 `isAssistant == true` 生效；其他直接原样返回。
/// - `enabled == false` / 编译失败的规则跳过。
/// - 执行顺序：先按 `presetDisplayRegexIds` 指定顺序（命中且 enabled），再追加所有
///   其他 enabled 但未出现过的条目。重复 ID 自动去重。
/// - 模式直接喂给 `NSRegularExpression`，inline flag group（如 `(?i)`）由
///   `SillyTavernFlagMapper` 在导入阶段注入；这里不做 flags 翻译。
enum MessageRendererCore {
    /// P3 native transpile：replacement 含以下任意 token → 不在 iOS 显示链执行。
    /// 与 fixture `ios_display_skip_rule.skip_when_replacement_contains_any_of` 对齐：
    /// 远程脚本 / `.load(` / `<object` / `<iframe` / `<details` / `<style` / `<div` 一律跳过。
    /// 同时 `promptOnly == true` 的规则（酒馆 `prompt_only` 字段）也不走显示链 —— 它
    /// 只在 outgoing prompt 阶段剥离（参见 ChatViewModel）。
    static let htmlBeautifyTokens: [String] = [
        "<script", ".load(", "<object", "<iframe", "<details", "<style", "<div"
    ]

    /// 给一条 replacement 字符串判定是否触发跳过规则。
    static func isHtmlBeautify(replacement: String) -> Bool {
        htmlBeautifyTokens.contains { replacement.contains($0) }
    }

    /// 真机 bug 兜底：pattern 命中 Pyramid 原生 transpile token 的规则一律不进显示链。
    ///
    /// 背景：酒馆的 `promptOnly` 字段（ST `prompt_only`）在 Pyramid 路径上被解析为
    /// `DisplayRegex.promptOnly`。`SillyTavernScriptImporter.convert` 已经在导入时
    /// 把 `promptOnly=true` 的脚本过滤掉。但**旧版本导入的存量 DisplayRegex**（UserDefaults
    /// 里的 JSON 没有 `promptOnly` 字段，`decodeIfPresent ?? false` 兜底为 false）
    /// 会绕过这一关，直接命中显示链、把 `<StatusPlaceHolderImpl/>` 替换成空串，
    /// 导致开场白卡片只剩 `.text("")` 整张空白。
    ///
    /// 兜底策略：只要规则的 pattern 命中以下任意原生 token，都视为「该规则只想用于 prompt 构造」
    /// —— 绝不让它在显示链执行。这样不管 `promptOnly` 字段有没有，规则都不会吃占位符。
    ///
    /// 命中判定用 NSRegularExpression 在 pattern 上做子串搜索（不要求 pattern 整体编译，
    /// 失败也按命中算 —— pattern 失败本就该被过滤）。
    static let nativeTranspileAnchors: [String] = [
        "StatusPlaceHolderImpl",
        "UpdateVariable"
    ]

    /// 给一条 pattern 字符串判定是否触碰原生 transpile token（用于显示链兜底过滤）。
    static func touchesNativeTranspile(pattern: String) -> Bool {
        for anchor in nativeTranspileAnchors {
            // 不试图编译 pattern（pattern 可能是合法的也可能是无效的 —— 任何情况下
            // 触碰 anchor 的规则都该被显示链拒掉）。
            guard let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: anchor)) else {
                continue
            }
            let range = NSRange(pattern.startIndex..., in: pattern)
            if regex.firstMatch(in: pattern, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    /// 把 `[DisplayRegex]` 按预设优先级排序 + 去重 + 过滤，返回最终执行序列。
    /// 过滤条件：`enabled` 且非 `promptOnly` 且 `!isHtmlBeautify(replacement)` 且
    /// `!touchesNativeTranspile(pattern)`（兜底防 promptOnly 规则误伤显示链）。
    static func orderedRegexes(
        presetDisplayRegexIds: [UUID],
        all: [DisplayRegex]
    ) -> [DisplayRegex] {
        let byID: [UUID: DisplayRegex] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var ordered: [DisplayRegex] = []
        var seen = Set<UUID>()
        for id in presetDisplayRegexIds {
            if let r = byID[id], shouldRunOnDisplay(r), !seen.contains(id) {
                ordered.append(r); seen.insert(id)
            }
        }
        for r in all where shouldRunOnDisplay(r) && !seen.contains(r.id) {
            ordered.append(r); seen.insert(r.id)
        }
        return ordered
    }

    /// 显示链过滤门：
    /// 1. enabled + !promptOnly（promptOnly 规则只在 API 构造时执行）
    /// 2. replacement 不含 HTML beautify token（防远程 JS / iframe 注入）
    /// 3. pattern 不触碰原生 transpile token（兜底：旧版导入数据缺 promptOnly 字段也安全）
    private static func shouldRunOnDisplay(_ r: DisplayRegex) -> Bool {
        guard r.enabled, !r.promptOnly else { return false }
        guard !isHtmlBeautify(replacement: r.replacement) else { return false }
        guard !touchesNativeTranspile(pattern: r.pattern) else { return false }
        return true
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