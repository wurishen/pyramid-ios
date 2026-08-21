import Foundation
import SwiftData

/// SwiftData `ModelContainer` 的单例工厂。
///
/// **Foundation only** —— 当前没有任何 store / view 真正消费这个容器；
/// 它已经在 `PyramidApp` 里被 `.modelContainer(...)` 注入，作用是：
/// 1. 让 Xcode 在编译期校验 `@Model` schema 字段合法性（防止漏字段拖到运行时）。
/// 2. 让 SwiftData 在 app 启动时建好 store 文件，方便后续迁移阶段直接读旧数据写新表。
/// 3. 提供 `shared` 与 `inMemory` 两个工厂；前者用于生产，后者用于单测 / 预览。
///
/// 完整的数据迁移（UserDefaults JSON snapshot → SwiftData）见
/// `docs/MIGRATION_TO_SWIFTDATA.md` —— 该任务在 follow-up 中。
enum PersistenceController {

    /// Schema 版本号。每次新增字段必须递增 —— SwiftData 用它判断是否需要轻量级迁移。
    /// 当前 schema 与 `Pyramid/Models/` 下的 value-type 一致，无需迁移即可升级。
    static let schemaVersion = "1.0"

    /// 整个 app 共享的 `ModelContainer`。第一次访问时构造；之后复用。
    static let shared: ModelContainer = {
        let schema = Schema([
            SDChatSession.self,
            SDChatMessage.self,
            SDWorldBook.self,
            SDWorldBookEntry.self,
            SDCharacter.self,
            SDPreset.self,
            SDDisplayRegex.self
        ])
        let config = ModelConfiguration(
            "PyramidStore",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // schema 不匹配 / 损坏 / 磁盘不可写。Foundation 阶段最坏情况：
            // 容器建不起来 → app 不能继续运行。但目前没有 store 真消费它，所以 fatal 是安全的。
            fatalError("无法创建 ModelContainer：\(error)")
        }
    }()

    /// 内存版 `ModelContainer`，给 SwiftUI Preview / XCTest 用。每次都返回新实例，避免测试间串数据。
    @MainActor
    static func inMemory() -> ModelContainer {
        let schema = Schema([
            SDChatSession.self,
            SDChatMessage.self,
            SDWorldBook.self,
            SDWorldBookEntry.self,
            SDCharacter.self,
            SDPreset.self,
            SDDisplayRegex.self
        ])
        let config = ModelConfiguration(
            "PyramidStore-InMemory",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("无法创建 in-memory ModelContainer：\(error)")
        }
    }
}
