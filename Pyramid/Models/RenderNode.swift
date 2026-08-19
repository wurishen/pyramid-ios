import Foundation

/// 渲染节点：RenderEngine 输出 → MessageCard 消费的最小单位。
///
/// 设计原则：
/// - **纯数据**：只含 Foundation 类型，不依赖 SwiftUI / UIKit，可独立单测。
/// - **不存第二份消息**：节点本身不持有 raw 或 ChatMessage 引用，按值传递。
/// - **不做缓存**：每次 RenderEngine 重新生成；调用方（SwiftUI 视图）按值相等自动 diff。
///
/// 第一阶段只支持两种节点：
/// - `.text(String)`：普通文本（可能含 Markdown），由 MarkdownTextView 渲染。
/// - `.status(hp:affection:)`：角色状态面板，由 StatusView 渲染。
///
/// 后续 Tavern 标签（变量表、按钮、骰子等）按需扩展，不在本阶段范围。
enum RenderNode: Equatable, Sendable {
    /// 普通文本，可能含 Markdown；具体渲染由 SwiftUI 视图层决定。
    case text(String)
    /// 角色状态：HP + 好感度；解析失败时调用方应降级为 `.text`。
    case status(hp: Int, affection: Int)
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