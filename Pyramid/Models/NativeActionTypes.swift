import Foundation

/// 动画意图 —— Native IR 表达"想做什么动画"，不锁死具体实现。
///
/// SwiftUI renderer 后续会把它映射到 SwiftUI `.animation` / `.transition` /
/// `withAnimation` 等。本枚举只描述**意图**，不解析 HTML / CSS，不依赖 WebView。
///
/// 未来酒馆 / 角色卡表达 `fade` / `slide` / `scale` / `transition` 等动画诉求时，
/// Pyramid 把它归一成 `NativeAnimation` 后由原生动画系统接管 —— 与 CSS / DOM 解耦。
///
/// **独立成文件的原因**：app target（Xcode 显式文件列表）与 SPM 测试包共享这两个
/// 基础原语 —— RenderNode.nativeAction / MessageCard 按钮都要用；而完整的新 pipeline
/// 文件（NativeIR / TavernTranspiler 等）目前只进 SPM target。
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

/// Tavern → Native iOS 第三层 IR 触发的副作用。所有按钮 / 触发器通过 `NativeAction`
/// 表达意图，**不让 SwiftUI View 直接解析角色卡文本**。
///
/// 不依赖 Pyramid 固定业务概念（HP / 好感度 / 金币 等），路径即 JSON Pointer。
/// 角色卡想更新 "小手机电量" 时直接写 `.updateVariable(path: "/小手机电量", value: 73)`，
/// Pyramid 不替它判断这是 HP 还是别的。
///
/// 现阶段实现：
/// - `.updateVariable` / `.toggle` —— 经 `NativeActionDispatcher` 落到 `JSONPatchApplier`，
///   由 VariableStore 写入。
/// - `.navigate` / `.custom` —— 本期 renderer 不实现；dispatcher 返回 `false`，由调用方决定 fallback。
enum NativeAction: Equatable, Sendable {
    /// 替换 JSON Pointer 路径处的值（绝对替换语义）。失败（path 不存在 / 类型错）dispatcher 返回 `false`。
    case updateVariable(path: String, value: JSONValue)
    /// 翻转 JSON Pointer 路径处的 bool；非 bool → dispatcher 返回 `false`。
    case toggle(path: String)
    /// 跳转到目标（session / character / view）。本期 renderer 不实现；占位。
    case navigate(target: String)
    /// 自定义 key + payload；renderer / 上层 UI 决定如何解释。本期不实现。
    case custom(key: String, payload: [String: JSONValue])
}

/// 通用选择控件的一个选项。`value` 是提交到 VariableStore 的字符串值；`label` 是显示文案（nil → 用 value）。
struct NativeControlOption: Equatable, Sendable {
    var value: String
    var label: String?
}

/// 通用交互控件：文本输入（input）/ 单选（select）。
///
/// 与 `NativeAction` 同一设计原则 —— **零业务语义**：
/// - `path` 即 JSON Pointer，提交时把字符串值写入 VariableStore 对应位置；
/// - 不解释字段名、不限定选项集合、不预置任何模板；
/// - 由 `<NativeInput …/>` / `<NativeSelect …/>` token 解析产生（见 RenderNodeParser）。
struct NativeControl: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case input
        case select
    }
    var kind: Kind
    var label: String?
    var path: String
    /// input 的占位提示；select 为 nil。
    var placeholder: String?
    /// select 的选项集合；input 为空。
    var options: [NativeControlOption]
}
