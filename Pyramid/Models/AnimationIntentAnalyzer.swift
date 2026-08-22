import Foundation

// P9 动画意图静态分析器。
//
// **职责**：把酒馆 / 角色卡里 CSS / 内联 style / 内联 script 里**明确可推导**
// 的动画意图静态归一为 AnimationIR；不能确定的 → 返回 `nil`，由调用方降级为
// `htmlScript(residual:)` / `deferredResidual(...)`，原文完整保留。
//
// **不**做的事：
// - 不执行 JavaScript。
// - 不实现 CSS 选择器引擎 / specificity 计算。
// - 不补全 `@keyframes` 序列（只识别关键字命名：`fadeIn` / `fadeOut` /
//
// `scaleIn` / `slideIn`，其它 keyframe 块 → nil）。
// - 不解析 `var(--token)` / CSS 自定义属性。
// - 不实现 cubic-bezier 语法糖（如 `ease-in` → 固定数值是 OK 的；字面 cubic-bezier 数字
//   解析错误 → nil）。
//
// **调用入口**：
// - `parseInlineStyle(_:trigger:)` —— HTMLTranspiler 在解析 `<tag style="...">` 属性时调用。
// - `parseTransition(_:)` / `parseTransform(_:)` —— CSS transition / transform 单独入口。
// - `parseKeyframeName(_:)` —— 关键字命名 keyframe（如 `animation: fadeIn 0.3s`）。
// - `analyzeScriptAnimation(_:)` —— ScriptIntentAnalyzer 扩展用，识别
//   `classList.toggle('cls')` / `style.opacity = 'N'` 等明确写法。

enum AnimationIntentAnalyzer {

    // MARK: - 入口

    /// 把 `style="..."` 属性解析成有序的 AnimationIR 列表。
    /// 多条声明（`opacity: 0; transition: opacity 0.3s`）按出现顺序串联。
    /// - 返回非 nil（即便空）= 「可解析」：返回的列表可能为空（例如 `color: red;`
    ///   不带任何动画意图；保守起见我们认为这种 style 解析成功，无动画可挂）。
    /// - 返回 nil = 「不可解析」：存在未知 / 畸形声明，整段 style 走 htmlScript
    ///   residual 路径，原始表达完整保留 —— 绝不**伪造**一条动画顶替。
    static func parseInlineStyle(_ style: String, trigger: AnimationTrigger = .onAppear) -> [AnimationIR]? {
        let trimmed = style.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let declarations = splitDeclarations(trimmed)
        if declarations.isEmpty { return [] }
        var result: [AnimationIR] = []
        for d in declarations {
            switch parseDeclaration(d, trigger: trigger) {
            case .some(let arr):
                result.append(contentsOf: arr)
            case .none:
                return nil
            case .inert:
                continue // 已识别但本条不产生动画（如 `color: red;`）—— 跳过。
            }
        }
        return result
    }

    /// parseDeclaration 的返回状态：
    /// - .some(irs) —— 本条产生 AnimationIR
    /// - .inert —— 已识别但无动画意图
    /// - .none —— 未识别 / 畸形 → 触发整段失败
    private enum DeclarationResult {
        case some([AnimationIR])
        case inert
        case none
    }

    /// `transition: <prop> <duration>s [easing] [delay]s` 单条。
    /// 不吃 `<prop> all <duration>` 写法（all → nil）。
    static func parseTransition(_ decl: String) -> [AnimationIR]? {
        let tokens = tokenizeTransition(decl)
        guard tokens.count >= 2 else { return nil }
        let propToken = tokens[0]
        guard let prop = animationProperty(fromTransitionToken: propToken) else { return nil }

        // 找出第一个时间 token → duration；第二个时间 token → delay。
        var durationMs: Int? = nil
        var delayMs: Int? = nil
        var curve: AnimationTimingCurve = .easeInOut

        for tok in tokens.dropFirst() {
            if let ms = parseMilliseconds(tok) {
                if durationMs == nil { durationMs = ms }
                else if delayMs == nil { delayMs = ms }
                else { return nil } // 多余时间 token 太多 → 拒绝
            } else if let c = parseEasingKeyword(tok) {
                curve = c
            } else if let c = parseCubicBezier(tok) {
                curve = c
            } else {
                return nil // 未知 token → 整条拒绝
            }
        }
        guard let dur = durationMs else { return nil }
        // transition 隐含语义：A → B（默认 0 → 1，renderer 看到 from=0 to=1
        // 仍可表达"入场"动画；如需更精确，可由调用方在 hook 层覆盖）。
        return [AnimationIR(
            property: prop,
            from: defaultFrom(for: prop),
            to: defaultTo(for: prop),
            durationMs: dur,
            delayMs: delayMs ?? 0,
            curve: curve,
            trigger: .onAppear
        )]
    }

