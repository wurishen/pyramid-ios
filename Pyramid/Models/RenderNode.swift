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
/// - `.status(hp:affection:)`：酒馆式角色状态面板，由 StatusView 渲染。
/// - `.statusPlaceholder(snapshot)`：P3 native transpile —— `<StatusPlaceHolderImpl/>` 节点，
///   数据来自 VariableStore；UI 列所有变量，空时显示「状态（等待变量）」。
/// - `.variableUpdate(summary)`：P3 native transpile —— `<<UpdateVariable>>[…JSON Patch…]<</UpdateVariable>>`
///   块解析后写入 VariableStore 后产出的可折叠摘要节点。
enum RenderNode: Equatable, Sendable {
    /// 普通文本，可能含 Markdown；具体渲染由 SwiftUI 视图层决定。
    case text(String)
    /// 角色状态：HP + 好感度；解析失败时调用方应降级为 `.text`。
    case status(hp: Int, affection: Int)
    /// 状态占位符：来自 VariableStore 的当前变量快照。
    /// UI 列所有变量；snapshot 为空 → 显示「状态（等待变量）」。
    case statusPlaceholder(snapshot: [VariableEntry])
    /// 变量更新摘要：一条 UI 折叠组，列出本次 apply 的 patch 数与受影响的 path。
    case variableUpdate(summary: VariableUpdateSummary)

    /// `.variableUpdate` 的摘要内容。
    struct VariableUpdateSummary: Equatable, Sendable {
        var appliedCount: Int
        var affectedPaths: [String]
    }
}

/// RenderNode 的有序集合。同一段 cleanedText 经过 RenderNodeParser 可以产生不同 RenderTree；
/// MessageCard 按顺序遍历渲染。
struct RenderTree: Equatable, Sendable {
    var nodes: [RenderNode]

    init(nodes: [RenderNode] = []) {
        self.nodes = nodes
    }

    /// 把所有 `.text` 节点的字符串拼回一段纯文本，便于折叠判断 / 调试。
    /// `.status` 等结构化节点不参与拼接。
    var flattenedText: String {
        nodes.compactMap { node -> String? in
            if case let .text(s) = node { return s }
            return nil
        }.joined()
    }
}
