# 替换映射表：酒馆概念 → NativeDisplayModel 原语

> Phase 7 调研结论（2026-08-20）。每条映射都附"源码依据"链接到对应仓库位置。
>
> NativeDisplayModel 原语（固定枚举，本期不增删）：
> - `text` —— 纯文本片段
> - `number` —— 数字（可带单位）
> - `bar(label, value, max?, kind?)` —— 进度条 / 数值条
> - `tag` —— 短标签（胶囊）
> - `field(label, value)` —— label-value 对
> - `section(label, content)` —— 带标题的分组
> - `group(title, children)` —— 嵌套分组
> - `residual` —— 兜底（保持原文）

---

## 1. chara_card_v3 顶层字段

| 酒馆字段 | 类型 | 原语 | 依据 | 备注 |
|---|---|---|---|---|
| `name` | String | `text` | char-data.js | 卡片标题 |
| `description` | String | `text` | char-data.js | 角色描述卡片 |
| `tags` | String[] | `tag[]` (multi-tag) | char-data.js | 每个 tag 渲染为独立 tag 节点 |
| `creator` | String | `field("作者", value)` | char-data.js | 单 field |
| `creator_notes` | String | `text`（可选折叠） | char-data.js | 折叠文本 |
| `system_prompt` | String | 提示词层，不渲染 | — | 进 API 请求 |
| `post_history_instructions` | String | 提示词层，不渲染 | — | 进 API 请求 |
| `first_mes` | String | `text`（首条消息正文） | char-data.js | 走显示管线 |
| `alternate_greetings` | String[] | `text[]`（首条消息备选） | char-data.js | 同上 |
| `personality` | String | `section("性格", text)` | char-data.js | 长描述归 section |
| `scenario` | String | `section("场景", text)` | char-data.js | 同上 |
| `talkativeness` | number (0–1) | `bar("话痨", value, 1, ratio)` | char-data.js | kind=ratio |
| `fav` | bool | `tag("收藏", 状态)` 或 `field` | char-data.js | 用 tag 视觉化更直观 |
| `depth_prompt.prompt` | String | 提示词层 | — | 不渲染 |
| `depth_prompt.depth` | number | 提示词层 | — | 不渲染 |
| `depth_prompt.role` | string | 提示词层 | — | 不渲染 |
| `nickname` | String | `text` | char-data.js | 昵称 |
| `source` | String[] | `field("出处", text)` | char-data.js | 多源 join 后显示 |
| `assets[i].name` | String | `tag`（点击切换） | char-data.js | tap → 切换头像 |
| `assets[i].uri` | data URL | `Image`（native SwiftUI Image） | — | decode 后 Image 节点 |
| `spec` / `spec_version` | String | 不渲染 | — | import 校验用 |
| `character_version` | String | `field("版本", value)` | char-data.js | meta 字段 |
| `create_date` | ISO date | `field("创建", formatted)` | — | 本地化日期 |

---

## 2. `extensions.regex_scripts` 单条

| 字段 | 类型 | 原语 | 依据 | 备注 |
|---|---|---|---|---|
| `findRegex` | String | 不渲染 | engine.js:391–448 | 解析后由 regex 引擎消费 |
| `replaceString` | String | **关键：决定跳过规则** | engine.js | 详见 §5 |
| `placement[]` | number[] | 不渲染（用于过滤） | engine.js:281–292 | native 显示管线按 placement 过滤 |
| `markdownOnly` / `promptOnly` | bool | 不渲染（用于过滤） | engine.js:348–355 | 显示管线过滤 promptOnly=true |
| `disabled` | bool | 不渲染（用于过滤） | index.js | 整条跳过 |
| `runOnEdit` | bool | 不渲染（用于过滤） | engine.js:356 | native 编辑期显示 |
| `substituteRegex` | number | 不渲染 | engine.js:298–302 | 编译时宏展开控制 |
| `minDepth` / `maxDepth` | number \| null | 不渲染 | engine.js:361–372 | 深度窗口过滤 |
| `trimStrings[]` | String[] | 不渲染 | engine.js:457–465 | 应用前后 trim |
| `id` | UUID | 不渲染 | char-data.js | 去重 key |
| `scriptName` | String | UI 编辑器显示，不进消息 | editor.html | 仅在 regex 编辑面板 |

