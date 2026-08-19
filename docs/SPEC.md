# Pyramid 产品规格文档

> 本文档为 iOS / Android 双端共用的产品规格，描述当前已实现功能与计划功能（TODO）。
> 最后更新：2026-08-19（v0.7.1 新增 RenderNode 渲染管线 + 原生 StatusView + Render Inspector 调试覆盖层 + 客户端界面缩放 uiScale）
>
> **当前版本**：v0.7.1（iOS 端）

---

## 1. 产品定位

Pyramid 是一款**本地优先的 AI 聊天客户端**，支持任何兼容 OpenAI `/v1/chat/completions` 接口的后端（OpenAI、Qwen、DeepSeek、本地 Ollama 等）。

核心差异化能力：**世界书（World Book / Lorebook）系统**——通过关键词匹配将结构化知识注入 Prompt，让 AI 在对话中自动参考用户定义的设定、背景、世界观。

**设计原则：**
- 纯本地存储，无服务器，无云端同步
- 零第三方依赖（iOS 端纯 SwiftUI + URLSession）
- 双端功能对齐，行为一致

---

## 2. 信息架构

### 2.1 页面结构

```
TabView
├── Tab 1: 聊天
│   ├── ChatView（消息列表 + 输入框 + 工具栏）
│   │   ├── 角色头像栏（聊天页顶部，绑定角色时显示）
│   │   └── 上下文紧凑提示（Nk / ⚠️Nk）
│   ├── SessionListView（会话列表，Sheet）
│   │   └── SessionDetailView（单会话配置，Sheet）
│   │       └── 角色绑定选择
│   ├── QuickSwitcherView（长按 Tab 触发，圆形网格快速切换会话）
│   └── EditMessageSheet（编辑消息，Sheet）
├── Tab 2: 设置
│   ├── SettingsView（全局设置表单）
│   │   ├── 用户（昵称 + 圆形头像）
│   │   ├── 管理角色卡 → CharacterListView
│   │   │   └── CharacterEditView（编辑角色，Sheet）
│   │   ├── ModelPicker（模型选择，Sheet）
│   │   ├── WorldBookView（世界书管理）
│   │   │   └── WorldBookEditView（编辑条目，Sheet）
│   │   └── PresetListView（预设列表）
│   │       └── PresetEditView（编辑预设，Sheet）
```

### 2.1.1 消息列表形态（酒馆式「回复视窗」）

聊天页不再使用 iMessage 风格的左右气泡。每条消息是一张完整卡片，结构自上而下：

- **头部行** — 头像（28 pt 圆形）+ 角色名 / 用户名 + 楼层号 `#N` + 时间戳；助手头像在左、用户头像在右（视觉区分）
- **正文卡片** — 圆角矩形（cornerRadius = 12），内含渲染后的内容；助手卡片底色 `Color(.systemGray6)`、淡灰描边；用户卡片底色 `Color.accentColor.opacity(0.12)`、强调色描边
- **被排除标签** — 不可进入上下文的消息在头部右侧追加 `已排除` 胶囊
- **长文折叠** — 清洗后正文 > 800 字符默认折叠到前 800 字 + `…`，底部追加「展开 / 收起」按钮（独立 `@State`）

视觉差异（用户 / 助手）通过 **头像位置 + 背景色 + 描边色 + 名字颜色** 实现，**不再是严格的左右气泡布局**。

渲染管线（仅作用于展示层，**不动 `message.content`**）：

1. `RenderEngine.render(raw:context:)` — 显示用正则 → 隐藏标签剥离 → **RenderNode 解析**（识别 `<status>` 块等结构化标签）→ `RenderTree`
2. `MessageCard` 遍历 `RenderTree.nodes`，按节点类型分发：`.text` → `MarkdownTextView`（块级 Markdown 排版：段落 / 围栏代码块 / 列表）/ `Text`（纯文本）；`.status` → 原生 `StatusView` 面板
3. 三态 Markdown 开关：预设 `enableMarkdown: Bool?` 三态 > 全局 `AppSettings.enableMarkdown`

> 流式期间仅 `streamingMessageID` 对应的卡片接收 `liveContent`，其余卡片不重绘。

### 2.1.2 RenderNode 渲染架构（v0.7.1）

**目标**：让模型原始输出里的结构化标签（如 `<status>`）能转为**原生 SwiftUI 视图**，而不是被当作普通 Markdown 文本渲染。

**数据模型**（`Models/RenderNode.swift`，纯 enum，Equatable + Sendable，无 SwiftUI 依赖）：

```swift
enum RenderNode: Equatable, Sendable {
    case text(String)                 // 普通段落，走 Markdown / 纯文本
    case status(hp: Int, affection: Int)  // 角色状态面板
}

struct RenderTree: Equatable, Sendable {
    var nodes: [RenderNode]
    var flattenedText: String { … }   // 仅拼接 .text，用于折叠长度判断
}
```

**渲染管线**：

```
Raw Message → DisplayRegex → HideTags → RenderNodeParser → RenderTree → MessageCard
                                                                                         ├─ .text  → MarkdownTextView / Text
                                                                                         └─ .status → StatusView（原生）
```

**StatusView**（`Views/StatusView.swift`，v0.7.1 新增）：

- 输入：`hp: Int`、`affection: Int`
- 视觉：紧凑面板（圆角 + 浅灰底 + 半透明描边），HP 数值带颜色梯度（≥60 绿 / 30-60 橙 / <30 红），好感度用强调色
- **不可交互**（v0.7.1 范围）；后续如需点击 / 滑入可单独迭代
- 纯展示组件：不持有状态、不查 store、不调网络

**RenderNodeParser**（`Models/RenderNodeParser.swift`）：

- 单遍扫描：`NSRegularExpression` 匹配 `<status>...</status>` 块（`(?is)` + `.dotMatchesLineSeparators`，允许跨行）
- 块内解析：识别 `HP: <int>` 与 `好感度: <int>`（支持中文全角冒号 `：`）；**任一缺失 / 非整数 → 整块降级为 `.text`**，保证不丢内容
- 多次重渲染同 raw → 相同 RenderTree（无副作用 / 无缓存）

**MessageCard 集成**（`Views/MessageCard.swift`）：

```swift
ForEach(tree.nodes) { node in
    switch node {
    case let .text(text):    textNodeView(text, isLong: isLong)
    case let .status(hp, a): StatusView(hp: hp, affection: a)   // 不受折叠影响
    }
}
```

**约束**：

1. **Raw Message 不被修改**——`RenderTree` 只在展示层计算，每次从 raw 重新算；流式期间 `liveContent` 覆盖 `message.content`，渲染管线不变
2. **Markdown / DisplayRegex 行为保持**——`<status>` 块先经正则替换与剥离，再解析为 `.status` 节点；不在 RenderNodeParser 里复刻正则逻辑
3. **不新增 Tavern 标签**——只识别 `<status>` 一种；其它结构化标签后续按需扩展
4. **不缓存 RenderNode**——`RenderTree` 每次重算；`RenderNode` 是 Equatable，SwiftUI diff 直接走结构相等

**Render Inspector**（`Views/RenderInspectorView.swift`，v0.7.1 新增，开发用）：

