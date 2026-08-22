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

struct NativeView: View {
    let node: NativeIRNode
    /// 会话级 MVU 变量存储。nil = 纯渲染（fixture / 单测）。
    var variableStore: VariableStore? = nil
    var sessionId: UUID? = nil
    /// UI 缩放。1.0 = 原始尺寸。
    var scale: CGFloat = 1.0

    var body: some View {
        NativeNodeRenderer(node: node,
                        variableStore: variableStore,
                        sessionId: sessionId,
                        scale: scale)
    }
}

// MARK: - 递归节点渲染器

/// 递归渲染单个 NativeIRNode：放在独立 View 类型里而不是 NativeView 内联函数，
/// 是为了让每个节点得到稳定的身份（SwiftUI diff 友好）。返回 `AnyView` 是为了
/// 让 `body` 在不同 case 下类型一致 —— 避免 switch → some View 触发编译期类型
/// 联合爆炸（与 MessageCard 同款约束）。
struct NativeNodeRenderer: View {
    let node: NativeIRNode
    var variableStore: VariableStore? = nil
    var sessionId: UUID? = nil
    var scale: CGFloat = 1.0

    /// 当前会话变量树；store 缺失 → 空 object（任何 binding / condition 都会得到
    /// unresolved / false —— 不崩溃）。
    private var currentTree: JSONValue {
        guard let store = variableStore, let sid = sessionId else { return .object([:]) }
        return store.raw(forSession: sid)
    }

    var body: some View {
        // VariableStore 是 ObservableObject。把它作为 @ObservedObject 持有（即便
        // nil）让 SwiftUI 在 @Published 触发时重绘本节点 —— 是闭环刷新源。
        VariableStoreObserver(store: variableStore) {
            render(node)
        }
    }

    /// 15 个 case 的 switch 必须显式返回 AnyView —— 用 @ViewBuilder / some View
    /// 让编译器花指数时间试图联合 15 种 concrete view 类型，与 MessageCard
    /// 同款风险（Release archive 全模块优化下展开无穷类型）。这里直接 AnyView
    /// 收敛类型。
    private func render(_ node: NativeIRNode) -> AnyView {
        switch node {
        case .text(let content):
            return AnyView(NativeTextView(content: content, scale: scale))

        case let .number(value, label):
            return AnyView(NativeNumberView(value: value, label: label, scale: scale))

        case let .progress(label, value, max):
            return AnyView(NativeProgressView(label: label, value: value, max: max, scale: scale))

        case let .field(label, value):
            return AnyView(NativeFieldView(label: label, value: value, scale: scale))

        case let .list(items):
            // list 是有序容器；children 顺序保留。
            return AnyView(NativeListView(items: items, variableStore: variableStore,
                                          sessionId: sessionId, scale: scale))

        case let .container(title, children, animation):
            // container 可挂动画意图；动画由本 View 翻译成 SwiftUI transition /
            // withAnimation —— 不引入第三方引擎。
            return AnyView(NativeContainerView(title: title, children: children,
                                               animation: animation,
                                               variableStore: variableStore,
                                               sessionId: sessionId, scale: scale))

        case let .button(label, action):
            // 点击 → dispatcher → store.apply → @Published → 重渲染（条件 / 动画生效）。
            return AnyView(NativeActionButtonView(label: label, action: action,
                                                  variableStore: variableStore,
                                                  sessionId: sessionId, scale: scale))

        case let .textInput(label, path, placeholder):
            return AnyView(NativeTextInputView(label: label, path: path,
                                               placeholder: placeholder,
                                               variableStore: variableStore,
                                               sessionId: sessionId, scale: scale))

        case let .selection(label, path, options):
            return AnyView(NativeSelectionView(label: label, path: path, options: options,
                                               variableStore: variableStore,
                                               sessionId: sessionId, scale: scale))

        case let .boundText(segments):
            // 宏绑定：对当前变量树求值；store 变化 → 重算 → 文本同步。
            // unresolved → 原文（信息不丢）。
            let text = MacroRenderer.render(segments: segments, tree: currentTree)
            return AnyView(NativeTextView(content: text, scale: scale))

        case let .branch(condition, whenTrue, whenFalse):
            // 条件分支：对当前变量树求值选支；store 变化 → 重算 → 分支切换。
            // withAnimation 让切换具备视觉过渡（from false branch → true branch）。
            let isTrue = condition.evaluate(in: currentTree)
            let active = isTrue ? whenTrue : whenFalse
            return AnyView(NativeBranchView(activeBranch: active, isTrue: isTrue,
                                            variableStore: variableStore,
                                            sessionId: sessionId, scale: scale))

        case let .image(src, alt):
            return AnyView(NativeImageView(src: src, alt: alt, scale: scale))

        case let .link(label, href):
            return AnyView(NativeLinkView(label: label, href: href, scale: scale))

        case let .externalResource(ir):
            return AnyView(NativeExternalResourceView(ir: ir, scale: scale))

        case let .scriptPlaceholder(raw, reason):
            return AnyView(NativeScriptPlaceholderView(raw: raw, reason: reason, scale: scale))
        }
    }
}

