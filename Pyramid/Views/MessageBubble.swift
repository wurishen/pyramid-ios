import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var floorNumber: Int = 0
    var isSending = false
    var compact = false
    var showTimestamp = false
    var showAvatar = false
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

    /// 渲染后的文本：原始 content → 显示用正则 → 隐藏标签剥离 → Markdown / 纯文本。
    /// 只用于显示；onCopy/onEdit/onRegenerate 始终传 `message.content` 原文。
    private var renderedAttributed: AttributedString {
        MessageRenderer.render(
            MessageRenderer.Inputs(
                raw: message.content,
                role: message.role,
                settings: settings,
                preset: preset,
                displayRegexes: displayRegexes
            )
        )
    }

    private var renderedPlain: String {
        String(renderedAttributed.characters[...])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 48)
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if message.role == .assistant {
                        Text("\(floorNumber)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    // 被排除出上下文的消息加一个小标签，让用户一眼看出 AI 看不到这条。
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
                    bubbleContent
                }
                HStack(spacing: 6) {
                    if message.role == .user {
                        if let createdAt = message.createdAt, showTimestamp {
                            Text(createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text("\(floorNumber)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        if let createdAt = message.createdAt, showTimestamp {
                            Text(createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            if message.role == .user {
                if showAvatar {
                    AvatarView(imageData: userAvatarData, name: "我", size: 28)
                }
            } else {
                Spacer(minLength: 48)
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        Group {
            if message.role == .assistant {
                assistantContent
            } else {
                Text(renderedAttributed)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 4 : 8)
        .background(message.role == .user ? Color.accentColor : Color(.systemGray5))
        .foregroundStyle(message.role == .user ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 14))
        .contextMenu {
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
                if message.role == .assistant {
                    Button(action: onRegenerate) {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var assistantContent: some View {
        let content = renderedPlain
        let isLong = content.count > Self.collapseThreshold
        VStack(alignment: .leading, spacing: 6) {
            if isLong && !expanded {
                Text(AttributedString(String(content.prefix(Self.collapseThreshold)) + "…"))
                    .textSelection(.enabled)
            } else {
                Text(renderedAttributed)
                    .textSelection(.enabled)
            }
            if isLong {
                Button(expanded ? "收起" : "展开") {
                    withAnimation { expanded.toggle() }
                }
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}