- **触发**：长按消息卡片 0.5s 弹出 Sheet
- **展示**：原文（raw）/ 处理后（cleanedText）/ RenderNode 树（逐节点类型 + 内容预览）/ 命中的 DisplayRegex / 隐藏标签剥离状态
- **只读**：不修改 raw / context / Result，不暴露 API 给普通用户
- **替代挂 lldb / view debugger** 的开发辅助：开发机 / 真机都能用

### 2.2 导航逻辑

- 首页为两 Tab 结构：聊天 + 设置
- **长按「聊天」Tab**（0.5s）：弹出 QuickSwitcherView 网格，快速切换会话
- 聊天页工具栏可打开会话列表
- 会话列表可创建/删除会话，点击进入会话详情
- 会话详情可配置角色绑定、预设、世界书绑定、系统提示词
- 设置页内，**「用户」为第一项**（昵称、换头像），**「角色卡」为第二项**，其后为 API 配置、系统提示词、世界书、预设、上下文、界面、数据管理等

---

## 3. 世界书（World Book）

世界书是 Pyramid 的核心功能，用于将结构化知识注入 AI 对话 Prompt。

### 3.1 条目字段

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `id` | UUID | 自动生成 | 唯一标识 |
| `title` | String | `""` | 条目标题 / 备注 |
| `content` | String | `""` | 注入 Prompt 的正文内容 |
| `keywords` | [String] | `[]` | 主关键词（任一匹配即触发） |
| `secondaryKeywords` | [String] | `[]` | 次关键词（与主关键词同时匹配才触发） |
| `scanDepth` | Int? | nil（默认 4） | 扫描最近 N 条消息进行匹配 |
| `probability` | Int | 100 | 注入概率 0-100%（见 3.2 的确定性说明） |
| `insertionPosition` | enum | `.afterSystem` | 注入位置：`.beforeSystem` / `.afterSystem` / `.afterHistory` |
| `isEnabled` | Bool | true | 启用/禁用开关 |
| `isConstant` | Bool | false | 常驻条目，始终注入 |
| `priority` | Int | 0 | 优先级（数值越小优先级越高） |
| `matchMode` | enum | `.contains` | 匹配模式：`.contains`（子串）/ `.exact`（全词） |

### 3.2 关键词匹配算法

1. 从当前消息 + 最近 N 条消息（N = `scanDepth`）构建可搜索文本
2. 跳过 `isEnabled == false` 的条目
3. `isConstant == true` 的条目始终注入
4. 主关键词匹配：根据 `matchMode` 检查文本
   - `contains`：不区分大小写的子串匹配
   - `exact`：全词边界匹配（前后不能是字母/数字/下划线）
5. 若主关键词匹配且存在次关键词，至少一个次关键词也必须匹配
6. 概率过滤：对 `(entryId + 可搜索文本)` 做哈希，实现注入概率
7. 按 `priority` 升序排序
8. 硬性限制：最多 **20 条**注入，内容总长最多 **2000 字符**（超出总长上限的条目被跳过）

> **概率确定性说明**：当前实现使用 Swift 标准库 `Hasher`，其种子在每次进程启动时随机化，因此**同一输入在同一进程内结果稳定，但跨启动（及跨 Android 端）无法保证结果一致**。见「已知限制」。

### 3.3 Prompt 注入位置

条目按 `insertionPosition` 分组，作为独立的 `role: system` 消息注入：

- **beforeSystem**：在系统提示词之前注入
- **afterSystem**（默认）：在系统提示词之后注入
- **afterHistory**：在聊天历史之后注入

注入格式：

```
[世界书]
### 条目标题 1
条目内容 1

### 条目标题 2
条目内容 2
```

### 3.4 作用域（三级）

世界书参与注入必须命中下面三种作用域之一，否则**不参与**匹配：

| 作用域 | 字段 | 行为 |
|--------|------|------|
| **全局启用** | `WorldBook.isGloballyEnabled: Bool` | 开关为 true 的书进入「全局启用集合」，进入任何会话都参与匹配 |
| **角色绑定** | `Character.worldBookId: UUID?` | 角色卡自带的世界书，仅在该角色被选中时参与匹配 |
| **会话临时启用** | `ChatSession.extraWorldBookIds: [UUID]` | 会话详情「会话额外启用」中勾选的书，仅当前会话参与匹配 |

注入源 = `全局启用 ∪ 角色绑定(若已选) ∪ 会话额外启用`（按 ID 去重，顺序：全局 → 角色 → 会话）。**所有书一锅炖已禁止**。

导入默认入库为「全局启用」。在导入对话框可选择「绑定到当前角色」将书绑给已选角色，或「覆盖当前世界书条目」覆盖条目但保留作用域。

> 旧数据兼容：旧 `WorldBook` 默认 `isGloballyEnabled = true`，即「所有书默认全局启用」的旧行为；新导入的书严格按入库时的作用域。

### 3.5 多世界书系统

- 支持多个世界书，列表首项为"全局世界书"（始终存在，不能删除）
- 会话可绑定特定世界书（`worldBookId`）
- 未绑定的会话使用全局世界书

### 3.5 SillyTavern 导入兼容

支持导入 SillyTavern 格式的 JSON 世界书，字段映射（V1/V2/V3 共用）：

| SillyTavern 字段 | Pyramid 字段 |
|---|---|
| `comment` / `name` | `title` |
| `content` | `content` |
| `key` / `keys` | `keywords` |
| `keysecondary` / `keySecondary` | `secondaryKeywords` |
| `constant` | `isConstant` |
| `disable` | `isEnabled`（取反） |
| `order` / `priority` / `insertion_order` | `priority` |
| `matchWholeWords` | `matchMode = .exact` |
| `useProbability` / `probability` | `probability`（钳制 0-100；`useProbability=false` 视为恒触发） |
| `depth` / `scanDepth` | `scanDepth` |
| `position` (0=before, 1-2=afterSystem, 3-6=afterHistory) | `insertionPosition` + `positionRaw`（保留 ST 原值 0-6，避免折叠漂移） |

**V3 新增字段（仅存储，运行时未消费；导出/重导入 round-trip 不丢）**：

| ST V3 字段 | Pyramid 字段 |
|---|---|
| `uid` (Int/String) | `externalId: Int?` |
| `group` | `groupKey: String?` |
| `group_weight` | `groupWeight: Double?` |
| `weight` | `weight: Double?` |
| `decay` | `decay: Double?` |
| `case_sensitive` | `caseSensitive: Bool?` |
| `useGroupScoring` | `useGroupScoring: Bool?` |
| `automationId` | `automationId: String?` |
| `role` (0/1/2) | `roleRaw: Int?` |
| `vectorized` | `vectorized: Bool?` |
| `sticky` / `cooldown` / `delay` | `sticky/cooldown/delay: Int?` |
| `displayIndex` | `displayIndex: Int?` |
| `triggers` / `excludes` | `[String]` |
| `outletName` | `outletName: String?` |
| `selectiveLogic` (0..3) | `selectiveLogicRaw: Int?` |
| per-entry `extensions` | `extensionsRaw: JSONValue?` |

导入选项：新建世界书 / 合并到当前 / 覆盖当前条目

---

## 4. 角色卡（Character）

