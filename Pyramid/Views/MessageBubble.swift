import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var floorNumber: Int = 0
    var isSending = false
    var compact = false
    var showTimestamp = false
    var showAvatar = false
    var userAvatarData: Data? = nil
    var onCopy: () -> Void = {}
    var onEdit: () -> Void = {}
    var onRegenerate: () -> Void = {}
    var onDelete: () -> Void = {}

    private static let collapseThreshold = 800
    @State private var expanded = false

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

    private var bubbleContent: some View {
        Group {
            if message.role == .assistant {
                assistantContent
            } else {
                Text(message.content)
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

    private var assistantContent: some View {
        let isLong = message.content.count > Self.collapseThreshold
        return VStack(alignment: .leading, spacing: 6) {
            MarkdownTextView(text: expanded ? message.content : collapsedContent)
            if isLong {
                Button(expanded ? "收起" : "展开") {
                    withAnimation { expanded.toggle() }
                }
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var collapsedContent: String {
        guard message.content.count > Self.collapseThreshold else { return message.content }
        let end = message.content.index(message.content.startIndex, offsetBy: Self.collapseThreshold)
        return String(message.content[..<end]) + "…"
    }
}
