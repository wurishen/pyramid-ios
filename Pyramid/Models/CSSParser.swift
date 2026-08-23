import Foundation

// P11: 角色卡 HTML/CSS → NativeIR 的纯静态 CSS 解析器。
//
// **职责**：把 `<style>...</style>` 块 / 内联 `style="..."` 属性里的 CSS 声明
// 静态归一为 `CSSStyleSheet` / `CSSStyleDeclaration`。可识别通用布局 / 视觉 / 文本
// 声明（颜色 / 背景 / 字体 / padding / margin / 边框 / 圆角 / 阴影 / 透明度 / 宽高 /
// display / flex-direction / justify-content / align-items / transform / transition
// / animation）。动画相关声明经 `AnimationIntentAnalyzer` 二次解析为 `AnimationIR`。
//
// **不**做的事（与 §13 已知限制并列）：
// - 不实现 CSS 选择器 specificity 排序（class / id / tag 同优先级叠加，覆盖策略
//   "后者覆盖前者"）。
// - 不实现 `:hover` / `:focus` / `:active` / `@media` / CSS variables (`var(--x)`) /
//   `calc()` / `min()` / `max()` / `clamp()`。
// - 不发起任何网络请求（不下载 `<link rel="stylesheet">`）。
// - 不引入 JavaScript / WebView —— `<style>` 只被**读取**为 CSS 文本。
// - 不修改 raw HTML：解析失败 / 不识别的声明保留在原始 `<style>` residual 块里。
//
// **硬边界（与 HTMLTranspiler / AnimationIntentAnalyzer 共享）**：
// - 纯 Foundation，不依赖 SwiftUI / UIKit。
// - 失败路径走 fallback —— 整体 CSS 解析失败时整段 `<style>` 仍以 `.scriptPlaceholder`
//   进入 Native IR（原始 HTML 完整保留）。

/// 一条 CSS 声明（property + value）。用枚举承载未知值（`other`）—— 不识别但解析成功的
/// 字面量原样保留，**绝不**静默丢弃。renderer 与未来 CSS engine 可识别新 case 时无需
/// 改 parser。
struct CSSDeclaration: Equatable, Sendable, Hashable {
    var property: String      // 原始属性名（小写）
    var value: String         // 原始值（去前后空白，保留大小写）
    /// 派生值：可识别属性解析后的强类型表示；未识别 → nil。
    var resolved: CSSResolvedValue?

    static func unparsed(_ property: String, _ value: String) -> CSSDeclaration {
        CSSDeclaration(property: property, value: value, resolved: nil)
    }
}

/// 一组 CSS 声明（一个 selector 的规则体 或 一个 inline style）。
struct CSSStyleDeclaration: Equatable, Sendable, Hashable {
    var declarations: [CSSDeclaration]

    var isEmpty: Bool { declarations.isEmpty }

    /// 把多份声明合并：后者覆盖前者（CSS "last wins" 语义）。同名 `property` 取最后
    /// 一条 `CSSDeclaration`。
    static func merge(_ lhs: CSSStyleDeclaration, _ rhs: CSSStyleDeclaration) -> CSSStyleDeclaration {
        var map: [String: CSSDeclaration] = [:]
        for d in lhs.declarations { map[d.property] = d }
        for d in rhs.declarations { map[d.property] = d }
        return CSSStyleDeclaration(declarations: Array(map.values))
    }

    /// 按声明出现顺序取出 `property == name` 的值（用于未走 `resolved` 的快速查询）。
    func value(forProperty name: String) -> String? {
        declarations.first(where: { $0.property == name })?.value
    }
}

/// 一条 CSS 规则：selector + 声明块。
struct CSSRule: Equatable, Sendable, Hashable {
    /// 选择器原文（已 trim / 已 lowercase）。可能是 `tag` / `.class` / `tag.class` /
    /// `tag .class`（descendant）/ `#id`。**不**支持 `:hover` / `>` / `+` / `*`。
    var selector: String
    var declarations: CSSStyleDeclaration
}

