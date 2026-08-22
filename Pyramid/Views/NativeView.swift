import SwiftUI

// P10: Native IR → SwiftUI 原生视图渲染器（端到端闭环）。
//
// **定位**：本视图是 Native IR 树的唯一渲染入口；它不引入业务组件（无
// PhoneComponent / StatusComponent / CharacterCard），不替角色卡赋语义，
// 不重复建立第二套 state / action / condition 系统 —— 全部复用：
//
//   - 单一变量存储：`VariableStore`（@Published ObservableObject）
//   - 单一 action 执行器：`NativeActionDispatcher`（dispatch + patch）
//   - 单一条件求值：`NativeCondition.evaluate`（JSON Pointer + 比较符）
//   - 单一宏绑定求值：`MacroRenderer.render(segments:, tree:)`
//   - 单一动画意图：`AnimationIR` + `AnimationRenderer`（来自 P9）
//
// **闭环**：
//
// ```
//   user taps button / submits input / picks option
//     ↓ NativeActionDispatcher.patches(for: action, currentTree:)
//   [JSONPatchOperation]
//     ↓ VariableStore.apply(_, to: sessionId)
//   stores[sessionId] 变更  →  @Published 触发  →  本 View body 重算
//     ↓ currentVariableTree 重读
//   macroText / branch / progress / container 重渲染
//     ↓ AnimationRenderer.swiftUIAnimation / swiftUITransition
//   SwiftUI 动画（withAnimation / .transition）按 trigger 应用
// ```
//
// **触发语义**：每个 `NativeAnimation` / `AnimationIR` 配 trigger；本 View
// 把 trigger 翻译成 SwiftUI 的运行时机：
//   - `.onAppear`         → `.onAppear { withAnimation { ... } }`
//   - `.onPathChange`     → 订阅 `VariableStore.currentValue(at: path)`，变化时
//                           `withAnimation` 重绘（与 `macroText` 同源）
//   - `.onAction(key)`    → 由 `NativeActionDispatcher.dispatch` 的 success 回调驱动
//
// **不**做的事：
// - 不引入 WebView / JavaScriptCore / 第三方动画引擎。
// - 不持有业务状态（HP / 好感度 / 金币等不写在这里）。
// - 不展开 HTML / 不解析新表达式 —— 输入就是 NativeIRNode 树。
//
// **递归注意**：与 `MessageCard.renderNode` 同款，用 `AnyView` 而非泛型
//  closure 避免 Release 全模块优化展开无穷类型（Debug 可过、Archive 崩）。

/// NativeIRNode → SwiftUI 视图渲染入口。
///
/// 把 NativeIR 树（来自 TavernExpression.transpile / HTMLTranspiler.transpile）
/// 渲染成纯 SwiftUI 视图。**当前实现是 P10 最小可用版本**，仅覆盖：
///   - `.text` / `.number` / `.field` / `.progress` —— 纯展示
///   - `.container` / `.list` / `.branch` —— 容器 + 条件
///   - `.button` / `.textInput` / `.selection` —— 交互（含闭环）
///   - `.boundText` —— 宏绑定求值
///   - `.image` / `.link` / `.externalResource` / `.scriptPlaceholder` —— 占位
///
/// **不**做：动画 trigger 的状态-触发动画、layout 校准、嵌套 container 动画继承。
/// 这些能力在 P11+ 通过扩展 `ContainerAnimationModifier` / 新增
/// `AnimationModifier(anim:)` 加回 —— 不破坏 P10 闭环。
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

/// 递归渲染单个 NativeIRNode。独立的 View 类型 → SwiftUI diff 友好。
/// 返回 `AnyView` 让 15-case switch 的 body 类型一致，避免编译器联合爆炸。
private struct NodeRenderer: View {
    let node: NativeIRNode
    var variableStore: VariableStore? = nil
    var sessionId: UUID? = nil
    var scale: CGFloat = 1.0