### 4.1 数据模型

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | UUID | 唯一标识 |
| `name` | String | 角色名 |
| `avatarData` | Data? | 头像图片（JPEG/PNG，见 4.2） |
| `description` | String | 角色描述 |
| `personality` | String | 性格 |
| `scenario` | String | 场景 |
| `systemPrompt` | String | 角色专属系统提示词 |
| `worldBookId` | UUID? | 绑定的世界书（可选） |
| `embeddedWorldBookId` | UUID? | ST V3 内嵌 `data.character_book` 自动建的书 ID（见 §4.8）；非全局，参与注入但不出现在全局世界书列表 |
| `isEmbeddedWorldBookEnabled` | Bool | 该角色本次聊天是否注入「`embeddedWorldBookId`」对应内嵌书（per-character 开关，默认 true；旧数据 decodeIfPresent 兜底 true，见 §4.7） |
| `extensionsRegexScripts` | `[SillyTavernRegexScript]` | 酒馆角色卡内嵌的 Regex Script（来自 `data.extensions.regex_scripts`）；导入时自动转成 DisplayRegex（见 §4.6） |
| `talkativeness` | Double? | ST `data.extensions.talkativeness`（0.0–1.0；导入时 clamp） |
| `isFavorite` | Bool? | ST `data.extensions.fav` |
| `depthPrompt` | `CharacterDepthPrompt?` | ST `data.extensions.depth_prompt`（typed lift；运行时按 ST 规则注入，见 §4.9） |
| `extensionsRaw` | `JSONValue?` | `data.extensions` 中未被 typed lift 的剩余子键（`world`、第三方扩展等）—— 字节级 round-trip |
| `tavernHelperRaw` | `JSONValue?` | `data.extensions.tavern_helper` 便捷指针（同时存在于 `extensionsRaw`） |
| `characterBookRaw` | `JSONValue?` | V3 `data.character_book` 整块 —— auto-build 后保留字节级 round-trip |

### 4.2 导入与头像

**导入格式**（自动识别，支持多文件同时选择）：

- **Pyramid 原生**：单个 `Character` 对象或 `[Character]` 数组
- **SillyTavern 角色卡 JSON**：兼容 `spec` v1（字段在根层）、v2（`data` 子对象 = chara_card_v2）、**v3**（`spec: chara_card_v3` + `character_book` + `extensions.depth_prompt` 等）
  - 字段映射：`name`, `description`, `personality`, `scenario`, `system_prompt`
  - `avatar`（base64）→ `avatarData`
  - V3 扩展：`data.character_book` → 自动建内嵌世界书（见 §4.8）；`data.extensions.talkativeness` / `fav` / `depth_prompt` → typed lift（见 §4.1 表）；其余 extensions 子键 + `tavern_helper` → `extensionsRaw` / `tavernHelperRaw` 保真
- **SillyTavern PNG 角色卡**：数据存于 PNG `tEXt` chunk 的 `chara` 关键字；解码兼容三种编码——明文 JSON、`zlib 压缩 + base64`（ST 标准）、纯 base64 JSON

导入后直接写入本地（自动 upsert），完成后提示「已导入 N 张角色卡」。

**头像来源**：
- 相册 / 相机选择，统一缩放（最长边 512px）并压缩为 JPEG（质量 0.8）后存储
- 从 ST 角色卡导入的 `avatar` 保留原始图片数据

### 4.3 会话绑定

- 每个会话可绑定一个角色（`ChatSession.characterId`）
- 绑定方式：会话详情页「角色卡」行选择
- 一个角色可同时被多个会话绑定（当前不限制唯一性）

### 4.4 Prompt 优先级

系统提示词实际合并顺序（`ChatViewModel.effectiveSystemPrompt`）：

1. **角色系统提示词**：若会话绑定了角色，将角色的 `description` / `personality` / `scenario` / `systemPrompt` 中非空字段以空行拼接（`Character.systemPromptText()`）作为提示词
2. **会话系统提示词**（`ChatSession.systemPrompt`）：若设置了，**追加**在角色提示词之后
3. **全局系统提示词**（`AppSettings.systemPrompt`）：**仅当以上都为空**时作为兜底

> 注意：与旧版「首个非空值胜出」不同，实际是**角色与会话提示词可以叠加**，全局仅作兜底。

### 4.5 世界书优先级

世界书绑定优先级（运行时 `worldBookEntries`）：
1. 会话绑定的世界书（`ChatSession.worldBookId`）
2. 角色绑定的世界书（`Character.worldBookId`）
3. 全局世界书

### 4.6 SillyTavern Regex Script 自动发现（角色内嵌）

酒馆角色卡可在 `data.extensions.regex_scripts` 内嵌 Regex Script 数组。导入时自动读出、经 `SillyTavernScriptImporter` 转成 DisplayRegex 后入库；同一会话立即生效（无需重启 / 重发 / 写回 raw）。

**字段映射**（依据酒馆 `public/scripts/extensions/regex/{index,engine}.js` 实际 schema）：

| ST 字段 | Pyramid 字段 | 备注 |
|---|---|---|
| `name` / `scriptName` | `DisplayRegex.name` | 取第一个非空；空时标 "(SillyTavern 导入)" |
| `regex` / `findRegex` | `DisplayRegex.pattern` | 必填；空 / 缺失则整条跳过 |
| `replacement` / `replaceString` | `DisplayRegex.replacement` | 缺省视为空串 |
| `flags` (g/i/m/s) | inline flag group | g 隐式；i/m/s → `(?i)` `(?m)` `(?s)` 前缀 |
| `enabled` / `!disabled` | `DisplayRegex.enabled` | nil → 视为启用；false → 整条跳过 |
| `placement` (数组) | 过滤 | 含 0（MD_DISPLAY）或 2（AI_OUTPUT）才保留；1/3/5/6 跳过 |
| `substituteRegex` (0/1/2) | replacement 处理 | 0=NONE 字面；1=RAW 支持 `$1`/`\1`；2=ESCAPED 先 JSON unescape |
| `promptOnly` / `markdownOnly` / `runOnEdit` | 过滤 / 仅记录 | `promptOnly=true` → 跳过；其余仅记录语义 |

**执行顺序**：JSON 数组顺序保留 → `extensionsRegexScripts` 顺序 → `convert` 后 DisplayRegex 数组顺序 = 实际渲染顺序。

**生命周期绑定**：转换出的 DisplayRegex 携带 `sourceCharacterId = character.id`。删除角色时 `DisplayRegexStore.removeCharacterScopedScripts` 同步清掉对应条目；用户手动添加的 DisplayRegex（`sourceCharacterId == nil`）不被影响。

**作用域**：Pyramid Phase 1 固定为 `assistant.display.pre`（与 `MessageRenderer.applyDisplayRegex` 生效范围一致）。用户消息与系统提示词不受这些脚本影响。

**Phase 1 暂不支持**：JS 引擎执行、`WebView`、HTML/DOM 注入、`promptOnly` 的回写语义。这些留作未来扩展位。

### 4.7 V3 内嵌世界书自动建书（`data.character_book`）

V3 角色卡可在 `data.character_book` 内嵌一本世界书（条目数 / 标题 / `entries`）。导入时自动构建，绑定到该角色，参与聊天注入。

**触发路径**：`CharacterListView.handleImport` 在 `store.upsert(character)` 之前调用 `WorldBookStore.adoptEmbeddedWorldBook(for:)`；返回值（book UUID）写回 `character.embeddedWorldBookId`，再 upsert。