/// 一个完整的 CSS stylesheet：有序规则列表 + @keyframes 命名块。
struct CSSStyleSheet: Equatable, Sendable, Hashable {
    var rules: [CSSRule]
    /// `@keyframes <name> { ... }` 块 —— 名字 → 该 keyframe 的有序关键帧序列。
    /// 序列化 / 渲染交由 `AnimationIntentAnalyzer`；本结构只做"识别 + 保真"。
    var keyframes: [String: [CSSKeyframe]]

    static let empty = CSSStyleSheet(rules: [], keyframes: [:])
}

/// `@keyframes` 内部的一条关键帧：百分比（0-100）+ 该点的声明。
struct CSSKeyframe: Equatable, Sendable, Hashable {
    var percent: Double       // 0 / 25 / 50 / 75 / 100
    var declarations: CSSStyleDeclaration
}

// MARK: - 已解析的强类型 CSS 值

/// 已知 CSS 属性的强类型表示。未识别 / 解析失败的属性 → `.other(property:value)`，
/// 原始字面量完整保留供 fallback / 调试。
indirect enum CSSResolvedValue: Equatable, Sendable, Hashable {
    case color(String)                       // #rrggbb / #rgb / rgb(...) / rgba(...) / named
    case backgroundColor(String)             // 同 color 解析
    case backgroundGradient([CSSGradientStop])
    case fontSize(Double, CSSLengthUnit)    // 16, .px / .pt / .em / .rem
    case fontWeight(CSSFontWeight)
    case textAlign(CSSTextAlign)
    case padding(CSSEdgeInsets)
    case margin(CSSEdgeInsets)
    case cornerRadius(Double, CSSLengthUnit)
    case borderWidth(Double, CSSLengthUnit)
    case borderColor(String)
    case shadow([CSSShadow])
    case opacity(Double)
    case width(Double, CSSLengthUnit)
    case height(Double, CSSLengthUnit)
    case display(CSSDisplay)
    case flexDirection(CSSFlexDirection)
    case justifyContent(CSSJustify)
    case alignItems(CSSAlign)
    case overflow(CSSOverflow)
    case gap(Double, CSSLengthUnit)
    /// 简单 transform 列表（按出现顺序链式应用；旋转 / 位移 / 缩放）。renderer 直接映射
    /// 到 SwiftUI `.rotationEffect` / `.offset` / `.scaleEffect`。
    case transform([CSSTransformComponent])
    /// 短手 transition：单 prop + duration / delay / curve。
    case transition(CSSShortTransition?)
    /// 短手 animation：name + duration / delay / curve / iterationCount。
    case animation(CSSShortAnimation?)
    /// 不识别但保留原文 —— 解析没失败的属性（用于未来扩展 / 调试）。
    case other(property: String, value: String)
}

enum CSSLengthUnit: String, Equatable, Sendable, Hashable {
    case px, pt, em, rem, percent, none
}

enum CSSFontWeight: String, Equatable, Sendable, Hashable {
    case ultraLight = "100"
    case thin = "200"
    case light = "300"
    case regular = "400"
    case medium = "500"
    case semibold = "600"
    case bold = "700"
    case heavy = "800"
    case black = "900"
    static let keywordMap: [String: CSSFontWeight] = [
        "normal": .regular, "bold": .bold, "bolder": .bold, "lighter": .light
    ]
}

enum CSSTextAlign: String, Equatable, Sendable, Hashable {
    case left, right, center, justify
}

enum CSSDisplay: String, Equatable, Sendable, Hashable {
    case flex, block, inline, `inlineBlock` = "inline-block", grid, none
}

enum CSSFlexDirection: String, Equatable, Sendable, Hashable {
    case row, column, rowReverse = "row-reverse", columnReverse = "column-reverse"
}

