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
            return AnyView(NatListView(items: items, variableStore: variableStore,
                                      sessionId: sessionId, scale: scale))
        case .container(let title, let children, let animation):
            return AnyView(NatContainerView(title: title, children: children,
                                            animation: animation,
                                            variableStore: variableStore,
                                            sessionId: sessionId, scale: scale))
        case .boundText(let segments):
            let text = MacroRenderer.render(segments: segments, tree: currentTree)
            return AnyView(TextView(content: text, scale: scale))
        case .branch(let condition, let whenTrue, let whenFalse):
            let isTrue = condition.evaluate(in: currentTree)
            let active = isTrue ? whenTrue : whenFalse
            return AnyView(NatBranchView(activeBranch: active, isTrue: isTrue,
                                        variableStore: variableStore,
                                        sessionId: sessionId, scale: scale))
        case .button(let label, let action):
            return AnyView(NatButtonView(label: label, action: action,
                                        variableStore: variableStore,
                                        sessionId: sessionId, scale: scale))
        case .textInput(let label, let path, let placeholder):
            return AnyView(NatInputView(label: label, path: path, placeholder: placeholder,
                                       variableStore: variableStore,
                                       sessionId: sessionId, scale: scale))
        case .selection(let label, let path, let options):
            return AnyView(NatSelectionView(label: label, path: path, options: options,
                                           variableStore: variableStore,
                                           sessionId: sessionId, scale: scale))
        case .boundText:
            return AnyView(Text("bound"))
        case .branch(_, let whenTrue, let whenFalse):
            _ = whenTrue; _ = whenFalse
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

// MARK: - Batch 3: 交互 view（button / input / select）
private struct NatButtonView: View {
    let label: String
    let action: NativeAction
    var variableStore: VariableStore? = nil
    var sessionId: UUID? = nil
    let scale: CGFloat

    @State private var dispatchToken: Int = 0

    var body: some View {
        Button {
            guard let store = variableStore, let sid = sessionId else { return }
            let dispatcher = NativeActionDispatcher()
            guard let ops = dispatcher.patches(
                for: action,
                currentTree: store.raw(forSession: sid)
            ) else { return }
            try? store.apply(ops, to: sid)
            dispatchToken = dispatchToken &+ 1
        } label: {
            Label(label, systemImage: "hand.tap")
                .font(.system(size: 14 * scale, weight: .medium))
        }
        .buttonStyle(.bordered)
        .tint(.accentColor)
        .padding(.vertical, 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dispatchToken)
    }
}

private struct NatInputView: View {
    let label: String?
    let path: String
    let placeholder: String?
    var variableStore: VariableStore? = nil
    var sessionId: UUID? = nil
    let scale: CGFloat

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            if let label = label {
                Text(label)
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6 * scale) {
                TextField(placeholder ?? "",
                          text: Binding<String>(
                            get: { draft.isEmpty ? currentValueText : draft },
                            set: { draft = $0 }
                          ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15 * scale))
                Button("提交") {
                    let text = draft.isEmpty ? currentValueText : draft
                    applyValue(.string(text))
                    draft = ""
                }
                .buttonStyle(.bordered)
                .font(.system(size: 13 * scale, weight: .medium))
            }
        }
        .padding(.vertical, 2)
    }

    private var currentValueText: String {
        guard let store = variableStore, let sid = sessionId,
              let v = NativeActionDispatcher().value(at: path, in: store.raw(forSession: sid)),
              case let .string(s) = v else {
            return ""
        }
        return s
    }

    private func applyValue(_ v: JSONValue) {
        guard let store = variableStore, let sid = sessionId else { return }
        let dispatcher = NativeActionDispatcher()
        guard let ops = dispatcher.patches(
            for: .updateVariable(path: path, value: v),
            currentTree: store.raw(forSession: sid)
        ) else { return }
        try? store.apply(ops, to: sid)
    }
}

private struct NatSelectionView: View {
    let label: String?
    let path: String
    let options: [NativeControlOption]
    var variableStore: VariableStore? = nil
    var sessionId: UUID? = nil
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            if let label = label {
                Text(label)
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.secondary)
            }
            Menu {
                ForEach(options, id: \.value) { option in
                    Button(option.label ?? option.value) {
                        applyValue(.string(option.value))
                    }
                }
            } label: {
                Label(currentLabel, systemImage: "chevron.up.chevron.down")
                    .font(.system(size: 14 * scale, weight: .medium))
            }
        }
        .padding(.vertical, 2)
    }

    private var currentValueText: String {
        guard let store = variableStore, let sid = sessionId,
              let v = NativeActionDispatcher().value(at: path, in: store.raw(forSession: sid)),
              case let .string(s) = v else {
            return ""
        }
        return s
    }

    private var currentLabel: String {
        let current = currentValueText
        if !current.isEmpty {
            return options.first(where: { $0.value == current })?.label ?? current
        }
        return label ?? "选择"
    }

    private func applyValue(_ v: JSONValue) {
        guard let store = variableStore, let sid = sessionId else { return }
        let dispatcher = NativeActionDispatcher()
        guard let ops = dispatcher.patches(
            for: .updateVariable(path: path, value: v),
            currentTree: store.raw(forSession: sid)
        ) else { return }
        try? store.apply(ops, to: sid)
    }
}

// MARK: - Batch 4: 容器 / 列表 / 分支（递归 + 动画 modifier）
private struct NatListView: View {
    let items: [NativeIRNode]
    var variableStore: VariableStore? = nil
    var sessionId: UUID? = nil
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, child in
                NodeRenderer(node: child,
                             variableStore: variableStore,
                             sessionId: sessionId,
                             scale: scale)
            }
        }
    }
}

private struct NatContainerView: View {
    let title: String
    let children: [NativeIRNode]
    let animation: NativeAnimation?
    var variableStore: VariableStore? = nil
    var sessionId: UUID? = nil
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                NodeRenderer(node: child,
                             variableStore: variableStore,
                             sessionId: sessionId,
                             scale: scale)
            }
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 10 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6),
                    in: RoundedRectangle(cornerRadius: 10 * scale))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * scale)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .modifier(NatContainerAnimationModifier(animation: animation))
    }
}

/// 容器级 NativeAnimation → SwiftUI `.transition`。
private struct NatContainerAnimationModifier: ViewModifier {
    let animation: NativeAnimation?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let animation = animation {
            switch animation.kind {
            case .fade:
                content.transition(.opacity)
            case .slide:
                content.transition(.move(edge: .leading).combined(with: .opacity))
            case .scale:
                content.transition(.scale.combined(with: .opacity))
            case .transition:
                content.transition(.opacity)
            }
        } else {
            content
        }
    }
}

private struct NatBranchView: View {
    let activeBranch: [NativeIRNode]
    let isTrue: Bool
    var variableStore: VariableStore? = nil
    var sessionId: UUID? = nil
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(Array(activeBranch.enumerated()), id: \.offset) { _, child in
                NodeRenderer(node: child,
                             variableStore: variableStore,
                             sessionId: sessionId,
                             scale: scale)
            }
        }
        .id(isTrue)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeInOut(duration: 0.25), value: isTrue)
    }
}