**行为**：

- `characterBookRaw` 为 nil 或非 `.object` → no-op（V1/V2 角色卡保持原行为）。
- 优先复用 `character.embeddedWorldBookId` 对应的现有书（同 ID 命中即更新，不重复建）。
- 否则 `createBook(title:isGloballyEnabled:false)` 新建 —— **embedded 永不全局启用**。
- 书名：`raw["name"]`（String）→ 否则 `"\(character.name) 内嵌世界书"`。
- `entries`：接受 `array` / 数字键字典（ST 两种都有）→ 逐条 `parseSillyTavernEntry`（V3 字段全表，见 §3.5）。
- 合并策略：按 `externalId == uid` 匹配替换旧条目；否则追加。**幂等**：同一角色二次导入复用同一本书，不重复创建。
- `characterBookRaw` 保留字节级 round-trip（导出 → 重导入仍能解析）。

**注入优先级**（`WorldBookStore.activeBooks`，从低到高）：

1. 全局启用世界书（`isGloballyEnabled == true`）
2. **embedded world book**（`character.embeddedWorldBookId`）
3. 角色手动绑定的世界书（`character.worldBookId`）
4. 会话额外启用的世界书（`session.extraWorldBookIds`）

embedded 排在「manual 绑定」之前，让用户 override 优先级；同 ID 重复出现只保留首个。

**Per-character 启用开关**（`isEmbeddedWorldBookEnabled`）：

- 默认 `true`（导入 V3 卡自动开启；旧数据 decodeIfPresent 兜底 `true`，避免老用户升级后行为突变）。
- 用户在「设置 → 角色卡 → 编辑 → 世界书绑定」Section 里看到一个「启用内嵌世界书」Toggle + 「打开「xxx 内嵌世界书」」按钮（仅当 `embeddedWorldBookId != nil` 时显示）。Toggle 切到 `false` → `WorldBookStore.activeBooks` 在 embedded 分支直接跳过该书。
- 按钮触发一个 Sheet，宿主 `WorldBookView(store:settings:characters:initialBookID:)` —— 直接落到该内嵌书页，用户可逐条开关 / 改内容 / 删条目 / 重命名（与普通书同权限；删除由 `WorldBookView` 现有 `deleteBook` 守住 `count > 1`）。
- 「Toggle / 打开按钮 / 字段写入」三个动作都走 `CharacterEditView` 的保存路径，`onSave → store.upsert`，无绕过。

**WorldBookView UX 调整**：

- Picker 标签：内嵌书的标题后面追加「·内嵌·<角色名>」次级小角标，用户一眼能看出哪些书是从角色卡自动建的。
- 「全局启用」Toggle 对内嵌书**隐藏**（embedded 永远非全局，无需暴露误导开关）。
- 作用域描述（`scopeDescription`）优先匹配内嵌书：显示「内嵌于「<角色名>」已启用 / 已停用」+「启用 / 停用开关在「设置 → 角色卡 → 编辑 → 世界书绑定」」；然后才回退到「全局启用 / 角色绑定 / 未启用」三态。

**删除角色清理**：`CharacterListView.deleteCharacters` 在 `store.delete(id)` 之前调 `worldBook.deleteBook(bookID)`（已守住 `books.count > 1`，最后一本书不会被删）。

### 4.8 V3 depth_prompt 运行时注入（`extensions.depth_prompt`）

V3 角色卡可在 `data.extensions.depth_prompt` 定义一条消息：指定 `role`（system/user/assistant）、`depth`（插入位置）、`content`、`position`（before/after/in-chat）。导入时 lift 到 typed `Character.depthPrompt: CharacterDepthPrompt?`，运行时按 ST 规则注入到当前请求的上下文。

**注入路径**：`ChatViewModel.request` 在 `expandMacros` 之后、构造 `OpenAIClient` 之前 switch `(role, position)`：

| `position` | `role` | 注入方式 |
|---|---|---|
| `.inChat` | `.user` / `.assistant` | `DepthPromptInjector.injectInChat(history:&apiHistory, prompt:dp)` —— `count - clamp(depth, 0, count)` 处插一条新消息（depth=0 → 末条后；depth=count → 首条前；越界 clamp） |
| `.inChat` | `.system` | caller 改走 `systemAppendage`（`ChatMessage.Role` 只 user/assistant，system 不进 history） |
| `.before` | 任意 | 拼到 `OpenAIClient.afterSystemText` 末尾（`WorldBookService.injectionText` 之后） |
| `.after` | 任意 | 拼到 `OpenAIClient.afterHistoryText` 末尾（`post_history_instructions` 之后） |

**空内容 guard**：`content.trimmingCharacters(...).isEmpty` 时不注入（`injectInChat` / `systemAppendage` 都早退）；`position=.inChat + role=.system` 静默 no-op（caller 应该改走 systemAppendage）。

**指纹失效**：`computeContextFingerprint` 把 `talkativeness` / `isFavorite` / `depthPrompt` 加入指纹（`Hashable` 合成），三个字段任一改动 → 缓存失效 → 下次请求重算。

**OpenAIClient 接口不变**：`depth_prompt` 内容通过 `afterSystemText` / `afterHistoryText` 现有的拼接路径直接吸收，零新字段。

**未实现语义（保留 raw）**：`position` 之外的 ST 特性（`sticky` / `cooldown` / `delay` 等 World Book Entry 时间字段）只存不消费；`selectiveLogic` / `case_sensitive` 暂不改 `WorldBookService.matches`。这些留作 P3。

---

## 5. 头像系统

### 5.1 显示规则

| 位置 | 规则 |
|------|------|
| 聊天页顶部栏 | 左侧：当前角色头像 28pt + 角色名（展示用，不可点）；右侧：「切换」按钮，点开角色选择器。**角色头像只在顶部栏出现**，不再贴在助手消息旁 |
| 聊天页导航栏 | 左侧：会话列表按钮；右侧：复制全部 + **用户头像** 26pt（酒馆风格） |
| 用户消息气泡 | 用户头像在气泡**右侧**外侧；未设置头像时显示昵称/「我」首字母；受 `showAvatars` 控制 |
| 助手消息气泡 | **不显示任何角色头像**（角色信息只在顶部栏，避免重复） |
| 会话列表每行 | 会话角色头像或默认首字母 |
| 会话快速切换器 | 顶部长条栏 = 当前角色头像（居中）+ 右侧「选择角色卡」按钮；下方为角色头像圆形气泡网格，气泡下方显示会话标签 |

### 5.2 AvatarView 组件

- `AvatarView(imageData:name:size:)`
- 有图片时显示圆形裁剪图片（`scaledToFill` + `Circle`）
- 无图片时显示主题色浅底 + 主题色首字母（取 `name` 首字符大写）
- 角色与用户共用该组件

### 5.3 用户人设（Persona）

| 字段 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `userName` | String | `""` | 用户昵称（气泡昵称、占位首字母） |
| `userAvatarData` | Data | 空 | 用户头像（圆形） |
| `userDisplayName` | String | `""` | 对 AI 看到的用户名（空 = 用 `userName`） |
| `userPersona` | String | `""` | 用户人设正文（多行） |
| `userPersonaInjected` | Bool | `true` | 是否将人设注入对话（默认开） |

