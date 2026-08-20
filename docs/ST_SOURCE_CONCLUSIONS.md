# SillyTavern + MagVarUpdate 源码结论

> Phase 7 调研结论（2026-08-20）。Pyramid native transpile 所需的"酒馆风格"显示层逻辑分散在三个仓库里，本文件汇总关键源码位置、关键数据结构、以及显示数据流。
>
> 所有路径都是绝对路径（指向本机 `/tmp/...` 下的克隆，不入库）。

---

## 1. 三个仓库的分工

| 仓库 | 路径 | 职责 |
|---|---|---|
| **SillyTavern（上游 ST）** | `/tmp/SillyTavern/public/` | 聊天核心：消息 DOM、regex 引擎、character card V2/V3、世界书 prompt 注入、宏替换。**没有 MVU、没有 StatusPlaceHolder。** |
| **JS-Slash-Runner（Tavern Helper）** | `/tmp/JS-Slash-Runner/src/` | ST 的官方 STscript 扩展。提供变量存储层（`getVariables` / `replaceVariables`）+ 自家 `{{get_*_variable::path}}` 宏（注意 `$`-prefix omit-on-output 规则）+ eventSource 桥。**MVU 引擎不在这里**。 |
| **MagVarUpdate (MagicalAstrogy)** | `/tmp/MagVarUpdate/src/` | **MVU 引擎本体**：`init_stat_data` 初始化、`<UpdateVariable>` 标签解析、`<JSONPatch>` 块解析、`<StatusPlaceHolderImpl/>` 自动追加、`stat_data`/`schema` schema-driven 写、`display_data`/`delta_data` 展示变化。 |

加载方式：JS-Slash-Runner 通过 `import 'https://testingcf.jsdelivr.net/gh/MagicalAstrogy/MagVarUpdate@master/artifact/bundle.js'` 把 MVU 当成第三方脚本载入；MVU 通过 `window.parent.Mvu` 暴露给 iframe。原生客户端不能依赖此 iframe 链路。

---

## 2. 关键源文件

### SillyTavern 上游

| 文件 | 行号 | 作用 |
|---|---|---|
| `/tmp/SillyTavern/public/script.js` | 1753–1911 | `messageFormatting` —— 显示管线主入口 |
| 同上 | 1785–1814 | 显示期 regex 调用（`isMarkdown: true`） |
| 同上 | 2464–2478 | `getMessageTextHTML` —— 优先 `extra.display_text` 而非 `mes` |
| 同上 | 2492–2548 | `addOneMessage` —— DOM 写入入口 |
| 同上 | 2559–2646 | `updateMessageElement` —— 模板 clone + attr 设置 |
| 同上 | 4442–4494 | 提示词组装期 regex 调用（`isPrompt: true`） |
| `/tmp/SillyTavern/public/scripts/extensions/regex/engine.js` | 281–292 | `regex_placement` 枚举 |
| 同上 | 298–302 | `substitute_find_regex` 枚举 |
| 同上 | 326–381 | `getRegexedString` 主入口（含 markdownOnly/promptOnly 过滤） |
| 同上 | 391–448 | `runRegexScript` 单�� regex 应用（含 `substituteParams`） |
| `/tmp/SillyTavern/public/scripts/extensions/regex/index.js` | 848–868 | 编辑器表单 → `RegexScriptData` 字段映射 |
| `/tmp/SillyTavern/public/scripts/char-data.js` | 87–102 | `RegexScriptData` typedef |
| `/tmp/SillyTavern/public/scripts/reasoning.js` | 1421–1450 | `parseReasoningFromString` 提取 thinking |
| 同上 | 1514–1607 | `MESSAGE_RECEIVED` 监听：剥思考→触发 `updateMessageBlock` |

### JS-Slash-Runner

