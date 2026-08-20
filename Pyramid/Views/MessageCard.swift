import SwiftUI

/// 酒馆式「回复视窗」：每条消息是一张完整卡片，不再使用 iMessage 左右气泡布局。
///
/// 卡片组成（自上而下）：
/// - 头部：头像 + 角色名 / 用户名 + 楼层号 + 时间戳（用户 / 助手视觉区分）
/// - 正文：渲染后的内容（MarkdownTextView）；超长自动折叠（>800 字）
///
/// 渲染管线仅作用于展示层：`MessageRenderer.preprocess(...)`（显示用正则 + 隐藏标签剥离）
/// → `MarkdownTextView(text:)` 块级 Markdown 排版。原始 `message.content` 始终保留，
/// 复制 / 编辑 / 重新生成 / 发送 API 一律使用原文（参见 `liveContent` 注释）。
struct MessageCard: View {
    let message: ChatMessage
    /// 流式期间外部传入的实时内容；非 nil 时用它渲染（覆盖 message.content）。
    /// 只有 id == viewModel.streamingMessageID 的那条卡片会拿到非 nil。
    var liveContent: String? = nil
    var floorNumber: Int = 0
    var isSending = false
    var compact = false
    var showTimestamp = false
    var showAvatar = false
    /// 当前会话绑定的角色（用于取头像 / 名字）；nil 时助手按系统角色渲染。
    var character: Character? = nil
    var userAvatarData: Data? = nil
    var preset: Preset? = nil
    var settings: AppSettings
    var displayRegexes: [DisplayRegex] = []
    /// P3 native transpile：会话级 MVU 变量存储 + sessionId，二者必须同时给出。
    /// nil 表示纯渲染（fixture / 单测场景）。
    var variableStore: VariableStore? = nil
    var sessionId: UUID? = nil
    var onCopy: () -> Void = {}
    var onEdit: () -> Void = {}
    var onRegenerate: () -> Void = {}
    var onDelete: () -> Void = {}
    var onToggleInclude: () -> Void = {}

    private static let collapseThreshold = 800
    @State private var expanded = false
    @State private var showRenderInspector = false

