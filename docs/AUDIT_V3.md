# Pyramid v0.7.1 → Tavern Character Card V3 / MVU 兼容性审计

**审计对象**：`wurishen/pyramid-ios` commit `cd8bd5b`
**审计范围**：18 个 Model 文件 + 5 个 Service 文件 + 17 个 View 文件 + 5 个 ViewModel 文件 + SPEC/README/xcconfig
**审计方式**：四路并行扫描（数据模型 / 导入服务 / 视图渲染 / SPEC 配置）+ ImportSupport 关键文件交叉验证（事实层面，无猜测）

---

## A. 当前仓库已经具备的能力

| 能力 | 实现位置 | 现状 |
|---|---|---|
| SillyTavern v1 / v2 角色卡 JSON 解析 | `ImportSupport.parseSillyTavernCard` | ✅ 自动识别 `data` 子对象，无 `data` 时退回根层 |
| SillyTavern v1 / v2 / v3 世界书 JSON 解析 | `WorldBookStore.parseSillyTavernData` + `parseSillyTavernEntry` | ✅ 接受 `{name, entries}` / 裸数组 / 数字键字典 / Pyramid 原生 |
| PNG 角色卡解析（tEXt `chara` chunk） | `ImportSupport.parsePngCharacters` | ✅ 三种编码（raw JSON / zlib+base64 / plain base64），2 MB 解压上限 |
| Regex Script 自动发现 | `Character.extensionsRegexScripts` + `SillyTavernScriptImporter` + `DisplayRegexStore.replaceCharacterScopedScripts` | ✅ 支持 `regex/replacement/enabled/flags/placement/substituteRegex/promptOnly/markdownOnly/runOnEdit` + 角色卡内嵌 + 生命周期绑定 |
| 原生 SwiftUI Markdown 渲染 | `MarkdownTextView`（手写块级 + 手写内联） | ✅ 零第三方依赖，无 WebView，无 `AttributedString(markdown:)`（仅 fallback 用） |
| 原生 Status 块渲染（HP / 好感度） | `RenderNodeParser` → `RenderNode.status` → `StatusView` | ✅ 原生 SwiftUI 面板 |
| 角色 ↔ 世界书绑定 | `Character.worldBookId` + `ChatSession.worldBookId/extraWorldBookIds` | ✅ 多重绑定 + 全局兜底 |
| 渲染管线（v0.7.1） | `Raw → DisplayRegex → HideTags → RenderNodeParser → RenderTree → MessageCard` | ✅ 纯函数 `RenderEngine.render(raw:context:)`，raw 永不写回 |
| iOS 17 部署目标 + iPhone/iPad | `Shared.xcconfig` `IPHONEOS_DEPLOYMENT_TARGET = 17.0` | ✅ |
| 零第三方依赖（纯 Foundation/SwiftUI/UIKit/URLSession/Combine） | — | ✅ SPEC §1 明文承诺 |
| 备份导出 / 合并 / 覆盖 | `BackupService` | ✅ JSON + 版本号，按 ID 去重 |

---

## B. 当前缺失的能力（按影响面）

