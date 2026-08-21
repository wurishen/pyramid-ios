# Pyramid iOS 已知问题清单

> 截至 v0.7.1+ — 按"对用户的影响"排序，不分模块。修复优先级在 issue tracker。

## 1. 持久层未迁移到 SwiftData

**现象**：当前所有 store（聊天 / 世界书 / 角色卡 / 预设 / DisplayRegex）通过 `JSONEncoder` + `UserDefaults` 持久化整份 snapshot。

**影响**：
- 大数据下（聊天 1000+ 条 / 角色卡 50+ 张）每次 mutate 都重写整份 JSON，写放大严重
- 无 SQL 风格的查询；列表 / 搜索 / 关系遍历都靠内存索引（参见 `ChatStore.session(for:)` 的自维护缓存）

**修复路径**：见 `docs/MIGRATION_TO_SWIFTDATA.md`。Foundation 已在 commit `54dca50` 落地（`@Model` schema + `ModelContainer` 注入）；实际数据迁移在 follow-up。

---

## 2. WorldBookEntry V3 字段编辑 UI 未做

**现象**：V3 字段（`triggers` / `excludes` / `caseSensitive` / `selectiveLogic` / `weight` / `decay` / `groupKey` / `useGroupScoring`）在 `WorldBookEntryEditView` 没有专门的编辑面板；导入 V3 角色卡 → 这些字段值是设置进去了，但用户在 UI 上看不到 / 改不了。

**影响**：
- 用户从 ST 导入了精细的 world book → 在 Pyramid 编辑后丢失 V3 设置
- 误改 ST 兼容性字段（selectiveLogic=2 NOT_ANY 等）会显著改变注入行为

**临时方案**：JSON 导入导出 round-trip 仍保留全部字段（`BackupService` + `JSONEncoder` 走 `WorldBookEntry.Codable`），用户可以编辑 JSON。

---

## 3. 编辑器缺：character_book / depth_prompt / regex scripts 面板

**现象**：
- V3 角色卡内嵌的 `character_book` / `depth_prompt` / `extensions.regex_scripts` 在 `CharacterEditView` 里看不到编辑入口
- 角色卡编辑后这些字段值是有的，但用户无法直接编辑它们

**影响**：用户只能编辑 V1 风格字段（name / description / personality / scenario / first_mes / mes_example），不能做 V3 风格的精细调整。

---

## 4. 概率门控使用 Swift Hasher（跨进程不稳定）

**现象**：`WorldBookService` 用 `Swift.Hasher` 做概率门控的 RNG。Swift `Hasher` 用每次进程启动的随机 seed（`Hasher.randomizeSeed()` 类似机制）—— 同一份输入在不同进程里**可能**得到不同的概率命中。

**实测**：iOS Simulator / 真机重启 app → 同一份聊天 + 同一份概率 50% 的 entry → 命中 / 不命中可能反转。

**影响**：
- 用户报告"概率 100% 的 entry 偶尔不出现" —— 实际是概率 < 100 的 entry 在重启后命中变化
- 跨进程 / 跨设备同步（未来多端同步）会导致同一份 entry 在两端表现不一致

**临时方案**：不修复；告知用户"重启 app 后概率命中可能变化"。

**修复路径**：把概率门控的哈希换为 `SipHash` 或 `SHA256(id+text).prefix(8)` 这种进程无关的稳定哈希。

---

## 5. ChatMessage 不支持 system role

**现象**：`ChatMessage.Role` 只有 `.user` 和 `.assistant`。

**影响**：
- 用户从 ST 导入带 system 消息的聊天 → system role 被映射成 assistant（数据丢失语义）
- 部分 API（Anthropic Claude / Google Gemini）支持 system role 单独传 —— Pyramid 目前通过拼 system prompt 解决，不通过消息 role

**临时方案**：保留 system 消息内容在 system prompt 拼接处（`ChatViewModel` 已有逻辑）。

---

## 6. WorldBook 注入按 (input + 后 N 楼 history) 扫描，无滑动窗口

**现象**：`WorldBookService.selectedEntries` 按每条目 `scanDepth` 拼 `input + "\n" + history.suffix(depth)` 作为扫描文本。改 depth 时整段重算。