// MARK: - VariableStore 订阅

/// 把 VariableStore 作为依赖注入到 body —— 仅为触发刷新；不修改数据。
/// store == nil（fixture）时退化为 passthrough，不订阅任何对象。
///
/// 实现要点：SwiftUI 的 `@ObservedObject` 触发刷新的前提是 **属性在 view body
/// 路径上被读取**。把 `store` 作为实例属性 + 在 body 里调 `store.raw(...)`，
/// 当 store 变化时 SwiftUI 自动重绘本 view。
private struct VariableStoreObserver<Content: View>: View {
    let store: VariableStore?
    let content: () -> Content

    var body: some View {
        if let store {
            // 用 `@ObservedObject` 持有 store：当 store.stores 变化时重绘子树。
            // 这是状态变化触发 NativeView 重渲染的唯一入口。
            PassthroughView(store: store, content: content)
        } else {
            content()
        }
    }
}

private struct PassthroughView<Content: View>: View {
    @ObservedObject var store: VariableStore
    let content: () -> Content
    var body: some View { content() }
}

// MARK: - 叶子节点视图

private struct NativeTextView: View {
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

private struct NativeNumberView: View {
    let value: Double
    let label: String?
    let scale: CGFloat
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
            Text(format(value))
                .font(.system(size: 18 * scale, weight: .semibold).monospacedDigit())
                .foregroundStyle(.accentColor)
            if let label {
                Text(label)
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.secondary)
            }
        }
    }
    private func format(_ v: Double) -> String {
        if v.rounded() == v { return String(Int(v)) }
        return String(v)
    }
}

private struct NativeProgressView: View {
    let label: String
    let value: Double
    let max: Double?
    let scale: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack {
                Text(label).font(.system(size: 13 * scale)).foregroundStyle(.secondary)
                Spacer()
                Text(progressText).font(.system(size: 13 * scale, weight: .medium).monospacedDigit())
            }
            ProgressView(value: clamped, total: clampedTotal)
                .progressViewStyle(.linear)
                .tint(.accentColor)
        }
    }
    private var clamped: Double { max == nil ? max(0, min(value, 1)) : max(0, min(value, max!)) }
    private var clampedTotal: Double { max ?? 1 }
    private var progressText: String {
        if let max { return "\(Int(value))/\(Int(max))" }
        return "\(Int(value))"
    }
}

private struct NativeFieldView: View {
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

private struct NativeImageView: View {
    let src: String
    let alt: String?
    let scale: CGFloat
    var body: some View {
        // 通用图像：URL 记录在 IR，**不**自动下载（与 MessageCard.HTMLImageView 同款策略）。
        Text("[图片] \(alt ?? src)").font(.system(size: 13 * scale)).foregroundStyle(.secondary)
    }
}

private struct NativeLinkView: View {
    let label: String
    let href: String
    let scale: CGFloat
    var body: some View {
        Text("🔗 \(label)").font(.system(size: 13 * scale)).foregroundStyle(.secondary)
        // href 仅作为客户端意图记录 —— 不打开浏览器。
    }
}

private struct NativeExternalResourceView: View {
    let ir: ExternalResourceIR
    let scale: CGFloat
    var body: some View {
        Text("🌐 外部资源(\(ir.kind.rawValue)) · \(ir.url)")
            .font(.system(size: 12 * scale)).foregroundStyle(.secondary)
    }
}

private struct NativeScriptPlaceholderView: View {
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

private struct NativeListView: View {
    let items: [NativeIRNode]
    var variableStore: VariableStore?
    var sessionId: UUID?
    let scale: CGFloat
    var body: some View {
        // 列表用 VStack 表达；保持子节点顺序。
        VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, child in
                NativeNodeRenderer(node: child, variableStore: variableStore,
                                   sessionId: sessionId, scale: scale)
            }
        }
    }
}