---

## 3. `<UpdateVariable>` 块

| 酒馆 op | MVU 内部 Command | 原语（patch 应用前） | 原语（patch 应用后） | 依据 |
|---|---|---|---|---|
| `<UpdateVariable>` 容器本身 | — | `text`（剥除整个块） | `text` | function_call.ts:412–420 |
| `{op: "replace", path, value}` | `set(path, value)` | `residual`（隐藏 patch 文本） | 触发 VariableStore 更新 | update_variables.ts:225–232 |
| `{op: "add", path, value}` | `insert(path, ...value)` | `residual` | 触发 VariableStore 更新 | update_variables.ts:242–255 |
| `{op: "delta", path, value}` | `add(path, delta)` | `residual` | 数值 += delta 或 bool toggle | update_variables.ts:233–241 |
| `{op: "insert", path, value}` | `insert(path, ...)` | `residual` | 数组插入 | update_variables.ts:242–255 |
| `{op: "remove", path}` | `delete(path)` | `residual` | 移除 key/index | update_variables.ts:257–264 |
| `{op: "move", from, path}` | `move(from, path)` | `residual` | 移动 key | update_variables.ts:265–272 |
| `{op: "copy", ...}` | — | `residual` | **silently dropped** | update_variables.ts switch 缺 case |
| `{op: "test", ...}` | — | `residual` | **silently dropped** | 同上 |
| `<Analyze>...</Analyze>` | — | `residual`（隐藏分析块） | 不影响变量 | function_call.ts:413–415 |
| `<JSONPatch>...</JSONPatch>` | — | `residual`（隐藏块） | 不影响变量 | function_call.ts:416–418 |

每条 `<UpdateVariable>` 块成功处理后，emit 一个 `RenderNode.variableUpdate(summary)` 节点（**当前 iOS 已实现**：`NativeTranspileFixtureTests` 验证）。

---

## 4. `<StatusPlaceHolderImpl/>` 渲染

### 4.1 实际渲染逻辑

`/tmp/MagVarUpdate/src/function/update_variables.ts:1554–1555`：MVU 只**追加**这个标记，**不渲染**。真正的"状态栏"由用户 regex 脚本做替换（产物是 HTML）。

### 4.2 Pyramid native 路径（绕过用户 regex）

直接从 `stat_data` 变量树生成 `StatusView`：

| 酒馆概念 | NativeDisplayModel 原语 | 备注 |
|---|---|---|
| 整个 `stat_data` 树 | `group("状态", children)` | 根容器 |
| 标量字段 `时间: "傍晚"` | `field(label: "时间", value: "傍晚")` | primitive string |
| 标量字段 `金币: 50` | `number(50)` 或 `field(label: "金币", value: "50")` | primitive number |
| 标量字段 `是否下雨: true` | `tag("是否下雨", value)` | bool → tag |
| 嵌套对象 `玩家: { 当前所在地: "集市" }` | `group("玩家", [field("当前所在地", "集市")])` | 递归 group |
| 数组字段 `库存: ["苹果", "梨"]` | `section("库存", [tag("苹果"), tag("梨")])` | 数组 → 多个 tag |
| `$meta.required[]` | 不渲染（UI 元信息） | 透传 |
| `$meta.template` | 不渲染（UI 元信息） | 透传 |
| `$internal.display_data` / `$internal.delta_data` | **不渲染** | patch 完成后清，native 永不持久化 |
| `$meta` 节点 | 跳过该子树（native 不展示元信息） | 仅遍历 `$meta` 之外的字段 |

### 4.3 深度限制

`stat_data` 嵌套深度 ≥ 5 时 native 应**截断为 residual**，避免 UI 过深。建议：
- 深度 ≤ 3 → 正常 group/nested
- 深度 4 → 最后一级展开成 `text`（join path）
- 深度 ≥ 5 → `residual`（保留原 path/value 文案，提示"过深"）

依据：`MagVarUpdate` 自身也只展示 4 层左右（profile `initvar` 示例）；native 客户端不必硬撑。

---

## 5. 用户 regex 脚本的"国内美化"识别

