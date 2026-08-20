# 原版字段清单：数据 vs 皮肤

> Phase 7 调研结论（2026-08-20）。基于对 SillyTavern Character Card V3 + MagVarUpdate 源码的阅读，将所有"酒馆风格"字段分类为 **必须 native 渲染** vs **皮肤/装饰/可选**。
>
> 分类原则：
> - **数据 (D)**：含可计算、有真实信息的字段（如 `stat_data`、`character_book`、`regex_scripts`），客户端必须读懂并按 native 原语转译。
> - **皮肤 (S)**：纯展示 / UI 装饰 / 用户审美偏好字段（如酒馆皮肤 HTML、CSS、嵌入图片）。native 端**不渲染**这些，转译时**跳过**。
> - **协议 (P)**：客户端间通信字段（如 `extensions.regex_scripts`、`extensions.TavernHelper-stscript`）。native 端**保留原值**不解析、但要在 import/export 时透传。
>
> 来源：
> - `/tmp/SillyTavern/public/scripts/char-data.js` —— V2/V3 schema
> - `/tmp/MagVarUpdate/src/variable_def.ts` —— MVU 数据结构
> - `/tmp/SillyTavern/public/scripts/extensions/regex/editor.html` —— 用户编辑 regex 的实际 UI
> - 社区"国内美化"脚本（用户在 `extensions.regex_scripts` 里手写的皮肤）

---

## 1. chara_card_v3 顶层字段

```jsonc
{
  "spec": "chara_card_v3",         // D：版本号，必须解析
  "spec_version": "3.0",           // D
  "name": "角色名",                  // D
  "description": "角色描述",        // D
  "tags": ["标签"],                  // D（搜索/分类用）
  "creator": "作者",                 // D（展示）
  "character_version": "1.0",       // D
  "mes_example": "<START>\n{{user}}: hi\n{{char}}: hi",  // D（few-shot，但 native 默认不用）
  "creator_notes": "提示词说明",        // S（meta UI，可作 plain text 显示）
  "system_prompt": "...",           // D
  "post_history_instructions": "...",// D
  "first_mes": "开场白",             // D
  "alternate_greetings": ["..."],   // D
  "personality": "...",             // D
  "scenario": "...",                // D
  "talkativeness": "0.5",           // D（number，V3 typed）
  "fav": false,                     // D（bool，V3 typed）
  "depth_prompt": { "prompt": "...", "depth": 4, "role": "system" }, // D（V3 typed）
  "extensions": { ... },            // 见 §2
  "character_book": { ... },        // D，见 §3
  "assets": [ ... ],                // S，见 §4
  "nickname": "昵称",                // D
  "source": ["..."]                 // D（出处）
}
```

---

## 2. `extensions` 字段

```jsonc
"extensions": {
  "regex_scripts": [                // P → D（native 解析为 DisplayRegex）
    {
      "id": "uuid",
      "scriptName": "...",
      "findRegex": "...",
      "replaceString": "...",
      "trimStrings": ["..."],
      "placement": [2, 5],          // D：决定何时跑
      "disabled": false,
      "markdownOnly": true,
      "promptOnly": false,
      "runOnEdit": true,
      "substituteRegex": 0,
      "minDepth": null,
      "maxDepth": null
    }
  ],
  "TavernHelper-stscript": { ... }, // P：透传不解析
  "talkativeness": "0.5",           // D：可能与顶层重复
  "fav": false,                     // D
  "world": "...",
  "depth_prompt": { ... },          // D：可能与顶层重复
  "character_version": "...",
  "create_date": "...",             // D（meta）
  "tag": ["..."],                   // D
  "riskChapter": "...",             // D
  "data": { ... }                   // P：内部
}
```

字段分类：

| 字段 | 类别 | 备注 |
|---|---|---|
| `regex_scripts` | D | native 解析为 `DisplayRegex`，跑 `getRegexedString` |
| `talkativeness` / `fav` / `depth_prompt` | D | V3 已 typed，与顶层合并即可 |
| `world` / `create_date` / `tag` / `riskChapter` / `character_version` | D/P | 编辑器元信息 |
| `TavernHelper-stscript` | P | 透传 |
| 其他任意自定义键 | P | 透传（按 `extensions` 整体保存） |

---

## 3. `character_book`（V3 内嵌世界书）

