import Foundation

// `NativeAnimation` / `NativeAction` 定义在 `NativeActionTypes.swift` ——
// app target 与 SPM 测试包共享的基础原语（RenderNode.nativeAction / MessageCard
// 按钮都依赖它们，而本文件目前只进 SPM target）。

/// Tavern → Native iOS 第三层中间表示（IR）。
///
/// **定位**：
/// - 纯数据（Foundation only），不依赖 SwiftUI；可在 Linux SPM 单测。
/// - 描述"角色卡想表达什么"，**不**描述"如何显示"。
/// - 与 `RenderNode` / `DisplayBlock` 等旧 IR **完全平行**，互不依赖；旧 IR
///   继续作为 legacy compat path 走 `MessageCard`，新 IR 由本枚举驱动新 renderer。
///
/// **不引入业务模板**：原语是通用的 text / number / progress / field / list /
/// container / button —— **不存在** HPComponent / AffectionComponent /
/// GoldComponent 之类的 Pyramid 业务组件。语义由角色卡数据与未来 Capability 层决定。
///
/// **闭环**：
/// ```
/// 角色卡文本 / JSONValue 树
///   ↓ NativeIRProjector.project(statData:)
/// NativeIRNode 树
///   ↓ SwiftUI renderer
/// 用户点击 button
///   ↓ NativeActionDispatcher.dispatch(action, to: &tree)
/// 变量树 mutation
///   ↓ NativeIRProjector.project(statData:) 重新跑
/// 新 NativeIRNode 树
/// ```
///
/// **未来扩展**：
/// - 通过 `container(...animation:)` 承载动画意图；新 case 即可，不改既有形状。
/// - 通过 `.button(label:action:)` 让 SwiftUI 事件 → Action → 变量 mutation 形成闭环。
indirect enum NativeIRNode: Equatable, Sendable {
    /// 纯文本片段。
    case text(content: String)
    /// 数值（可带可选 label）。label = `nil` → 纯数字；label = `"金币"` → UI 自渲染成 "50 (金币)"。
    case number(value: Double, label: String?)
    /// 通用进度条：`max == nil` → UI 不画上限标线。
    ///
    /// **不携带 Pyramid 业务语义**：本枚举不区分 HP / 好感度 / 比率 / 通用 等。
    /// 谁是 progress 由**数据形状**（`{value, max}` 显式对）决定，不由字段名决定。
    case progress(label: String, value: Double, max: Double?)
    /// label-value 对（最朴素呈现）。
    case field(label: String, value: String)
    /// 有序列表；元素是任意 IR 节点。
    case list(items: [NativeIRNode])
    /// 带标题的容器 / 嵌套分组。`animation` 可选承载容器级动画意图。
    case container(title: String, children: [NativeIRNode], animation: NativeAnimation?)
    /// 按钮：label 给 SwiftUI 渲染，action 给 dispatcher 执行。
    /// 是 Native IR 中唯一允许触发 `NativeAction` 的载体。
    case button(label: String, action: NativeAction)
}