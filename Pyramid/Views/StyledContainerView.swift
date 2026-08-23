import SwiftUI
import Combine

// P11: HTML/CSS → NativeIR → SwiftUI 通用容器 renderer。
//
// **职责**：把 `.styledContainer(tag:classNames:style:children:)` 转译成 SwiftUI
// 原生 modifier —— 把 CSS 声明（颜色 / 背景 / 圆角 / 阴影 / 透明度 / 字体 / padding /
// margin / 边框 / transform / transition / animation）逐条映射到对应 SwiftUI API。
//
// **硬边界**（与 HTMLCSSTranspiler / CSSParser 共享）：
// - **不**引入 WebView / JavaScriptCore —— 任何 CSS 选择器 / animation 都**仅**映射到
//   SwiftUI 原生 modifier。
// - **不**创建业务组件（PhoneContainer / StatusCard / CharacterPanel）；tag 仅用于
//   `fontWeight` / `padding` 等通用 SwiftUI modifier，**不**触发任何 Pyramid 业务名。
// - **不**下载任何远程资源（背景图 URL / web font URL 仅记录在 IR，本视图层**不**发起）。
// - 解析失败 / 不识别一律保留原文 residual —— 不在本视图"伪造"任何样式。

/// P11 CSS-aware 容器 view：把 CSSStyleDeclaration 翻译为 SwiftUI modifier 链。
struct StyledContainerView<Content: View>: View {
    let tag: String
    let classNames: [String]
    let style: CSSStyleDeclaration
    let children: () -> Content
    let scale: CGFloat

    var body: some View {
        let view = children()
            .modifier(StyledContainerModifier(style: style, scale: scale))
            .modifier(StyledContainerAnimationModifier(style: style, scale: scale))
        return AnyView(view)
    }
}

/// 把静态 CSS 声明（padding / margin / 边框 / 圆角 / 阴影 / 背景 / 透明度 / 字体 / 宽高 /
/// transform）翻译为 SwiftUI modifier 链。
private struct StyledContainerModifier: ViewModifier {
    let style: CSSStyleDeclaration
    let scale: CGFloat