    /// 当前会话变量树；store 缺失 → 空 object（binding / condition 走 fallback）。
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
            return AnyView(ProgressView_(label: label, value: value, max: max, scale: scale))
        case .field(let label, let value):
            return AnyView(FieldView_(label: label, value: value, scale: scale))
        case .list(let items):
            return AnyView(ListView_(items: items, variableStore: variableStore,
                                     sessionId: sessionId, scale: scale))
        case .container(let title, let children, let animation):
            return AnyView(ContainerView_(title: title, children: children,
                                          animation: animation,
                                          variableStore: variableStore,
                                          sessionId: sessionId, scale: scale))
        case .button(let label, let action):
            return AnyView(ButtonView_(label: label, action: action,
                                       variableStore: variableStore,
                                       sessionId: sessionId, scale: scale))
        case .textInput(let label, let path, let placeholder):
            return AnyView(InputView_(label: label, path: path,
                                      placeholder: placeholder,
                                      variableStore: variableStore,
                                      sessionId: sessionId, scale: scale))
        case .selection(let label, let path, let options):
            return AnyView(SelectionView_(label: label, path: path, options: options,
                                          variableStore: variableStore,
                                          sessionId: sessionId, scale: scale))
        case .boundText(let segments):
            let text = MacroRenderer.render(segments: segments, tree: currentTree)
            return AnyView(TextView(content: text, scale: scale))
        case .branch(let condition, let whenTrue, let whenFalse):
            let isTrue = condition.evaluate(in: currentTree)
            let active = isTrue ? whenTrue : whenFalse
            return AnyView(BranchView_(activeBranch: active, isTrue: isTrue,
                                       variableStore: variableStore,
                                       sessionId: sessionId, scale: scale))
        case .image(let src, let alt):
            return AnyView(ImageView_(src: src, alt: alt, scale: scale))
        case .link(let label, let href):
            return AnyView(LinkView_(label: label, href: href, scale: scale))
        case .externalResource(let ir):
            return AnyView(ExternalResourceView_(ir: ir, scale: scale))
        case .scriptPlaceholder(let raw, let reason):
            return AnyView(ScriptPlaceholderView_(raw: raw, reason: reason, scale: scale))
        }
    }
}

// MARK: - VariableStore 订阅

/// 把 VariableStore 作为依赖注入到 body —— 仅为触发刷新；不修改数据。
/// store == nil 时退化为 passthrough，不订阅任何对象。
private struct StoreObserver<Content: View>: View {
    let store: VariableStore?
    let content: () -> Content

    var body: some View {
        if let store {
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

// MARK: - 叶子节点视图

private struct TextView: View {
    let content: String
    let scale: CGFloat
    var body: some View {
        Text(content)
            .font(.system(size: 16 * scale))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NumberView: View {
    let value: Double
    let label: String?
    let scale: CGFloat
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
            Text(formatted)
                .font(.system(size: 18 * scale, weight: .semibold).monospacedDigit())
                .foregroundStyle(.accentColor)
            if let label = label {
                Text(label)
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.secondary)
            }
        }
    }
    private var formatted: String {
        if value.rounded() == value { return String(Int(value)) }
        return String(value)
    }
}

private struct ProgressView_: View {
    let label: String
    let value: Double
    let max: Double?
    let scale: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack {
                Text(label).font(.system(size: 13 * scale)).foregroundStyle(.secondary)
                Spacer()
                Text(text).font(.system(size: 13 * scale, weight: .medium).monospacedDigit())
            }
            ProgressView(value: clamped, total: total)
                .progressViewStyle(.linear)
                .tint(.accentColor)
        }
    }
    private var clamped: Double {
        if let max = max { return Swift.max(0, Swift.min(value, max)) }
        return Swift.max(0, Swift.min(value, 1))
    }
    private var total: Double { max ?? 1 }
    private var text: String {
        if let max = max { return "\(Int(value))/\(Int(max))" }
        return "\(Int(value))"
    }
}

