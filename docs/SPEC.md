# Pyramid 产品规格文档

> 本文档为 iOS / Android 双端共用的产品规格，描述当前已实现功能与计划功能（TODO）。
> 最后更新：2026-08-16

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

### 3.4 多世界书系统

- 支持多个世界书，列表首项为"全局世界书"（始终存在，不能删除）
- 会话可绑定特定世界书（`worldBookId`）
- 未绑定的会话使用全局世界书

### 3.5 SillyTavern 导入兼容

支持导入 SillyTavern 格式的 JSON 世界书，字段映射：

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
| `position` (0=before, 1-2=afterSystem, 3-6=afterHistory) | `insertionPosition` |

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

### 4.2 导入与头像

**导入格式**（自动识别，支持多文件同时选择）：

- **Pyramid 原生**：单个 `Character` 对象或 `[Character]` 数组
- **SillyTavern 角色卡 JSON**：兼容 `spec` v1（字段在根层）与 v2（字段在 `data` 子对象）
  - 字段映射：`name`, `description`, `personality`, `scenario`, `system_prompt`
  - `avatar`（base64）→ `avatarData`
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

### 5.3 用户头像设置

- 在「设置 → 用户」中可设置**昵称**与**用户头像**
- 头像更换方式与角色一致（相册 / 相机 / 移除），圆形预览
- 设置后聊天页用户消息气泡旁即显示该头像
- 关闭 `showAvatars` 后聊天页用户消息气泡不再显示头像

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

> 采样参数在「预设编辑」中有「覆盖采样参数」开关。开 = 任一字段填值会随下次请求一起发到 OpenAI 兼容接口；未填字段不写入请求体。

### 7.2 应用行为

在会话详情选择某预设时（`SessionDetailView.apply`）：
1. 设置会话的 `systemPrompt` 为预设值（可能为 nil）
2. 设置会话的 `worldBookId` 为预设值（可能为 nil）
3. 若预设的 `modelName` 非空，设置**全局** `modelName`
4. `appliedPresetId` 记录到会话，下次请求时携带其采样参数

即：预设一次性把「系统提示词、世界书绑定」写入当前会话，模型名写入全局，采样参数延迟到下次请求生效。

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
| `title` | String | 会话标题（首条用户消息自动截取，最多 20 字符） |
| `messages` | [ChatMessage] | 消息列表 |
| `createdAt` | Date | 创建时间 |
| `worldBookId` | UUID? | 绑定的世界书 |
| `systemPrompt` | String? | 会话级系统提示词覆盖 |
| `appliedPresetId` | UUID? | 最近应用的预设 |
| `characterId` | UUID? | 绑定的角色卡 |

### 8.3 消息操作

| 操作 | 适用范围 | 行为 |
|------|----------|------|
| 复制 | 所有消息 | 复制内容到剪贴板 |
| 编辑 | 所有消息（发送中不可用） | 全屏编辑器修改内容 |
| 重新生成 | 仅助手消息 | 删除该助手消息及后续消息，重新发送（需确认） |
| 删除 | 所有消息（发送中不可用） | 删除单条消息（需确认） |

### 8.4 流式传输

- 开启流式：立即创建空助手消息，通过 SSE 逐块追加内容，实时更新 UI
- 关闭流式：等待完整响应后一次性追加
- 支持通过 `AsyncThrowingStream` 取消请求

### 8.5 Markdown 渲染

原生 `AttributedString` 渲染，支持：

- **段落**：Markdown 自动解析
- **代码块**：等宽字体、水平滚动、深色背景、圆角矩形
- **列表**：有序/无序列表
- **行内格式**：粗体、斜体、行内代码、可点击链接

### 8.6 其他

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
| `userName` | String | `""` | 用户昵称（用户头像占位首字母） |
| `userAvatarData` | Data | 空 | 用户头像数据（圆形显示，空 = 显示首字母） |

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