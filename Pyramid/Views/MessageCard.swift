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
    var onCopy: () -> Void = {}
    var onEdit: () -> Void = {}
    var onRegenerate: () -> Void = {}
    var onDelete: () -> Void = {}
    var onToggleInclude: () -> Void = {}

    private static let collapseThreshold = 800
    @State private var expanded = false

    var body: some View {
        let isUser = message.role == .user
        let displayName: String = {
            if isUser { return "我" }
            if let c = character, !c.name.isEmpty { return c.name }
            return "助手"
        }()
        let avatarData: Data? = isUser ? userAvatarData : character?.avatarData

        VStack(alignment: .leading, spacing: 6) {
            headerRow(
                isUser: isUser,
                displayName: displayName,
                avatarData: avatarData
            )
            contentCard(isUser: isUser)
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal, 12)
    }

    // MARK: - 头部

    @ViewBuilder
    private func headerRow(isUser: Bool, displayName: String, avatarData: Data?) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if isUser {
                // 用户：时间靠左、楼层靠左、name 靠右；头像在最右
                Spacer(minLength: 0)
                metaTrailing(isUser: isUser)
                Text(displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                if showAvatar {
                    AvatarView(imageData: avatarData, name: displayName, size: 28)
                } else {
                    Spacer().frame(width: 28)
                }
            } else {
                // 助手：头像在最左、name 紧随其后，时间 / 楼层靠右
                if showAvatar {
                    AvatarView(imageData: avatarData, name: displayName, size: 28)
                } else {
                    Spacer().frame(width: 28)
                }
                Text(displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                metaTrailing(isUser: isUser)
            }
        }
    }

    @ViewBuilder
    private func metaTrailing(isUser: Bool) -> some View {
        HStack(spacing: 6) {
            if !message.isIncluded {
                Text("已排除")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemGray5), in: Capsule())
                    .overlay(
                        Capsule().stroke(Color(.systemGray3), lineWidth: 0.5)
                    )
            }
            Text("#\(floorNumber)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            if showTimestamp, let createdAt = message.createdAt {
                Text(createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 正文卡片

    @ViewBuilder
    private func contentCard(isUser: Bool) -> some View {
        let raw = liveContent ?? message.content
        // 通过 RenderEngine 加工：raw 永不被修改，每次都从 raw 重新计算。
        // 同一 (raw, context) → 相同 Result；context 改变 → SwiftUI 自动重绘。
        let context = RenderEngine.Context(
            isAssistant: message.role == .assistant,
            presetDisplayRegexIds: preset?.displayRegexIds ?? [],
            allDisplayRegexes: displayRegexes,
            hideTagStripEnabled: settings.hideTagStripEnabled,
            hideTags: settings.hideTags,
            markdownEnabled: preset?.enableMarkdown ?? settings.enableMarkdown
        )
        let cleaned = RenderEngine.render(raw: raw, context: context).cleanedText

        VStack(alignment: .leading, spacing: 6) {
            bodyContent(cleaned: cleaned, isUser: isUser)
            if let createdAt = message.createdAt, showTimestamp, isUser {
                Text(createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 6 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isUser ? Color.accentColor.opacity(0.12) : Color(.systemGray6))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isUser ? Color.accentColor.opacity(0.35) : Color(.systemGray4), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu { contextMenuButtons(isUser: isUser) }
    }

    @ViewBuilder
    private func bodyContent(cleaned: String, isUser: Bool) -> some View {
        // 渲染前折叠判断：按 cleaned 长度阈值，>800 默认折叠到 800 + 「…」。
        let isLong = cleaned.count > Self.collapseThreshold
        let visibleText: String = (isLong && !expanded)
            ? String(cleaned.prefix(Self.collapseThreshold)) + "…"
            : cleaned

        Group {
            // 三态：预设 nil → 用全局；预设 Bool → 用预设。
            if markdownEnabled(settings: settings, preset: preset) {
                MarkdownTextView(text: visibleText)
            } else {
                Text(visibleText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.primary)

        if isLong {
            Button(expanded ? "收起" : "展开") {
                withAnimation { expanded.toggle() }
            }
            .font(.caption)
            .foregroundStyle(Color.accentColor)
        }
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