- `userDisplayName`：若与昵称分开可在此填写；为空则向 AI 报告你在聊天里自称的昵称。
- `userPersona`：描述背景、性格、说话风格等，可与角色卡独立。
- 「将用户人设注入对话」开关关闭后，**不写入请求**，仅在本机保留。
- 会话级覆盖：在「会话详情」可填「本会话对 AI 显示的用户名」，覆盖全局 `userDisplayName`（仍改动全局 `userName`）。

### 5.4 API 注入顺序（与 SPEC 10.2 同步）

| 顺位 | 内容 | 来源 |
|------|------|------|
| 1 | user-persona 系统段 | `AppSettings.userPersona` + `userDisplayName`（开关开时） |
| 2 | beforeSystem 世界书 | 命中条目 (.beforeSystem) |
| 3 | systemPrompt | 角色 systemPrompt → 会话 systemPrompt → 全局 systemPrompt |
| 4 | afterSystem 世界书 | 命中条目 (.afterSystem) |
| 5 | history | 用户/助手消息原文 |
| 6 | afterHistory 世界书 | 命中条目 (.afterHistory) |

> 楼层号 / 时间戳 / 「已注入世界书 N 条」均为纯 UI 装饰，**不写入 message.content**也不再随请求发送。

---

## 6. UI 装饰层

> **重要**：楼层号和时间戳为纯 UI 装饰，**绝不写入消息 content 字段**，也**不发送至 API**。

### 6.1 楼层号

- 用户消息显示 `#N`（N 从 1 开始递增）
- 助手消息不显示楼层号
- 位于消息气泡左上角小字

### 6.2 时间戳

- 每条消息下方可选显示本地时间
- 格式：`HH:mm`（当天）/ `MM-dd HH:mm`（非当天）
- 由 `showTimestamps` 设置控制

### 6.3 客户端界面缩放（uiScale）

**位置**：设置 → **界面** 子页（与「显示头像」「显示时间戳」「紧凑模式」同组，集中放客户端展示类选项）。

**字段**：`AppSettings.uiScale: UIScale`，三档：

| 档位 | `factor` | 显示名 |
|------|---------|--------|
| `.small` | 0.85 | 小 |
| `.medium`（默认） | 1.0 | 中 |
| `.large` | 1.25 | 大 |

**作用对象**（机械乘 `factor`）：

- **正文字号** — `MarkdownTextView` 内段落、行内（bold / italic / code / link）、标题（heading 1-5）、列表项正文、代码块的等宽字体；统一以「17 × uiScale」为基准，标题按层级字号（28/22/20/17/15）再乘 uiScale
- **辅助字号** — `MessageCard` 头部 `displayName`（caption/12pt）、楼层号 `#N`、时间戳、「已排除」胶囊（caption2/11pt）
- **头像尺寸** — `MessageCard` 内 `AvatarView(size:)`（默认 28pt → 28 × scale）
- **卡片内边距** — 内容卡 `.padding(.horizontal, 12)`、`.padding(.vertical, compact ? 6 : 10)`、外层 `.padding(.horizontal, 12)`、圆角 `cornerRadius = 12`
- **列表间距** — `ChatView.messageList` 的 `LazyVStack(spacing:)`（紧凑 8 / 普通 14 → × scale）
- **块级 padding** — MarkdownTextView 内 VStack 间距（10 → × scale）、引用块左 padding（10 → × scale）、代码块 padding（10 → × scale）、列表缩进（4 → × scale）、列表项 HStack 间距（8 → × scale）、分割线上下 padding（6 → × scale）
- **原生面板** — `StatusView` 通过 `MessageCard` 调用处的 `.scaleEffect(scale, anchor: .topLeading)` 整体缩放（不修改内部字面量，避免污染其它调用点）

**与「紧凑模式」的关系**（叠加，非互斥）：

- 缩放调基准：`spacing = base × uiScale.factor`
- 紧凑再略减间距：`(compactMode ? 8 : 14) × uiScale.factor`
- 字号：紧凑模式**不**影响字号，只动间距与 padding；缩放档位独立生效

**约束**：

1. 只作用于客户端展示层，不修改 `message.content`，不影响复制 / 编辑 / 重新生成 / API 发送
2. 切换档位立即生效（`@AppStorage` → `@ObservedObject` → SwiftUI 自动重绘整棵子树）
3. 不修改 MarkdownTextView / StatusView 内部字面量之外的设计常量（如颜色、阴影）；只调比例

### 6.4 设置分组归属

设置页的子页划分遵循「同类相聚」原则，**客户端展示相关项集中在「界面」组，渲染管线相关项集中在「渲染」组**：

| 子页 | 归属 | 项 |
|------|------|----|
| **界面** | 客户端展示（视觉偏好） | `uiScale` / `showAvatars` / `showTimestamps` / `compactMode` |
| **渲染** | 渲染管线（内容呈现规则） | `enableMarkdown` / `hideTagStripEnabled` / `hideTagsRaw` / DisplayRegex |

划分依据：

- **界面**：只影响「怎么展示」——卡片多大、间距多宽、头像出不出现、时间戳显不显示；与内容无关
- **渲染**：影响「内容怎么变成视图」——Markdown 解不解析、隐藏标签剥不剥离、显示用正则是哪几条；规则可由 Preset 覆盖

两者独立，但都对「卡片正文的视觉」有影响；规则互不重叠，没有同一项需要二选一放在哪边的问题。

---

## 7. 预设（Preset）

### 7.1 字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | UUID | 唯一标识 |
| `name` | String | 预设名称 |
| `modelName` | String? | 模型名称（nil = 使用全局） |
| `systemPrompt` | String? | 系统提示词（nil = 不覆盖会话） |
| `worldBookId` | UUID? | 绑定的世界书（nil = 不覆盖会话） |
| `temperature` | Double? | 采样温度（nil = 不覆盖） |
| `topP` | Double? | 核采样（0-1） |
| `maxTokens` | Int? | 单次最大输出 token |
| `enableMarkdown` | Bool? | 三态：true=强制开 / false=强制关 / nil=沿用全局 `enableMarkdown` |
| `displayRegexIds` | `[UUID]` | 关联的「显示用正则」ID 列表；空 = 应用所有启用中的正则 |

> 采样参数在「预设编辑」中有「覆盖采样参数」开关。开 = 任一字段填值会随下次请求一起发到 OpenAI 兼容接口；未填字段不写入请求体。
> 切换预设保留所有消息历史（仅元数据 `appliedPresetId` / `systemPrompt` / `worldBookId` 更新）。

### 7.2 应用行为

在会话详情选择某预设时（`SessionDetailView.apply`）：
1. 设置会话的 `systemPrompt` 为预设值（可能为 nil）
2. 设置会话的 `worldBookId` 为预设值（可能为 nil）
3. 若预设的 `modelName` 非空，设置**全局** `modelName`
4. `appliedPresetId` 记录到会话，下次请求时携带其采样参数

即：预设一次性把「系统提示词、世界书绑定」写入当前会话，模型名写入全局，采样参数延迟到下次请求生效。

> 实际请求时 `effectiveModelName` / `effectiveSystemPrompt` 优先采用预设值，再回退到全局 / 会话 / 角色。`effectiveModelName` **不**会回写到 `settings.modelName` —— 切换预设只影响当前会话的下次请求。