判定 `replaceString` 命中以下任一即视为"国内美化"皮肤脚本，native **跳过**（不应用）：

| 子串（substring） | 含义 | 来源观察 |
|---|---|---|
| `<script` | HTML script 标签 | fixture regex_scripts[0] |
| `.load(` | jQuery AJAX 远程副作用 | fixture regex_scripts[1] |
| `<object` | HTML object | 上游观测 |
| `<iframe` | HTML iframe | 上游观测 |
| `<details` | HTML5 details（常带皮肤） | fixture regex_scripts[6] |
| `<style` | HTML style（嵌入 CSS） | fixture regex_scripts[7] |
| `<div class=` 多重嵌套 | 视觉布局 | heuristic |

判定后：
- 整条 regex 脚本从 `MessageRendererCore.orderedRegexes` 里过滤
- `replaceString` 出现过的占位符（如 `<StatusPlaceHolderImpl/>`）**靠 native 自己的 StatusView 兜底**

代码位置（已实现）：`Pyramid/Models/MessageRendererCore.swift` 的 `isHtmlBeautify(replacement:)` + `orderedRegexes` 过滤逻辑。

---

## 6. JSON Patch 路径转换

| 酒馆 path | RFC 6901 token | Native lodash-style path | 依据 |
|---|---|---|---|
| `/时间` | `/` + `时间` | `时间` | update_variables.ts:210–217 |
| `/玩家/当前所在地` | `/` + `玩家` + `/` + `当前所在地` | `玩家.当前所在地` | 同上 |
| `/~1escaped~1key` | `~1` → `/` | `…key` | update_variables.ts:215 |
| `/~0tilde` | `~0` → `~` | `…tilde` | 同上 |
| 空 path `""` | 整棵 `stat_data` 替换 | `stat_data` | update_variables.ts:771 |

Pyramid 已在 `JSONPatch` 中实现该路径转换（参见 `swift-tests/Tests/PyramidCoreTests/JSONPatchTests.swift`）。

---

## 7. 关键事件流 → native 触发点

| 酒馆事件 | 触发时机 | Pyramid native 触发点 | 依据 |
|---|---|---|---|
| `MESSAGE_RECEIVED` | AI 回流进 `chat[]` | `ChatStore` 收到 LLM 响应后调 `RenderEngine.render` | script.js:3740 |
| `MESSAGE_UPDATED` | 用户保存编辑 | 编辑消息 sheet 保存后重新 transpile | script.js:8277 |
| `MESSAGE_SWIPED` | 滑动切换 | swipe 后重新 transpile（按当前 swipe_id 取 variables） | script.js:10255 |
| `CHARACTER_MESSAGE_RENDERED` | AI 卡片 DOM 完成 | 仅显示用，不影响 transpile | script.js:3741 |
| `BEFORE_MESSAGE_UPDATE`（MVU） | patch 应用前 | native `JSONPatch.apply` 前 emit | variable_def.ts:238 |
| `VARIABLE_UPDATE_ENDED`（MVU） | patch 应用后 | native `JSONPatch.apply` 后 emit `.variableUpdate` | variable_def.ts:235 |

---

## 8. 持久化映射

| 酒馆存储位置 | 内容 | native 存储位置 | 依据 |
|---|---|---|---|
| `chat[i].variables[swipe_id]` | per-message 变量 | `VariableStore[sessionId][messageId]` 或独立 key | variables.ts:135–148 |
| `chat_metadata.variables` | chat 级别变量 | `VariableStore[sessionId]["chat_metadata"]` | variables.ts:72 |
| `characters[chid].data.extensions.settings.variables` | character 级别变量 | `VariableStore[characterId]` | variables.ts:73 |
| `presets[pid].settings.variables` | preset 级别变量 | `VariableStore[presetId]` | variables.ts:74 |
| `extension_settings.variables.global` | 全局变量 | `VariableStore["global"]` | variables.ts:75 |

Pyramid 当前 MVP 只实现 **chat scope**（`VariableStore[sessionId]`），其余 scope 在本期与后续 scope-blocking 阶段逐步加入（参见 `docs/ST_OPEN_QUESTIONS.md` §3）。