| 文件 | 行号 | 作用 |
|---|---|---|
| `/tmp/JS-Slash-Runner/src/function/variables.ts` | 56–94 | `get_variables_without_clone` —— 按 scope 取变量树 |
| 同上 | 128–191 | `replaceVariables` —— 按 scope 全量写回 |
| 同上 | 203–239 | `updateVariablesWith` —— 读改写原子操作 |
| 同上 | 241–301 | `insertOrAssignVariables` / `insertVariables` / `deleteVariable` |
| `/tmp/JS-Slash-Runner/src/function/tavern_regex.ts` | 27–73 | `formatAsTavernRegexedString` —— ST regex → `substituteParams` → 自家宏 |
| `/tmp/JS-Slash-Runner/src/function/macro_like.ts` | 60–78 | `{{get_*_variable::path}}` 宏注册（**注意 `$`-prefix omit-on-output**） |
| `/tmp/JS-Slash-Runner/src/function/global.ts` | 34–39 | `waitGlobalInitialized('Mvu')` —— 轮询 `chat[0].variables[0].stat_data` |
| `/tmp/JS-Slash-Runner/src/iframe/predefine.js` | — | 把 `window.parent.Mvu` 暴露给 iframe |
| `/tmp/JS-Slash-Runner/@types/iframe/exported.mvu.d.ts` | 55–119 | `Mvu.events.*` 常量 + payload 类型 |
| `/tmp/JS-Slash-Runner/@types/iframe/exported.mvu.d.ts` | 249–302 | `CommandInfo` 类型（这是 function-call tool_calls 走法，不是内联 `<UpdateVariable>` 标签走法） |

### MagVarUpdate

| 文件 | 行号 | 作用 |
|---|---|---|
| `/tmp/MagVarUpdate/src/variable_def.ts` | 5–21 | `StatDataMeta` / `StatData` 类型（含 `$meta`、`$arrayMeta` 特殊键） |
| 同上 | 99–102 | `InternalData`：`display_data` + `delta_data` |
| 同上 | 121–152 | `MvuData` 主结构：`initialized_lorebooks` + `stat_data` + `schema` + 弃用的 `display_data`/`delta_data` |
| 同上 | 114–119 | `exported_events` 常量：`mag_invoke_mvu`、`mag_update_variable` |
| 同上 | 213–242 | `exported_events`（`variable_events.*`）：`VARIABLE_INITIALIZED`、`VARIABLE_UPDATE_STARTED`、`COMMAND_PARSED`、`VARIABLE_UPDATE_ENDED`、`BEFORE_MESSAGE_UPDATE` |
| 同上 | 249–302 | `CommandInfo` 类型（lodash-call 风格，给 function-call tool_calls 路径用） |
| `/tmp/MagVarUpdate/src/util.ts` | 48–62 | `isJsonPatch(patch)` —— RFC 6902 验证：数组，每项 `op: string` + `path: string`（`move` 用 `to: string`） |
| `/tmp/MagVarUpdate/src/function/update_variables.ts` | 219–276 | `extractJsonPatch` —— JSON Patch → MVU 内部 Command 翻译：`replace`→`set`、`delta`→`add`、`insert`/`add`→`insert`、`remove`→`delete`、`move`→`move` |
| 同上 | 210–217 | `jsonPatchPathToCommandPath` —— RFC 6901 path (`/foo/bar`) → lodash path (`["foo"]["bar"]`)；处理 `~1`（`/`）和 `~0`（`~`）转义 |
| 同上 | 291–… | `extractCommands` —— 从输入文本里匹配 `<json_patch>` / `<JSONPatch>` 块，解析为 patch ops |
| 同上 | 1547–1557 | `BEFORE_MESSAGE_UPDATE` 钩子：若不含 `<StatusPlaceHolderImpl/>`，自动追加到消息末尾 |
| `/tmp/MagVarUpdate/src/function/initvar/variable_init.ts` | 全文 | `initStatData` 初始化流程：触发点 = chat 打开 / 世界书 `[initvar]` 条目 / 开场白 `<initvar>` 块 |
| `/tmp/MagVarUpdate/src/function/function_call.ts` | 153 | MVU tool definition（`use this tool to UpdateVariable`） |
| 同上 | 240–248 | function-call → 包装成 `<UpdateVariable>...<JSONPatch>...</JSONPatch></UpdateVariable>` |
| 同上 | 390–421 | `normalizeJsonPatchPayload` —— 把 LLM 输出（可能是 JSON Patch / JS lodash-call 混在 `<UpdateVariable>` 里）规范化 |
| 同上 | 423–492 | `extractFromToolCall` —— 从 tool_calls 反向构造 `<UpdateVariable>` 块 |
| 同上 | 494–… | `extractFromFormattedOutput` —— 从格式化输出（`{analysis, json_patch}`）反向构造 |
| `/tmp/MagVarUpdate/src/function/request/filter_prompts.ts` | 16, 26 | 提示词组装时**剥掉**含 `<UpdateVariable>` / `<StatusPlaceHolderImpl/>` 的消息（避免污染提示词） |

---

## 3. 显示数据流

### 3.1 用户视角：一条 AI 回复从模型到屏幕

