import Foundation
import SwiftUI
import os

private let worldBookLog = Logger(subsystem: "pyramid.import", category: "WorldBook")

final class WorldBookStore: ObservableObject {
    @Published var books: [WorldBook] = []

    var globalBook: WorldBook {
        books.first ?? WorldBook(title: "全局世界书")
    }

    init() {
        load()
        if books.isEmpty {
            books = [migrateLegacyEntries()]
            save()
        }
    }

    func book(for id: UUID?) -> WorldBook {
        if let id, let found = books.first(where: { $0.id == id }) {
            return found
        }
        return globalBook
    }

    /// 当前会话参与注入的世界书集合（三级作用域并集）。
    /// - 全局启用: `isGloballyEnabled == true`
    /// - 角色绑定: `character.worldBookId` 对应书
    /// - 会话临时启用: `session.extraWorldBookIds`
    /// 顺序: 全局 → 角色 → 会话额外；同 ID 重复出现只保留首个。
    func activeBooks(for session: ChatSession?, character: Character?) -> [WorldBook] {
        var seen = Set<UUID>()
        var result: [WorldBook] = []
        for book in books where book.isGloballyEnabled {
            if seen.insert(book.id).inserted { result.append(book) }
        }
        if let char = character, let id = char.worldBookId,
           let book = books.first(where: { $0.id == id }),
           seen.insert(book.id).inserted {
            result.append(book)
        }
        if let session {
            for id in session.extraWorldBookIds {
                if let book = books.first(where: { $0.id == id }),
                   seen.insert(book.id).inserted {
                    result.append(book)
                }
            }
        }
        return result
    }

    @discardableResult
    func createBook() -> WorldBook {
        let book = WorldBook(title: "世界书 \(books.count + 1)")
        books.append(book)
        save()
        return book
    }

    @discardableResult
    func createBook(title: String) -> WorldBook {
        let book = WorldBook(title: title)
        books.append(book)
        save()
        return book
    }

    func renameBook(_ id: UUID, to title: String) {
        guard let index = books.firstIndex(where: { $0.id == id }),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        books[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func resetBooks() {
        books = [WorldBook(title: "全局世界书")]
        save()
    }

    func add(_ entry: WorldBookEntry, to bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].entries.append(entry)
        save()
    }

    func update(_ entry: WorldBookEntry, in bookID: UUID) {
        guard let bookIndex = books.firstIndex(where: { $0.id == bookID }),
              let entryIndex = books[bookIndex].entries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        books[bookIndex].entries[entryIndex] = entry
        save()
    }

    func deleteBook(_ id: UUID) {
        guard books.count > 1 else { return }
        books.removeAll { $0.id == id }
        save()
    }

    func deleteEntry(_ id: UUID, in bookID: UUID) {
        guard let bookIndex = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[bookIndex].entries.removeAll { $0.id == id }
        save()
    }

    func exportJSON(books: [WorldBook]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(WorldBookExport(books: books))) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writeExport(books: [WorldBook], suffix: String) -> URL {
        let filename = "pyramid-worldbook-\(suffix)-\(Int(Date().timeIntervalSince1970)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? exportJSON(books: books).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func parseImportData(_ data: Data) throws -> WorldBookImportContent {
        if let export = try? JSONDecoder().decode(WorldBookExport.self, from: data) {
            guard !export.books.isEmpty else { throw WorldBookImportError.noBooks }
            worldBookLog.info("recognized native export: \(export.books.count) book(s), \(export.books.reduce(0) { $0 + $1.entries.count }) entries")
            return WorldBookImportContent(books: export.books)
        }
        if let array = try? JSONDecoder().decode([WorldBook].self, from: data) {
            guard !array.isEmpty else { throw WorldBookImportError.noBooks }
            worldBookLog.info("recognized bare book array: \(array.count) book(s)")
            return WorldBookImportContent(books: array)
        }
        if let single = try? JSONDecoder().decode(WorldBook.self, from: data) {
            worldBookLog.info("recognized single book: \(single.entries.count) entries")
            return WorldBookImportContent(books: [single])
        }
        if let st = try? Self.parseSillyTavernData(data) {
            worldBookLog.info("recognized SillyTavern world book: \(st.entries.count) entries")
            return WorldBookImportContent(entries: st.entries, suggestedTitle: st.name)
        }
        throw WorldBookImportError.invalidData
    }

    @discardableResult
    func importBooks(_ decoded: [WorldBook], mode: WorldBookImportMode) -> WorldBookImportResult {
        switch mode {
        case .overwrite:
            books = decoded
            save()
            let entries = decoded.reduce(0) { $0 + $1.entries.count }
            worldBookLog.info("overwrite import: \(decoded.count) book(s), \(entries) entries")
            return WorldBookImportResult(books: decoded.count, entries: entries, firstBookID: decoded.first?.id)
        case .merge:
            var addedEntries = 0
            var firstBookID: UUID?
            for book in decoded {
                if let bookIndex = books.firstIndex(where: { $0.id == book.id }) {
                    var merged = books[bookIndex]
                    for entry in book.entries where !merged.entries.contains(where: { $0.id == entry.id }) {
                        merged.entries.append(entry)
                        addedEntries += 1
                    }
                    books[bookIndex] = merged
                    if firstBookID == nil { firstBookID = merged.id }
                } else {
                    books.append(book)
                    addedEntries += book.entries.count
                    if firstBookID == nil { firstBookID = book.id }
                }
            }
            save()
            worldBookLog.info("merge import: \(decoded.count) book(s) processed, \(addedEntries) entries added")
            return WorldBookImportResult(books: decoded.count, entries: addedEntries, firstBookID: firstBookID)
        }
    }

    @discardableResult
    func createBook(title: String, entries: [WorldBookEntry], isGloballyEnabled: Bool = true) -> WorldBook {
        let book = WorldBook(title: title, entries: entries, isGloballyEnabled: isGloballyEnabled)
        books.append(book)
        save()
        return book
    }

    func setGloballyEnabled(_ enabled: Bool, for bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].isGloballyEnabled = enabled
        save()
    }