| 缺口 | 影响 |
|---|---|
| **��色卡内嵌世界书** `data.character_book` | **完全丢弃**，导入时根本没读这条键 |
| **角色卡 extensions 整块保留** | 仅 `regex_scripts` 被读，其余子键（`talkativeness` / `fav` / `depth_prompt` / 第三方扩展等）全部静默丢弃 |
| **`data.tavern_helper`** | 完全丢弃，从未读取 |
| **`spec` / `spec_version`** | 没读没校验，无法区分 V1 / V2 / V3 |
| **`data.assets`** | 完全丢弃（ST 用于角色立绘集） |
| **V3 World Book Entry 字段** | ST V3 entry 的 `id / uid / group / group_weight / weight / decay / case_sensitive / useGroupScoring / automationId / role / vectorized / sticky / cooldown / delay / displayIndex / triggers / outletName / excludes / selectiveLogic / extensions` 全部丢失 |
| **ST `position` 4 值映射** | 只接受 0/3-6 四档，1-2（after char def / after example）被合并到 `.afterSystem` |
| **PNG zTXt / iTXt chunk** | 只识别 `tEXt`（明文），PNG 含压缩文本的角色卡会被丢弃 |
| **JSON round-trip 未知字段保留** | `JSONEncoder` 只编模型声明字段，导出 → 重导入 = 数据丢失 |
| **MVU（变量状态）** | 完全没有 `stat_data` / JSON Patch / 变量 schema；`<status>` 只识别硬编码的 HP + 好感度 |
| **聊天 system role** | `ChatMessage.Role` 只有 `user / assistant` |
| **多页编辑深度** | 角色编辑器没有 character_book / tavern_helper / regex_scripts / MVU 编辑面板 |
| **跨平台 worldbook 注入可复现性** | 用 Swift `Hasher` 做概率决策（SPEC §13 已记 TODO） |

---

## C. 导入 Tavern Character Card V3 最大的技术障碍

**首要阻塞：未知字段整块丢失，三层叠加**——

1. **解析层**：`ImportSupport.parseSillyTavernCard` 只读 14 个枚举键 + `extensions.regex_scripts`，其余字段被静默丢弃
2. **模型层**：`Character` struct 用 `decodeIfPresent` 容错，但 `CodingKeys` 不含 `data.character_book` / `data.extensions.*` / `data.tavern_helper`，即使 JSON 还在也无法 decode
3. **持久化层**：`CharacterStore.save` + `BackupService.makeBackup` + `JSONEncoder` 都只编模型声明字段，未知字段在每次写入时丢失

**次要阻塞（但相对独立可解）**：
- `WorldBookService.parseSillyTavernEntry` 字段映射遗漏（V3 entry 十几个字段没接）
- `parsePngCharacters` 不识别 `zTXt` / `iTXt` chunk
- 无 `spec` 字段校验，无法给用户清晰错误（"这不是 ST 卡" vs "这是 V3 但我们不识别"）

**好消息**：这些阻塞**不需要重写架构**。最大改动是给 `Character` / `WorldBookEntry` 加三个 `JSONValue?` 透传字段（`extensionsRaw` / `tavernHelperRaw` / `characterBookRaw`），导入时原样存、导出时原样写。**Phase 1 实现复杂度大约 200-300 行 Swift + 8-10 个测试**。

---

## D. 可复用代码（无需重写）

| 复用对象 | 位置 | 用途 |
|---|---|---|
| `JSONSerialization` 解码通用 JSON | `ImportSupport.parseExtensionsRegexScripts` 已示范 | 阶段 1：`extensionsRaw` / `tavernHelperRaw` / `characterBookRaw` 全部走 `JSONSerialization` 拿 `[String: Any]` |
| `SillyTavernScriptImporter` | `SillyTavernRegexScript.swift` | 阶段 1 不动，继续吃 `data.extensions.regex_scripts` |
| `decodeIfPresent` 容错模式 | 所有现有 Model | 阶段 1：透传字段直接 `decodeIfPresent` 给空 |
| `BackupService` 按 ID 去重 | `BackupService.merge` | 阶段 2：透传字段随 Character 一起走备份 |
| `WorldBookStore.parseSillyTavernEntry` | 已有 V1/V2 字段映射 | 阶段 2：在它前面加 V3 字段映射（`uid` → `externalId`, `group` → `groupId`, `case_sensitive` → 新增 caseSensitive 字段等） |
| `CharacterStore.upsert` | 已有 | 阶段 1：导入 V3 时额外调 `worldBookStore.upsertFromCharacterCard` |
| `MarkdownTextView` 手写渲染 | `Views/MarkdownTextView.swift` | 阶段 3（MVU）状态面板：扩展 `RenderNode.status` 接受任意键值对，仍走 SwiftUI 原生组件 |

---

## E. 新增 Swift 数据模型

### 阶段 1（最小改造，立刻解锁 V3 兼容）

