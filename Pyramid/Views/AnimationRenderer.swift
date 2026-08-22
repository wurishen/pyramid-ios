import SwiftUI

// P9: 把 AnimationIR 翻译成 SwiftUI 原生动画 modifier。
//
// 渲染策略：
// - `AnimationSidecarModifier` 是 P9 给空 sidecar 节点用的占位 modifier ——
//   看到 `.htmlAnimation(anim)` 节点本身时挂上，不改变可视内容（避免丢数据）。
// - `AnimationModifier`（`animationModifier(_:triggerValue:)`）由 htmlContainer /
//   button 等真实渲染容器在子树挂载 —— 把 AnimationIR 翻译成 `.animation(...)`
//   / `.transition(...)` / `withAnimation(...)`，**不**引入 WebView、**不**执行 JS。
//
// **触发语义**：每个 AnimationIR 配 trigger；renderer 用 trigger 决定何时启动动画：
//   - `.onAppear`       → SwiftUI `.animation(_:value:)` + `.onAppear { withAnimation }`
//   - `.onDisappear`    → SwiftUI `.transition(...)` 配 `.animation(_:value:isActive)`
//   - `.onPathChange`   → 上层订阅 VariableStore 该 path；变化时 `withAnimation` 应用 modifier
//   - `.onAction(key)`  → NativeActionDispatcher 在执行后回调 renderer 触发
//
// **不**做的事：
// - 不引入 SceneKit / Lottie / Rive / 任何第三方动画库。
// - 不实现 keyframe（仅 fadeIn / fadeOut / scaleIn / slideIn 这几个关键字白名单 →
//   `AnimationIR`，由 AnimationIntentAnalyzer 生成）。

/// 把 AnimationIR 转成 SwiftUI `Animation`（用于 `.animation` / `.transition` / `withAnimation`）。
///
/// Foundation-only 的 AnimationTimingCurve ↔ SwiftUI Animation 一对一映射；
/// 唯一非直接对应的是 `spring(response:dampingFraction:)` —— 仍然用 SwiftUI 原生 spring。
enum AnimationRenderer {

    /// AnimationIR → SwiftUI `Animation`。`durationMs == 0` 时返回 `.default`，
    /// renderer 让 SwiftUI 自选时长（保留 IR 的 from/to 语义）。
    static func swiftUIAnimation(_ ir: AnimationIR) -> Animation {
        let duration: Double = ir.durationMs > 0 ? Double(ir.durationMs) / 1000.0 : 0.4
        let delay: Double = ir.delayMs > 0 ? Double(ir.delayMs) / 1000.0 : 0
        switch ir.curve {
        case .linear:
            return .linear(duration: duration).delay(delay)
        case .easeIn:
            return .easeIn(duration: duration).delay(delay)
        case .easeOut:
            return .easeOut(duration: duration).delay(delay)
        case .easeInOut:
            return .easeInOut(duration: duration).delay(delay)
        case .cubicBezier(let x1, let y1, let x2, let y2):
            return .timingCurve(x1, y1, x2, y2, duration: duration).delay(delay)
        case .spring(let response, let damping):
            return .spring(response: response, dampingFraction: damping).delay(delay)
        }
    }

    /// `AnimationIR` → SwiftUI `AnyTransition`（用于 `.transition(...)`）。
    /// transition 不带 timing 参数语义；用 `swiftUIAnimation` 转成 Animation 即可。
    static func swiftUITransition(_ ir: AnimationIR) -> AnyTransition {
        switch ir.property {
        case .opacity:
            return .opacity.animation(swiftUIAnimation(ir))
        case .scale, .scaleX, .scaleY:
            return .scale(scale: CGFloat(max(ir.to, 0.001))).animation(swiftUIAnimation(ir))
        case .offsetX:
            return .move(edge: ir.to >= 0 ? .leading : .trailing)
                .animation(swiftUIAnimation(ir))
        case .offsetY:
            return .move(edge: ir.to >= 0 ? .top : .bottom)
                .animation(swiftUIAnimation(ir))
        case .rotation:
            return .modifier(active: RotationModifier(angle: ir.from),
                            identity: RotationModifier(angle: ir.to))
                .animation(swiftUIAnimation(ir))
        }
    }
}

// MARK: - 修饰 ViewModifier

/// 把 AnimationIR 应用到任意 View 上：当 trigger 条件触发时启动动画。
/// 具体绑定逻辑（onAppear / onPathChange / onAction）由调用方通过 `triggerValue`
/// 传入；本 modifier 只负责把 AnimationIR 转换成 SwiftUI 的 from/to 值。
struct AnimationModifier: ViewModifier {
    let anim: AnimationIR
    /// 驱动动画重放的外部状态值（任意 Hashable）。trigger 是 `.onPathChange` /
    /// `.onAction` 时，调用方把 VariableStore 该 path 的当前值 / action 触发的
    /// 自定义 token 传进来；变化 → SwiftUI 自动重放 `.animation(_:value:)`。
    let triggerValue: AnyHashable?

    func body(content: Content) -> some View {
        content
            .modifier(AnimationFromToModifier(anim: anim))
            .animation(
                AnimationRenderer.swiftUIAnimation(anim),
                value: triggerValue
            )
            .transition(AnimationRenderer.swiftUITransition(anim))
    }
}

/// 应用 AnimationIR 的 from/to 静态值。
/// 注意：from/to 是 SwiftUI Animation 起止时的瞬时值；运行时由 `withAnimation` /
/// `.animation(_:value:)` 联动起来。本 modifier 只把 IR 落到 SwiftUI modifier。
private struct AnimationFromToModifier: ViewModifier {
    let anim: AnimationIR

    func body(content: Content) -> some View {
        switch anim.property {
        case .opacity:
            return content.opacity(max(min(anim.to, 1), 0)).anyView()
        case .scale:
            return content.scaleEffect(CGFloat(anim.to), anchor: .center).anyView()
        case .scaleX:
            return content.scaleEffect(x: CGFloat(anim.to), y: 1, anchor: .center).anyView()
        case .scaleY:
            return content.scaleEffect(x: 1, y: CGFloat(anim.to), anchor: .center).anyView()
        case .offsetX:
            return content.offset(x: CGFloat(anim.to)).anyView()
        case .offsetY:
            return content.offset(y: CGFloat(anim.to)).anyView()
        case .rotation:
            return content.rotationEffect(.degrees(anim.to)).anyView()
        }
    }
}

/// 用来在 `switch` 里统一类型为 `AnyView` 的小工具。
private extension View {
    func anyView() -> AnyView { AnyView(self) }
}

/// rotation 的 transition helper（避免 AnyTransition 直接吐 SwiftUI `.rotationEffect`）。
private struct RotationModifier: ViewModifier {
    var angle: Double
    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(angle))
    }
}

/// Sidecar 节点占位 modifier：挂在 `.htmlAnimation(anim)` 节点上，
/// 不改变可视内容（避免空 node 丢数据），仅供 debug inspector 标注。
struct AnimationSidecarModifier: ViewModifier {
    let anim: AnimationIR
    func body(content: Content) -> some View {
        // 直接透传：动画意图由**下一个** concrete 容器（htmlContainer / button / …）
        // 通过 `animationModifier(_:triggerValue:)` 接管，本节点不重复应用。
        content
    }
}