---

## 8. 聊天消息

### 8.1 消息模型

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | UUID | 唯一标识 |
| `role` | enum | `.user` 或 `.assistant` |
| `content` | String | 消息内容 |
| `createdAt` | Date? | 创建时间 |

### 8.2 会话模型

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | UUID | 唯一标识 |
| `title` | String | 会话标题（首条用户消息自动截取，最多 20 字符；可手动重命名） |
| `messages` | [ChatMessage] | 消息列表 |
| `createdAt` | Date | 创建时间 |
| `worldBookId` | UUID? | 绑定的世界书 |
| `systemPrompt` | String? | 会话级系统提示词覆盖 |
| `appliedPresetId` | UUID? | 最近应用的预设 |
| `characterId` | UUID? | 绑定的角色卡 |
| `userDisplayNameOverride` | String | 本会话对 AI 显示的用户名覆盖 |
| `extraWorldBookIds` | [UUID] | 本会话「额外启用」的世界书 ID 集合 |
| `isPinned` | Bool | 置顶；列表与网格置顶段靠前显示 |
| `draft` | String | 输入框未发送草稿；切换会话时保留，发送或取消时清空 |

### 8.2.1 会话列表与排序

- 排序：置顶在前 → 按 `createdAt` 倒序；置顶段使用「置顶」Section，剩余为「其它」Section。
- 行内容（`SessionListView.sessionRow`）：
  - 左侧：绑定角色头像（无角色则用标题首字母）。
  - 中上：会话标题（首条用户消息自动截取，或手动命名；为空且有角色时回退为角色名）。
  - 中右：置顶图钉 + 角色名角标。
  - 中下：最后一条消息单行预览（无则显示「尚无消息」）+ 时间戳（最后一条消息时间或创建时间）。
  - 右侧：当前会话的选中对勾。
- 行高亮：当前会话行 `listRowBackground` 用主色 12% 透明。
- 操作（左滑 / 右滑 / 长按菜单 / 删除 confirm）：
  - 左滑：置顶 / 取消置顶
  - 右滑：重命名 / 删除（确认）/ 详情（进入 SessionDetailView）
  - 长按菜单：重命名 / 置顶 / 详情 / 删除
  - 删除须 `confirmationDialog` 二次确认

### 8.2.2 新建会话

- 「新建」按钮为 Menu：
  - **新建空白会话**：直接创建。
  - **新建并绑定角色**：先弹出角色选择 Sheet，点选后用 `ChatStore.createSession(character:)` 创建并绑定。
- 新建会话标题默认「角色名」或「「新会话」占位」；首条用户消息发出后自动改写标题（前 20 字符）。

### 8.2.3 草稿（输入框未发送文本）

- `ChatSession.draft` 按会话保存输入框内容。
- `ChatView.onAppear` / `onChange(of: store.currentSessionID)` 触发 `handleSessionChange`：先把当前 `input` 写入旧会话的 `draft`，再把新会话的 `draft` 装载进 `input`。
- `onChange(of: viewModel.input)` 实时把 `input` 持久化到当前会话 `draft`。
- 用户主动「发送」后 `input` 与 `draft` 都被清空；「停止生成」恢复 `input` 与 `draft`。

### 8.3 消息操作

| 操作 | 适用范围 | 行为 |
|------|----------|------|
| 复制 | 所有消息 | 复制内容到剪贴板 |
| 编辑 | 所有消息（发送中不可用） | 全屏编辑器修改内容，**保存后不自动重发** |
| 重新生成 | 仅助手消息 | 删除该助手消息及后续消息，重新发送（需确认） |
| 删除 | 所有消息（发送中不可用） | 删除单条消息（需确认） |

- 长按消息气泡弹出 `.contextMenu` 菜单，操作按钮根据消息角色与状态动态展示。
- 楼层号（用户消息 `#N`）在删除中间消息后 **保持稳定**：剩余消息的楼层号不重排，仅被删的楼层消失。这与 SPEC §6.1「用户消息显示 `#N`」一致。
- 「重新生成」是「删除后续 → 重新请求」，不是「替换当前回复」；删除前需 `confirmationDialog` 确认。

### 8.4 流式传输

- 开启流式：立即创建空助手消息，通过 SSE 逐块追加内容，实时更新 UI
- 关闭流式：等待完整响应后一次性追加
- 取消：`ChatViewModel.cancelCurrent()` `Task.cancel()` 取消当前流；已生成的内容保留，未生成时占位空消息被删除；同时把输入文本恢复到输入框与会话草稿。

### 8.4.1 停止生成 / 重试 / 错误提示

- 输入栏：发送中显示「停止」按钮（红圆 stop），点击调用 `viewModel.cancelCurrent()`。
- 错误提示（`errorBanner`）：网络 / 超时 / 解析 / 空响应均显示在顶部红色横幅。
  - 含「重试」按钮：复用最近失败的用户消息（`lastFailedUserMessageID`）重新发起一次请求。
  - 含「关闭」按钮：清空 `errorMessage` / `lastFailedUserMessageID` / `lastFailedReason`。
- API 正文（向 `OpenAIClient` 发送的 `messages`）**永远不包含**楼层号、时间戳、「已注入世界书 N 条」、草稿、未发送输入；这些都是纯 UI 装饰。

### 8.4 消息显示管线

> **核心约束**：存储 / 编辑 / 复制 / 重新生成 / 发送 API 全部使用 `message.content` 原始内容；以下 4 个阶段**仅**作用于气泡渲染。

```
原始 content
  ↓ (1) 显示用正则（仅助手消息，作用域 assistant.display.pre）
  ↓ (2) 隐藏标签剥离（<tag>...</tag> 默认含 think / thinking）
  ↓ (3) Markdown 渲染（AttributedString(markdown:)，失败则降级为剥离 HTML 后的纯文本）
  ↓ (4) HTML 兜底（<…> 全部剥掉，避免残留）
气泡显示
```

四阶段均不写回 `message.content`；任何阶段失败（正则不合法 / 隐藏标签 pattern 编译失败 / Markdown 解析失败）均回退到当前 stage 的原文，不崩溃。

#### 8.4.1 显示用正则（Display Regex）

- 字段：`id` / `name` / `pattern` / `replacement` / `enabled` / `scope`（固定 `assistant.display.pre`）/ `sourceCharacterId`（可空，来自角色内嵌 ST Regex Script 自动转出）
- 行为：仅对 `role == .assistant` 的消息在渲染前依次应用；用户消息不经过。
- 顺序：先按当前预设的 `displayRegexIds` 顺序，再追加其它启用的正则（兜底）。
- 编辑：保存前用 `NSRegularExpression` 校验 `pattern`，失败给出错误提示并阻止保存。
- 来源：① 用户在「显示用正则」面板手动创建；② 酒馆角色卡导入时由 §4.6 的 ST Regex Script 自动转出（带 `sourceCharacterId`，删除角色时同步清理）。
- **Phase 1 无 ST 脚本 / 扩展市场**：不做全量 JS 沙箱；只接受酒馆已落盘的 JSON 字段（详见 §4.6 表）。

#### 8.4.2 隐藏标签剥离