不需要新增独立 model 文件，只在现有 struct 上加字段 + 一个新枚举：

```swift
// Pyramid/Models/Character.swift —— 加 3 个字段
struct Character: Codable, Identifiable, Equatable {
    // ... 现有字段 ...
    
    /// 角色卡里 extensions 整块透传（除 regex_scripts 已独立处理）。
    /// 用 JSONValue 不用 [String: Any]，保证 Codable 完整。
    var extensionsRaw: JSONValue?
    
    /// tavern_helper 整块透传。
    var tavernHelperRaw: JSONValue?
    
    /// 内嵌 character_book 整块透传；阶段 2 才转成 WorldBookEntry。
    var characterBookRaw: JSONValue?
}
```

```swift
// Pyramid/Models/JSONValue.swift —— 新文件（~60 行）
/// 与 [String: Any] 等价但 Codable 完整，用于"未知结构透传"。
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "无法识别的 JSONValue"
        ))
    }
    
    /// 从 [String: Any] 转（导入路径用）。
    static func from(any: Any) -> JSONValue? {
        // 标准递归实现，nil / 非法类型返回 nil
    }
}
```

### 阶段 2（V3 世界书落地）

扩展现有 `WorldBookEntry`，加 11 个字段：
```swift
struct WorldBookEntry {
    // ... 现有 12 个字段 ...
    var externalId: Int?           // ST `uid`
    var groupId: String?           // ST `group`
    var groupWeight: Double?       // ST `group_weight`
    var weight: Double?            // ST `weight`
    var decay: Double?             // ST `decay`
    var caseSensitive: Bool?       // ST `case_sensitive`
    var useGroupScoring: Bool?     // ST `useGroupScoring`
    var role: Int?                 // ST `role` (0=system/1=user/2=assistant)
    var sticky: Int?               // ST `sticky`
    var cooldown: Int?             // ST `cooldown`
    var delay: Int?                // ST `delay`
    var selectiveLogic: Int?       // ST `selectiveLogic` (0=AND_ANY,1=NOT_ALL,2=NOT_ANY,3=AND_ALL)
    var positionRaw: Int?          // 原始 ST 数值（覆盖当前 .insertionPosition 3 值限制）
    var triggers: [String]         // ST `triggers`
    var displayIndex: Int?         // ST `displayIndex`
    var extensionsRaw: JSONValue?  // ST entry 内嵌 extensions
}
```

### 阶段 3（MVU —— 本审计不实现，仅留扩展位）

不新增 model；扩展现有 `RenderNode.status` 接受 `[String: Int]` 通用键值对：
```swift
enum RenderNode {
    case text(String)
    case status(hp: Int, affection: Int)        // 向后兼容
    case stats([String: JSONValue])             // 新增：MVU 通用 stat 块
}
```

---

## F. 推荐的最小改造方案

**分三阶段，每阶段独立 commit + push + CI 验证**：

| 阶段 | 目标 | 改动量 | 风险 |
|---|---|---|---|
| **Phase 1** | V3 角色卡零丢失导入/导出 | +1 新文件（JSONValue）+ 3 个字段 + 1 个解析改动 + 8 个测试 | 低（纯加字段，向后兼容） |
| **Phase 2** | V3 内嵌 character_book 自动建世界书 + entry V3 字段映射 | +13 个 WorldBookEntry 字段 + parseSillyTavernEntry 增强 + 1 个测试 | 中（位置映射从 3 值扩到 6 值，需谨慎） |
| **Phase 3** | MVU stat_data + JSON Patch + 通用 stat 块 | +1 个 RenderNode case + 1 个变量 store + 1 个测试 | 高（设计空间大，先做 Phase 1） |

**Phase 1 优先**。完成后立刻能：
- 导入 V3 角色卡不丢任何未知字段
- 备份导出 → 删角色 → 导入备份 → 完整还原
- 旧 V1/V2 角色卡 100% 兼容（`extensionsRaw` / `tavernHelperRaw` / `characterBookRaw` 留空）

---