    func body(content: Content) -> some View {
        var v = content
        // CSS 转换规则：
        // 1. display: none → 完全隐藏
        // 2. opacity → .opacity
        // 3. background → .background
        // 4. padding → .padding
        // 5. border-radius → .clipShape(RoundedRectangle)
        // 6. shadow → .shadow
        // 7. font-size / font-weight → .font
        // 8. width / height → .frame
        // 9. border → .overlay(Rectangle().stroke)
        // 10. transform → .rotationEffect / .offset / .scaleEffect 链
        // 11. display: flex + flex-direction → 不变（SwiftUI 默认 VStack/HStack 由调用方决定）

        // 1. display: none —— 提前返回 EmptyView
        if let display = displayValue, display == .none {
            return AnyView(EmptyView())
        }

        // 2. opacity
        if let op = opacityValue {
            v = v.opacity(CGFloat(op)).anyView()
        }

        // 3. background（color 或 gradient）
        v = applyBackground(to: v)

        // 4. padding（short / longhand 之一即可 —— CSS 解析阶段已归一）
        if let ins = paddingValue {
            v = applyEdgeInsets(ins, to: v, edgeInset: .padding)
        }
        // 5. margin —— SwiftUI 无 .margin，用 Spacer 不直观。保守：忽略 margin（不渲染），
        //    真实角色卡几乎不用 margin，绝大多数用 padding。

        // 6. cornerRadius
        if let (n, unit) = cornerRadiusValue {
            let r = scaleLength(n, unit: unit, scale: scale)
            v = v.clipShape(RoundedRectangle(cornerRadius: r)).anyView()
        }

        // 7. shadow
        if let shadows = shadowValue, !shadows.isEmpty {
            for s in shadows {
                let dx = scaleLength(s.offsetX, unit: .px, scale: scale)
                let dy = scaleLength(s.offsetY, unit: .px, scale: scale)
                let blur = scaleLength(s.blur, unit: .px, scale: scale)
                let shadowColor: Color = parseColor(s.color) ?? Color.black
                v = v.shadow(color: shadowColor,
                             radius: CGFloat(blur),
                             x: CGFloat(dx), y: CGFloat(dy)).anyView()
            }
        }

        // 8. font-size / font-weight / text-align
        if let fontSize = fontSizeValue {
            let fs = scaleLength(fontSize.0, unit: fontSize.1, scale: scale)
            if let weight = fontWeightValue {
                v = v.font(.system(size: fs).weight(weight.swiftUI)).anyView()
            } else {
                v = v.font(.system(size: fs)).anyView()
            }
        } else if let weight = fontWeightValue {
            v = v.font(.system(.body).weight(weight.swiftUI)).anyView()
        }
        if let align = textAlignValue {
            switch align {
            case .left: v = v.multilineTextAlignment(.leading).anyView()
            case .right: v = v.multilineTextAlignment(.trailing).anyView()
            case .center: v = v.multilineTextAlignment(.center).anyView()
            case .justify: v = v.multilineTextAlignment(.leading).anyView() // SwiftUI 无 justify，fallback leading
            }
        }

        // 9. color (text)
        if let color = textColorValue, let c = parseColor(color) {
            v = v.foregroundStyle(c).anyView()
        }

        // 10. width / height
        if let w = widthValue {
            v = v.frame(width: CGFloat(scaleLength(w.0, unit: w.1, scale: scale))).anyView()
        }
        if let h = heightValue {
            v = v.frame(height: CGFloat(scaleLength(h.0, unit: h.1, scale: scale))).anyView()
        }

        // 11. overflow
        if let ov = overflowValue {
            switch ov {
            case .hidden:
                v = v.clipped().anyView()
            case .scroll, .auto:
                v = v.anyView()  // SwiftUI 容器自带 ScrollView 包装，此处不强制
            case .visible:
                break
            }
        }

        // 12. transform
        if let comps = transformValue, !comps.isEmpty {
            for c in comps {
                switch c {
                case .translateX(let n):
                    v = v.offset(x: CGFloat(scaleLength(n, unit: .px, scale: scale))).anyView()
                case .translateY(let n):
                    v = v.offset(y: CGFloat(scaleLength(n, unit: .px, scale: scale))).anyView()
                case .scale(let n):
                    v = v.scaleEffect(CGFloat(n), anchor: .center).anyView()
                case .scaleX(let n):
                    v = v.scaleEffect(x: CGFloat(n), y: 1, anchor: .center).anyView()
                case .scaleY(let n):
                    v = v.scaleEffect(x: 1, y: CGFloat(n), anchor: .center).anyView()
                case .rotate(let deg):
                    v = v.rotationEffect(.degrees(deg), anchor: .center).anyView()
                }
            }
        }

        // 13. border（仅取 border-width 数值 + border-color）
        if let (bw, _) = borderWidthValue, let bc = borderColorValue {
            let w = scaleLength(bw, unit: .px, scale: scale)
            let c = parseColor(bc) ?? Color.gray
            v = v.overlay(RoundedRectangle(cornerRadius: 0).stroke(c, lineWidth: CGFloat(w))).anyView()
        }

        // 14. align-items (flex container) —— SwiftUI 默认对齐，无需改动
        // 15. gap —— SwiftUI VStack/HStack spacing 由调用方决定，本层不强制覆盖

        return AnyView(v)
    }

    // MARK: - 解 CSSDeclaration → 强类型

    private var displayValue: CSSDisplay? {
        for d in style.declarations {
            if case .display(let v) = d.resolved { return v }
        }
        return nil
    }

    private var opacityValue: Double? {
        for d in style.declarations {
            if case .opacity(let v) = d.resolved { return v }
        }
        return nil
    }

    private var paddingValue: CSSEdgeInsets? {
        for d in style.declarations {
            if case .padding(let v) = d.resolved { return v }
        }
        return nil
    }

    private var cornerRadiusValue: (Double, CSSLengthUnit)? {
        for d in style.declarations {
            if case .cornerRadius(let n, let u) = d.resolved { return (n, u) }
        }
        return nil
    }

    private var shadowValue: [CSSShadow]? {
        for d in style.declarations {
            if case .shadow(let v) = d.resolved { return v }
        }
        return nil
    }