- 全局开关 `hideTagStripEnabled`（默认 true）。
- 标签列表 `hideTagsRaw`（逗号或换行分隔），默认 `think,thinking`。
- 模式：兼容 `<tag>...</tag>`、`<tag attr="...">...</tag>`、`<tag>` 与 `</tag>` 配对不严格的情况（`.` 跨行匹配）。
- 失败：单个标签 pattern 编译失败时跳过该标签，不影响其他标签；绝不修改原文。

#### 8.4.3 Markdown 渲染

- `settings.enableMarkdown` 与 `preset.enableMarkdown` 同时为空 / 同时为 false 时，渲染为纯文本（仍会剥离 HTML 兜底）。
- 实际生效：`preset.enableMarkdown` ≠ nil 时它覆盖全局；否则读全局 `enableMarkdown`（默认 true）。
- 助手与用户气泡均生效；用户气泡走相同的 `MessageRenderer` 路径，因此同样保留隐藏标签剥离与正则管道（用户消息上的正则不会触发，因作用域限定助手）。

### 8.5 Markdown 渲染（原生）

原生 `AttributedString` 渲染（iOS 15+），支持：

- **段落**：Markdown 自动解析
- **代码块**：等宽字体、水平滚动、深色背景、圆角矩形
- **列表**：有序/无序列表
- **行内格式**：粗体、斜体、行内代码、可点击链接
- **未识别 HTML 标签**：自动剥掉（`<…>` 整段匹配），不显示原始标签字符

> **无 WebView**：禁止使用 `WKWebView` / `SFSafariViewController` 作为聊天列表或气泡。

### 8.6 宏

进入 API 之前在消息文本上展开 `{{user}}` / `{{char}}` 及其大小写变体（`{{User}}` / `{{CHAR}}` 等，匹配 `(?i)\{\{\s*<token>\s*\}\}`）。

- `user` 解析顺序：会话 `userDisplayNameOverride` → 全局 `userDisplayName` → 全局 `userName`
- `char` 解析：当前会话绑定的角色卡 `name`
- 替换对象：**仅** 送入 `OpenAIClient` 的 `messages` 副本；**不**写回 `message.content`，**不**作用于气泡显示。
- 顺序（与 SPEC §10.2 同步）：用户人设 → 角色 → 会话/预设 → 世界书 → 历史（已展开宏）→ 用户最新消息（已展开宏）。

### 8.7 其他

- **上下文长度提示**：可选栏显示当前上下文字符数，超过阈值变橙色警告（默认 12000，可调 2000-50000）
- **注入调试指示器**：可选显示世界书注入状态
- **紧凑模式**：减少气泡间距和圆角
- **时间戳**：可选显示消息时间
- **复制全部对话**：工具栏按钮一键复制整个对话

---

## 9. 存储与导入导出

### 9.1 存储方式

> **当前实现**: 100% 使用 UserDefaults（JSON 编码），无数据库。

| 数据 | UserDefaults Key | 格式 |
|------|-------------------|------|
| 聊天会话 + 消息 | `chatSessions` | `[ChatSession]` |
| 当前会话 ID | `currentSessionID` | UUID 字符串 |
| 世界书 + 条目 | `worldBookList` | `[WorldBook]` |
| 世界书旧版条目（一次性迁移） | `worldBookEntries` | `[WorldBookEntry]`（读取后移除） |
| 预设 | `presets` | `[Preset]` |
| 角色卡 | `characters` | `[Character]` |
| 用户昵称 | `userName` | String（@AppStorage） |
| 用户头像 | `userAvatarData` | Data（@AppStorage，空 Data = 无头像） |
| 全局设置 | 见附录 12 | @AppStorage |

> **TODO**: 迁移到更可靠的持久化方案（如 SwiftData / Core Data / 文件系统），以解决大数据量下 UserDefaults 的性能问题。

### 9.2 世界书导出

- 导出为 JSON 文件（`pyramid-worldbook-<后缀>-<时间戳>.json`）
- 支持导出当前书或全部书
- 通过 iOS 分享面板（`ShareLink`）发送
- 格式为 `WorldBookExport`（`{ "version": 1, "books": [...] }`，pretty + sortedKeys）

### 9.3 世界书导入

- **导入机制**：使用 `UIDocumentPicker`（`asCopy: true`）选择文件，支持一次多选，逐个解析并排队处理
- 支持格式（自动检测）：
  - Pyramid 原生 `WorldBookExport`（`version` + `books`）
  - 裸世界书数组 `[WorldBook]`
  - 单个 `WorldBook`
  - SillyTavern 世界书（顶层 `entries` 为字典或数组，或顶层为数组）
- 原生格式导入选项：**合并**（按 id 去重）/ **覆盖**（替换全部世界书）
- SillyTavern 导入选项：**新建世界书** / **合并到当前世界书**（按内容去重）/ **覆盖当前世界书条目**
- 解析失败时弹出「导入失败」并显示具体错误信息

### 9.4 角色卡导入

- **导入机制**：与 9.3 相同的 `UIDocumentPicker`（`asCopy: true`），支持多选，自动识别后直接写入（无确认弹窗）
- 支持格式见 4.2
- 单个文件解析失败即中断，并弹出错误提示

### 9.5 全量备份（设置 → 备份）

- **导出**：JSON 单一文件（`pyramid-backup-yyyyMMdd-HHmmss.json`），内容包含会话列表（含消息）+ 当前会话指针 + 角色卡 + 世界书 + 预设，`pretty + sortedKeys`
- **导入**：通过 `UIDocumentPicker` 选择 JSON
  - **合并**：按 `id` 去重，已有保留本机版本，新条目追加；最后尝试恢复 `currentSessionID`
  - **覆盖**：先清空本机所有数据再替换（需二次确认）
- 失败原因（解析失败 / 版本不兼容）通过 alert 弹窗告知用户
- 备份是单一 JSON，便于 iCloud / AirDrop / 「文件」App 迁移

> **历史修复**：早期用 SwiftUI `fileImporter` 时，真机上会因 security-scoped URL 权限 / iCloud 占位文件导致「点打开无反应」；已改为 `UIDocumentPicker` 并强制 `asCopy: true`，把文件直接复制进 App 沙盒读取，彻底绕开该问题。

---

## 10. API 集成

### 10.1 支持的后端

兼容所有实现 OpenAI `/v1/chat/completions` 接口的服务：

- OpenAI（GPT-4o、GPT-4o-mini、GPT-4 等）
- Qwen（通义千问）
- DeepSeek
- Groq、Together、Fireworks 等
- 本地部署（Ollama、LM Studio、vLLM 等）

### 10.2 客户端行为

- 自动补全 `/v1` 和 `/chat/completions` 路径（Base URL 以 `/v1` 结尾或自动补上）
- 60 秒请求超时
- 支持无认证（本地服务器场景，apiKey 为空时跳过 Authorization 头）
- 系统提示词组装顺序：`beforeSystem → systemPrompt → afterSystem → history → afterHistory`（均为独立 `system` 消息）
- `systemPrompt` 内部合并：角色 `systemPromptText()` 优先 → 会话 `systemPrompt` → 全局 `systemPrompt`（兜底）
- 采样参数（`temperature` / `top_p` / `max_tokens`）：仅在预设填写时随请求传递；留空 = 不写字段，使用后端默认
- 模型列表：尝试 `GET /v1/models`（自动补 `/v1`，并回退到去掉 `/v1` 的 `/models`），兼容 `data[].id` 与纯字符串数组两种响应
- 消息进入 API 前会做宏展开（`{{user}}` / `{{char}}`，大小写不敏感）。展开仅作用于送入 `OpenAIClient` 的副本，存储与显示始终保留原文。