    var body: some View {
        let isUser = message.role == .user
        let displayName: String = {
            if isUser { return "我" }
            if let c = character, !c.name.isEmpty { return c.name }
            return "助手"
        }()
        let avatarData: Data? = isUser ? userAvatarData : character?.avatarData
        let raw = liveContent ?? message.content
        // 界面整体缩放档位（来自 AppSettings.uiScale.factor）。
        // 与「紧凑模式」叠加：先按 scale 调基准，再叠加紧凑模式的间距减项。
        let scale = settings.uiScale.factor
        // 通过 RenderEngine 加工：raw 永不被修改，每次都从 raw 重新计算。
        // 同一 (raw, context) → 相同 Result；context 改变 → SwiftUI 自动重绘。
        let context = RenderEngine.Context(
            isAssistant: message.role == .assistant,
            presetDisplayRegexIds: preset?.displayRegexIds ?? [],
            allDisplayRegexes: displayRegexes,
            hideTagStripEnabled: settings.hideTagStripEnabled,
            hideTags: settings.hideTags,
            markdownEnabled: preset?.enableMarkdown ?? settings.enableMarkdown,
            variableStore: variableStore,
            sessionId: sessionId
        )
        let result = RenderEngine.render(raw: raw, context: context)

        VStack(alignment: .leading, spacing: 6 * scale) {
            headerRow(
                isUser: isUser,
                displayName: displayName,
                avatarData: avatarData,
                scale: scale
            )
            contentCard(isUser: isUser, raw: raw, tree: result.tree, scale: scale)
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal, 12 * scale)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.5) {
            showRenderInspector = true
        }
        .sheet(isPresented: $showRenderInspector) {
            RenderInspectorView(raw: raw, result: result, context: context)
        }
    }

    // MARK: - 头部

    @ViewBuilder
    private func headerRow(isUser: Bool, displayName: String, avatarData: Data?, scale: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 8 * scale) {
            if isUser {
                // 用户：时间靠左、楼层靠左、name 靠右；头像在最右
                Spacer(minLength: 0)
                metaTrailing(isUser: isUser, scale: scale)
                Text(displayName)
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                if showAvatar {
                    AvatarView(imageData: avatarData, name: displayName, size: 28 * scale)
                } else {
                    Spacer().frame(width: 28 * scale)
                }
            } else {
                // 助手：头像在最左、name 紧随其后，时间 / 楼层靠右
                if showAvatar {
                    AvatarView(imageData: avatarData, name: displayName, size: 28 * scale)
                } else {
                    Spacer().frame(width: 28 * scale)
                }
                Text(displayName)
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                metaTrailing(isUser: isUser, scale: scale)
            }
        }
    }

    @ViewBuilder
    private func metaTrailing(isUser: Bool, scale: CGFloat) -> some View {
        HStack(spacing: 6 * scale) {
            if !message.isIncluded {
                Text("已排除")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6 * scale)
                    .padding(.vertical, 2 * scale)
                    .background(Color(.systemGray5), in: Capsule())
                    .overlay(
                        Capsule().stroke(Color(.systemGray3), lineWidth: 0.5)
                    )
            }
            Text("#\(floorNumber)")
                .font(.system(size: 11 * scale, design: .monospaced))
                .foregroundStyle(.tertiary)
            if showTimestamp, let createdAt = message.createdAt {
                Text(createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 正文卡片

    @ViewBuilder
    private func contentCard(isUser: Bool, raw: String, tree: RenderTree, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            bodyContent(tree: tree, isUser: isUser, scale: scale)
            if let createdAt = message.createdAt, showTimestamp, isUser {
                Text(createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, (compact ? 6 : 10) * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isUser ? Color.accentColor.opacity(0.12) : Color(.systemGray6))
        .overlay(
            RoundedRectangle(cornerRadius: 12 * scale)
                .stroke(isUser ? Color.accentColor.opacity(0.35) : Color(.systemGray4), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12 * scale))
        .contextMenu { contextMenuButtons(isUser: isUser) }
    }

    @ViewBuilder
    private func bodyContent(tree: RenderTree, isUser: Bool, scale: CGFloat) -> some View {
        // 渲染前折叠判断：按全部 .text 节点的拼回长度判断，>800 默认折叠。
        // 折叠只影响 .text 节点；.status 节点不受折叠限制。
        let flattened = tree.flattenedText
        let isLong = flattened.count > Self.collapseThreshold

        VStack(alignment: .leading, spacing: 8 * scale) {
            ForEach(Array(tree.nodes.enumerated()), id: \.offset) { _, node in
                renderNode(node, isLong: isLong, scale: scale)
            }
        }

        if isLong {
            Button(expanded ? "收起" : "展开") {
                withAnimation { expanded.toggle() }
            }
            .font(.system(size: 12 * scale))
            .foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private func renderNode(_ node: RenderNode, isLong: Bool, scale: CGFloat) -> some View {
        switch node {
        case let .text(text):
            textNodeView(text, isLong: isLong, scale: scale)
        case let .status(hp, affection):
            // .status 节点不受折叠影响；视觉上本身是一个紧凑面板。
            // 单独 .scaleEffect 而不是改内部字面量，让面板整体放大。
            StatusView(hp: hp, affection: affection)
                .scaleEffect(scale, anchor: .topLeading)
        case let .statusPlaceholder(snapshot):
            // P3 native transpile：`<StatusPlaceHolderImpl/>` → 列当前会话所有变量。
            // snapshot 空 → 显示「状态（等待变量）」，与 fixture ios_render_boundary 对齐。
            StatusPlaceholderView(snapshot: snapshot, scale: scale)
        case let .variableUpdate(summary):
            // P3 native transpile：`<UpdateVariable>…</UpdateVariable>` 块 → 可折叠摘要。
            VariableUpdateView(summary: summary, scale: scale)
        }
    }

    @ViewBuilder
    private func textNodeView(_ text: String, isLong: Bool, scale: CGFloat) -> some View {
        // 长文折叠时截断 .text 节点；保留所有节点原顺序。
        let visibleText: String = (isLong && !expanded)
            ? String(text.prefix(Self.collapseThreshold)) + "…"
            : text

        Group {
            // 三态：预设 nil → 用全局；预设 Bool → 用预设。
            if markdownEnabled(settings: settings, preset: preset) {
                MarkdownTextView(text: visibleText, uiScale: scale)
            } else {
                Text(visibleText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: 17 * scale))
            }
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func contextMenuButtons(isUser: Bool) -> some View {
        Button(action: onCopy) {
            Label("复制", systemImage: "doc.on.doc")
        }
        if !isSending {
            Button(action: onEdit) {
                Label("编辑", systemImage: "pencil")
            }
            Button(action: onToggleInclude) {
                Label(
                    message.isIncluded ? "不包含在上下文" : "包含在上下文",
                    systemImage: message.isIncluded ? "eye.slash" : "eye"
                )
            }
            if !isUser {
                Button(action: onRegenerate) {
                    Label("重新生成", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func markdownEnabled(settings: AppSettings, preset: Preset?) -> Bool {
        if let preset = preset, let flag = preset.enableMarkdown {
            return flag
        }
        return settings.enableMarkdown
    }
}

// MARK: - SwiftUI Preview

#Preview("MessageCard - assistant with regex applied") {
    ScrollView {
        VStack(spacing: 12) {
            MessageCard(
                message: ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: "Hello **World**",
                    createdAt: Date(),
                    isIncluded: true
                ),
                floorNumber: 1,
                isSending: false,
                compact: false,
                showTimestamp: true,
                showAvatar: true,
                character: Character(name: "助手", description: ""),
                userAvatarData: nil,
                preset: nil,
                settings: AppSettings(),
                displayRegexes: [
                    DisplayRegex(name: "World → Pyramid", pattern: "World", replacement: "Pyramid", enabled: true)
                ]
            )

            MessageCard(
                message: ChatMessage(
                    id: UUID(),
                    role: .user,
                    content: "Hello from user",
                    createdAt: Date(),
                    isIncluded: true
                ),
                floorNumber: 2,
                isSending: false,
                compact: false,
                showTimestamp: true,
                showAvatar: true,
                character: Character(name: "助手", description: ""),
                userAvatarData: nil,
                preset: nil,
                settings: AppSettings(),
                displayRegexes: []
            )

            MessageCard(
                message: ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: """
                    # Markdown sample

                    Long content for collapse testing — this should trigger the
                    >800 char threshold and show the collapse toggle button at the end.
                    """ + String(repeating: "padding line for length ", count: 60),
                    createdAt: Date(),
                    isIncluded: true
                ),
                floorNumber: 3,
                isSending: false,
                compact: false,
                showTimestamp: false,
                showAvatar: false,
                character: nil,
                userAvatarData: nil,
                preset: nil,
                settings: AppSettings(),
                displayRegexes: []
            )
        }
        .padding()
    }
}

#Preview("MessageCard - markdown disabled (plain text)") {
    let plain = AppSettings()
    // 直接覆盖 @AppStorage 不方便；用 SwiftUI 上下文传入 enableMarkdown=false 的 preset。
    let preset = Preset(name: "preview", enableMarkdown: false)
    return MessageCard(
        message: ChatMessage(
            id: UUID(),
            role: .assistant,
            content: "Plain text rendering — no **markdown** here.",
            createdAt: nil,
            isIncluded: true
        ),
        floorNumber: 1,
        isSending: false,
        compact: false,
        showTimestamp: false,
        showAvatar: false,
        character: nil,
        userAvatarData: nil,
        preset: preset,
        settings: plain,
        displayRegexes: []
    )
}

#Preview("MessageCard - assistant with status block") {
    MessageCard(
        message: ChatMessage(
            id: UUID(),
            role: .assistant,
            content: "你推开酒馆的木门。\n\n<status>\nHP: 80\n好感度: 65\n</status>\n\n老板抬头看了你一眼。",
            createdAt: nil,
            isIncluded: true
        ),
        floorNumber: 2,
        isSending: false,
        compact: false,
        showTimestamp: false,
        showAvatar: true,
        character: nil,
        userAvatarData: nil,
        preset: nil,
        settings: AppSettings(),
        displayRegexes: []
    )
    .padding()
}

// MARK: - P3 native transpile 节点视图

/// `<StatusPlaceHolderImpl/>` → 状态占位面板：按 JSON Pointer 第一段自动分组，
/// 数字用更醒目的样式；空时显示「状态（等待变量）」。
///
/// 设计目标：酒馆「状态栏」感 —— 不是调试器的扁平 key-value 表。
///   /时间               → 顶层键，单独成行
///   /玩家/当前所在地    ┐
///   /玩家/好感          ┘  → 「玩家」分组，2 行
///
/// 边界：
/// - 不读 `message.content`，不改 `RenderNode` / `VariableStore` 协议。
/// - 仅消费 `RenderNode.statusPlaceholder(snapshot:)` 给的 `[VariableEntry]`。
struct StatusPlaceholderView: View {
    let snapshot: [VariableEntry]
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            header
            if snapshot.isEmpty {
                Text("状态（等待变量）")
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4 * scale)
            } else {
                ForEach(Array(Self.group(snapshot).enumerated()), id: \.offset) { _, group in
                    StatusPlaceholderGroupView(group: group, scale: scale)
                }
            }
        }
        .padding(10 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10 * scale))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * scale)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 6 * scale) {
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 13 * scale))
            Text("状态")
                .font(.system(size: 13 * scale, weight: .semibold))
        }
        .foregroundStyle(.secondary)
    }

    /// 按 JSON Pointer 第一段分组。顶层键（如 `/时间`）自己成一组，组内只有 1 条；
    /// 嵌套键（如 `/玩家/当前所在地`）归入 `玩家` 组，组内按 path 余段排序。
    /// 不递归 / 排序依赖 `VariableStoreFlattener` 已经按 key 排序好的结果。
    fileprivate static func group(_ entries: [VariableEntry]) -> [StatusPlaceholderGroup] {
        var groups: [StatusPlaceholderGroup] = []
        var indexByTitle: [String: Int] = [:]
        for entry in entries {
            let segments = entry.path.split(separator: "/").map(String.init)
            // path 形如 "/时间" / "/玩家/当前所在地" —— split 后第一段就是组名。
            guard let head = segments.first, !head.isEmpty else { continue }
            let leafSegments = Array(segments.dropFirst())
            let leafPath = leafSegments.isEmpty ? head : leafSegments.joined(separator: "/")
            if let i = indexByTitle[head], groups[i].title == head {
                groups[i].entries.append(StatusPlaceholderEntry(leafPath: leafPath, displayValue: entry.displayValue))
            } else {
                indexByTitle[head] = groups.count
                groups.append(StatusPlaceholderGroup(
                    title: head,
                    entries: [StatusPlaceholderEntry(leafPath: leafPath, displayValue: entry.displayValue)]
                ))
            }
        }
        return groups
    }
}