## G. 第一阶段（Phase 1）修改的具体文件

| # | 文件 | 改动类型 |
|---|---|---|
| 1 | `Pyramid/Models/JSONValue.swift` | **新增**（~60 行） |
| 2 | `Pyramid/Models/Character.swift` | **改**：加 3 个字段 + CodingKeys + init(from:) 容错 |
| 3 | `Pyramid/Services/ImportSupport.swift` | **改**：`parseSillyTavernCard` 写入 extensionsRaw / tavernHelperRaw / characterBookRaw |
| 4 | `swift-tests/Sources/PyramidCore/Character.swift` | （symlink 自动跟随，**不动**） |
| 5 | `swift-tests/Sources/PyramidCore/JSONValue.swift` | **新增**（symlink 到 1） |
| 6 | `swift-tests/Tests/PyramidCoreTests/CharacterV3ImportTests.swift` | **新增**（8 个测试） |
| 7 | `docs/SPEC.md` §4.7 | **新增小节**：未知字段透传规则 |
| 8 | `README.md` 角色卡兼容性小节 | **改**：补 V3 / 透传说明 |

**不动**：
- `CharacterListView` / `CharacterEditView`（UI 不变）
- `WorldBookService` / `WorldBookStore`（阶段 2 才改）
- `RenderEngine` / `MessageRenderer` / `MarkdownTextView`（渲染管线不变）
- pbxproj / xcconfig / CI workflow（无新增 target 或依赖）

---

## H. 每个文件怎么改

### H.1 新增 `Pyramid/Models/JSONValue.swift`

```swift
import Foundation

/// 递归 JSON 值类型，与 [String: Any] 等价但 Codable 完整。
/// 用于"未知结构透传"：导入时保留，导出时原样写。
enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), int(Int), double(Double)
    case string(String), array([JSONValue]), object([String: JSONValue])
    
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "JSONValue: 无法识别的类型"
        ))
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    
    /// 从 [String: Any] 转（导入路径）。nil / NSNull / 不支持类型 → nil。
    static func from(any: Any?) -> JSONValue? {
        guard let any = any else { return nil }
        if any is NSNull { return .null }
        if let v = any as? Bool { return .bool(v) }
        if let v = any as? Int { return .int(v) }
        if let v = any as? Double { return .double(v) }
        if let v = any as? String { return .string(v) }
        if let v = any as? [Any] { return .array(v.compactMap(from)) }
        if let v = any as? [String: Any] {
            var obj: [String: JSONValue] = [:]
            for (k, val) in v { if let jv = from(val) { obj[k] = jv } }
            return .object(obj)
        }
        return nil
    }
}
```

### H.2 改 `Pyramid/Models/Character.swift`

加 3 个字段 + 3 个 CodingKeys + init(from:) 用 decodeIfPresent：

```swift
/// 角色卡 extensions 整块透传（除 regex_scripts 独立处理）。
var extensionsRaw: JSONValue?
/// tavern_helper 整块透传。
var tavernHelperRaw: JSONValue?
/// 内嵌 character_book 整块透传；阶段 2 才转成 WorldBookEntry。
var characterBookRaw: JSONValue?

// init 加默认值 JSONValue? = nil
// CodingKeys 加：
case extensionsRaw, tavernHelperRaw, characterBookRaw
// init(from:) 加三行 decodeIfPresent，旧数据无此字段 → nil
extensionsRaw = try c.decodeIfPresent(JSONValue.self, forKey: .extensionsRaw)
tavernHelperRaw = try c.decodeIfPresent(JSONValue.self, forKey: .tavernHelperRaw)
characterBookRaw = try c.decodeIfPresent(JSONValue.self, forKey: .characterBookRaw)
```

### H.3 改 `Pyramid/Services/ImportSupport.swift`

`parseSillyTavernCard` 在现有解析后加：