enum CSSJustify: String, Equatable, Sendable, Hashable {
    case flexStart = "flex-start", flexEnd = "flex-end", center, spaceBetween = "space-between"
    case spaceAround = "space-around", spaceEvenly = "space-evenly"
}

enum CSSAlign: String, Equatable, Sendable, Hashable {
    case flexStart = "flex-start", flexEnd = "flex-end", center, stretch, baseline
}

enum CSSOverflow: String, Equatable, Sendable, Hashable {
    case visible, hidden, scroll, auto
}

/// CSS 简写 padding / margin —— 四边独立值，nil 表示该边未指定（与 SwiftUI 一致）。
struct CSSEdgeInsets: Equatable, Sendable, Hashable {
    var top: Double?
    var leading: Double?
    var bottom: Double?
    var trailing: Double?
    var unit: CSSLengthUnit

    static func all(_ value: Double, _ unit: CSSLengthUnit) -> CSSEdgeInsets {
        CSSEdgeInsets(top: value, leading: value, bottom: value, trailing: value, unit: unit)
    }
}

/// 渐变停靠点（`linear-gradient(0deg, #fff 0%, #000 100%)`）。支持单 / 双停 / 多停。
struct CSSGradientStop: Equatable, Sendable, Hashable {
    var color: String         // 原文色值；不强制解析为 UIColor —— SwiftUI Color 可接受 hex / rgb 字面
    var percent: Double?      // 0-100；nil = auto
}

/// 单条 `box-shadow: 2px 2px 4px #000`。
struct CSSShadow: Equatable, Sendable, Hashable {
    var offsetX: Double
    var offsetY: Double
    var blur: Double
    var color: String
}

/// transform 单一组件（按出现顺序排列）。
enum CSSTransformComponent: Equatable, Sendable, Hashable {
    case translateX(Double)
    case translateY(Double)
    case scale(Double)
    case scaleX(Double)
    case scaleY(Double)
    case rotate(Double)       // 度数
}

/// transition 短手：`<prop> <duration> [easing] [delay]`。
struct CSSShortTransition: Equatable, Sendable, Hashable {
    var property: String
    var durationMs: Int
    var delayMs: Int
    var curveRaw: String      // 原始 easing 字符串（renderer 转 SwiftUI Animation）
}

/// animation 短手：`<name> <duration> [easing] [delay] [iteration-count]`。
struct CSSShortAnimation: Equatable, Sendable, Hashable {
    var name: String
    var durationMs: Int
    var delayMs: Int
    var curveRaw: String
    var iterationCount: Int   // 1 = 一次性；-1 = 无限（用负数表达"无限"，与 CSS 一致）
}

// MARK: - 主入口

/// CSS 文本解析器 —— 静态入口。
enum CSSParser {

    /// 解析一段完整的 CSS 文本（含 `<style>` 标签内部 或 独立 CSS 字符串）。
    ///
    /// 返回非 nil = 解析成功（即便 rules / keyframes 都为空，例如空 stylesheet）。
    /// 返回 nil = 解析失败（**绝不**静默丢数据：调用方应保留 raw CSS 进 residual）。
    static func parseSheet(_ css: String) -> CSSStyleSheet? {
        let trimmed = css.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return CSSStyleSheet.empty }

        var rules: [CSSRule] = []
        var keyframes: [String: [CSSKeyframe]] = [:]

        // 状态机：顶层 = 一段顶层花括号块（rule 或 @keyframes）；顶层外文本一律忽略。
        var i = css.startIndex
        let end = css.endIndex
        while i < end {
            // 跳过空白
            while i < end, css[i].isWhitespace { i = css.index(after: i) }
            if i >= end { break }

            if css[i] == "@" {
                // @ 块（@keyframes / @media / @import ...）。只识别 @keyframes。
                guard let atEnd = findAtBlockEnd(css, from: i) else { return nil }
                let block = String(css[i..<atEnd])
                if let parsed = parseAtKeyframesBlock(block) {
                    keyframes[parsed.name] = parsed.frames
                }
                // 其它 @ 块（@media / @import / @font-face）一律吞掉，不失败。
                i = atEnd
            } else if css[i] == "}" {
                // 孤立 `}` —— 容错，跳过。
                i = css.index(after: i)
            } else {
                // 一条 rule：selector { declarations }
                guard let ruleEnd = findRuleEnd(css, from: i) else { return nil }
                let ruleText = String(css[i..<ruleEnd])
                if let rule = parseRule(ruleText) {
                    rules.append(rule)
                }
                i = ruleEnd
            }
        }

