import Foundation

/// 动画意图 —— Native IR 表达"想做什么动画"，不锁死具体实现。
///
/// SwiftUI renderer 后续会把它映射到 SwiftUI `.animation` / `.transition` /
/// `withAnimation` 等。本枚举只描述**意图**，不解析 HTML / CSS，不依赖 WebView。
///
/// 未来酒馆 / 角色卡表达 `fade` / `slide` / `scale` / `transition` 等动画诉求时，
/// Pyramid 把它归一成 `NativeAnimation` 后由原生动画系统接管 —— 与 CSS / DOM 解耦。
struct NativeAnimation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case fade
        case slide
        case scale
        case transition
    }
    var kind: Kind
    /// 可选持续时间（毫秒）；`nil` 表示让 renderer 选默认值。
    var durationMs: Int?
}

/// Native IR 触发的副作用。所有按钮 / 触发器通过 `NativeAction` 表达意图，
/// **不让 SwiftUI View 直接解析角色卡文本**。
///
/// 不依赖 Pyramid 固定业务概念（HP / 好感度 / 金币 等），路径即 JSON Pointer。
/// 角色卡想更新 "小手机电量" 时直接写 `.updateVariable(path: "/小手机电量", value: 73)`，
/// Pyramid 不替它判断这是 HP 还是别的。
///
/// 现阶段实现：
/// - `.updateVariable` / `.toggle` —— 直接落到 `JSONPatchApplier`，由 VariableStore 写入。
/// - `.navigate` / `.custom` —— 本期 renderer 不实现；dispatcher 返回 `false`，由调用方决定 fallback。
enum NativeAction: Equatable, Sendable {
    /// 替换 JSON Pointer 路径处的值。失败（path 不存在 / 类型错）dispatcher 返回 `false`。
    case updateVariable(path: String, value: JSONValue)
    /// 翻转 JSON Pointer 路径处的 bool；非 bool → dispatcher 返回 `false`。
    case toggle(path: String)
    /// 跳转到目标（session / character / view）。本期 renderer 不实现；占位。
    case navigate(target: String)
    /// 自定义 key + payload；renderer / 上层 UI 决定如何解释。本期不实现。
    case custom(key: String, payload: [String: JSONValue])
}

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