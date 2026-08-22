import SwiftUI

// P10: Native IR → SwiftUI 原生视图渲染器（端到端闭环）。

/// NativeIRNode → SwiftUI 视图渲染入口。
struct NativeView: View {
    let node: NativeIRNode
    var variableStore: VariableStore? = nil
    var sessionId: UUID? = nil
    var scale: CGFloat = 1.0

    var body: some View {
        NodeRenderer(node: node,
                    variableStore: variableStore,
                    sessionId: sessionId,
                    scale: scale)
    }
}

// MARK: - 递归节点渲染器
private struct NodeRenderer: View {
    let node: NativeIRNode
    var variableStore: VariableStore? = nil
    var sessionId: UUID? = nil
    var scale: CGFloat = 1.0

    private var currentTree: JSONValue {
        guard let store = variableStore, let sid = sessionId else { return .object([:]) }
        return store.raw(forSession: sid)
    }

    var body: some View {
        StoreObserver(store: variableStore) { render(node) }
    }

    private func render(_ node: NativeIRNode) -> AnyView {
        switch node {
        case .text(let content):
            return AnyView(TextView(content: content, scale: scale))
        case .number(let value, let label):
            return AnyView(NumberView(value: value, label: label, scale: scale))
        case .progress(let label, let value, let max):
            return AnyView(NatProgressView(label: label, value: value, max: max, scale: scale))
        case .field(let label, let value):
            return AnyView(NatFieldView(label: label, value: value, scale: scale))
        case .list(let items):
            return AnyView(Text("\(items.count) items"))
        case .container(let title, let children, _):
            return AnyView(Text("container \(title) \(children.count)"))
        case .button(let label, _):
            return AnyView(Text("button \(label)"))
        case .textInput(let label, let path, _):
            return AnyView(Text("input \(label ?? "") \(path)"))
        case .selection(let label, let path, let options):
            return AnyView(Text("selection \(label ?? "") \(path) \(options.count)"))
        case .boundText:
            return AnyView(Text("bound"))
        case .branch(_, let whenTrue, let whenFalse):
            let active = currentTree == .object([:]) ? whenFalse : whenTrue
            return AnyView(NodeRenderer(node: .text(content: "branch"), variableStore: variableStore, sessionId: sessionId, scale: scale))
        case .image(let src, let alt):
            return AnyView(NatImageView(src: src, alt: alt, scale: scale))
        case .link(let label, let href):
            return AnyView(NatLinkView(label: label, href: href, scale: scale))
        case .externalResource(let resource):
            return AnyView(NatExternalResourceView(resource: resource, scale: scale))
        case .scriptPlaceholder(let raw, _):
            return AnyView(NatScriptPlaceholderView(hint: raw, scale: scale))
        }
    }
}

// MARK: - VariableStore 订阅
private struct StoreObserver<Content: View>: View {
    let store: VariableStore?
    let content: () -> Content

    var body: some View {
        if let store = store {
            ObservedPassthrough(store: store, content: content)
        } else {
            content()
        }
    }
}

private struct ObservedPassthrough<Content: View>: View {
    @ObservedObject var store: VariableStore
    let content: () -> Content
    var body: some View { content() }
}

// MARK: - Batch 1: 纯展示 view（无状态、无 action）
private struct TextView: View {
    let content: String
    let scale: CGFloat
    var body: some View {
        Text(content)
            .font(.system(size: 15 * scale))
            .textSelection(.enabled)
    }
}

private struct NumberView: View {
    let value: Double
    let label: String?
    let scale: CGFloat
    var body: some View {
        HStack(spacing: 6) {
            Text("\(Int(value))")
                .font(.system(size: 18 * scale, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
            if let label = label {
                Text(label)
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NatProgressView: View {
    let label: String
    let value: Double
    let max: Double?
    let scale: CGFloat
    var body: some View {
        let total = max ?? 100
        let fraction = total > 0 ? min(value / total, 1.0) : 0
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 13 * scale, weight: .medium))
                Spacer()
                Text("\(Int(value))/\(Int(total))")
                    .font(.system(size: 12 * scale).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: value, total: total)
                .progressViewStyle(.linear)
        }
    }
}

private struct NatFieldView: View {
    let label: String
    let value: String
    let scale: CGFloat
    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13 * scale, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14 * scale))
                .textSelection(.enabled)
        }
    }
}

// MARK: - Batch 2: 占位 view（image / link / external / scriptPlaceholder）
private struct NatImageView: View {
    let src: String
    let alt: String?
    let scale: CGFloat
    var body: some View {
        Text(alt ?? src)
            .font(.system(size: 13 * scale))
            .foregroundStyle(.secondary)
    }
}

private struct NatLinkView: View {
    let label: String
    let href: String
    let scale: CGFloat
    var body: some View {
        Text(label)
            .font(.system(size: 14 * scale))
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(href)
    }
}

private struct NatExternalResourceView: View {
    let resource: ExternalResourceIR
    let scale: CGFloat
    var body: some View {
        Text("[ext:\(resource.kind.rawValue)] \(resource.url)")
            .font(.system(size: 12 * scale))
            .foregroundStyle(.secondary)
    }
}

private struct NatScriptPlaceholderView: View {
    let hint: String
    let scale: CGFloat
    var body: some View {
        Text("[placeholder] \(hint)")
            .font(.system(size: 11 * scale))
            .foregroundStyle(.tertiary)
    }
}