    /// `transform: <func>(<arg>)` 单条。多个函数复合（如 `scale(.8) translateX(20px)`）
    /// → 每条单独 AnimationIR，顺序叠加。
    static func parseTransform(_ decl: String) -> [AnimationIR]? {
        // 去掉 'transform' 前缀（如果有） —— 调用方在 parseDeclaration 里已经剥过。
        let body = stripKeyword(decl, "transform")
        // 多个 transform 用空白分隔（如 `scale(.8) translateX(20px)`）。
        // 这里用一个朴素切法 —— 函数体不内含空格（CSS 函数实参里数值通常连续）。
        let funcs = splitTransformFuncs(body)
        guard !funcs.isEmpty else { return nil }
        var out: [AnimationIR] = []
        for f in funcs {
            guard let one = parseOneTransform(f) else { return nil }
            out.append(one)
        }
        return out
    }

    /// `animation: <name> <duration>s [easing] [delay]s [iteration-count]` 单条。
    /// 只吃**关键字命名** keyframe（`fadeIn` / `fadeOut` / `scaleIn` / `slideIn`），
    /// 其它 → nil。
    static func parseAnimation(_ decl: String) -> [AnimationIR]? {
        let tokens = tokenizeTransition(stripKeyword(decl, "animation"))
        guard let first = tokens.first else { return nil }
        guard let keyframe = keyframeMapping[first.lowercased()] else { return nil }

        var durationMs: Int? = nil
        var delayMs: Int? = nil
        var curve: AnimationTimingCurve = .easeInOut

        for tok in tokens.dropFirst() {
            if let ms = parseMilliseconds(tok) {
                if durationMs == nil { durationMs = ms }
                else if delayMs == nil { delayMs = ms }
                else { return nil }
            } else if let c = parseEasingKeyword(tok) {
                curve = c
            } else if let c = parseCubicBezier(tok) {
                curve = c
            } else if tok == "infinite" || tok == "1" || tok == "2" || tok == "3" {
                // iteration-count：吃掉即可，不影响 IR。
                continue
            } else {
                return nil
            }
        }
        guard let dur = durationMs else { return nil }
        // animation 默认从 0 → 1（与 transition 同语义）；keyframe 名决定
        // property / from / to 在 keyframeMapping 里给出。
        return [AnimationIR(
            property: keyframe.property,
            from: keyframe.from,
            to: keyframe.to,
            durationMs: dur,
            delayMs: delayMs ?? 0,
            curve: curve,
            trigger: .onAppear
        )]
    }

    // MARK: - Script 入口（给 ScriptIntentAnalyzer 调用）

    /// `el.classList.toggle('cls')` / `el.classList.add('cls')` 这类
    /// 「class 名 → 已有 CSS class 的动画」静态映射：
    /// - 若 cls 在 `classKeyframeMap` 内 → 返回那条 AnimationIR。
    /// - 其它 → nil。
    static func animation(forClassToggle cls: String) -> [AnimationIR]? {
        guard let kf = classKeyframeMap[cls.lowercased()] else { return nil }
        return [AnimationIR(
            property: kf.property,
            from: kf.from,
            to: kf.to,
            durationMs: kf.durationMs,
            delayMs: 0,
            curve: kf.curve,
            trigger: .onAction(key: "class-toggle:\(cls.lowercased())")
        )]
    }

    /// `el.style.opacity = '1'` / `el.style.transform = 'scale(1)'` 这类
    /// **直接 style 属性赋值** —— 静态归一为 from→to 动画意图（from = 0，
    /// to = 1）。调用方决定是否挂进 trigger。
    static func animation(forStyleAssignment property: String, value: String) -> AnimationIR? {
        let prop = property.lowercased()
        let v = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        switch prop {
        case "opacity":
            guard let d = parseDouble(v) else { return nil }
            return AnimationIR(
                property: .opacity, from: 0, to: d,
                durationMs: 300, delayMs: 0, curve: .easeInOut,
                trigger: .onAction(key: "style.opacity")
            )
        default:
            return nil
        }
    }