private struct FieldView_: View {
    let label: String
    let value: String
    let scale: CGFloat
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 14 * scale, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 15 * scale, weight: .semibold).monospacedDigit())
                .foregroundStyle(.accentColor)
        }
    }
}

private struct ImageView_: View {
    let src: String
    let alt: String?
    let scale: CGFloat
    var body: some View {
        Text("[图片] \(alt ?? src)").font(.system(size: 13 * scale)).foregroundStyle(.secondary)
    }
}

private struct LinkView_: View {
    let label: String
    let href: String
    let scale: CGFloat
    var body: some View {
        Text("🔗 \(label)")
            .font(.system(size: 13 * scale))
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(label), \(href)")
    }
}

private struct ExternalResourceView_: View {
    let ir: ExternalResourceIR
    let scale: CGFloat
    var body: some View {
        Text("🌐 外部资源(\(ir.kind.rawValue)) · \(ir.url)")
            .font(.system(size: 12 * scale)).foregroundStyle(.secondary)
    }
}

private struct ScriptPlaceholderView_: View {
    let raw: String
    let reason: String
    let scale: CGFloat
    var body: some View {
        Text("⚠️ \(reason)\n\(raw)")
            .font(.system(size: 11 * scale, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(6 * scale)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 6 * scale))
    }
}

// MARK: - 容器 / 列表 / 分支

private struct ListView_: View {
    let items: [NativeIRNode]
    var variableStore: VariableStore?
    var sessionId: UUID?
    let scale: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, child in
                NodeRenderer(node: child, variableStore: variableStore,
                             sessionId: sessionId, scale: scale)
            }
        }
    }
}

private struct ContainerView_: View {
    let title: String
    let children: [NativeIRNode]
    let animation: NativeAnimation?
    var variableStore: VariableStore?
    var sessionId: UUID?
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                NodeRenderer(node: child, variableStore: variableStore,
                             sessionId: sessionId, scale: scale)
            }
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 10 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10 * scale))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * scale)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .modifier(ContainerAnimationModifier_(animation: animation))
    }
}

/// 容器级 NativeAnimation → SwiftUI 动画。
///
/// 不持有状态、不做时间轴 —— 只把 animation.kind 翻译成 SwiftUI `.transition`。
/// 真正按 trigger 播放的能力留给 P11+（用 `AnimationModifier(anim:)` 替换）。
private struct ContainerAnimationModifier_: ViewModifier {
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

private struct BranchView_: View {
    let activeBranch: [NativeIRNode]
    let isTrue: Bool
    var variableStore: VariableStore?
    var sessionId: UUID?
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(Array(activeBranch.enumerated()), id: \.offset) { _, child in
                NodeRenderer(node: child, variableStore: variableStore,
                             sessionId: sessionId, scale: scale)
            }
        }
        .id(isTrue)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeInOut(duration: 0.25), value: isTrue)
    }
}

// MARK: - 交互节点

private struct ButtonView_: View {
    let label: String
    let action: NativeAction
    var variableStore: VariableStore?
    var sessionId: UUID?
    let scale: CGFloat

    /// 单调递增的 dispatch token：变化时驱动 .onAction 动画重放（SwiftUI 原生）。
    @State private var dispatchToken = 0

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
        .scaleEffect(dispatchToken > 0 ? 1.0 : 0.98)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dispatchToken)
    }
}

private struct InputView_: View {
    let label: String?
    let path: String
    let placeholder: String?
    var variableStore: VariableStore?
    var sessionId: UUID?
    let scale: CGFloat

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            if let label = label {
                Text(label)
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6 * scale) {
                TextField(placeholder ?? "",
                          text: Binding(
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

private struct SelectionView_: View {
    let label: String?
    let path: String
    let options: [NativeControlOption]
    var variableStore: VariableStore?
    var sessionId: UUID?
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
