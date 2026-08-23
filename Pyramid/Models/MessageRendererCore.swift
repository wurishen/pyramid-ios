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
        // 重复 id（导入异常 / 用户复制）不崩溃 —— 保留首个，其余去重。
        let byID: [UUID: DisplayRegex] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

    // MARK: - Prompt-only chain（ST `prompt_only` 字段 → `DisplayRegex.promptOnly`）

    /// prompt 链过滤门：
    /// 1. enabled + promptOnly（仅 outgoing prompt 阶段生效）
    /// 2. replacement 不含 HTML beautify token（防注入远程脚本 / iframe）
    /// 注意：**不**复用 `touchesNativeTranspile` —— promptOnly 规则的典型用途就是
    /// 在 prompt 里剥掉原生 transpile token（`StatusPlaceHolderImpl` / `UpdateVariable`），
    /// 所以这些规则必须进入 prompt 链。
    static func shouldRunOnPrompt(_ r: DisplayRegex) -> Bool {
        guard r.enabled, r.promptOnly else { return false }
        guard !isHtmlBeautify(replacement: r.replacement) else { return false }
        return true
    }

    /// 把 `[DisplayRegex]` 中 promptOnly 部分按预设优先级排序 + 去重 + 过滤。
    static func orderedPromptOnlyRegexes(
        presetDisplayRegexIds: [UUID],
        all: [DisplayRegex]
    ) -> [DisplayRegex] {
        // 重复 id（导入异常 / 用户复制）不崩溃 —— 保留首个，其余去重。
        let byID: [UUID: DisplayRegex] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [DisplayRegex] = []
        var seen = Set<UUID>()
        for id in presetDisplayRegexIds {
            if let r = byID[id], shouldRunOnPrompt(r), !seen.contains(id) {
                ordered.append(r); seen.insert(id)
            }
        }
        for r in all where shouldRunOnPrompt(r) && !seen.contains(r.id) {
            ordered.append(r); seen.insert(r.id)
        }
        return ordered
    }

    /// 在 outgoing prompt 阶段应用 promptOnly 规则（不限角色 —— 助手历史消息与用户
    /// 消息都可能需要被这些规则预处理）。
    static func applyPromptOnly(
        text: String,
        presetDisplayRegexIds: [UUID],
        all: [DisplayRegex]
    ) -> String {
        let ordered = orderedPromptOnlyRegexes(
            presetDisplayRegexIds: presetDisplayRegexIds,
            all: all
        )
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

    // MARK: - Deferred 显示层（P6）

    /// 此前 `shouldRunOnDisplay` 把「pattern 触碰原生 token」或「replacement 含 HTML」的
    /// 规则一律跳过 —— 角色卡 extension 提供的 Placeholder 皮肤因此从未执行，占位符
    /// 永远退化成通用变量树投影。P6 改为：这类规则移入 **deferred 层受控执行**，
    /// 每条替换产物按内容分流：
    ///
    /// ```
    /// Tier A 安全规则（行为不变）
    ///   ↓
    /// Tier B deferred 规则逐条执行
    ///   ↓ 检查替换产物
    /// 纯文本 ──────────────► 拼回文本流（普通 Renderer）
    /// 可识别 Tavern 表达 ───► 拼回文本流 → RenderNodeParser → NativeIR
    /// 其余 HTML/CSS 标记 ───► DeferredResidual 冻结保留（原文绝不丢弃）
    /// ```
    ///
    /// 残留块不进入文本流 —— 同一内容只处理一次，不会被后续规则 / parser 重复消费。

    /// 无法原生转换的 deferred 替换产物。**原文完整保留**；UI 以折叠块展示。
    struct DeferredResidual: Equatable, Sendable {
        /// 规则名（可能为空）。
        var ruleName: String?
        /// 原始 pattern（溯源用）。
        var sourcePattern: String
        /// 替换串中无法转换部分的原文。
        var replacement: String
    }

    /// deferred 层输出的一段。`text` 继续走隐藏标签剥离 + RenderNodeParser；
    /// `residual` 是冻结证据，原样直达 UI。
    enum PreParseSegment: Equatable, Sendable {
        case text(String)
        case residual(DeferredResidual)
    }

    /// deferred 候选门：enabled + 非 promptOnly + （pattern 触碰原生 token 或
    /// replacement 含 HTML token）。enabled=false 仍彻底跳过（用户显式关闭）。
    static func isDeferredCandidate(_ r: DisplayRegex) -> Bool {
        guard r.enabled, !r.promptOnly else { return false }
        return touchesNativeTranspile(pattern: r.pattern) || isHtmlBeautify(replacement: r.replacement)
    }

    /// deferred 层执行序列：与 `orderedRegexes` 同一套预设优先级排序 + 去重，
    /// 仅过滤谓词换成 `isDeferredCandidate`。
    static func orderedDeferredRegexes(
        presetDisplayRegexIds: [UUID],
        all: [DisplayRegex]
    ) -> [DisplayRegex] {
        // 重复 id（导入异常 / 用户复制）不崩溃 —— 保留首个，其余去重。
        let byID: [UUID: DisplayRegex] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [DisplayRegex] = []
        var seen = Set<UUID>()
        for id in presetDisplayRegexIds {
            if let r = byID[id], isDeferredCandidate(r), !seen.contains(id) {
                ordered.append(r); seen.insert(id)
            }
        }
        for r in all where isDeferredCandidate(r) && !seen.contains(r.id) {
            ordered.append(r); seen.insert(r.id)
        }
        return ordered
    }

    /// 替换产物中可被 RenderNodeParser 原生转译的表达（与 parser 支持的块一致：
    /// 占位符 / UpdateVariable canonical + legacy 拼写 / `<status>` 块）。
    static let nativeExpressionPatterns: [String] = [
        "(?is)<StatusPlaceHolderImpl\\s*/?>",
        "(?is)<UpdateVariable\\b[^>]*>[\\s\\S]*?</UpdateVariable>",
        "(?is)<<UpdateVariable[^>]*>>[\\s\\S]*?<</UpdateVariable>>",
        "(?is)<status\\b[^>]*>[\\s\\S]*?</status\\s*>",
        // Pyramid 声明式交互原语：自闭合或空 body 配对（与 RenderNodeParser 命中范围一致；
        // 畸形形态不进白名单 —— 留在片段里按标记冻结为残留，逐字保留）。
        "(?is)" +
            "(<NativeAction|<NativeInput|<NativeSelect)\\b[^>]*>\\s*</(?:NativeAction|NativeInput|NativeSelect)\\s*>" +
            "|<(?:NativeAction|NativeInput|NativeSelect)\\b[^>]*/>",
        // P6 条件原语：配对形态整体进文本流交给 parser 求值；畸形不命中 → 残留保真。
        "(?is)<NativeIf\\b[^>]*>[\\s\\S]*?</NativeIf\\s*>"
    ]

    /// 片段是否含标签式标记（`<tag …>` / `</tag>`）。只在 `splitReplacement`
    /// 剥掉原生表达之后调用 —— 此时命中即代表「剩余内容无法原生转换」。
    /// `<3` 这类表情不算标记（标签必须以字母开头）。
    static func containsTagMarkup(_ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "<\\s*/?\\s*[A-Za-z][^>]*>") else {
            return false
        }
        let ns = s as NSString
        return re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// 片段是否含**完整** `<style…>…</style>` 块（大小写不敏感）。
    /// P12a：这类片段不再冻成残留 —— 送回文本流，由 RenderNodeParser 的
    /// htmlPass（HTMLCSSTranspiler）抽出 stylesheet、升级 htmlStyled，并剥掉
    /// 已消费的 `<style>` 原文节点。未闭合 / 畸形块不命中 → 维持残留冻结，
    /// 原文逐字保留（万界 / 圣樱类卡的正则皮肤由此点亮）。
    static func containsCompleteStyleBlock(_ s: String) -> Bool {
        guard let re = try? NSRegularExpression(
            pattern: "(?is)<style\\b[^>]*>[\\s\\S]*?</style\\s*>"
        ) else { return false }
        let ns = s as NSString
        return re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// 替换产物切片：原生表达片段 vs 其余片段（保序）。
    struct ReplacementPiece: Equatable, Sendable {
        var content: String
        var isNativeExpression: Bool
    }

    /// 把 expanded replacement 切成有序片段。原生表达片段拼回文本流交给 parser；
    /// 其余片段再按是否含标记分流为纯文本 / 残留。
    static func splitReplacement(_ expanded: String) -> [ReplacementPiece] {
        let ns = expanded as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return [] }
        var ranges: [NSRange] = []
        for p in nativeExpressionPatterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            ranges.append(contentsOf: re.matches(in: expanded, options: [], range: full).map(\.range))
        }
        ranges.sort { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }

        var pieces: [ReplacementPiece] = []
        var cursor = 0
        func appendPlain(_ upto: Int) {
            guard upto > cursor else { return }
            pieces.append(ReplacementPiece(
                content: ns.substring(with: NSRange(location: cursor, length: upto - cursor)),
                isNativeExpression: false
            ))
        }
        for r in ranges where r.location >= cursor {
            appendPlain(r.location)
            pieces.append(ReplacementPiece(content: ns.substring(with: r), isNativeExpression: true))
            cursor = r.location + r.length
        }
        appendPlain(ns.length)
        return pieces
    }

    /// 执行 deferred 层：对输入文本按序应用 `orderedDeferredRegexes`，返回有序分段。
    /// 相邻文本段合并、空文本段丢弃；残留块对后续规则不可见（防重复处理）。
    static func applyDeferred(
        text: String,
        presetDisplayRegexIds: [UUID],
        all: [DisplayRegex]
    ) -> [PreParseSegment] {
        var segments: [PreParseSegment] = [.text(text)]
        for rule in orderedDeferredRegexes(presetDisplayRegexIds: presetDisplayRegexIds, all: all) {
            segments = applyDeferredRule(rule, to: segments)
        }
        var merged: [PreParseSegment] = []
        for seg in segments {
            switch seg {
            case .text(let t):
                if t.isEmpty { continue }
                if case .text(let last)? = merged.last {
                    merged[merged.count - 1] = .text(last + t)
                } else {
                    merged.append(.text(t))
                }
            case .residual:
                merged.append(seg)
            }
        }
        return merged
    }

    /// 单条 deferred 规则：只改写 `.text` 段；命中处按 `emitReplacement` 分流，
    /// 未命中段与残留段原样透传。
    private static func applyDeferredRule(
        _ rule: DisplayRegex,
        to segments: [PreParseSegment]
    ) -> [PreParseSegment] {
        guard let compiled = try? NSRegularExpression(
            pattern: rule.pattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            return segments
        }
        var out: [PreParseSegment] = []
        for seg in segments {
            guard case .text(let s) = seg else {
                out.append(seg)
                continue
            }
            let ns = s as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matches = compiled.matches(in: s, options: [], range: full)
            if matches.isEmpty {
                out.append(seg)
                continue
            }
            var cursor = 0
            for m in matches {
                if m.range.location > cursor {
                    out.append(.text(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
                }
                let expanded = compiled.replacementString(
                    for: m, in: s, offset: 0, template: rule.replacement
                )
                emitReplacement(expanded, rule: rule, into: &out)
                cursor = m.range.location + m.range.length
            }
            if cursor < ns.length {
                out.append(.text(ns.substring(from: cursor)))
            }
        }
        return out
    }

    /// 一份 expanded replacement 的分流：原生表达片段 → 文本流（parser 转译）；
    /// 含完整 `<style>` 块的片段 → 文本流（P12a：CSS 管线消费，见
    /// `containsCompleteStyleBlock`）；其余含标记片段 → 残留冻结；再其余 → 普通
    /// 文本。空产物（剥除类替换）不产生节点。
    private static func emitReplacement(
        _ expanded: String,
        rule: DisplayRegex,
        into out: inout [PreParseSegment]
    ) {
        for piece in splitReplacement(expanded) {
            if piece.isNativeExpression {
                out.append(.text(piece.content))
            } else if containsTagMarkup(piece.content) {
                if containsCompleteStyleBlock(piece.content) {
                    // P12a：style + 标记整体进文本流。HTMLTranspiler 对不识别的
                    // 部分逐字降级为纯文本 / residual 节点，原文绝不丢弃。
                    out.append(.text(piece.content))
                } else {
                    out.append(.residual(DeferredResidual(
                        ruleName: rule.name,
                        sourcePattern: rule.pattern,
                        replacement: piece.content
                    )))
                }
            } else {
                out.append(.text(piece.content))
            }
        }
    }
}