```jsonc
"character_book": {
  "name": "内嵌书",
  "description": "...",
  "scan_depth": 50,
  "token_budget": 500,
  "recursive_scanning": false,
  "entries": [
    {
      "id": 1,
      "keys": ["keyword"],
      "secondary_keys": ["..."],
      "comment": "...",
      "content": "...",
      "constant": false,
      "selective": true,
      "insertion_order": 100,
      "enabled": true,
      "position": "before_char",     // "before_char" | "after_char" | "before_example_messages" | "after_example_messages" | "before_desc" | "after_desc" | "at_depth_as_system" | "at_depth_as_assistant"
      "use_regex": true,
      "extensions": {
        "position": 4,              // 数字 position，与字符串 position 并存；优先数字
        "exclude_recursion": false,
        "prevent_recursion": false,
        "probability": 100,
        "depth": [4, 8],            // @depth 时生效
        "selectiveLogic": 0,        // 0=AND_ANY, 1=NOT_ALL, 2=NOT_ANY, 3=AND_ALL
        "group": "group_name",
        "group_override": false,
        "group_weight": 100,
        "display_index": 0,
        "macro": null,
        "case_sensitive": null,
        "match_text": null,
        "delay_until_recursion": null,
        "sticky": null,
        "cooldown": null,
        "triggers": []
      }
    }
  ]
}
```

字段分类：全部 D。

---

## 4. `assets`（头像/图标）

```jsonc
"assets": [
  {
    "type": "icon",                // "icon" | "background" | "user_icon" | "expression" | "decoration" | "video"
    "name": "happy",
    "uri": "data:image/png;base64,...",   // S
    "ext": "png"
  }
]
```

字段分类：

- `assets` 数组整体 **S**：native 客户端可以**展示**图标列表（tap 切换），但不解析皮肤 HTML。
- `uri`（base64 data URL）**D**：iOS 直接 decode 成 `UIImage`。

---

## 5. `regex_scripts` 字段逐项

### 5.1 数据字段（D）—— 必须解析

| 字段 | 类型 | 含义 |
|---|---|---|
| `id` | string (UUID) | 唯一标识 |
| `scriptName` | string | UI 显示名 |
| `findRegex` | string | 正则源 |
| `replaceString` | string | 替换模板（含 `{{match}}` / `$1` / `{{macros}}`） |
| `trimStrings` | string[] | 替换前后先 trim 掉的字符串 |
| `placement` | number[] | 见下表 |
| `disabled` | bool | 是否启用 |
| `markdownOnly` | bool | 是否仅作用于显示 |
| `promptOnly` | bool | 是否仅作用于提示词 |
| `runOnEdit` | bool | 编辑消息时是否重跑 |
| `substituteRegex` | number (0/1/2) | findRegex 在编译前是否替换 `{{macros}}` |
| `minDepth` / `maxDepth` | number \| null | 深度窗口 |

### 5.2 placement 数值含义（D）

| 值 | 名称 | 含义 | native 端处理 |
|---|---|---|---|
| 0 | MD_DISPLAY | 已弃用 | 迁移到 all-placement，display+prompt 都跑 |
| 1 | USER_INPUT | 用户消息 | native 显示期：message.is_user |
| 2 | AI_OUTPUT | AI 消息 | native 显示期：默认 |
| 3 | SLASH_COMMAND | narrator | native 暂不支持（普通 AI 消息也会误命中，不理） |
| 4 | (legacy) | 已迁移到 3 | 同 3 |
| 5 | WORLD_INFO | 世界书内容 | native 不渲染世界书内容（提示词层） |
| 6 | REASONING | 推理块 | native 暂不渲染思考块（V1 计划） |

### 5.3 substituteRegex 含义（D）

| 值 | 名称 | 含义 |
|---|---|---|
| 0 | NONE | 不替换宏，原样编译 |
| 1 | RAW | 替换宏后再编译（变量值不转义） |
| 2 | ESCAPED | 替换宏后再编译（变量值做正则转义） |

### 5.4 皮肤触发标志（D，但用于 native 跳过规则）

`replaceString` **含以下任意关键字**时为"国内美化"皮肤脚本，**native 必须跳过**：

| 子串 | 含义 |
|---|---|
| `<script` | 注入脚本标签 |
| `.load(` | jQuery 远程加载 |
| `<object` | 远程对象 |
| `<iframe` | 远程框架 |
| `<details` | 折叠面板（常配合 HTML 皮肤） |
| `<style` | 内联样式表 |
| `<div class=...><div...>` 深嵌套 | 视觉布局 |