/// 一个分组（如「玩家」）：组内多条叶子变量。
struct StatusPlaceholderGroup: Equatable {
    let title: String
    var entries: [StatusPlaceholderEntry]
}

/// 组内一行：叶路径（去掉组名前缀）+ 显示值。
struct StatusPlaceholderEntry: Equatable {
    let leafPath: String
    let displayValue: String
}

/// 一个分组的视觉：组标题（小、灰）+ 行列表。
/// 顶层键（组内只有 1 条，且 leafPath == title）隐藏组标题，避免重复（路径 = 组名）。
private struct StatusPlaceholderGroupView: View {
    let group: StatusPlaceholderGroup
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            if !shouldHideTitle {
                Text(group.title)
                    .font(.system(size: 11 * scale, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 1 * scale)
            }
            ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                row(entry)
            }
        }
    }

    /// 顶层键（如 `/时间` → 组「时间」+ 1 条 leafPath=「时间」）标题与 leaf 名相同，隐藏重复。
    private var shouldHideTitle: Bool {
        group.entries.count == 1 && group.entries[0].leafPath == group.title
    }

    @ViewBuilder
    private func row(_ entry: StatusPlaceholderEntry) -> some View {
        let isNumeric = Self.isNumeric(entry.displayValue)
        HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
            Text(entry.leafPath)
                .font(.system(size: 12 * scale, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8 * scale)
            Text(entry.displayValue)
                .font(.system(
                    size: (isNumeric ? 14 : 13) * scale,
                    weight: isNumeric ? .semibold : .regular,
                    design: isNumeric ? .monospaced : .default
                ))
                .foregroundStyle(isNumeric ? Color.accentColor : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.leading, shouldHideTitle ? 0 : 6 * scale)
    }

    /// 简单判定显示值是不是数字。`VariableStoreFlattener.format` 会把 int/double
    /// 编为纯数字字符串、bool 编为「是 / 否」、null 编为 `—`。这里���看是不是纯数字。
    private static func isNumeric(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return Double(s) != nil
    }
}

/// `<UpdateVariable>…</UpdateVariable>` → 可折叠摘要节点：本次 apply 的 op 数 + 受影响的 path 列表。
struct VariableUpdateView: View {
    let summary: RenderNode.VariableUpdateSummary
    let scale: CGFloat
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if summary.affectedPaths.isEmpty {
                Text("无路径变更")
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2 * scale)
            } else {
                ForEach(Array(summary.affectedPaths.enumerated()), id: \.offset) { _, path in
                    Text(path)
                        .font(.system(size: 12 * scale, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack(spacing: 6 * scale) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12 * scale))
                Text("变量更新（\(summary.appliedCount) 条）")
                    .font(.system(size: 12 * scale, weight: .medium))
            }
            .foregroundStyle(Color.accentColor)
        }
        .padding(8 * scale)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8 * scale))
    }
}