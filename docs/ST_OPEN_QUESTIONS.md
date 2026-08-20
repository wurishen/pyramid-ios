# 风险与未知：源码里仍不明确的点

> Phase 7 调研结论（2026-08-20）。明确"现在不知道的"——这些都是下一阶段 native 客户端需要再决策 / 实验 / 跟用户对齐的点。
>
> 标注约定：
> - 🔴 **阻塞**：影响本期实现正确性，必须先解决
> - 🟡 **延期**：本期有合理 fallback，但 P3+ 阶段需要正式决策
> - 🟢 **已知未知**：记录下来以备后人翻

---

## 1. JSON Patch op 词汇表边界

### 1.1 MVU 内部 op 词汇表 vs RFC 6902

🔴 **阻塞**（影响 native patch 实现正确性）

MVU 的 `extractJsonPatch` switch（`/tmp/MagVarUpdate/src/function/update_variables.ts:222–273`）只覆盖：

- `replace` → `set`
- `delta`（**MVU 扩展**） → `add`
- `insert`（**MVU 扩展**） → `insert`
- `add`（RFC 6902） → `insert`
- `remove` → `delete`
- `move` → `move`

**未覆盖（silently dropped）**：`copy`、`test`。

> **决策**：native 端对 `copy` / `test` 一律 drop，与 MVU 行为一致。fixture 不覆盖这两条 op，需要在后续 PR 加 `JSONPatchTests.swift` 用例。

### 1.2 `delta` op 的语义细节

🔴 **阻塞**

`delta` 是 MVU 自定义 op，但 `extractJsonPatch` 里只是把它当成 `add`（数值加/减）。**真正的 delta 计算在 `update_variables.ts` 后面的 `_applyDelta` 函数里**（未深入阅读）。

> **风险**：如果 delta 是 `boolean toggle`、或负数反向 delta，行为可能不同于简单的 `+=`。本期 fixture 没覆盖 boolean / negative delta。
> 
> **行动建议**：读完 `_applyDelta` 全文（约 200 行），补一条 fixture 用例（`{op: "delta", path: "/金币", value: -5}`）和 SPM 测试。

### 1.3 path 空字符串 `""` 是否合法

🔴 **阻塞**

MVU 在 `update_variables.ts:771` 显式支持 `path === ''`（整棵 `stat_data` 替换）。native 端 `JSONPatchOperation.replace(path, value)` 的 `path` 是否允许空字符串？

> **决策**：native 端**允许**（fixture 不需要覆盖，文档里记一句）。

---

## 2. `stat_data` Schema 行为

### 2.1 schema 缺失时的行为

🟡 **延期**

MagVarUpdate 要求 `MvuData.schema` 存在（`variable_def.ts:172`），但 Pyramid 当前 native 实现**不解析 schema**——schema 缺失时所有 patch 照常应用（无验证）。

> **风险**：若上游用户编写的 LLM prompt 依赖 schema 自动生成 default value，缺失 schema 会导致上游 LLM 输出 patch 失败率上升。
> 
> **本期决策**：native 不实现 schema 校验。`schema` 字段**透传保存**，未来 P3+ 阶段补 schema-aware 默认值生成。

### 2.2 `$meta.template` 字段语义

🟡 **延期**

`StatDataMeta.template` 字段（`variable_def.ts:9`）描述"自动填充新元素的模板"。MagVarUpdate 在 update 阶段用 `correctlyMerge` 把模板合并到新创建的对象里。

> **未知点**：当一个数组有 `$meta.template`，新增元素时是否会自动用模板填充？本期 native 不实现 UI 触发新增（用户不能手动加变量），所以无影响。
> 
> **P3+ 行动**：若未来要做"变量编辑器"，需要把 template 字段展示给用户作为新增默认值。

---

## 3. Variable Store Scope（多 scope 持久化）

🟡 **延期**

JS-Slash-Runner `variables.ts` 暴露 5 个 scope：
- `chat` → `chat_metadata.variables`
- `character` → `characters[chid].data.extensions.settings.variables`
- `preset` → `presets[pid].settings.variables`
- `global` → `extension_settings.variables.global`
- `message` → `chat[i].variables[swipe_id]`

Pyramid MVP 只支持 **chat scope**（per-sessionId）。

> **风险**：用户在酒馆写的角色卡通过 character scope 设置的"全局设定"（如 `玩家: { 姓名: "Alice" }`），native 端**读不到**。这会让某些角色卡"换到 native 客户端就初始化失败"。
> 
> **P3+ 行动**：
> 1. 决定"character scope"在 native 端落点：是按 characterId 单独存，还是只算在 chat scope（copy-on-init）
> 2. 决定"preset scope"是否需要：可能直接不要（preset 是酒馆生成参数的预设，跟角色状态变量无关）
> 3. 决定"global scope"落点：`UserDefaults["mvu_global"]` 或独立文件

---

## 4. Per-Swipe 变量（`message` scope）

🟡 **延期**

JS-Slash-Runner `chat[i].variables[swipe_id]` 是**每条 swipe 各自一份变量**。MVU init 时会给 `swipes` 数组的每一项都建空 dict，patch 应用时只动当前 swipe。