```swift
// 透传 extensions 整块（剥掉 regex_scripts，已独立处理）
if let extensions = root["extensions"] as? [String: Any] {
    var filtered = extensions
    filtered.removeValue(forKey: "regex_scripts")
    character.extensionsRaw = JSONValue.from(any: filtered)
}
// 透传 tavern_helper
if let th = root["tavern_helper"] {
    character.tavernHelperRaw = JSONValue.from(any: th)
}
// 透传 character_book（阶段 1 只存不消费，阶段 2 才转 WorldBookEntry）
if let cb = root["character_book"] {
    character.characterBookRaw = JSONValue.from(any: cb)
}
```

注意：`root = (json["data"] as? [String: Any]) ?? json` 已让 V1/V2/V3 共用同一路径，无需版本判断。

### H.4-H.5 SPM 模块

`swift-tests/Sources/PyramidCore/Character.swift` 是 symlink → 自动跟随。`JSONValue.swift` 同理建 symlink：
```bash
ln -s ../../../Pyramid/Models/JSONValue.swift swift-tests/Sources/PyramidCore/JSONValue.swift
```

### H.6 新增 `swift-tests/Tests/PyramidCoreTests/CharacterV3ImportTests.swift`

8 个测试：
- `testV3CharacterBookIsPreservedAsRaw` —— V3 JSON 含 `character_book` → `Character.characterBookRaw` 非空
- `testV3ExtensionsPreservedExceptRegexScripts` —— V3 JSON 含多个 extensions 子键 → `extensionsRaw` 保留，但 `regex_scripts` 被剥离（独立处理）
- `testV3TavernHelperIsPreservedAsRaw` —— V3 JSON 含 `tavern_helper` → `tavernHelperRaw` 非空
- `testV2CardWithoutV3FieldsStillWorks` —— 向后兼容（V2 没 character_book → raw 字段为 nil）
- `testV1RootFieldsStillWorks` —— V1（无 `data`）→ extensionsRaw / characterBookRaw 不崩
- `testRoundTripPreservesUnknownFields` —— 导入 V3 → JSONEncoder → JSONDecoder → raw 字段完整还原
- `testMissingExtensionsLeavesRawNil` —— 无 extensions → extensionsRaw = nil
- `testJSONValueFromAnyHandlesNSNull` —— `JSONValue.from(any: NSNull)` → `.null`，不崩

### H.7 `docs/SPEC.md`

§4.7 新增小节"未知字段透传"：
- 哪些字段进 typed，哪些进 raw（规则表）
- 透传字段的导入/导出 round-trip 不变性
- 阶段 1 只存不消费（`characterBookRaw` 阶段 2 才转 WorldBookEntry）
- 不引入 JS / WebView 承诺

### H.8 `README.md`

"角色卡兼容性"小节加：
- V3 兼容说明（含 character_book / tavern_helper / extensions 整块保留）
- 强调"无 JS 沙箱 / 无 WebView"

---

## I. 修改后如何测试

### I.1 自动化测试（SPM Linux，无需 iOS）

```bash
cd swift-tests
swift test
```

新增 8 个 `CharacterV3ImportTests` 用例（见 H.6）。CI 的 `lint` job 自动跑。

### I.2 iOS build 验证（CI ���发，无需本地 Mac）

```bash
git add -A
git commit -m "feat(character): V3 unknown-fields passthrough"
git push origin main
gh run watch   # 等 lint / build / release 三 job 全绿
```

### I.3 真机手动测试（用户 Mac 上）

| 场景 | 步骤 | 期望 |
|---|---|---|
| V3 角色卡导入 | 用酒馆 V3 PNG 角色卡（含 `character_book`）导入 | 角色入库；导入完成提示含字符数；角色详情无 raw JSON 编辑面板（阶段 2 再加） |
| 导出 → 重导入不丢字段 | 导入 V3 → Settings → Backup → Export → 删角色 → 从备份 Import | 重新入库后，`extensionsRaw` / `tavernHelperRaw` / `characterBookRaw` 字段值完全相同（可加 Render Inspector 或日志断言） |
| V2 向后兼容 | 导入 V2 角色卡 | 不报错；V3-only 字段（character_book 等）留空 |
| V1 向后兼容 | 导入 V1 角色卡（字段在根层） | 不报错；正常入库 |
| 旧数据无 raw 字段 | 从 v0.7.1 升级 | 现有角色卡打开不报错；raw 字段 = nil |
| PNG zTXt 仍失败 | 导入含 zTXt chunk 的角色卡 | 维持 v0.7.1 行为（tEXt 失败时落 `invalidData`，不静默丢角色） |