```
LLM 输出 (raw string, e.g. "她转身离开。\n\n<UpdateVariable>\n<JSONPatch>[{op:"replace",path:"/时间",value:"傍晚"}]</JSONPatch>\n</UpdateVariable>\n\n<StatusPlaceHolderImpl/>")
        │
        ▼
[MVU] extractCommands / parseUpdateVariable
   ├─ 剥出 <UpdateVariable>...</UpdateVariable> → JSON Patch ops
   ├─ apply 到 chat[i].variables[i].stat_data
   ├─ 触发 mag_variable_update_started/ended 事件
   ├─ 若不含 <StatusPlaceHolderImpl/>，自动追加到末尾
   ▼
message.mes = 剥过 <UpdateVariable> 块 + 含 <StatusPlaceHolderImpl/> 的文本
message.extra.reasoning = 思考块（独立）
        │
        ▼
[ST] saveReply → chat[] push → addOneMessage → updateMessageElement
        │
        ▼
[ST] getMessageTextHTML → messageFormatting（message.mes OR extra.display_text）
        │
        ▼  ← 顺序：
   1. substituteParams（仅 messageId===0，替换宏）
   2. getRegexedString（display phase，isMarkdown=true）
   3. fixMarkdown
   4. encode_tags（可选 < → &lt;）
   5. 引号转换 "" → <q>
   6. Showdown Markdown → HTML
   7. DOMPurify 消毒
   8. <style> 标签 round-trip
        │
        ▼
.mes_text.innerHTML = messageHTML
        │
        ▼
用户看到的卡片正文：
   "她转身离开。"
   [状态栏占位（由用户 regex 脚本替换为 HTML）]
```

### 3.2 用户正则脚本的"状态栏美化"实际是怎么发生的

**关键发现**：`<StatusPlaceHolderImpl/>` **不**会自己渲染成好看的状态栏。MVU 只会自动追加这个 token。要把它变成 `<div class="status-card">...<span class="time">傍晚</span>...</div>` 这种皮肤，**靠用户编写的 regex 脚本**做替换。

典型用户脚本（在 `extensions.regex_scripts` 里）：

```js
{
  scriptName: "状态栏美化",
  findRegex: "<StatusPlaceHolderImpl/>",
  replaceString: `
    <div class="status-card">
      <div class="status-time">{{getvar::stat_data.时间}}</div>
      ...
    </div>
  `,
  placement: [2],   // AI_OUTPUT
  markdownOnly: true,
  promptOnly: false,
}
```

酒馆的传统"国内美化"状态栏脚本（"角色状态 / 状态栏美化"）做这一类替换，产物常常含 `<script>` / `.load(` / `<style>` / `<details>` —— **正是 iOS 端要跳过的脚本**（参见 `MessageRendererCore.orderedRegexes` 的 HTML beautify 跳过规则）。

Pyramid 的 native 路径必须**绕开这个 regex 替换环节**，直接从 `stat_data` 变量树渲染自己的 `StatusView`。

---

## 4. 变量树数据结构（MvuData）

```
MvuData {
  initialized_lorebooks: { [bookName: string]: any[] }    // 已初始化的世界书记录
  stat_data: {                                            // 实际状态数据
    时间: "傍晚",
    玩家: {
      当前所在地: "集市",
    },
    $meta: { ... StatDataMeta },                           // 元数据（template / required / extensible / ...）
    $internal: { display_data, delta_data },              // 临时，patch 应用完后清
  },
  schema: {                                               // JSON-Schema 风格
    type: "object",
    properties: { ... },
    strictTemplate?: boolean,
    concatTemplateArray?: boolean,
    strictSet?: boolean,
  },
  display_data?: { ... },                                 // @deprecated: "100->80 (受伤)" 字符串展示
  delta_data?: { ... },                                   // @deprecated: 本次更新的变更
}
```

StatData 节点特殊键：
- `$meta` —— 节点的元信息（template / required / extensible）
- `$arrayMeta` —— 数组节点的元信息
- `$internal` —— 仅 patch 执行期间存在，patch 应用完后由 `cleanUpMetadata` 清掉
- **任何键都可以是另一层 StatData / JSONPrimitive / 数组**

---

## 5. JSON Patch 词汇表（MVU "JsonPatch dialect"）

MVU 在 `extractJsonPatch` 里把以下 op 翻译成内部 Command：