Pyramid MVP **不支持 swipe**（所有回复都是单条）。

> **风险**：若未来加 swipe，需要给 VariableStore 加 `[messageId][swipeId]` 二维 key。
> 
> **P3+ 行动**：swipe 上线时再做。

---

## 5. `initvar` 块（开场白内的 `<initvar>` 标签）

🟡 **延期**

`/tmp/MagVarUpdate/src/function/initvar/variable_init.ts:156` 的正则：

```
/<(initvar)>(?:\s*```.*)?([\s\S]*?)(?:```\s*)?<\/\1>/gim
```

当开场白（`first_mes`）里包含 `<initvar>` 块时，**该块优先**于角色世界书的 `[initvar]` 条目（initvar.ts:159 明确说明）。

> **决策**：native MVP 只支持 `extensions.init_stat_data`（character 级别 init）。开场白里的 `<initvar>` 块暂不解析（fallback 到 character 级别）。
> 
> **风险**：若用户角色卡只依赖开场白内的 init，native 端会"init 失败"。
> 
> **P3+ 行动**：开场白 `<initvar>` 解析时优先级要高于 character 级别 init。

---

## 6. 世界书 `[initvar]` 条目

🟡 **延期**

`MagVarUpdate` 通过 `lorebook_entry.initvar` 字段标记哪些世界书条目是 init 来源。条目里 YAML/JSON 内容是 stat_data 子树，会合并进最终 init。

> **决策**：native MVP 不实现世界书 init 来源。仅 `extensions.init_stat_data` 唯一来源。
> 
> **P3+ 行动**：补 world book init entry 解析。

---

## 7. `<StatusPlaceHolderImpl/>` 的"皮肤替换脚本"语义

🔴 **已知未知 / 记录**

`<StatusPlaceHolderImpl/>` 自身不渲染。酒馆渲染路径 = 用户 regex 脚本替换为 HTML。**但用户脚本里展开的宏是 `{{getvar::stat_data.玩家.姓名}}` 这样的形式**——native 完全跳过这些脚本后，`{{getvar::...}}` 不会被替换。

> **风险**：如果用户 regex 脚本**同时**做 HTML 皮肤**和**嵌入 `{{getvar}}` 宏，native 端跳过整条脚本后，状态栏就会空白。
> 
> **本期决策**：直接 `StatusView` 渲染整棵 `stat_data` 树——绕开用户脚本。Pyramid 用户的预期是"看 native UI，不是看酒馆 HTML 皮肤"。
> 
> **P3+ 行动**：若用户强烈要求渲染"特定酒馆 HTML 皮肤"，可以**逐条**选择开启某条用户脚本（人工 override skip 规则）。但这是 UI 复杂度爆炸，不建议做。

---

## 8. MagVarUpdate "extra-model" 解析路径

🟢 **已知未知 / 不实现**

`/tmp/MagVarUpdate/src/function/update/invoke_extra_model.ts:372` 描述：MVU 可以**调用一个额外的 LLM**专门解析 `<UpdateVariable>` 块（用于"LLM 输出不规范时纠错"）。

> **决策**：native 端**不实现** extra-model。本期假设 LLM 输出格式良好（fixture 假设）。
> 
> **风险**：真实场景里 LLM 输出经常漏 `<UpdateVariable>` 闭合、漏 `<JSONPatch>` 标签、value 是 stringified 等。
> 
> **P3+ 行动**：若发现真实失败率高，再考虑"轻量级本地纠错"（如正则补全闭合标签、尝试解析非严格 JSON）。

---

## 9. Macro engine 的兼容

🟡 **延期**

`/tmp/SillyTavern/public/script.js:2922` `substituteParams` 有两个实现：
- 默认 `substituteParamsLegacy`
- 实验性 `MacroEnvBuilder.buildFromRawEnv(ctx)` + `MacroEngine.evaluate`

JS-Slash-Runner 的 `formatAsTavernRegexedString`（tavern_regex.ts:27）在 ST regex 跑完后**紧接着**调 `substituteParams`。这意味着酒馆���染期 = ST regex → ST macros → JS-Slash-Runner macros 三段。

> **本期决策**���native MVP 只实现 ST regex。`{{char}}` / `{{user}}` 这类 ST macros 在 prompt 阶段**展开**（生成 API 请求时替换），不在显示期展开。
> 
> **已知未知**：酒馆 display 阶段**只对 messageId === 0 展开宏**（script.js:1761），后续消息**不展开**——意味着酒馆正文里出现 `{{user}}` 字面量是合法的（前提是这是非首条消息）。native MVP 同样遵循：**只在 prompt 阶段展开宏**。

---

## 10. `<Analysis>` 块的语义

🟢 **已知未知**

`<UpdateVariable>` 块内常有 `<Analyze>` 子块（function_call.ts:413）。MVU 把 Analysis 当作"LLM 推理过程"展示给用户，不影响变量。

> **决策**：native MVP 不解析 `<Analysis>`，当作 `<UpdateVariable>` 内部的 residual 隐藏。
> 
> **P3+ 行动**：若用户想看 LLM 推理，把 Analysis 单独 emit 为 `.analysis` RenderNode。

---

## 11. `$internal.display_data` / `$internal.delta_data` 的展示

🟡 **延期**

MagVarUpdate 用这两个字段展示"变量变化"：`100->80 (受伤)`。这两个字段是 `@deprecated`（variable_def.ts:144, 156），但仍是当前 UI 主要展示方式。

> **本期决策**：native 不展示 display_data / delta_data（直接展示当前 stat_data 值）。等价于 MagVarUpdate 的"默认模式"——只有在用户打开"变化历史"开关时才填充这两个字段。
> 
> **P3+ 行动**：若用户想看"本次 patch 改了哪些"，本地计算 `before != after` 的子路径展示。

---

## 12. 角色卡 import 时的 `data.extensions.regex_scripts` 与 character 级别 regex 的关系

🟢 **已知未知**

SillyTavern 的 regex 脚本来源有 3 个：
- `extension_settings.regex`（全局）
- `characters[chid].data.extensions.regex_scripts`（character 级别）
- `presetManager.readPresetExtensionField('regex_scripts')`（preset 级别）

Pyramid 当前支持 character 级别（`Pyramid/Models/DisplayRegex.swift` 通过 `Character.extensions.regex_scripts` 自动同步）。

> **未知点**：preset 级别的 regex 脚本是不是常用于"酒馆助手"自定义输出格式？fixture 没覆盖 preset regex。
> 
> **P3+ 行动**：若未来支持 preset import，再补 preset regex 自动同步。

---

## 13. `data-extension-added` / `mes_id` / `[chid]` 等不存在属性

🟢 **已确认不存在**

调研明确：上游 ST **不**设这些属性。常见误以为存在的属性：
- `mes_id` → 实际是 `mesid`（无下划线）
- `[chid]` → 实际是 `this_chid` 模块级变量
- `[swipe_id]` → 实际是 `swipeid`（无下划线）或 swipe picker popup 内的 `data-swipe-id`
- `data-extension-added` → 不存在，扩展走 eventSource
- `data-history` → 不存在，最接近 `bookmark_link`

> **决策**：native 不模拟这些属性（避免假数据误导后续维护）。

---

## 14. ST DOM hooks 对 native 的可借鉴性

🟢 **已确认**

message DOM 元素上有约 20 个属性 hook（script.js:2588–2627）：
- `mesid` / `swipeid` / `ch_name` / `is_user` / `is_system` / `bookmark_link` / `force_avatar` / `timestamp` / `type` / `title` / `data-media-display` / `data-char-tags` / `data-reasoning-state`

> **决策**：native MessageCard 不模仿这些 DOM attribute，而是直接用 SwiftUI `@State` / `@Environment` 传 property。
>
> **可借鉴**：枚举出哪些 hook 在 native 端对应哪个 `@State` 字段，未来重构 MessageCard 时参考。

---

## 15. Pyramid 当前代码已知的实现债务

🟡 **延期**

- `MessageRendererCore.swift` 的 `isHtmlBeautify` 跳过规则是 substring 检测，**可能误伤**（如合法 `<style="...">` 属性的 replacement）。需要更精确的"开头是不是 `<script>`/`iframe`/`<style>`"判定（不区分大小写）。
- `JSONPatch.swift` 的 `_`-prefix skip 是用户��定，**没在酒馆源码里找到对应规则**。可能属于 fixture 自定。若用户后续要切换到"`_ui/`"外的不跳过，要重新校验。
- `VariableStore` 是 `@MainActor ObservableObject`，不是真正的并发安全 store（多线程 patch 可能 race）。当前 MVP 单线程使用没问题，未来加 streaming 要重审。

---

## 附录：本期（Phase 7）已落地的决策一览

| 决策 | 落点 | 状态 |
|---|---|---|
| Tag spelling 修正：`<UpdateVariable>` 单 `<`，**不是** `<<UpdateVariable>>` | 修正 pyramid 代码 + fixture | ⏳ 下一 PR 修 fixture |
| `<<UpdateVariable>>` 是错误拼写，fixture 应该是 `<UpdateVariable>` | 修 fixture + 修 `RenderNodeParser` | ⏳ 下一 PR |
| JSON Patch op 词汇表：replace/add/remove/move + delta（MVU 扩展） + insert（MVU 扩展） | 已有 + 需要补 delta/insert fixture 用例 | ⏳ |
| copy/test op 静默 drop | 已有 + 需要补 fixture 用例 | ⏳ |
| `_`-prefix path skip | 已有（Pyramid 自定） | ✅ |
| `<StatusPlaceHolderImpl/>` 兜底从 stat_data 渲染 StatusView | 已有 | ✅ |
| HTML beautify regex 跳过 | 已有 | ✅ |
| promptOnly regex 跳过 | 已有 | ✅ |
| session lifecycle VariableStore seed | 已有 | ✅ |
| message.content 永不写回 | 已有（硬约束） | ✅ |
| 多 scope（character/preset/global/message）VariableStore | 仅 chat scope | 🟡 P3+ |