import Foundation

// P9: 通用动画意图中间表达（AnimationIR）。
//
// 跟 P8 的 HTML/Script 静态分析一脉相承 —— 酒馆 / 角色卡表达的"想做什么动画"
// 静态识别后归一成 AnimationIR，再由 SwiftUI Native Renderer 落地为 SwiftUI 原生
// `.animation` / `.transition` / `withAnimation`。**不**试图执行 JS、**不**完整
// 实现 CSS engine —— 只表达"看得懂的意图"。
//
// 设计原则：
// - **零业务语义**：没有 PhoneAnimation / StatusAnimation / CharacterCardAnimation。
//   不绑定任何角色卡字段名 / 主题。动画只描述属性 + 起止 + 时序 + 触发。
// - **不锁实现**：TimingCurve 抽象到 linear / easeIn / easeOut / easeInOut /
//   cubicBezier / spring —— 跟 SwiftUI Animation 一一对应，renderer 直接映射。
// - **可缓存**：纯 Foundation 数据，Equatable + Hashable��HTMLTranspiler / Script
//   静态分析只跑一次，存进 RenderNode / NativeIR 后不���重算。
// - **信息保真**：解析不出来 → 调用方降级为 `.htmlScript(residual:)` /
//   `.deferredResidual(...)`，原文完整保留；本枚举不出现"近似猜测"路径。

/// 一个动画意图作用的目标属性。
///
/// 命名贴近 SwiftUI modifier（`opacity()` / `scaleEffect()` /
/// `offset()` / `rotationEffect()`），renderer 可以零成本映射。
enum AnimationProperty: String, Equatable, Sendable, Hashable {
    /// CSS `opacity` / `style.opacity`。
    case opacity
    /// CSS `transform: scale(s)`。
    case scale
    /// 横向 scale —— CSS `transform: scaleX(s)`。
    case scaleX
    /// 纵向 scale —— CSS `transform: scaleY(s)`。
    case scaleY
    /// 横向位移 —— CSS `transform: translateX(...)`。
    case offsetX
    /// 纵向位移 —— CSS `transform: translateY(...)`。
    case offsetY
    /// 旋转 —— CSS `transform: rotate(...)`，角度按度数计。
    case rotation
}

/// 时序曲线 —— 对齐 SwiftUI `Animation` / CSS `transition-timing-function` /
/// CSS `animation-timing-function`。renderer 一对一映射到 SwiftUI 原生 API。
enum AnimationTimingCurve: Equatable, Sendable, Hashable {
    /// `linear` —— CSS `linear` / SwiftUI `.linear`。
    case linear
    /// CSS `ease-in` / SwiftUI `.easeIn`。
    case easeIn
    /// CSS `ease-out` / SwiftUI `.easeOut`。
    case easeOut
    /// CSS `ease-in-out` / SwiftUI `.easeInOut`。
    case easeInOut
    /// 显式三次贝塞尔 —— CSS `cubic-bezier(x1, y1, x2, y2)`。
    /// SwiftUI `.timingCurve(x1, y1, x2, y2, duration:)` 接收同样的四个值。
    case cubicBezier(x1: Double, y1: Double, x2: Double, y2: Double)
    /// 弹簧 —— CSS 无对应；SwiftUI `.spring(response:dampingFraction:)`。
    case spring(response: Double, dampingFraction: Double)
}

/// 动画触发条件 —— 谁来"激活"这次动画。
///
/// 与现有 VariableStore / NativeAction 复用：**不**建立第二套状态系统。
enum AnimationTrigger: Equatable, Sendable, Hashable {
    /// 视图出现（SwiftUI `.onAppear`）。
    case onAppear
    /// 视图消失（SwiftUI `.onDisappear`）。
    case onDisappear
    /// 当 JSON Pointer 路径上的变量值变化时触发。
    /// renderer 订阅 VariableStore 该 path 的变化信号 —— 复用既有数据流。
    case onPathChange(path: String)
    /// 当 `NativeAction` 触发时附加动画。`key` 与 `NativeAction` 类别对齐
    /// （例如 `.onAction(key: "toggle")` 表示 toggle 类动作产生动画）。
    case onAction(key: String)
}

/// 一条完整的动画意图（IR）。
///
/// 一个节点可挂多条（多条 AnimationIR 顺序叠加：先 opacity 再 scale）。Renderer
/// 按出现顺序链式应用。
struct AnimationIR: Equatable, Sendable, Hashable {
    /// 作用目标。
    var property: AnimationProperty
    /// 起始值（CSS `from` / 状态 A 的快照）。opacity / scale 类通常 0；offset / rotation 类通常 0。
    var from: Double
    /// 目标值（CSS `to` / 状态 B 的快照）。opacity / scale 类通常 1。
    var to: Double
    /// 持续时间（毫秒）。CSS `transition-duration` / `animation-duration` 解析得到。
    /// `0` 表示瞬时；renderer 可按需映射到 `.animation(nil)`。
    var durationMs: Int
    /// 延迟（毫秒）。CSS `transition-delay` / `animation-delay`。默认 0。
    var delayMs: Int
    /// 时序曲线。
    var curve: AnimationTimingCurve
    /// 触发条件 —— 不强制，缺省 `.onAppear`（与"视图出现即动画"直觉一致）。
    var trigger: AnimationTrigger

    init(
        property: AnimationProperty,
        from: Double,
        to: Double,
        durationMs: Int,
        delayMs: Int = 0,
        curve: AnimationTimingCurve = .easeInOut,
        trigger: AnimationTrigger = .onAppear
    ) {
        self.property = property
        self.from = from
        self.to = to
        self.durationMs = durationMs
        self.delayMs = delayMs
        self.curve = curve
        self.trigger = trigger
    }
}

// MARK: - Debug / Inspector 助手

extension AnimationTimingCurve {
    /// 给调试视图 / 日志用的紧凑标签（不参与 IR 形状）。
    var label: String {
        switch self {
        case .linear: return "linear"
        case .easeIn: return "easeIn"
        case .easeOut: return "easeOut"
        case .easeInOut: return "easeInOut"
        case .cubicBezier(let x1, let y1, let x2, let y2):
            return "cubicBezier(\(x1),\(y1),\(x2),\(y2))"
        case .spring(let response, let damping):
            return "spring(\(response),\(damping))"
        }
    }
}