### 10.3 不支持的特性

> **TODO 以下功能尚未实现：**
> - Anthropic Claude 原生 Messages API
> - Gemini API
> - 图片/视觉/多模态
> - Function Calling / Tool Use
> - Token 精确计数（当前使用字符数粗估）

---

## 11. 双端对齐原则

### 11.1 功能对齐

iOS 和 Android 双端应实现**相同的核心功能集**，包括：

- [x] 多会话聊天（持久化）
- [x] OpenAI 兼容 API 接入
- [x] 流式 / 非流式传输
- [x] 世界书系统（字段、匹配算法、注入位置）
- [x] SillyTavern 世界书导入
- [x] 预设系统
- [x] Markdown 渲染
- [x] 消息操作（复制、编辑、重新生成、删除）
- [x] 角色卡导入与管理（含 ST v1/v2 / PNG）
- [x] 头像系统（角色 + 用户）
- [x] 会话快速切换（长按 Tab）

### 11.2 行为对齐

- 关键词匹配算法：双端实现必须产生**完全相同**的匹配结果
- Prompt 注入顺序：`beforeSystem → systemPrompt → afterSystem → history → afterHistory`
- 系统提示词合并：角色提示词 + 会话提示词可叠加，全局仅兜底
- 世界书绑定优先级：`session.worldBookId → character.worldBookId → global`
- SillyTavern 字段映射：双端使用完全相同的映射规则
- 注入格式：`[世界书]\n### Title\nContent`

> **概率过滤说明**：双端需约定一致的哈希实现以保证确定性；当前 iOS 用 Swift `Hasher`（每次启动随机种子），**无法跨端复现**，需在双端统一改用确定性哈希（见「已知限制」）。

### 11.3 数据格式对齐

- 世界书导出格式统一为 `WorldBookExport`（version: 1）
- JSON 字段命名和类型双端一致
- UserDefaults / SharedPreferences 的存储格式应尽量兼容

### 11.4 UI 差异允许

- 导航模式可因平台差异不同（iOS NavigationStack vs Android Navigation Compose）
- 键盘交互可因平台差异不同
- 分享/导出交互可因平台差异不同
- 状态栏、安全区域处理可不同

### 11.5 版本同步

- 双端大版本号保持一致（如 v1.0、v2.0）
- 功能发布节奏尽量同步
- 本文档为双端共同的规格来源

---

## 12. 附录：全局设置项

| 设置项 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `baseURL` | String | `""` | API 基础 URL |
| `apiKey` | String | `""` | API 密钥 |
| `modelName` | String | `""` | 当前模型名称 |
| `systemPrompt` | String | `""` | 全局系统提示词 |
| `useStreaming` | Bool | true | 是否启用流式传输 |
| `worldBookEnabled` | Bool | true | 世界书总开关 |
| `showInjectionIndicator` | Bool | false | 显示注入调试指示器 |
| `showContextHint` | Bool | true | 显示上下文长度提示 |
| `contextLimit` | Int | 12000 | 上下文长度阈值（字符） |
| `compactMode` | Bool | false | 紧凑模式 |
| `showTimestamps` | Bool | true | 显示时间戳 |
| `showAvatars` | Bool | true | 聊天页显示头像（角色栏 + 用户消息） |
| `uiScale` | enum `UIScale` | `.medium` (1.0) | 客户端界面整体缩放档位（小=0.85 / 中=1.0 / 大=1.25），作用于消息卡片正文字号、楼层/时间辅助字号、头像尺寸、卡片内边距与列表间距 |
| `userName` | String | `""` | 用户昵称（用户头像占位首字母） |
| `userAvatarData` | Data | 空 | 用户头像数据（圆形显示，空 = 显示首字母） |
| `contextTrimMode` | enum | `.byMessages` | 上下文裁剪策略：`.off` / `.byMessages` / `.byCharacters` |
| `contextTrimMessages` | Int | 50 | 按消息条数裁剪：保留最近 N 条（2-500） |
| `contextTrimCharacters` | Int | 8000 | 按字符数裁剪：保留最近 C 字符（500-80000） |
| `enableMarkdown` | Bool | true | 全局「启用 Markdown 渲染」开关（预设可覆盖） |
| `hideTagStripEnabled` | Bool | true | 全局「剥离隐藏标签」开关 |
| `hideTagsRaw` | String | `think,thinking` | 隐藏标签列表原文本（逗号 / 换行分隔） |

---

## 14. 上下文裁剪

发送请求前可按设置裁剪历史，节省 token 与避免超出上下文窗口：

| 模式 | 行为 |
|------|------|
| `.off` | 全量历史；不做裁剪 |
| `.byMessages`（默认） | 仅保留最近 N 条消息（默认 50，范围 2-500） |
| `.byCharacters` | 仅保留最近 C 字符（默认 8000，范围 500-80000） |

**保留保证**：发起当前请求的那条用户消息（`userMessageID`）若被裁剪掉，仍会附加回历史末尾——AI 永远看得到本轮提问。

**上下文长度提示**：`ChatView.contextHintBar` 显示的字符数 = 「裁剪后历史字符数 + 世界书注入估算字符数」，与实际请求体一致。

**裁剪对象**：仅 `messages` 历史；系统提示词（角色 / 会话 / 全局 / 用户人设 / 世界书注入段）**不被裁剪**，且不被计入裁剪预算。

---

## 13. 已知限制

> 当前无独立 `KNOWN_ISSUES.md`，以下限制统一记录于此。

1. **存储可靠性**：全部数据存于 UserDefaults，数据量大时（长对话、多角色、大世界书）可能出现性能与容量问题。**TODO**：迁移到 SwiftData / Core Data / 文件系统。
2. **概率匹配确定性**：注入概率用 Swift `Hasher`（每次进程启动随机种子），同一输入在同一进程内稳定，但**跨启动不稳定，且无法与 Android 端复现相同结果**。若需跨端一致，应改用确定性哈希（如基于文本的 stable hash）。
3. **CI 产物未签名**：GitHub Actions 打出的 `Pyramid-unsigned.ipa` 为**未签名**归档，无法直接安装到真机，仅用于测试/发布流程验证。真机安装需另配签名。
4. **PNG 角色卡解压上限**：解压 `chara` 数据时输出缓冲上限为 2MB，超大卡片可能解压失败。
5. **世界书注入硬上限**：单次最多注入 20 条、内容总长最多 2000 字符；超出上限的条目会被跳过（不报错）。
6. **ST 世界书合并去重**：合并到当前世界书时按 `content` 去重，标题/关键词变化而内容相同的条目不会被再次导入。
7. **角色卡 PNG 识别范围**：仅解析 PNG 顶层 `tEXt` chunk 的 `chara` 关键字；zTXt / iTXt（压缩）或其它存储方式不识别。
8. **无云端同步**：所有数据仅存本机，不做任何服务器同步（属设计原则）。