    @discardableResult
    func mergeEntries(_ entries: [WorldBookEntry], into bookID: UUID) -> Int {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return 0 }
        var existingContents = Set(books[index].entries.map(\.content))
        var importedCount = 0
        for entry in entries where !existingContents.contains(entry.content) {
            books[index].entries.append(entry)
            existingContents.insert(entry.content)
            importedCount += 1
        }
        save()
        return importedCount
    }

    @discardableResult
    func overwriteEntries(_ entries: [WorldBookEntry], in bookID: UUID) -> Int {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return 0 }
        books[index].entries = entries
        save()
        return entries.count
    }

    private struct SillyTavernParseResult {
        var entries: [WorldBookEntry]
        var name: String?
    }

    private static func parseSillyTavernData(_ data: Data) throws -> SillyTavernParseResult {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw WorldBookImportError.invalidData
        }

        var entriesRaw: Any?
        var name: String?
        if let dict = json as? [String: Any] {
            name = dict["name"] as? String
            entriesRaw = dict["entries"]
        } else if let array = json as? [Any] {
            entriesRaw = array
        }

        guard let entriesRaw else { throw WorldBookImportError.invalidData }

        var entryObjects: [Any] = []
        if let entriesDict = entriesRaw as? [String: Any] {
            let keys = entriesDict.keys.sorted { lhs, rhs in
                let left = Int(lhs) ?? Int.max
                let right = Int(rhs) ?? Int.max
                return left == right ? lhs < rhs : left < right
            }
            entryObjects = keys.compactMap { entriesDict[$0] }
        } else if let entriesArray = entriesRaw as? [Any] {
            entryObjects = entriesArray
        }

        let entries = entryObjects.compactMap { object -> WorldBookEntry? in
            guard let raw = object as? [String: Any] else { return nil }
            return Self.parseSillyTavernEntry(raw)
        }
        guard !entries.isEmpty else { throw WorldBookImportError.noEntries }
        return SillyTavernParseResult(entries: entries, name: name)
    }

    private static func parseSillyTavernEntry(_ raw: [String: Any]) -> WorldBookEntry {
        var entry = WorldBookEntry()

        let content = (raw["content"] as? String) ?? ""
        entry.content = content

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comment = raw["comment"] as? String, !comment.trimmingCharacters(in: .whitespaces).isEmpty {
            entry.title = comment
        } else if let name = raw["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            entry.title = name
        } else if !trimmedContent.isEmpty {
            let maxLen = 50
            entry.title = trimmedContent.count > maxLen
                ? String(trimmedContent.prefix(maxLen)) + "…"
                : trimmedContent
        } else {
            entry.title = "未命名"
        }

        let keyField = raw["key"] ?? raw["keys"]
        if let keyArray = keyField as? [String] {
            entry.keywords = keyArray.flatMap { Self.splitKeywords($0) }
        } else if let keyString = keyField as? String {
            entry.keywords = Self.splitKeywords(keyString)
        }

        let secondaryField = raw["keysecondary"] ?? raw["keySecondary"]
        if let secondaryArray = secondaryField as? [String] {
            entry.secondaryKeywords = secondaryArray.flatMap { Self.splitKeywords($0) }
        } else if let secondaryString = secondaryField as? String {
            entry.secondaryKeywords = Self.splitKeywords(secondaryString)
        }

        entry.isConstant = (raw["constant"] as? Bool) ?? false
        entry.isEnabled = !((raw["disable"] as? Bool) ?? false)

        // 酒馆 order 越小越优先，与原生 priority 升序排序（小=优先）一致，直接映射
        if let order = raw["order"] as? NSNumber {
            entry.priority = order.intValue
        } else if let priority = raw["priority"] as? NSNumber {
            entry.priority = priority.intValue
        } else if let insertion = raw["insertion_order"] as? NSNumber {
            entry.priority = insertion.intValue
        }

        if let matchWholeWords = raw["matchWholeWords"] as? Bool, matchWholeWords {
            entry.matchMode = .exact
        }

        // useProbability=false 视为不启用概率（=100 恒触发）
        if let useProbability = raw["useProbability"] as? Bool, !useProbability {
            entry.probability = 100
        } else if let probability = raw["probability"] as? NSNumber {
            entry.probability = min(max(probability.intValue, 0), 100)
        }

        if let depth = raw["depth"] as? NSNumber {
            entry.scanDepth = depth.intValue
        } else if let scanDepth = raw["scanDepth"] as? NSNumber {
            entry.scanDepth = scanDepth.intValue
        }

        // 酒馆 position：0=角色定义前、1=角色定义后、2=示例对话后、
        // 3=聊天历史前、4=聊天历史后、5/6=作者笔记深度位。
        // Phase 2：保留 `positionRaw` 用于 round-trip；运行时 `insertionPosition`
        // 仍是 3 值枚举（beforeSystem / afterSystem / afterHistory），5、6 折叠到 afterHistory。
        if let position = raw["position"] as? NSNumber {
            entry.positionRaw = position.intValue
            switch position.intValue {
            case 0:
                entry.insertionPosition = .beforeSystem
            case 3, 4, 5, 6:
                entry.insertionPosition = .afterHistory
            default:
                entry.insertionPosition = .afterSystem
            }
        }

        // MARK: - V3 字段读取（透传，不影响运行时）
        // uid：ST 允许 Int 或 String，统一尝试两种类型后取 Int。
        if let uidInt = raw["uid"] as? NSNumber {
            entry.externalId = uidInt.intValue
        } else if let uidStr = raw["uid"] as? String, let parsed = Int(uidStr) {
            entry.externalId = parsed
        }
        entry.groupKey = raw["group"] as? String
        entry.groupWeight = (raw["group_weight"] as? NSNumber)?.doubleValue
        entry.weight = (raw["weight"] as? NSNumber)?.doubleValue
        entry.decay = (raw["decay"] as? NSNumber)?.doubleValue
        entry.caseSensitive = raw["case_sensitive"] as? Bool
        entry.useGroupScoring = raw["useGroupScoring"] as? Bool
        entry.automationId = raw["automationId"] as? String
        entry.roleRaw = (raw["role"] as? NSNumber)?.intValue
        entry.vectorized = raw["vectorized"] as? Bool
        entry.sticky = (raw["sticky"] as? NSNumber)?.intValue
        entry.cooldown = (raw["cooldown"] as? NSNumber)?.intValue
        entry.delay = (raw["delay"] as? NSNumber)?.intValue
        entry.displayIndex = (raw["displayIndex"] as? NSNumber)?.intValue
        if let triggers = raw["triggers"] as? [String] { entry.triggers = triggers }
        entry.outletName = raw["outletName"] as? String
        if let excludes = raw["excludes"] as? [String] { entry.excludes = excludes }
        entry.selectiveLogicRaw = (raw["selectiveLogic"] as? NSNumber)?.intValue
        // per-entry extensions → JSONValue 透传；非 dict 也照样收（与 characterBookRaw 行为对齐）
        if let ext = raw["extensions"] { entry.extensionsRaw = JSONValue.from(any: ext) }

        return entry
    }

    private static func splitKeywords(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，")
            .union(.whitespacesAndNewlines))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.books),
              let decoded = try? JSONDecoder().decode([WorldBook].self, from: data) else {
            return
        }
        books = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(books) {
            UserDefaults.standard.set(data, forKey: StorageKeys.books)
        }
    }

    private func migrateLegacyEntries() -> WorldBook {
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.legacyEntries),
              let decoded = try? JSONDecoder().decode([WorldBookEntry].self, from: data),
              !decoded.isEmpty else {
            return WorldBook(title: "全局世界书")
        }
        UserDefaults.standard.removeObject(forKey: StorageKeys.legacyEntries)
        return WorldBook(title: "全局世界书", entries: decoded)
    }
}

private enum StorageKeys {
    static let books = "worldBookList"
    static let legacyEntries = "worldBookEntries"
}

enum WorldBookImportMode {
    case merge
    case overwrite
}

struct WorldBookImportResult {
    var books: Int
    var entries: Int
    /// 当次导入新增/合并后的第一本书的 ID（用于「导入后绑定到角色」流）。
    var firstBookID: UUID?
}

struct WorldBookImportContent {
    var books: [WorldBook] = []
    var entries: [WorldBookEntry] = []
    var suggestedTitle: String?
    var isSillyTavern: Bool { !entries.isEmpty }
}

enum WorldBookImportError: LocalizedError {
    case invalidData
    case noBooks
    case noEntries

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "不是 Pyramid 或 SillyTavern（酒馆）世界书格式"
        case .noBooks:
            return "文件中没有可导入的世界书"
        case .noEntries:
            return "文件中没有可导入的条目"
        }
    }
}