private struct NativeContainerView: View {
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
                NativeNodeRenderer(node: child, variableStore: variableStore,
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
        // container 级动画：进入 → withAnimation。
        .modifier(ContainerAnimationModifier(animation: animation))
    }
}

/// 容器级 NativeAnimation → SwiftUI 动画。
///
/// **复用 P9 AnimationRenderer**：旧式 NativeAnimation（fade / slide / scale /
/// transition）由 `AnimationRenderer` 旁路映射；如果未来扩展成 `AnimationIR`
/// trigger 形式，本 modifier 一对一替换为 `AnimationModifier(anim:)`。
private struct ContainerAnimationModifier: ViewModifier {
    let animation: NativeAnimation?
    func body(content: Content) -> some View {
        guard let animation else { return AnyView(content) }
        switch animation.kind {
        case .fade:
            return AnyView(content.transition(.opacity))
        case .slide:
            return AnyView(content.transition(.move(edge: .leading).combined(with: .opacity)))
        case .scale:
            return AnyView(content.transition(.scale.combined(with: .opacity)))
        case .transition:
            return AnyView(content.transition(.opacity))
        }
    }
}

private struct NativeBranchView: View {
    let activeBranch: [NativeIRNode]
    let isTrue: Bool
    var variableStore: VariableStore?
    var sessionId: UUID?
    let scale: CGFloat

    var body: some View {
        // 用 withAnimation + .id(isTrue) 触发分支切换的视觉过渡。
        // .id 切换让 SwiftUI 把前后分支视作不同身份，触发 transition。
        let content = VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(Array(activeBranch.enumerated()), id: \.offset) { _, child in
                NativeNodeRenderer(node: child, variableStore: variableStore,
                                   sessionId: sessionId, scale: scale)
            }
        }
        return AnyView(
            content
                .id(isTrue)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut(duration: 0.25), value: isTrue)
        )
    }
}

// MARK: - 交互节点

private struct NativeActionButtonView: View {
    let label: String
    let action: NativeAction
    var variableStore: VariableStore?
    var sessionId: UUID?
    let scale: CGFloat

    /// 单调递增的 dispatch token：变化时驱动 .onAction 动画重放（SwiftUI 原生）。
    @State private var dispatchToken: Int = 0

    var body: some View {
        Button {
            guard let store = variableStore, let sid = sessionId else { return }
            let dispatcher = NativeActionDispatcher()
            // 与 MessageCard.nativeActionButton 同一通路 —— dispatcher 算等价
            // patch → VariableStore.apply → @Published 触发重渲染。
            guard let ops = dispatcher.patches(
                for: action,
                currentTree: store.raw(forSession: sid)
            ) else { return }
            try? store.apply(ops, to: sid)
            // 触发 .onAction 动画重放：token 单调递增。
            dispatchToken &+= 1
        } label: {
            Label(label, systemImage: "hand.tap")
                .font(.system(size: 14 * scale, weight: .medium))
        }
        .buttonStyle(.bordered)
        .tint(.accentColor)
        .padding(.vertical, 2)
        // token 变化 → scale 弹一下（SwiftUI 原生 spring）。
        .scaleEffect(dispatchToken > 0 ? 1.0 : 0.98)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dispatchToken)
    }
}

private struct NativeTextInputView: View {
    let label: String?
    let path: String
    let placeholder: String?
    var variableStore: VariableStore?
    var sessionId: UUID?
    let scale: CGFloat

    /// UI 会话态草稿（不进消息数据）。
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            if let label {
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

private struct NativeSelectionView: View {
    let label: String?
    let path: String
    let options: [NativeControlOption]
    var variableStore: VariableStore?
    var sessionId: UUID?
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            if let label {
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

// MARK: - SwiftUI Preview
//
// 临时移除 #Preview 块 —— Swift 6 编译器对 #Preview macro + 含有 `@ObservedObject`
// + 私有 generic 子 view 的组合存在已知诊断差异（参见 Xcode 16.2 release notes）。
// NativeView 在 ChatView / MessageCard 迁移到 NativeIR 后会被实际装配使用，
// 这里留出空间以便后续加回 Preview。

#if false
#Preview("NativeView - text") {
    NativeView(node: .text(content: "hello pyramid"))
        .padding()
        .background(Color(.systemBackground))
}
#endif