# 降级规则：何时退到 residual / text

> Phase 7 调研结论（2026-08-20）。每条降级都附"触发场景"和"降级后用户看到什么"。
>
> 核心原则：**宁可少渲染，不能渲染错。** native 客户端不能跑 JS 沙箱、不能执行 HTML 皮肤、不能回写 `message.content`——遇到任何 native 端无法表达的形态，必须降级为最朴素的原语。

---

## 1. 总览

| 降级形态 | 原语 | 用户看到 |
|---|---|---|
| **text** | `RenderNode.text` | 纯文本，最朴素的渲染 |
| **residual** | `RenderNode.residual` | 折叠面板里"展开原文"（保留原 JSON / HTML / 未知结构） |
| **drop** | 不 emit | 完全不显示（用户无感知） |
| **pass-through** | 走 MarkdownTextView native 渲染 | 等价于 text |

---

## 2. Regex 脚本层降级

| 触发场景 | 降级 | 依据 |
|---|---|---|
| `regex_scripts[i].disabled == true` | **drop**（整条跳过） | engine.js:392 |
| `regex_scripts[i].replaceString` 含 `<script` / `.load(` / `<object` / `<iframe` / `<details` / `<style` / `<div class=...>` 多重嵌套 | **drop**（整条跳过） | 本地化跳过规则，fixture 已覆盖 |
| `regex_scripts[i].promptOnly == true` | **drop**（显示期过滤） | engine.js:354 |
| `regex_scripts[i].markdownOnly == false && !script.markdownOnly && isMarkdown` | **drop** | engine.js:354（不重复在 markdown 阶段跑） |
| `placement` 不含当前 placement | **drop** | engine.js:374 |
| `placement` 包含 `WORLD_INFO` (5) | **drop**（显示期没有该 phase） | engine.js:374 |
| `placement` 包含 `REASONING` (6) | **drop**（MVP 不渲染思考块） | reasoning.js |
| `placement` 包含 `SLASH_COMMAND` (3) | **drop**（MVP 不区分 narrator） | engine.js:374 |
| `minDepth` / `maxDepth` 限定窗口外 | **drop**（当前 depth 超窗） | engine.js:361–372 |
| `findRegex` 非合法正则 | **drop**（编译失败） | engine.js:413 |
| `substituteRegex` 值不在 `{0,1,2}` | 退到 `NONE`（不替换宏，原样编译） | engine.js:300 |
| `trimStrings[]` 含空字符串 | 静默跳过该 trim 条目 | engine.js:457 |
| `replaceString` 含未替换的 `{{macros}}` | **pass-through**（保留 `{{xxx}}` 字面量） | substituteParams 不报错 |

---

## 3. `<UpdateVariable>` 块层降级

| 触发场景 | 降级 | 依据 |
|---|---|---|
| `<UpdateVariable>` 块**不存在** | drop（block 本身不存在） | 无 |
| 块**未闭合**（无 `</UpdateVariable>`） | **text**（保留整段 raw 文本） | function_call.ts:475–478 拒绝；native 同 |
| 块内**非合法 JSON**（既不是 JSON Patch 数组也不是 lodash-call） | **text**（保留 raw 文本） | function_call.ts:null 拒绝；native 同 |
| JSON Patch 数组**为空** | drop（noop） | util.ts:53（isJsonPatch([]) === true） |
| JSON Patch 中某条 op 不在词汇表（`copy` / `test`） | **drop 单条**（其他 op 继续应用） | update_variables.ts switch 缺 case |
| op 字段 `op` 不是字符串 | **drop 单条** | util.ts:59 |
| op 字段 `path` 不是字符串（且非 `move` 的 `to`） | **drop 单条** | util.ts:60 |
| op 字段 `value` 是 `undefined` 且 op 是 `replace` / `add` | **drop 单条** | lodash `_.set` 静默失败 |
| path 是**空字符串**（整棵树替换） | 应用为 `JSONPatchOperation.replace("", value)` | update_variables.ts:771 |
| path 以 `_` 开头（用户自定义保留前缀） | **drop 单条**（私有命名空间） | fixture 约定：path 跳过 `_` |
| path 含 `~0` / `~1` 但**顺序错**（如 `~2`） | **drop 单条** | update_variables.ts:215 仅处理 `~0`/`~1` |
| path 含**未转义**特殊字符（控制字符、null byte） | **drop 单条** | 无明确处理；lodash 会失败 |
| value 是 `undefined` / `function` / `Symbol` 等不可序列化 | **drop 单条** | JSONValue 解码层兜底 |
| value 是循环引用 | **drop 单条** | Codable 拒绝 |
| `<Analyze>` 块缺 / 不闭合 | drop Analyze 块（不影响变量） | function_call.ts:413 |
| `<JSONPatch>` 块缺 / 不闭合 | **text**（整段 fallback） | function_call.ts:475 |

---

## 4. `<StatusPlaceHolderImpl/>` 层降级

| 触发场景 | 降级 | 依据 |
|---|---|---|
| `<StatusPlaceHolderImpl/>` **存在但 stat_data 是空** | **text**（"[状态（等待变量）]" 占位） | Pyramid `StatusView` 已实现 |
| stat_data 是非 plain object（数组 / 字符串 / number） | **text**（展示整个 stat_data JSON） | 类型守卫 |
| stat_data 嵌套深度 ≥ 5 | **residual**（保留 path + value 字符串） | 防止 UI 无限嵌套 |
| 节点含 `$meta` 子键 | 跳过 `$meta`，继续遍历其他键 | 类型守卫 |
| 节点含 `$internal` 子键 | 跳过 `$internal`，继续遍历其他键 | patch 完成后会被清掉 |
| 节点含 `$arrayMeta` | 跳过该子键 | 元信息 |
| value 是数组且元素是异质（mix 标量 / 对象） | 仍按数组处理：标量 → tag，对象 → group | 混合支持 |
| value 是 `undefined` | drop 该 key（不展示） | JSONValue 不编码 undefined |
| value 是空字符串 `""` | 仍展示（空字符串是有效值） | — |
| value 是 `NaN` / `Infinity` | **text**（展示字符串 "NaN" / "Infinity"） | JSONValue 不能表示 |

