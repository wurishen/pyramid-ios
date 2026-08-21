# SwiftData 迁移路线图

> 状态：foundation only — 当前没有任何 store / view 真正消费 SwiftData，
> UserDefaults + JSONEncoder 仍是真实数据来源。

## 为什么需要迁移

当前持久层（`Pyramid/ViewModels/*Store.swift`）把整个 store 序列化成 JSON
塞进 `UserDefaults`。问题：

- **写放大**：每次 mutate 都重写整份 snapshot（聊天 / 世界书 / 角色卡都按 MB 级增长）。
- **无查询**：列表 / 搜索 / 关系遍历都在内存里手动维护索引（参见 `ChatStore.session(for:)`）。
- **无迁移**：schema 字段变更靠 `init(from:)` 的 `decodeIfPresent` 兜底，扩展性差。

SwiftData（iOS 17+）能解决以上三点：`@Query` 替代内存索引、`@Relationship` 替代
手写 parent/child 反查、VersionedSchema 替代 `decodeIfPresent` 兜底。

## Foundation 已落地的部分

`Pyramid/Persistence/`：

- `PersistenceSchema.swift` —— 7 个 `@Model` 类，与 `Pyramid/Models/` 下 value-type 字段一一对应：
  - `SDChatSession` / `SDChatMessage`（含 cascade delete 关系）
  - `SDWorldBook` / `SDWorldBookEntry`（含 cascade delete 关系）
  - `SDCharacter`（含 ST V3 透传字段）
  - `SDPreset`
  - `SDDisplayRegex`
- `PersistenceController.swift` —— `shared` + `inMemory()` 两个 `ModelContainer` 工厂。
  `schemaVersion = "1.0"`；新增字段必须递增版本号触发轻量级迁移。
- `PyramidApp.swift` —— 通过 `.modelContainer(...)` 注入 shared 容器。
  注入本身只是占位：让编译期校验 schema、让 SwiftData 在启动时建好 store 文件。

### 字段映射约定

| value-type 字段 | `@Model` 字段 | 备注 |
|---|---|---|
| `enum WorldBookInsertionPosition` | `insertionPositionRaw: String` | SwiftData 不持久化 enum |
| `enum WorldBookMatchMode` | `matchModeRaw: String` | 同上 |
| `enum ChatMessage.Role` | `roleRaw: String` | 同上 |
| `enum DisplayRegex.Scope` | `scopeRaw: String` | 同上 |
| `JSONValue?`（任意结构） | `*Data: Data?` | 走 JSONEncoder / Decoder 二进制化 |
| `Data?`（avatar / binary） | `@Attribute(.externalStorage) var avatarData: Data?` | 大文件走外部存储 |

迁移时这些平铺字段需要 `toStruct()` / `init(_ struct:)` 互转：
- `insertionPositionRaw == "afterSystem"` → `WorldBookInsertionPosition.afterSystem`
- `extensionsRawData == JSONEncoder().encode(value)` → `JSONValue` 还原

## Follow-up 工作（不在本任务范围）

1. **迁移触发器**：在 `AppSettings` 加 `@AppStorage("swiftDataMigrated")`；
   启动时若 `false` → 跑一次性迁移脚本：读 UserDefaults JSON → 写 SwiftData → 标 true。
2. **Store 改造**：每个 `*Store.swift` 改为持有 `@Environment(\.modelContext)` + `@Query`
   或 `ModelContext.fetch(...)`。先在「聊天 / 世界书」两条 store 试水；通过后再铺剩余。
3. **删除旧路径**：迁移完成后移除 `JSONEncoder` + `UserDefaults.standard.set`。
   保留 `StorageKeys` 常量文件至下个 release，确认线上无回滚报告再删。
4. **备份 / 导出兼容**：`BackupService` 仍按 JSON snapshot 导出；SwiftData → JSON 时
   用同一份 `toStruct()` helper，导出 / 导入格式不变。

## 注意事项

- **不要**直接用 `@Attribute(.unique)` 给非 id 字段加唯一性约束；后续多端同步会冲突。
- **不要**给关系用 `.cascade` 之外的其他 deleteRule —— 角色删除要带走 worldBook/chat，
  聊天删除要带走 message；其他方向不该触发 delete。
- SwiftData 的 `@Relationship` 在 SwiftUI 之外访问时需要手动拿 `ModelContext.fetch`；
  不要从后台线程直接碰 `@Model` 对象。
