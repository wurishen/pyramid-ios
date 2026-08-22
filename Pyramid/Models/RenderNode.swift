import Foundation

/// 渲染节点：RenderEngine 输出 → MessageCard 消费的最小单位。
///
/// 设计原则：
/// - **纯数据**：只含 Foundation 类型，不依赖 SwiftUI / UIKit，可独立单测。
/// - **不存第二份消息**：节点本身不持有 raw 或 ChatMessage 引用，按值传递。
/// - **不做缓存**：每次 RenderEngine 重新生成；调用方（SwiftUI 视图）按值相等自动 diff。
///
/// P3 起支持的节点：
/// - `.text(String)`：普通文本（可能含 Markdown），由 MarkdownTextView 渲染。
/// - `.status(hp:affection:)`：酒馆式角色状态面板（仅 HP + 好感度 两个整数），由 StatusView 渲染。
///   仍保留作 fast-path；只在 `<status>` 块**只含**这两个字段且都为整数时走此节点。
/// - `.statusFields([StatusField])`：通用的 `<status>` 状态面板 —— 任意 key/value 列表，
///   包含 HP / 好感度 / 金币 / 法力 / 饱腹 等模型可能产出的任何状态字段。
///   至少识别出一个字段时由 `StatusFieldsView` 渲染。本节点只携带数据，
///   Pyramid 不在此处注入「HP 颜色梯度」之类的固定 UI 语义 —— 那是
///   `.status(hp:affection:)` 节点对应 `StatusView` 的责任。
/// - `.statusPlaceholder(statData)`：P3 native transpile —— `<StatusPlaceHolderImpl/>` 节点，
///   数据来自 VariableStore 的当前 session 整棵 `JSONValue` 树。UI 走
///   `NativeDisplayModelProjector.project(statData:)` 纯函数投影；**不**走拍平后的
///   `[VariableEntry]` 路径（那会把嵌套结构压扁，丢失 group / section 等原语）。
/// - `.variableUpdate(summary)`：P3 native transpile —— `<UpdateVariable>…</UpdateVariable>`
///   （canonical 单 `<`）块解析后写入 VariableStore 后产出的可折叠摘要节点；旧数据里
///   `<<UpdateVariable>>…<</UpdateVariable>>` 双尖括号拼写由 `RenderNodeParser` 兼容处理。
enum RenderNode: Equatable, Sendable {
    /// 普通文本，可能含 Markdown；具体渲染由 SwiftUI 视图层决定。
    case text(String)
    /// 角色状态（fast-path）：仅 HP + 好感度 两个整数，调用方应使用 StatusView 渲染。
    case status(hp: Int, affection: Int)
    /// 状态占位符：来自 VariableStore 的当前 session 整棵 `JSONValue` 树。
    /// 树就是变量树本身——**不**预置任何"时间/位置/选项"等固定栏目，
    /// 树上有什么键，UI `NativeDisplayModelProjector.project(statData:)` 就产什么 block。
    /// 树空 → `statData` = `.object([:])` → UI 显示「状态（等待变量）」。
    case statusPlaceholder(statData: JSONValue)
    /// 变量更新摘要：一条 UI 折叠组，列出本次 apply 的 patch 数与受影响的 path。
    case variableUpdate(summary: VariableUpdateSummary)
    /// 通用 `<status>` 面板：模型原始输出里任意 key/value 字段。
    case statusFields([StatusField])
    /// P6 deferred 显示层产物：角色卡 Regex Script 替换结果中无法安全原生转换的部分
    /// （HTML / CSS / 远程脚本标记等）。**原文完整保留** —— 绝不静默丢弃；UI 以折叠块
    /// 展示。内容不进入文本流、不参与后续 regex / Markdown / transpile（防重复处理）。
    case deferredResidual(MessageRendererCore.DeferredResidual)
    /// P6 通用交互表达：`<NativeAction label kind path value/>` 自闭合 token。
    ///
    /// **非 HTML、无 JS/CSS** —— 这是 Pyramid 定义的声明式交互原语，让角色卡 /
    /// Regex replacement 能在不引入浏览器执行环境的前提下表达「按钮 → 动作」。
    /// `action` 交给 `NativeActionDispatcher` 执行，形成
    /// 「点击 → NativeAction → 变量树 mutation → 重新投影 Native IR」闭环。
    /// 解析失败（缺属性 / 未知 kind）降级为 `.text(原文)`，绝不丢内容。
    case nativeAction(label: String, action: NativeAction)
    /// P6 通用交互控件：`<NativeInput …/>`（文本输入）/ `<NativeSelect …/>`（单选）。
    /// 与 nativeAction 同一原则 —— path 即 JSON Pointer，提交写入 VariableStore；
    /// 零业务语义、无固定模板。解析失败降级 `.text(原文)` 保真。
    case nativeControl(NativeControl)

    /// `.variableUpdate` 的摘要内容。
    struct VariableUpdateSummary: Equatable, Sendable {
        var appliedCount: Int
        var affectedPaths: [String]
    }
}

/// `.statusFields` 节点的字段条目。保留文本原文（不强制数字），由 UI 决定显示。
struct StatusField: Equatable, Sendable, Hashable, Identifiable {
    var label: String
    var value: String
    var id: String { "\(label)=\(value)" }
}

/// RenderNode 的有序集合。同一段 cleanedText 经过 RenderNodeParser 可以产生不同 RenderTree；
/// MessageCard 按顺序遍历渲染。
struct RenderTree: Equatable, Sendable {
    var nodes: [RenderNode]

    init(nodes: [RenderNode] = []) {
        self.nodes = nodes
    }

    /// 把所有 `.text` 节点的字符串拼回一段纯文本，便于折叠判断 / 调试。
    /// `.deferredResidual` 的原文参与拼接（超长残留同样触发正文折叠）；
    /// 其余结构化节点不参与。
    var flattenedText: String {
        nodes.compactMap { node -> String? in
            switch node {
            case let .text(s):
                return s
            case let .deferredResidual(r):
                return r.replacement
            default:
                return nil
            }
        }.joined()
    }
}