        return CSSStyleSheet(rules: rules, keyframes: keyframes)
    }

    /// 解析 `style="..."` 内联属性 —— 只有一个 declarations 块、无 selector。
    static func parseInlineStyle(_ style: String) -> CSSStyleDeclaration? {
        let trimmed = style.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return CSSStyleDeclaration(declarations: []) }
        let decls = splitDeclarations(trimmed)
        var out: [CSSDeclaration] = []
        for raw in decls {
            if let d = parseDeclaration(raw) {
                out.append(d)
            } else {
                // 任何声明解析失败 → 整段 inline style 解析失败（保守策略）。
                return nil
            }
        }
        return CSSStyleDeclaration(declarations: out)
    }

    // MARK: - 内部：tokenization

    /// 把 declarations 拆成 `prop: value` 对（按 `;` 切分，保留空 token 过滤）。
    fileprivate static func splitDeclarations(_ text: String) -> [String] {
        return text.split(separator: ";", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    fileprivate static func parseDeclaration(_ raw: String) -> CSSDeclaration? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let property = String(raw[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if property.isEmpty || value.isEmpty { return nil }
        let resolved = resolve(property: property, value: value)
        return CSSDeclaration(property: property, value: value, resolved: resolved)
    }

    /// 强类型化单条声明。**永远**返回非 nil —— 不识别属性降级 `.other(property:value)`。
    fileprivate static func resolve(property: String, value: String) -> CSSResolvedValue {
        switch property {
        case "color":
            return .color(value)
        case "background", "background-color":
            if let grad = parseGradient(value) { return .backgroundGradient(grad) }
            return .backgroundColor(value)
        case "font-size":
            if let (n, unit) = parseLength(value) { return .fontSize(n, unit) }
            return .other(property: property, value: value)
        case "font-weight":
            let lc = value.lowercased()
            if let w = CSSFontWeight.keywordMap[lc] { return .fontWeight(w) }
            if let w = CSSFontWeight(rawValue: lc) { return .fontWeight(w) }
            return .other(property: property, value: value)
        case "text-align":
            if let a = CSSTextAlign(rawValue: value.lowercased()) { return .textAlign(a) }
            return .other(property: property, value: value)
        case "padding":
            if let ins = parseEdgeInsets(value) { return .padding(ins) }
            return .other(property: property, value: value)
        case "margin":
            if let ins = parseEdgeInsets(value) { return .margin(ins) }
            return .other(property: property, value: value)
        case "border-radius":
            if let (n, u) = parseLength(value) { return .cornerRadius(n, u) }
            return .other(property: property, value: value)
        case "border", "border-width":
            // 简写 `border: 1px solid #000` —— 拆出来只取第一个长度作为宽度。
            if let (n, u) = parseFirstLength(value) { return .borderWidth(n, u) }
            return .other(property: property, value: value)
        case "border-color":
            return .borderColor(value)
        case "box-shadow":
            if let shadows = parseShadowList(value) { return .shadow(shadows) }
            return .other(property: property, value: value)
        case "opacity":
            if let d = Double(value) { return .opacity(max(0, min(1, d))) }
            return .other(property: property, value: value)
        case "width":
            if let (n, u) = parseLength(value) { return .width(n, u) }
            return .other(property: property, value: value)
        case "height":
            if let (n, u) = parseLength(value) { return .height(n, u) }
            return .other(property: property, value: value)
        case "display":
            if let d = CSSDisplay(rawValue: value.lowercased()) { return .display(d) }
            return .other(property: property, value: value)
        case "flex-direction":
            if let d = CSSFlexDirection(rawValue: value.lowercased()) { return .flexDirection(d) }
            return .other(property: property, value: value)
        case "justify-content":
            if let j = CSSJustify(rawValue: value.lowercased()) { return .justifyContent(j) }
            return .other(property: property, value: value)
        case "align-items":
            if let a = CSSAlign(rawValue: value.lowercased()) { return .alignItems(a) }
            return .other(property: property, value: value)
        case "overflow":
            if let o = CSSOverflow(rawValue: value.lowercased()) { return .overflow(o) }
            return .other(property: property, value: value)
        case "gap":
            if let (n, u) = parseLength(value) { return .gap(n, u) }
            return .other(property: property, value: value)
        case "transform":
            if let comps = parseTransform(value) { return .transform(comps) }
            return .other(property: property, value: value)
        case "transition":
            if let t = parseShortTransition(value) { return .transition(t) }
            return .other(property: property, value: value)
        case "animation":
            if let a = parseShortAnimation(value) { return .animation(a) }
            return .other(property: property, value: value)
        default:
            return .other(property: property, value: value)
        }
    }

    // MARK: - 内部：length / color / shadow / transform 解析

    /// 解析 `16px` / `1.5em` / `.5rem` / `50%` —— `(数值, 单位)`。纯数字默认 px。
    fileprivate static func parseLength(_ s: String) -> (Double, CSSLengthUnit)? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        // 数字 + 单位 / 数字裸
        var digits = ""
        var rest = ""
        var seenDot = false
        for ch in t {
            if ch.isNumber || (ch == "." && !seenDot) {
                if ch == "." { seenDot = true }
                digits.append(ch)
            } else if !digits.isEmpty {
                rest.append(ch)
            }
        }
        if digits.isEmpty { return nil }
        guard let n = Double(digits) else { return nil }
        let unitStr = rest.trimmingCharacters(in: .whitespaces)
        let unit: CSSLengthUnit
        switch unitStr {
        case "", "px": unit = .px
        case "pt": unit = .pt
        case "em": unit = .em
        case "rem": unit = .rem
        case "%": unit = .percent
        default: unit = .none
        }
        return (n, unit)
    }

    /// `border: 1px solid #000` → 取第一个 length。
    fileprivate static func parseFirstLength(_ s: String) -> (Double, CSSLengthUnit)? {
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        for part in parts {
            if let r = parseLength(String(part)) { return r }
        }
        return nil
    }

    /// 拆 padding / margin 的四边值（1 / 2 / 3 / 4 个值，遵循 CSS shorthand）。
    fileprivate static func parseEdgeInsets(_ s: String) -> CSSEdgeInsets? {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if parts.isEmpty { return nil }
        let parsed: [(Double, CSSLengthUnit)?] = parts.map { parseLength($0) }
        if parsed.contains(where: { $0 == nil }) { return nil }
        let units = parsed.map { $0!.1 }
        let values = parsed.map { $0!.0 }
        // 单位以第一个为准（同 CSS —— 实际工程里单位混用少见）。
        let unit = units.first ?? .px
        switch values.count {
        case 1:
            return CSSEdgeInsets(top: values[0], leading: values[0], bottom: values[0], trailing: values[0], unit: unit)
        case 2:
            // vertical / horizontal
            return CSSEdgeInsets(top: values[0], leading: values[1], bottom: values[0], trailing: values[1], unit: unit)
        case 3:
            // top / horizontal / bottom
            return CSSEdgeInsets(top: values[0], leading: values[1], bottom: values[2], trailing: values[1], unit: unit)
        case 4:
            return CSSEdgeInsets(top: values[0], leading: values[3], bottom: values[2], trailing: values[1], unit: unit)
        default:
            return nil
        }
    }

    /// 渐变：`linear-gradient(90deg, #fff, #000)` / `linear-gradient(0deg, #fff 0%, #000 100%)`。
    /// 不识别 → nil（保留原文作 .backgroundColor 退化）。
    fileprivate static func parseGradient(_ s: String) -> [CSSGradientStop]? {
        let lower = s.lowercased()
        guard lower.hasPrefix("linear-gradient(") || lower.hasPrefix("radial-gradient(") else {
            return nil
        }
        guard let lp = s.firstIndex(of: "("),
              let rp = s.lastIndex(of: ")"),
              lp < rp else { return nil }
        let body = String(s[s.index(after: lp)..<rp])
        // 用 comma 切，但要小心 rgba(...) 内也有逗号 —— 简单策略：递归括号。
        let parts = splitTopLevelCommas(body)
        guard !parts.isEmpty else { return nil }
        var stops: [CSSGradientStop] = []
        var firstIsAngle = false
        for (idx, part) in parts.enumerated() {
            let t = part.trimmingCharacters(in: .whitespaces)
            if idx == 0, t.hasSuffix("deg") {
                firstIsAngle = true
                continue
            }
            // 颜色 + 可选百分比：`<color> [<percent>%]`
            let toks = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let color = toks.first else { return nil }
            var percent: Double? = nil
            if toks.count >= 2 {
                let pStr = toks[1].replacingOccurrences(of: "%", with: "")
                if let p = Double(pStr) { percent = p }
            }
            stops.append(CSSGradientStop(color: color, percent: percent))
        }
        if stops.isEmpty { return nil }
        _ = firstIsAngle  // 暂不消费；renderer 默认按 stops 序列
        return stops
    }

    /// 顶层按逗号拆分（不进入 `()` 嵌套）。
    fileprivate static func splitTopLevelCommas(_ s: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var start = s.startIndex
        for i in s.indices {
            let ch = s[i]
            if ch == "(" { depth += 1 }
            else if ch == ")" { depth -= 1 }
            else if ch == "," && depth == 0 {
                out.append(String(s[start..<i]))
                start = s.index(after: i)
            }
        }
        if start < s.endIndex { out.append(String(s[start...])) }
        return out
    }

    /// `box-shadow: 2px 2px 4px #000` / 多条阴影按逗号分隔。
    fileprivate static func parseShadowList(_ s: String) -> [CSSShadow]? {
        let parts = splitTopLevelCommas(s)
        var out: [CSSShadow] = []
        for part in parts {
            let toks = part.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard toks.count >= 2 else { return nil }
            // 收集前几个长度作为 offsetX / offsetY / blur（其余当颜色）。
            var lengths: [Double] = []
            var colorStart = toks.count
            for (idx, t) in toks.enumerated() {
                if let (n, _) = parseLength(t) {
                    lengths.append(n)
                } else {
                    colorStart = idx
                    break
                }
            }
            guard lengths.count >= 2 else { return nil }
            let ox = lengths[0]
            let oy = lengths[1]
            let blur = lengths.count >= 3 ? lengths[2] : 0
            let color = toks[colorStart...].joined(separator: " ")
            if color.isEmpty { return nil }
            out.append(CSSShadow(offsetX: ox, offsetY: oy, blur: blur, color: color))
        }
        return out.isEmpty ? nil : out
    }

    /// `transform: translateX(20px) rotate(45deg) scale(1.2)` —— 多函数链式。
    fileprivate static func parseTransform(_ s: String) -> [CSSTransformComponent]? {
        var comps: [CSSTransformComponent] = []
        // 按空格切函数（容忍 `transform: translateX(20px) rotate(45deg)`）。
        var idx = s.startIndex
        while idx < s.endIndex {
            // 跳过空白
            while idx < s.endIndex, s[idx].isWhitespace { idx = s.index(after: idx) }
            if idx >= s.endIndex { break }
            // 找下一个 `(` 与匹配的 `)`。
            guard let lp = s[idx...].firstIndex(of: "(") else { break }
            // 函数名
            let fnName = String(s[idx..<lp]).trimmingCharacters(in: .whitespaces).lowercased()
            guard let rp = s[lp...].firstIndex(of: ")") else { return nil }
            let body = String(s[s.index(after: lp)..<rp])
            idx = s.index(after: rp)
            guard let comp = parseTransformFn(fnName, body: body) else { return nil }
            comps.append(comp)
        }
        return comps.isEmpty ? nil : comps
    }

    fileprivate static func parseTransformFn(_ fn: String, body: String) -> CSSTransformComponent? {
        let t = body.trimmingCharacters(in: .whitespaces)
        switch fn {
        case "translatex":
            guard let (n, _) = parseLength(t) else { return nil }
            return .translateX(n)
        case "translatey":
            guard let (n, _) = parseLength(t) else { return nil }
            return .translateY(n)
        case "scale":
            guard let n = Double(t) else { return nil }
            return .scale(n)
        case "scalex":
            guard let n = Double(t) else { return nil }
            return .scaleX(n)
        case "scaley":
            guard let n = Double(t) else { return nil }
            return .scaleY(n)
        case "rotate":
            // 接受 `45deg` / `0.5turn` / 裸数字（默认 deg）。
            let lower = t.lowercased()
            if lower.hasSuffix("deg") {
                guard let n = Double(lower.dropLast(3)) else { return nil }
                return .rotate(n)
            }
            if lower.hasSuffix("turn") {
                guard let n = Double(lower.dropLast(4)) else { return nil }
                return .rotate(n * 360)
            }
            if let n = Double(t) { return .rotate(n) }
            return nil
        default:
            return nil
        }
    }

    /// `transition: opacity 0.3s ease-in 0.1s` → 单条短手。
    fileprivate static func parseShortTransition(_ s: String) -> CSSShortTransition? {
        let toks = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard toks.count >= 2 else { return nil }
        let prop = toks[0].lowercased()
        // 第二个 token 必须是时间
        guard let (d, _) = parseLength(toks[1]), toks[1].lowercased().hasSuffix("s") else { return nil }
        let durationMs = Int(d * 1000)
        var delayMs = 0
        var curveRaw = "ease"
        // 其余 token：可能是 `ease-in` / `0.1s` / `cubic-bezier(...)` 顺序任意。
        var i = 2
        var pendingCurve: String? = nil
        while i < toks.count {
            let t = toks[i].lowercased()
            if t.hasSuffix("s") {
                if let (dd, _) = parseLength(t) {
                    if delayMs == 0 { delayMs = Int(dd * 1000) }
                }
            } else if pendingCurve == nil {
                pendingCurve = t
            }
            i += 1
        }
        if let c = pendingCurve { curveRaw = c }
        return CSSShortTransition(property: prop, durationMs: durationMs, delayMs: delayMs, curveRaw: curveRaw)
    }

    /// `animation: fadeIn 0.3s ease-in 0.1s 3` → 短手。
    fileprivate static func parseShortAnimation(_ s: String) -> CSSShortAnimation? {
        let toks = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard toks.count >= 2 else { return nil }
        let name = toks[0]
        guard let (d, _) = parseLength(toks[1]), toks[1].lowercased().hasSuffix("s") else { return nil }
        let durationMs = Int(d * 1000)
        var delayMs = 0
        var curveRaw = "ease"
        var iterationCount = 1
        var i = 2
        while i < toks.count {
            let t = toks[i].lowercased()
            if t.hasSuffix("s") {
                if let (dd, _) = parseLength(t) { delayMs = Int(dd * 1000) }
            } else if t == "infinite" {
                iterationCount = -1
            } else if let n = Int(t) {
                iterationCount = n
            } else if !t.isEmpty {
                curveRaw = t
            }
            i += 1
        }
        return CSSShortAnimation(name: name, durationMs: durationMs, delayMs: delayMs, curveRaw: curveRaw, iterationCount: iterationCount)
    }

    // MARK: - 内部：rule / @keyframes 顶层解析

    /// 找下一条顶层 rule 的结束位置（匹配外层 `}` 后一位）。
    fileprivate static func findRuleEnd(_ s: String, from: String.Index) -> String.Index? {
        var depth = 0
        var i = from
        while i < s.endIndex {
            let ch = s[i]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return s.index(after: i) }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// 找 @ 块的结束位置（与 rule 同一规则 —— 顶层第一个 `}` 后一位）。
    fileprivate static func findAtBlockEnd(_ s: String, from: String.Index) -> String.Index? {
        return findRuleEnd(s, from: from)
    }

    fileprivate static func parseRule(_ text: String) -> CSSRule? {
        guard let lb = text.firstIndex(of: "{"),
              let rb = text.lastIndex(of: "}") else { return nil }
        let selector = String(text[..<lb]).trimmingCharacters(in: .whitespaces).lowercased()
        let body = String(text[text.index(after: lb)..<rb])
        if selector.isEmpty { return nil }
        let decls = splitDeclarations(body).compactMap(parseDeclaration)
        return CSSRule(selector: selector, declarations: CSSStyleDeclaration(declarations: decls))
    }

    /// `@keyframes <name> { 0% { ... } 100% { ... } }` → name + 关键帧列表。
    fileprivate static func parseAtKeyframesBlock(_ block: String) -> (name: String, frames: [CSSKeyframe])? {
        guard let lb = block.firstIndex(of: "{") else { return nil }
        let header = String(block[..<lb]).trimmingCharacters(in: .whitespaces).lowercased()
        guard header.hasPrefix("@keyframes ") else { return nil }
        let name = String(header.dropFirst("@keyframes ".count)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        // 关键帧块体：从第一个 `{` 后到匹配的最后一个 `}`
        guard let rb = block.lastIndex(of: "}") else { return nil }
        let body = String(block[block.index(after: lb)..<rb])
        // 按顶层 `}` 切分（避免 nested 误切；关键帧里没有嵌套）。
        var frames: [CSSKeyframe] = []
        var i = body.startIndex
        while i < body.endIndex {
            // 跳过空白
            while i < body.endIndex, body[i].isWhitespace { i = body.index(after: i) }
            if i >= body.endIndex { break }
            // 找这一帧的 selector（`0%` / `from` / `to` / `50%`）。
            // 直接读到下一个 `{` 之前。
            guard let fb = body[i...].firstIndex(of: "{") else { break }
            let selectorRaw = String(body[i..<fb]).trimmingCharacters(in: .whitespaces).lowercased()
            // 找匹配的 `}` —— 简单：单层，关键帧没有嵌套。
            guard let fe = body[fb...].firstIndex(of: "}") else { break }
            let inner = String(body[body.index(after: fb)..<fe])
            i = body.index(after: fe)
            let decls = splitDeclarations(inner).compactMap(parseDeclaration)
            let percent = keyframePercent(from: selectorRaw)
            // 同一百分比允许多次出现 —— 后者覆盖前者（CSS 语义）。
            frames.removeAll(where: { $0.percent == percent })
            frames.append(CSSKeyframe(percent: percent,
                                      declarations: CSSStyleDeclaration(declarations: decls)))
        }
        frames.sort { $0.percent < $1.percent }
        return (name, frames)
    }

    /// `0%` / `from` / `to` / `50%` → 0 / 0 / 100 / 50。
    fileprivate static func keyframePercent(from raw: String) -> Double {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t == "from" { return 0 }
        if t == "to" { return 100 }
        if t.hasSuffix("%") {
            return Double(t.dropLast()) ?? 0
        }
        return Double(t) ?? 0
    }
}