    private var fontSizeValue: (Double, CSSLengthUnit)? {
        for d in style.declarations {
            if case .fontSize(let n, let u) = d.resolved { return (n, u) }
        }
        return nil
    }

    private var fontWeightValue: CSSFontWeight? {
        for d in style.declarations {
            if case .fontWeight(let w) = d.resolved { return w }
        }
        return nil
    }

    private var textAlignValue: CSSTextAlign? {
        for d in style.declarations {
            if case .textAlign(let a) = d.resolved { return a }
        }
        return nil
    }

    private var textColorValue: String? {
        for d in style.declarations {
            if case .color(let s) = d.resolved { return s }
        }
        return nil
    }

    private var backgroundColorValue: String? {
        for d in style.declarations {
            if case .backgroundColor(let s) = d.resolved { return s }
        }
        return nil
    }

    private var backgroundGradientValue: [CSSGradientStop]? {
        for d in style.declarations {
            if case .backgroundGradient(let stops) = d.resolved { return stops }
        }
        return nil
    }

    private var widthValue: (Double, CSSLengthUnit)? {
        for d in style.declarations {
            if case .width(let n, let u) = d.resolved { return (n, u) }
        }
        return nil
    }

    private var heightValue: (Double, CSSLengthUnit)? {
        for d in style.declarations {
            if case .height(let n, let u) = d.resolved { return (n, u) }
        }
        return nil
    }

    private var borderWidthValue: (Double, CSSLengthUnit)? {
        for d in style.declarations {
            if case .borderWidth(let n, let u) = d.resolved { return (n, u) }
        }
        return nil
    }

    private var borderColorValue: String? {
        for d in style.declarations {
            if case .borderColor(let s) = d.resolved { return s }
        }
        return nil
    }

    private var overflowValue: CSSOverflow? {
        for d in style.declarations {
            if case .overflow(let v) = d.resolved { return v }
        }
        return nil
    }

    private var transformValue: [CSSTransformComponent]? {
        for d in style.declarations {
            if case .transform(let v) = d.resolved { return v }
        }
        return nil
    }

    // MARK: - helpers

    private func applyBackground<V: View>(to v: V) -> AnyView {
        if let stops = backgroundGradientValue, !stops.isEmpty {
            let colors = stops.compactMap { parseColor($0.color) }
            if !colors.isEmpty {
                return AnyView(v.background(LinearGradient(
                    colors: colors,
                    startPoint: .top, endPoint: .bottom
                )))
            }
        }
        if let raw = backgroundColorValue, let c = parseColor(raw) {
            return AnyView(v.background(c))
        }
        return AnyView(v)
    }

    private enum EdgeInset { case padding }

    private func applyEdgeInsets<V: View>(_ ins: CSSEdgeInsets, to v: V, edgeInset: EdgeInset) -> AnyView {
        let top = scaleLength(ins.top ?? 0, unit: ins.unit, scale: scale)
        let leading = scaleLength(ins.leading ?? 0, unit: ins.unit, scale: scale)
        let bottom = scaleLength(ins.bottom ?? 0, unit: ins.unit, scale: scale)
        let trailing = scaleLength(ins.trailing ?? 0, unit: ins.unit, scale: scale)
        switch edgeInset {
        case .padding:
            return AnyView(v.padding(EdgeInsets(
                top: CGFloat(top), leading: CGFloat(leading),
                bottom: CGFloat(bottom), trailing: CGFloat(trailing)
            )))
        }
    }
}

/// 把 CSS `animation:` / `transition:` 翻译为 SwiftUI `.animation` / `transition`。
/// 静态稳态值已在 StyledContainerModifier 应用，本 modifier 只挂动画意图。
private struct StyledContainerAnimationModifier: ViewModifier {
    let style: CSSStyleDeclaration
    let scale: CGFloat