### I.4 回归验证清单

- ✅ 现有 36 个 SPM 测试（RenderEngine / SillyTavern / MarkdownParser）继续通过
- ✅ 现有 iOS UI 不变（CharacterListView / CharacterEditView 不动）
- ✅ Regex Script 自动发现继续工作（`extensionsRegexScripts` 路径不变）
- ✅ SwiftLint 通过（无新增 warning）
- ✅ iOS 17 部署目标不变

---

## 一句话结论

**首要缺口是"未知字段透传通道不存在"**——结构性、三层叠加（解析 → 模型 → 持久化）。阶段 1 最小改造（~200 行 Swift + 1 新文件 + 8 测试）就能让 V3 角色卡**零丢失导入 + 零丢失导出重导入**，不引入 JS / WebView / 任何第三方依赖。阶段 2-3 是世界书落地和 MVU，按需追加。

---

## Phase 2 落地记录（2026-08-19）

| Commit | SHA | 范围 |
|---|---|---|
| 1 | `732bb1b` | `WorldBookEntry` 加 17 个 V3 字段；`parseSillyTavernEntry` 6 值 position 映射 + `positionRaw` 保留 |
| 2 | `87a60dc` | V3 `character_book` 内嵌世界书自动建书：`WorldBookStore.adoptEmbeddedWorldBook(for:)` + `Character.embeddedWorldBookId` + `activeBooks` 优先级注入 + 删除角色清理 |
| 3 | `2191b52` | `extensions` typed lift：`CharacterDepthPrompt` 新建 + `Character.talkativeness` / `isFavorite` / `depthPrompt`；`ImportSupport.applyRawPassthrough` 镜像 strip 模式；失败字段保留 raw 不动 |
| 4 | `618e83d` | `depth_prompt` 运行时注入：`DepthPromptInjector.injectInChat` / `systemAppendage`；`ChatViewModel.request` switch (role, position) → system 段拼 / history 注入；`computeContextFingerprint` 加 3 字段 |
| 5 | `7654418` | SPM 测试：3 个新文件 + `Package.swift` 更新（`V3WorldBookEntryTests` 11 例 / `CharacterExtensionsLiftTests` 17 例 / `DepthPromptInjectionTests` 14 例） |

### B 表缺口（Phase 2 后）

| 缺口 | Phase 2 状态 |
|---|---|
| 角色卡内嵌世界书 `data.character_book` | ✅ 导入时自动建书，参与运行时注入；`characterBookRaw` 保留字节级 round-trip |
| `data.extensions` 整块保留 | ✅ typed lift（`talkativeness` / `fav` / `depth_prompt`）+ 其余子键保留在 `extensionsRaw` |
| `data.extensions.depth_prompt` | ✅ typed 字段 + 运行时按 ST 规则注入（`.inChat` 插历史 / `.before` 拼 system / `.after` 拼 history）|
| V3 World Book Entry 字段（17 个） | ✅ 全部落到 typed 字段；`positionRaw` 保留 ST 原值避免折叠漂移 |
| ST `position` 4 值映射 | ✅ `insertionPosition` 仍是 3 值（beforeSystem / afterSystem / afterHistory），1-2 / 3-6 折叠规则不变 |

### Phase 3（暂不做，按需追加）

- MVU / JSON Patch / 变量 store / stat_data UI
- `<status>` 块扩展接受任意键值对
- 编辑器 UI（character_book / depth_prompt 页面）
- `selectiveLogic` / `sticky` / `cooldown` 运行时语义
- `case_sensitive` 改动 `WorldBookService.matches`