---

## 5. VariableStore 初始化降级

| 触发场景 | 降级 | 依据 |
|---|---|---|
| `init_stat_data` 不存在 | drop（无初始化，stat_data 留空） | MagVarUpdate initvar/variable_init.ts |
| `init_stat_data` 解析失败（非合法 JSON object） | drop（无初始化，记 warning） | 同上 |
| `init_stat_data.stat_data` 存在但 `schema` 不存在 | 仅 patch，不做 schema 校验 | variable_def.ts:172（schema 缺失时 MVU 关掉大部分功能） |
| session 已存在 VariableStore（同 sessionId） | **不重新覆盖**（保留现状） | fixture 约定：seed-if-empty |
| session 删除时 VariableStore 还在 | drop（清 VariableStore 行） | ChatStore 生命周期 |
| 世界书条目 `extensions.initvar == true` | **隔离**（不进 entries 列表、不注入 lore） | `WorldBookEntry.parse(sillyTavern:)` 顶部守卫；MVP 暂不消费 initvar 子树 |

---

## 6. `message.content` 写入降级（**硬约束**）

| 触发场景 | 降级 | 依据 |
|---|---|---|
| 任何 native 处理流程想要修改 `message.content` | **绝对禁止** | Fixture README 硬约束：所有占位符 / 状态栏 / JSON Patch 指令转译**只**通过 `RenderNode` 子树输出 |
| 用户点"复制原文" / "编辑" / "重新生成" | 必须看到原始 `message.content`（含 `<UpdateVariable>` 块、`{{macros}}`、`<StatusPlaceHolderImpl/>` 等） | 同上 |
| 显示时 `extra.display_text` 存在 | 酒馆走 `extra.display_text`（script.js:2470）；native **不实现此覆盖**（保持 raw） | 简化 |

---

## 7. 字段类型降级（CharaCard → JSONValue）

| 酒馆字���声明 | 实际值不在预期 | 降级 | 依据 |
|---|---|---|---|
| `talkativeness` | 不是 0–1 数字（如字符串 "高"） | **text**（"高"） | 当前 native 已支持 typed fallthrough |
| `fav` | 不是 bool | drop | — |
| `depth_prompt.depth` | 不是 number | drop depth_prompt 整体 | V3 typed fallthrough |
| `assets[i].uri` | 不是合法 base64 data URL | drop asset | Image 解码失败 |
| `extensions.regex_scripts[i].placement` | 含未知数字（如 `[7]`） | 整条 regex 脚本 drop（保守） | engine.js:374 |
| `extensions.data.stat_data` 顶层键是 `$internal` | drop（不持久化） | variable_def.ts:99 |

---

## 8. 输出层降级（iOS SwiftUI 渲染）

| 触发场景 | 降级 | 备注 |
|---|---|---|
| `RenderNode.text` 长度 > 10000 | 折叠显示（前 200 字 + "展开"） | MessageCard `isLong` 逻辑已实现 |
| `RenderNode.bar` value 超出 max | clamp 到 [0, max] | 视觉上仍合理 |
| `RenderNode.bar` max == 0 | 退化为 `field(label, value)` | 防 0 除 |
| `RenderNode.section` / `group` children 数 > 50 | 折叠（"显示前 50 / 展开全部"） | 防 ScrollView 卡 |
| `RenderNode.tag` 长度 > 30 | 截断 + "…" | UI 视觉约束 |
| `RenderNode.field` label 为空 | 退化为 `text`（只展示 value） | 视觉对齐 |
| 整条消息 RenderNode 数 > 500 | 折叠尾部 + "渲染上限提示" | 防 memory pressure |
| RenderNode 树构造超时（> 200ms） | 返回当前已构造的部分 + 尾部 residual | 防主线程卡顿 |

---

## 9. Fixture 中已实现的降级断言

`swift-tests/Tests/PyramidCoreTests/NativeTranspileFixtureTests.swift` 当前覆盖：

- ✅ Sample 1: `<StatusPlaceHolderImpl/>` → `[.statusPlaceholder, .text("你好，欢迎回来。")]`；raw 字符串不变
- ✅ Sample 2: `<UpdateVariable>` → 剥 block + 写 store + emit `.variableUpdate`；raw 字符串不变
- ✅ Skip rule: rules 1/2/6/7（HTML beautify）→ `isHtmlBeautify == true` → 过滤
- ✅ Prompt-only rules 3/4/5 → 显示管线过滤
- ✅ `_ui/scroll` 路径 → patch 时跳过（path_underscore_skip 契约）

未覆盖但应该补的（**下一阶段任务**）：

- ⏳ `<UpdateVariable>` 缺闭合标签 → fallback text
- ⏳ `<UpdateVariable>` 内部非法 JSON → fallback text
- ⏳ `copy` / `test` op → silently dropped
- ⏳ 嵌套 stat_data 深度 ≥ 5 → residual
- ⏳ stat_data 空 → "等待变量" 占位
- ⏳ `asset.uri` 非法 base64 → drop asset