| op | 内部 Command | 说明 |
|---|---|---|
| `replace` | `set` | 完整替换值（`op.path` 必须命中） |
| `delta` | `add` | **MVU 自定义**：数值加/减（`op.value` 可正可负），bool toggle |
| `insert` | `insert` | 数组按下标插入，对象按 key 插入 |
| `add` | `insert` | RFC 6902 `add`（数组末尾、对象新增键） |
| `remove` | `delete` | 删除 key / 数组下标 |
| `move` | `move` | RFC 6902 `move`（需要 `from` + `path`） |
| `copy` | — | **未实现**：switch 缺 case，silently dropped |
| `test` | — | **未实现**：switch 缺 case，silently dropped |

Path 格式严格 RFC 6901：`/foo/bar`，`~1` 解码为 `/`，`~0` 解码为 `~`。

`-` 作为数组 index token 在 `insert`/`add` 里特殊处理（push 到末尾）。

**MVU 内部**还会接受 JS lodash 表达式（`_.set('path', value)` 等）通过 `extractCommands` 解析——但 native 客户端只需支持 JSON Patch 一种格式，简化实现。

---

## 6. EventSource 钩子汇总

### ST 原生事件

| 事件 | 触发时机 | MVU 是否监听 |
|---|---|---|
| `MESSAGE_RECEIVED` | AI 回复写入 `chat[]` 之后、`addOneMessage` 之前 | ✅ MVU 在这里剥思考 + 跑 patch |
| `MESSAGE_SENT` | 用户消息推入 `chat[]` | — |
| `MESSAGE_SWIPED` | 滑动切换 | — |
| `MESSAGE_EDITED` | 用户点开编辑框 | — |
| `MESSAGE_UPDATED` | 用户保存编辑 | — |
| `MESSAGE_DELETED` | 删除消息 | — |
| `CHARACTER_MESSAGE_RENDERED` | AI 卡片 DOM 完成 | — |
| `USER_MESSAGE_RENDERED` | 用户卡片 DOM 完成 | — |
| `GENERATION_ENDED` | 一次生成结束 | — |

### MVU 自有事件（`variable_events.*`）

| 事件 | payload |
|---|---|
| `VARIABLE_INITIALIZED`（`mag_variable_initiailized`，注意 typo） | `(variables: MvuData, swipe_id: number)` |
| `VARIABLE_UPDATE_STARTED`（`mag_variable_update_started`） | `(variables: MvuData)` |
| `COMMAND_PARSED`（`mag_command_parsed`） | `(variables: MvuData, commands: CommandInfo[], message_content: string)` |
| `VARIABLE_UPDATE_ENDED`（`mag_variable_update_ended`） | `(variables: MvuData, variables_before_update: MvuData)` |
| `BEFORE_MESSAGE_UPDATE`（`mag_before_message_update`） | `(context: { variables: MvuData; message_content: string })` |

Pyramid 在 native 端只需在 `MESSAGE_RECEIVED` 等价时机（API 回流完成后）调用自己的 transpile 函数；MVU 自有事件不直接相关。

---

## 7. 错误/降级语义

| 场景 | MVU 行为 | native 端对应 |
|---|---|---|
| LLM 输出不含 `<UpdateVariable>` 块 | 静默，视为无 patch | 同 |
| `<UpdateVariable>` 内部非合法 JSON | 尝试 fallback 到 lodash 表达式正则；都不匹配则 `null`（tool-call 路径） / 整体忽略（inline 路径） | patch list 为空 → 不更新 → 输出视为纯文本 |
| Patch op 不在词汇表里（`copy` / `test`） | switch 缺 case，silently dropped | 同：跳过该 op，记录但不报错 |
| path 以 `/` 开头但其他字符非法 | `pathSegmentsToLodashPath` 转义后写入 → 变量树里出现一个诡异 key | 同；不校验 |
| 变量树被破坏（不是 plain object） | lodash 静默失败 | 同；JSONValue 类型系统天然兜底 |
| schema 不存在 | `_.has(variables, 'schema') === false`，MVU 大部分功能关掉，但仍允许 patch | native 端无 schema 概念，更简单 |
| `<StatusPlaceHolderImpl/>` 已存在但 stat_data 是空 | 用户正则替换会渲染一个"空状态" | Pyramid 的 `StatusView` 直接渲染 `["状态（等待变量）"]` 占位 |
| 世界书 `[initvar]` 条目格式错 | `entryParseFailedLog` 报错，跳过该条目 | native 端 init 阶段做 schema 校验，失败记 warning |