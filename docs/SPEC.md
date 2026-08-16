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
│   ├── SessionListView（会话列表，Sheet）
│   │   └── SessionDetailView（单会话配置，Sheet）
│   └── EditMessageSheet（编辑消息，Sheet）
└── Tab 2: 设置
    ├── SettingsView（全局设置表单）
    │   ├── ModelPicker（模型选择，Sheet）
    │   ├── WorldBookView（世界书管理）
    │   │   └── WorldBookEditView（编辑条目，Sheet）
    │   └── PresetListView（预设列表）
    │       └── PresetEditView（编辑预设，Sheet）
```

### 2.2 导航逻辑

- 首页为两 Tab 结构：聊天 + 设置
- 聊天页工具栏可打开会话列表
- 会话列表可创建/删除会话，点击进入会话详情
- 会话详情可配置预设、世界书绑定、系统提示词
- 设置页内可进入世界书管理、预设管理

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
| `probability` | Int | 100 | 注入概率 0-100%（确定性哈希，同输入同结果） |
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
6. 概率过滤：对 `(entryId + 可搜索文本)` 做哈希，实现确定性随机
7. 按 `priority` 升序排序
8. 硬性限制：最多 **20 条**注入，内容总长最多 **2000 字符**

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

- 支持多个世界书，列表首项为"全局世界书"（始终存在）
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
| `useProbability` / `probability` | `probability` |
| `depth` / `scanDepth` | `scanDepth` |
| `position` (0=before, 1-2=afterSystem, 3-6=afterHistory) | `insertionPosition` |

导入选项：新建世界书 / 合并到当前 / 覆盖当前条目

---

## 4. 角色卡

### 4.1 当前状态

> **TODO**: 角色卡 PNG/JSON 导入功能尚未实现。

当前通过「系统提示词 + 世界书 + 预设」组合可模拟基础角色卡体验：
1. 系统提示词定义角色人格
2. 世界书绑定角色世界观
3. 保存为预设以便复用

### 4.2 计划功能

> **TODO**: 支持角色卡 PNG（含元数据）和 JSON 导入，字段包括：
> - name（角色名）
> - description（角色描述）
> - personality（性格）
> - scenario（场景）
> - first_mes（开场白）
> - mes_example（对话示例）
> - creator_notes（作者备注）
> - system_prompt（系统提示词）
> - post_history_instructions（历史后指令）
> - tags（标签）
> - spec（规范版本）

---

## 5. 预设（Preset）

### 5.1 字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | UUID | 唯一标识 |
| `name` | String | 预设名称 |
| `modelName` | String? | 模型名称（nil = 使用全局） |
| `systemPrompt` | String? | 系统提示词（nil = 使用全局） |
| `worldBookId` | UUID? | 绑定的世界书（nil = 使用全局） |

### 5.2 应用行为

应用预设到会话时：
1. 设置会话的 `systemPrompt` 为预设值
2. 设置会话的 `worldBookId` 为预设值
3. 设置**全局** `modelName` 为预设值

---

## 6. 聊天消息

### 6.1 消息模型

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | UUID | 唯一标识 |
| `role` | enum | `.user` 或 `.assistant` |
| `content` | String | 消息内容 |
| `createdAt` | Date? | 创建时间 |

### 6.2 会话模型

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | UUID | 唯一标识 |
| `title` | String | 会话标题（首条用户消息自动截取，最多 20 字符） |
| `messages` | [ChatMessage] | 消息列表 |
| `createdAt` | Date | 创建时间 |
| `worldBookId` | UUID? | 绑定的世界书 |
| `systemPrompt` | String? | 会话级系统提示词覆盖 |
| `appliedPresetId` | UUID? | 最近应用的预设 |

### 6.3 消息操作

| 操作 | 适用范围 | 行为 |
|------|----------|------|
| 复制 | 所有消息 | 复制内容到剪贴板 |
| 编辑 | 所有消息（发送中不可用） | 全屏编辑器修改内容 |
| 重新生成 | 仅助手消息 | 删除该助手消息及后续消息，重新发送（需确认） |
| 删除 | 所有消息（发送中不可用） | 删除单条消息（需确认） |

### 6.4 流式传输

- 开启流式：立即创建空助手消息，通过 SSE 逐块追加内容，实时更新 UI
- 关闭流式：等待完整响应后一次性追加
- 支持通过 `AsyncThrowingStream` 取消请求

### 6.5 Markdown 渲染

原生 `AttributedString` 渲染，支持：

- **段落**：Markdown 自动解析
- **代码块**：等宽字体、水平滚动、深色背景、圆角矩形
- **列表**：有序/无序列表
- **行内格式**：粗体、斜体、行内代码、可点击链接

### 6.6 其他

- **上下文长度提示**：可选栏显示当前上下文字符数，超过阈值变橙色警告（默认 12000，可调 2000-50000）
- **注入调试指示器**：可选显示世界书注入状态
- **紧凑模式**：减少气泡间距和圆角
- **时间戳**：可选显示消息时间
- **复制全部对话**：工具栏按钮一键复制整个对话

---

## 7. 存储与导入导出

### 7.1 存储方式

> **当前实现**: 100% 使用 UserDefaults（JSON 编码），无数据库。

| 数据 | UserDefaults Key | 格式 |
|------|-------------------|------|
| 聊天会话 + 消息 | `chatSessions` | `[ChatSession]` |
| 当前会话 ID | `currentSessionID` | UUID 字符串 |
| 世界书 + 条目 | `worldBookList` | `[WorldBook]` |
| 预设 | `presets` | `[Preset]` |

> **TODO**: 迁移到更可靠的持久化方案（如 SwiftData / Core Data / 文件系统），以解决大数据量下 UserDefaults 的性能问题。

### 7.2 世界书导出

- 导出为 JSON 文件
- 支持导出当前书或全部书
- 通过 iOS 分享面板发送

### 7.3 世界书导入

- 支持 Pyramid 原生格式（`WorldBookExport` 包装器或裸数组）
- 支持 SillyTavern 格式（自动检测）
- 合并模式：按 ID 去重 / 覆盖
- SillyTavern 导入选项：新建 / 合并到当前 / 覆盖当前

---

## 8. API 集成

### 8.1 支持的后端

兼容所有实现 OpenAI `/v1/chat/completions` 接口的服务：

- OpenAI（GPT-4o、GPT-4o-mini、GPT-4 等）
- Qwen（通义千问）
- DeepSeek
- Groq、Together、Fireworks 等
- 本地部署（Ollama、LM Studio、vLLM 等）

### 8.2 客户端行为

- 自动补全 `/v1` 和 `/chat/completions` 路径
- 60 秒超时
- 支持无认证（本地服务器场景，apiKey 为空时跳过 Authorization 头）
- 模型列表：尝试 `GET /v1/models`，兼容多种响应格式

### 8.3 不支持的特性

> **TODO 以下功能尚未实现：**
> - Anthropic Claude 原生 Messages API
> - Gemini API
> - 图片/视觉/多模态
> - Function Calling / Tool Use
> - Token 精确计数（当前使用字符数粗估）

---

## 9. 双端对齐原则

### 9.1 功能对齐

iOS 和 Android 双端应实现**相同的核心功能集**，包括：

- [x] 多会话聊天（持久化）
- [x] OpenAI 兼容 API 接入
- [x] 流式 / 非流式传输
- [x] 世界书系统（字段、匹配算法、注入位置）
- [x] SillyTavern 世界书导入
- [x] 预设系统
- [x] Markdown 渲染
- [x] 消息操作（复制、编辑、重新生成、删除）
- [ ] 角色卡导入（TODO）

### 9.2 行为对齐

- 关键词匹配算法：双端实现必须产生**完全相同**的匹配结果
- 概率过滤：使用相同哈希算法保证确定性
- Prompt 注入顺序：`beforeSystem → systemPrompt → afterSystem → history → afterHistory`
- SillyTavern 字段映射：双端使用完全相同的映射规则
- 注入格式：`[世界书]\n### Title\nContent`

### 9.3 数据格式对齐

- 世界书导出格式统一为 `WorldBookExport`（version: 1）
- JSON 字段命名和类型双端一致
- UserDefaults / SharedPreferences 的存储格式应尽量兼容

### 9.4 UI 差异允许

- 导航模式可因平台差异不同（iOS NavigationStack vs Android Navigation Compose）
- 键盘交互可因平台差异不同
- 分享/导出交互可因平台差异不同
- 状态栏、安全区域处理可不同

### 9.5 版本同步

- 双端大版本号保持一致（如 v1.0、v2.0）
- 功能发布节奏尽量同步
- 本文档为双端共同的规格来源

---

## 10. 附录：全局设置项

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
