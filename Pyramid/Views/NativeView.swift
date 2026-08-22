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
            return AnyView(Text(content))
        case .number(let value, let label):
            return AnyView(Text("\(value) \(label ?? "")"))
        case .progress(let label, let value, let max):
            return AnyView(Text("\(label) \(value)/\(max ?? 0)"))
        case .field(let label, let value):
            return AnyView(Text("\(label): \(value)"))
        case .list(let items):
            return AnyView(NodeRenderer(node: .text(content: "\(items.count) items"), variableStore: variableStore, sessionId: sessionId, scale: scale))
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
        case .image(let src, _):
            return AnyView(Text("image \(src)"))
        case .link(let label, _):
            return AnyView(Text("link \(label)"))
        case .externalResource:
            return AnyView(Text("ext"))
        case .scriptPlaceholder:
            return AnyView(Text("placeholder"))
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