    // MARK: - 内部 helpers

    private static func parseDeclaration(_ raw: String, trigger: AnimationTrigger) -> DeclarationResult {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let colonIdx = s.firstIndex(of: ":") else { return .none }
        let key = s[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
        let value = s[s.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)

        switch key {
        case "transition":
            if let arr = parseTransition(value) { return .some(arr) }
            return .none
        case "transform":
            if let arr = parseTransform(value) { return .some(arr) }
            return .none
        case "animation":
            if let arr = parseAnimation(value) { return .some(arr) }
            return .none
        case "opacity", "color", "background", "background-color",
             "width", "height", "margin", "padding", "border",
             "display", "position", "top", "left", "right", "bottom",
             "font", "font-size", "font-weight", "line-height", "text-align",
             "visibility", "overflow", "z-index", "cursor":
            // 已识别为合法 CSS property，但本身不携带动画意图（缺 timing 信息）→ inert。
            return .inert
        default:
            return .none
        }
    }

    private static func splitDeclarations(_ style: String) -> [String] {
        // CSS 声明以 `;` 分隔。允许末位空。
        style.split(separator: ";", omittingEmptySubsequences: true).map { String($0) }
    }

    private static func tokenizeTransition(_ s: String) -> [String] {
        // 空格 / 逗号切。transition / animation 语法里没有嵌套括号，
        // 因此朴素切即可。
        s.split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0) }
    }

    private static func parseOneTransform(_ func: String) -> AnimationIR? {
        // 形如 `scale(.8)` / `scaleX(0.5)` / `translateX(20px)` / `rotate(45deg)`。
        guard let lp = `func`.firstIndex(of: "("),
              let rp = `func`.firstIndex(of: ")"),
              lp < rp else { return nil }
        let name = String(`func`[`func`.startIndex..<lp]).lowercased()
        let argRaw = String(`func`[`func`.index(after: lp)..<rp])
        let arg = argRaw.trimmingCharacters(in: .whitespaces)
        guard let n = parseNumber(arg) else { return nil }

        switch name {
        case "scale":
            return AnimationIR(property: .scale, from: 0, to: n, durationMs: 0, trigger: .onAppear)
        case "scalex":
            return AnimationIR(property: .scaleX, from: 0, to: n, durationMs: 0, trigger: .onAppear)
        case "scaley":
            return AnimationIR(property: .scaleY, from: 0, to: n, durationMs: 0, trigger: .onAppear)
        case "translatex":
            return AnimationIR(property: .offsetX, from: 0, to: n, durationMs: 0, trigger: .onAppear)
        case "translatey":
            return AnimationIR(property: .offsetY, from: 0, to: n, durationMs: 0, trigger: .onAppear)
        case "rotate":
            // rotate 用度数；用户输入可能 `45deg` / `0.5turn` —— 只吃纯数字 + 度。
            return AnimationIR(property: .rotation, from: 0, to: n, durationMs: 0, trigger: .onAppear)
        default:
            return nil
        }
    }

    private static func splitTransformFuncs(_ body: String) -> [String] {
        // 用 `)` 作分隔点：每个 transform 函数以 `)` 结尾，后面可跟空白接下一个。
        // 朴素写法：按 `)` 切，再 trim 前缀空白。
        var out: [String] = []
        var current = ""
        for ch in body {
            current.append(ch)
            if ch == ")" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        return out
    }

    private static func animationProperty(fromTransitionToken tok: String) -> AnimationProperty? {
        switch tok.lowercased() {
        case "opacity": return .opacity
        case "scale", "transform": return .scale
        case "scalex": return .scaleX
        case "scaley": return .scaleY
        case "translatex", "left", "right": return .offsetX
        case "translatey", "top", "bottom": return .offsetY
        case "rotate", "rotation": return .rotation
        default: return nil
        }
    }

    private static func parseMilliseconds(_ s: String) -> Int? {
        // `0.3s` / `300ms` / `0s`。
        let t = s.lowercased()
        if t.hasSuffix("ms") {
            let num = String(t.dropLast(2))
            guard let d = Double(num) else { return nil }
            return Int(d)
        }
        if t.hasSuffix("s") {
            let num = String(t.dropLast())
            guard let d = Double(num) else { return nil }
            return Int(d * 1000)
        }
        return nil
    }

    private static func parseEasingKeyword(_ s: String) -> AnimationTimingCurve? {
        switch s.lowercased() {
        case "linear": return .linear
        case "ease", "ease-in-out": return .easeInOut
        case "ease-in": return .easeIn
        case "ease-out": return .easeOut
        default: return nil
        }
    }

    private static func parseCubicBezier(_ s: String) -> AnimationTimingCurve? {
        // `cubic-bezier(0.25, 0.1, 0.25, 1.0)` 形式。
        guard s.lowercased().hasPrefix("cubic-bezier(") else { return nil }
        guard let lp = s.firstIndex(of: "("),
              let rp = s.firstIndex(of: ")"),
              lp < rp else { return nil }
        let body = String(s[s.index(after: lp)..<rp])
        let parts = body.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4 else { return nil }
        guard let x1 = Double(parts[0]),
              let y1 = Double(parts[1]),
              let x2 = Double(parts[2]),
              let y2 = Double(parts[3]) else { return nil }
        return .cubicBezier(x1: x1, y1: y1, x2: x2, y2: y2)
    }

    private static func parseNumber(_ s: String) -> Double? {
        // 支持 `0.5` / `.5` / `45deg`（去后缀） / `20px`（去后缀）。
        var t = s.trimmingCharacters(in: .whitespaces)
        // 剥单位（deg / px / em / % —— 只剥这些常见单位；其它原���返回）。
        for suffix in ["deg", "px", "em", "%", "rem"] {
            if t.lowercased().hasSuffix(suffix) {
                t = String(t.dropLast(suffix.count))
                break
            }
        }
        return Double(t)
    }

    private static func parseDouble(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces))
    }

    private static func stripKeyword(_ s: String, _ keyword: String) -> String {
        // 容忍 `transition: opacity 0.3s` 与 `opacity 0.3s` 两种入参形态。
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix(keyword + ":") {
            return String(t.dropFirst(keyword.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        if t.lowercased().hasPrefix(keyword + " ") {
            return String(t.dropFirst(keyword.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private static func defaultFrom(for prop: AnimationProperty) -> Double {
        switch prop {
        case .opacity, .scale, .scaleX, .scaleY: return 0
        case .offsetX, .offsetY, .rotation: return 0
        }
    }

    private static func defaultTo(for prop: AnimationProperty) -> Double {
        switch prop {
        case .opacity, .scale, .scaleX, .scaleY: return 1
        case .offsetX, .offsetY, .rotation: return 0
        }
    }

    // MARK: - 关键字 → AnimationIR 映射（保守白名单）

    private struct KeyframeSpec {
        var property: AnimationProperty
        var from: Double
        var to: Double
        var durationMs: Int
        var curve: AnimationTimingCurve
    }

    private static let keyframeMapping: [String: KeyframeSpec] = [
        "fadein": KeyframeSpec(property: .opacity, from: 0, to: 1, durationMs: 300, curve: .easeInOut),
        "fadeout": KeyframeSpec(property: .opacity, from: 1, to: 0, durationMs: 300, curve: .easeInOut),
        "scalein": KeyframeSpec(property: .scale, from: 0, to: 1, durationMs: 300, curve: .easeInOut),
        "slidein": KeyframeSpec(property: .offsetX, from: -20, to: 0, durationMs: 300, curve: .easeOut)
    ]

    private static let classKeyframeMap: [String: KeyframeSpec] = [
        // 保守白名单：只识别酒馆 / MVU 角色卡常见 class 名。
        "show": KeyframeSpec(property: .opacity, from: 0, to: 1, durationMs: 300, curve: .easeInOut),
        "hide": KeyframeSpec(property: .opacity, from: 1, to: 0, durationMs: 300, curve: .easeInOut),
        "fade-in": KeyframeSpec(property: .opacity, from: 0, to: 1, durationMs: 300, curve: .easeInOut),
        "fade-out": KeyframeSpec(property: .opacity, from: 1, to: 0, durationMs: 300, curve: .easeInOut),
        "scale-in": KeyframeSpec(property: .scale, from: 0, to: 1, durationMs: 300, curve: .easeInOut)
    ]
}