**影响**：
- 大聊天（100+ 楼）下，每次请求都要重算所有 entry 的搜索文本
- 同一份聊天 + 不同 entry 不同 depth → 缓存键 (depth, caseSensitive) 维护得正确但 key 数量可能膨胀

**临时方案**：缓存按 `(depth, caseSensitive)` 二维 key 分桶。

**修复路径**：改成滑动窗口 + lazy 编译（每个 entry 第一次编译后缓存编译后的小写关键字 + 正则），已在 commit `cdac2fd` 部分落地；进一步优化（per-character 哈希预计算）待做。

---

## 7. `<UpdateVariable>` JSON Patch 应用失败时整块降级为 .text

**现象**：`RenderNodeParser.parseUpdateVariableBlock` 在 JSON 解析失败或 `applyPatches` 抛错时，把整段标签 + body 降级为 `.text(rawBlock)`。

**影响**：用户在聊天里看到 `<UpdateVariable>[...]</UpdateVariable>` 字面文本；变量没更新。

**常见失败原因**：
- 模型输出 malformed JSON（缺 `]` / 缺逗号 / 引号不配对）
- Patch 路径不存在（VariableStore 里没有该 key）
- Patch 操作符不支持（Pyramid 不实现 `move` / `copy` / `test`）

**临时方案**：在调试构建里用 `RenderInspectorView` 看 `.text` 节点是否有标签字面文本，判断是否 patch 失败。

**修复路径**：增加 JSON Patch 解析的容错（部分 op 失败时其他 op 仍生效）+ 在 `.text` 降级前给一个 `.variableUpdate` 错误摘要节点。

---

## 8. MarkdownTextView 手写 parser 不支持嵌套列表 / 表格

**现象**：`MarkdownTextView` 是手写块级 + 内联 parser，覆盖了 Pyramid 实际能遇到的所有格式（标题 / 列表 / 代码块 / 引用 / 链接 / 粗体 / 斜体 / 删除线）。但：
- 嵌套列表只支持一层缩进
- 不支持表格（`| col | col |`）
- 不支持脚注 / 定义列表

**影响**：模型按规范输出 → 渲染正常；模型偶尔输出 ST 风格的表格 → 表格被原样当文本展示。

**临时方案**：表格行 / 脚注作为字面文本显示，不丢失内容。

---

## 9. BackupService 导出不含 MVU 变量树

**现象**：`BackupService.export` 把 `VariableStore.raw(forSession:)` 的数据塞进 JSON；但跨会话的 VariableStore 没有单独持久层（每次 app 启动从 session initData 重算）。

**影响**：
- 导出 → 重导入 → 跨 session 的变量引用关系可能错乱
- 实际影响有限：99% 的变量是 per-session，重算就能恢复

**临时方案**：导出每会话的 `initData`（character.initStatData）已足够 99% 场景重建。

---

## 10. SPM 测试在 Linux 不能跑（环境限制）

**现象**：`PyramidCoreTests` SPM target 走 `.macOS(.v13)`，但项目根目录的 CI 是 `macos-14 + Xcode 16.2`。本地 Linux / WSL 用户无法 `swift test`。

**原因**：`WorldBookService` / `BackupService` 用了 `import os`（OSAllocatedUnfairLock），Linux 没有对应实现。

**临时方案**：CI 用 macos runner，无本地跨平台需求。

**修复路径**：把 OSAllocatedUnfairLock 替换成 `DispatchQueue` / `Mutex`（Linux `Synchronization.Mutex`），或加 `#if canImport(Darwin)` 双实现。

---

## 历史已修复（参见 `docs/AUDIT_V3.md` Phase 1-3 落地记录）

- ✅ MessageRenderer.swift 是死代码（commit `a33e38a` 删除）
- ✅ `MessageRenderer.swift` 在 project.pbxproj 里的 stale references（commit `54dca50` 顺手清理）
- ✅ `<status>` 块只识别 HP + 好感度（commit `2f2b0ec` 扩展到任意 key/value）
- ✅ V3 World Book Entry 字段未运行时生效（commit `cdac2fd`）
- ✅ ST `promptOnly` 未生效（commit `1d025cb`）
- ✅ MVU / JSON Patch / VariableStore 缺失（commit `cdac2fd` 之前的 P3 落地）
