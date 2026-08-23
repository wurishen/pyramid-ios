import Foundation

// `NativeAnimation` / `NativeAction` 定义在 `NativeActionTypes.swift` ——
// app target 与 SPM 测试包共享的基础原语（RenderNode.nativeAction / MessageCard
// 按钮都依赖它们，而本文件目前只进 SPM target）。

/// Tavern → Native iOS 第三层中间表示（IR）。
///
/// **定位**：
/// - 纯数据（Foundation only），不依赖 SwiftUI；可在 Linux SPM 单测。
/// - 描述"角色卡想表达什么"，**不**描述"如何显示"。
/// - 与 `RenderNode` / `DisplayBlock` 等旧 IR **完全平行**，互不依赖；旧 IR
///   继续作为 legacy compat path 走 `MessageCard`，新 IR 由本枚举驱动新 renderer。
///
/// **不引入业务模板**：原语是通用的 text / number / progress / field / list /
/// container / button —— **不存在** HPComponent / AffectionComponent /
/// GoldComponent 之类的 Pyramid 业务组件。语义由角色卡数据与未来 Capability 层决定。
///
/// **闭环**：
/// ```
/// 角色卡文本 / JSONValue 树
///   ↓ NativeIRProjector.project(statData:)
/// NativeIRNode 树
///   ↓ SwiftUI renderer
/// 用户点击 button
///   ↓ NativeActionDispatcher.dispatch(action, to: &tree)
/// 变量树 mutation
///   ↓ NativeIRProjector.project(statData:) 重新跑
/// 新 NativeIRNode 树
/// ```
///
/// **未来扩展**：
/// - 通过 `container(...animation:)` 承载动画意图；新 case 即可，不改既有形状。
/// - 通过 `.button(label:action:)` 让 SwiftUI 事件 → Action → 变量 mutation 形成闭环。
indirect enum NativeIRNode: Equatable, Sendable {
    /// 纯文本片段。
    case text(content: String)
    /// 数值（可带可选 label）。label = `nil` → 纯数字；label = `"金币"` → UI 自渲染成 "50 (金币)"。
    case number(value: Double, label: String?)
    /// 通用进度条：`max == nil` → UI 不画上限标线。
    ///
    /// **不携带 Pyramid 业务语义**：本枚举不区分 HP / 好感度 / 比率 / 通用 等。
    /// 谁是 progress 由**数据形状**（`{value, max}` 显式对）决定，不由字段名决定。
    case progress(label: String, value: Double, max: Double?)
    /// label-value 对（最朴素呈现）。
    case field(label: String, value: String)
    /// 有序列表；元素是任意 IR 节点。
    case list(items: [NativeIRNode])
    /// 带标题的容器 / 嵌套分组。`animation` 可选承载容器级动画意图。
    case container(title: String, children: [NativeIRNode], animation: NativeAnimation?)
    /// P11 HTML/CSS → NativeIR 通用容器（携带样式）：`container` 的样式增强版。
    /// children 同 `container`，额外携带 HTML 标签名 / class 名 / 合并后的 CSS 声明。
    /// renderer 把 CSS 翻译为 SwiftUI modifier（padding / background / cornerRadius /
    /// shadow / opacity / font / transform / animation 等）；不引入 WebView / 不执行 JS
    /// / 不创建业务组件（无 PhoneContainer / StatusContainer / CharacterPanel）。
    case styledContainer(tag: String, classNames: [String], style: CSSStyleDeclaration, children: [NativeIRNode])
    /// 按钮：label 给 SwiftUI 渲染，action 给 dispatcher 执行。
    /// 是 Native IR 中唯一允许触发 `NativeAction` 的载体。
    case button(label: String, action: NativeAction)
    /// 通用文本输入：提交时把字符串写到 `path`（JSON Pointer）。
    /// **零业务语义** —— 不解释字段名；renderer 决定键盘 / 样式。
    case textInput(label: String?, path: String, placeholder: String?)
    /// 通用单选：选中项的 value 字符串写到 `path`。
    /// **零业务语义** —— 选项集合完全由角色卡数据提供。
    case selection(label: String?, path: String, options: [NativeControlOption])
    /// 宏绑定文本：解析一次的 `MacroSegment` 有序片段（literal / 变量绑定），
    /// 结构完整进入 IR。渲染层对当前变量树求值（变量更新 → 重算 → 新内容）；
    /// 未识别 / 缺失的绑定回退原文 —— 信息不丢。
    case boundText(segments: [MacroSegment])
    /// 条件分支：解析一次的组合条件 + 预转译双分支。渲染层对当前变量树求值选支
    /// （变量更新 → 重算 → 分支切换）；两支内容都是任意 NativeIRNode 子树。
    case branch(condition: NativeCondition, whenTrue: [NativeIRNode], whenFalse: [NativeIRNode])
    /// P8 通用图像原语：HTML `<img>` 转译产物。`src` 记录 URL 意图，**不**保证加载
    /// —— renderer 决定是否真的下载（默认不下载外部 URL）。`alt` 是 fallback 文本。
    /// **不是**业务组件；非 Character avatar 之类专用节点。
    case image(src: String, alt: String?)
    /// P8 通用链接原语：HTML `<a href>` 转译产物。`href` 记录 URL 意图，**不**保证跳转
    /// —— renderer 决定（默认展示 label + URL 提示，点击不打开浏览器，纯客户端意图）。
    case link(label: String, href: String)
    /// P8 外部资源 IR —— `<script src>` / `<iframe src>` / `$(...).load(url)` /
    /// `fetch()` 等远端调用转译产物。仅描述「存在一个远程 URL」，**永不下载、永不执行**。
    /// UI 可选折叠展示 raw + URL 提示；renderer 不得调用任何 HTTP / WebView 加载。
    case externalResource(ExternalResourceIR)
    /// P8 不可执行脚本占位：HTML `<script>...</script>` / `<style>...</style>` /
    /// 任何 `isSafeURL == false` 的远端调用转译产物。`raw` 是原始片段（含完整开闭标签），
    /// **永不执行**。UI 折叠展示原文 + 「未执行」提示。
    case scriptPlaceholder(raw: String, reason: String)
    /// P10 动画意图元数据节点：P9 `RenderNode.htmlAnimation(AnimationIR)` 桥接进
    /// Native IR 的载体 —— 纯数据，不承载可视内容。renderer 把它作为**同级下一个**
    /// 兄弟节点的修饰信息（trigger = onPathChange / onAction 时由
    /// `AnimationTriggerCoordinator` 反向调度到 SwiftUI 运行时）。
    case animation(AnimationIR)
}