实际工程上：跳过规则直接走 substring 检测（前 6 个标签字面量），命中即过滤。

---

## 6. `init_stat_data` / `extensions.data.stat_data`（D）

```jsonc
{
  "时间": "傍晚",
  "玩家": {
    "当前所在地": "集市"
  },
  "$meta": {                       // D：模板/必需项声明
    "strictTemplate": false,
    "concatTemplateArray": false,
    "strictSet": false
  }
}
```

字段分类：

- **普通键** D：stateful 状态变量
- `$meta` D：节点的 schema 元信息（native 端可忽略，但需透传）
- `$internal` D：patch 临时缓存，patch 完成后清（native 永不持久化）
- `$arrayMeta` D：数组节点元信息

---

## 7. `<UpdateVariable>` 块内部（D）

两种格式（MVU 都接受）：

### 7.1 JSON Patch 数组（推荐）

```json
[
  { "op": "replace", "path": "/时间", "value": "傍晚" },
  { "op": "delta", "path": "/玩家/金币", "value": -5 },
  { "op": "remove", "path": "/玩家/旧值" }
]
```

op 词汇表：

| op | 来源 | native 翻译 |
|---|---|---|
| `replace` | RFC 6902 | `JSONPatchOperation.replace(path, value)` |
| `add` | RFC 6902 | `JSONPatchOperation.add(path, value)` |
| `remove` | RFC 6902 | `JSONPatchOperation.remove(path)` |
| `move` | RFC 6902 | `JSONPatchOperation.move(from, path)` |
| `delta` | MVU 扩展 | 数值 `+= value` 或 `bool toggle` |
| `insert` | MVU 扩展 | 数组按下标插入、对象按 key 插入 |

**注意**：MVU 的 `extractJsonPatch` switch 没有 `copy` / `test` 的 case——这两类 op **silently dropped**。native 端要么同样 drop，要么单独实现。

### 7.2 lodash-call 表达式（兼容模式）

```
_.set('stat_data.玩家.金币', 50);
_.insert('stat_data.库存', '苹果');
_.delete('stat_data.旧值');
```

native **不实现**此格式（用户契约是 JSON Patch 数组）。

---

## 8. `<StatusPlaceHolderImpl/>` 替换内容

`<StatusPlaceHolderImpl/>` 自身不渲染。**酒馆原生渲染完全靠用户 regex 脚本**（§5.4 提到的"国内美化"皮肤）。

native 端必须**完全跳过**这些皮肤脚本，**自己**从 `stat_data` 渲染 `StatusView`：

- 字段路径 → `path` (D)
- 字段值 → primitive string / number / bool / 嵌套对象（D）
- `$meta.template` → 模板（D，可用于"新建子项"按钮，本期不实现 UI）
- `$meta.required` → 必填项（D，本期不实现 UI）

字段分类结论：**全部 D**（无皮肤字段）。

---

## 9. Pyramid 当前 Fixture 中各字段的角色

`swift-tests/Fixtures/native_transpile_fixture.json` 现有字段：

| 字段 | 类别 | 当前 iOS 行为 |
|---|---|---|
| `first_mes` | D | ✅ 渲染 |
| `sample_messages[].content` | D | ✅ 渲染 |
| `sample_messages[]` 含 `<StatusPlaceHolderImpl/>` | D | ✅ 跳过对应文本，转 `.statusPlaceholder` |
| `sample_messages[]` 含 `<<UpdateVariable>>` | D | ✅ 剥 block，应用 JSON Patch，emit `.variableUpdate` |
| `regex_scripts[i]` D 项 | D | ✅ 解析进 DisplayRegex |
| `regex_scripts[i]` 含 `<script>` / `.load(` / `<details>` / `<style>` / `<object>` / `<iframe` 跳过规则 | 触发跳过 | ✅ `MessageRendererCore.isHtmlBeautify` 过滤 |
| `regex_scripts[i]` `promptOnly == true` | D | ✅ 显示管线过滤 |
| `init_stat_data` | D | ✅ sessionId 首启时种 `VariableStore` |
| `mvu_output_contract.path_underscore_skip` | D（Pyramid 自定义） | ✅ patch path 以 `_` 开头跳过 |

fixture 没有"皮肤字段"——所有数据都是协议层（P/D），所以 fixture 可以零风险扩展。