    func body(content: Content) -> some View {
        var v = content
        // transition 短手：单条 → .animation + .transition（按 property 推断方向）
        if let t = transitionValue {
            let dur = Double(t.durationMs) / 1000.0
            let anim: Animation = swiftUIAnimation(for: t.curveRaw, duration: dur)
            let transition: AnyTransition = swiftUITransition(for: t.property, animation: anim)
            v = v.animation(anim, value: UUID()).transition(transition).anyView()
        }
        // animation 短手：单独挂 transition（onAppear 触发动画）
        if let a = animationValue {
            let dur = Double(a.durationMs) / 1000.0
            let anim = swiftUIAnimation(for: a.curveRaw, duration: dur)
            // 用 onAppear + withAnimation 重放一次（简易实现）
            v = v.onAppear {
                withAnimation(anim) {
                    // 一次性动画；具体属性变化由 StyledContainerModifier 处理。
                }
            }.anyView()
        }
        return AnyView(v)
    }

    private var transitionValue: CSSShortTransition? {
        for d in style.declarations {
            if case .transition(let t?) = d.resolved { return t }
        }
        return nil
    }

    private var animationValue: CSSShortAnimation? {
        for d in style.declarations {
            if case .animation(let a?) = d.resolved { return a }
        }
        return nil
    }

    private func swiftUIAnimation(for curve: String, duration: Double) -> Animation {
        switch curve.lowercased() {
        case "linear": return .linear(duration: duration)
        case "ease-in": return .easeIn(duration: duration)
        case "ease-out": return .easeOut(duration: duration)
        case "ease", "ease-in-out", "": return .easeInOut(duration: duration)
        default:
            if curve.lowercased().hasPrefix("cubic-bezier(") {
                // 解析 cubic-bezier(x1,y1,x2,y2)
                let body = curve
                    .lowercased()
                    .replacingOccurrences(of: "cubic-bezier(", with: "")
                    .replacingOccurrences(of: ")", with: "")
                let parts = body.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0.5 }
                if parts.count == 4 {
                    return .timingCurve(parts[0], parts[1], parts[2], parts[3], duration: duration)
                }
            }
            return .easeInOut(duration: duration)
        }
    }

    private func swiftUITransition(for prop: String, animation: Animation) -> AnyTransition {
        switch prop.lowercased() {
        case "opacity": return .opacity.animation(animation)
        case "transform", "all":
            return .opacity.animation(animation)
        case "color", "background-color":
            return .opacity.animation(animation)
        default:
            return .opacity.animation(animation)
        }
    }
}

// MARK: - Color 解析（hex / rgb / rgba）

private func parseColor(_ raw: String) -> Color? {
    let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if s.hasPrefix("#") {
        return Color(hex: s) ?? namedColor(s)
    }
    if s.hasPrefix("rgb(") || s.hasPrefix("rgba(") {
        let body = s
            .replacingOccurrences(of: "rgba(", with: "")
            .replacingOccurrences(of: "rgb(", with: "")
            .replacingOccurrences(of: ")", with: "")
        let parts = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        guard let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else {
            return nil
        }
        let a = parts.count >= 4 ? (Double(parts[3]) ?? 1.0) : 1.0
        return Color(red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: a)
    }
    return namedColor(s)
}

private func namedColor(_ s: String) -> Color? {
    switch s {
    case "red": return .red
    case "blue": return .blue
    case "green": return .green
    case "black": return .black
    case "white": return .white
    case "gray", "grey": return .gray
    case "yellow": return .yellow
    case "orange": return .orange
    case "pink": return .pink
    case "purple": return .purple
    case "transparent": return .clear
    default: return nil
    }
}

private extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        if h.count == 3 {
            // #rgb → #rrggbb
            h = h.map { "\($0)\($0)" }.joined()
        }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xff) / 255.0
        let g = Double((v >> 8) & 0xff) / 255.0
        let b = Double(v & 0xff) / 255.0
        self.init(red: r, green: g, blue: b, opacity: 1.0)
    }
}

private extension CSSFontWeight {
    var swiftUI: Font.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

// MARK: - 长度单位 → 实际像素

private func scaleLength(_ n: Double, unit: CSSLengthUnit, scale: CGFloat) -> CGFloat {
    switch unit {
    case .px, .none: return CGFloat(n) * scale
    case .pt: return CGFloat(n) * 1.25 * scale
    case .em: return CGFloat(n) * 14 * scale  // 简单基准：1em ≈ 14pt
    case .rem: return CGFloat(n) * 14 * scale
    case .percent: return CGFloat(n) * scale
    }
}

private extension View {
    func anyView() -> AnyView { AnyView(self) }
}
