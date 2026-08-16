import Foundation
import SwiftUI

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

    @discardableResult
    func createBook() -> WorldBook {
        let book = WorldBook(title: "世界书 \(books.count + 1)")
        books.append(book)
        save()
        return book
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
            return WorldBookImportContent(books: export.books)
        }
        if let array = try? JSONDecoder().decode([WorldBook].self, from: data) {
            guard !array.isEmpty else { throw WorldBookImportError.noBooks }
            return WorldBookImportContent(books: array)
        }
        if let single = try? JSONDecoder().decode(WorldBook.self, from: data) {
            return WorldBookImportContent(books: [single])
        }
        if let st = try? Self.parseSillyTavernData(data) {
            return WorldBookImportContent(entries: st.entries, suggestedTitle: st.name)
        }
        throw WorldBookImportError.invalidData
    }

    func importBooks(_ decoded: [WorldBook], mode: WorldBookImportMode) {
        switch mode {
        case .overwrite:
            books = decoded
        case .merge:
            for book in decoded {
                if let bookIndex = books.firstIndex(where: { $0.id == book.id }) {
                    var merged = books[bookIndex]
                    for entry in book.entries where !merged.entries.contains(where: { $0.id == entry.id }) {
                        merged.entries.append(entry)
                    }
                    books[bookIndex] = merged
                } else {
                    books.append(book)
                }
            }
        }
        save()
    }

    @discardableResult
    func createBook(title: String, entries: [WorldBookEntry]) -> WorldBook {
        let book = WorldBook(title: title, entries: entries)
        books.append(book)
        save()
        return book
    }

    func mergeEntries(_ entries: [WorldBookEntry], into bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        var existingContents = Set(books[index].entries.map(\.content))
        for entry in entries where !existingContents.contains(entry.content) {
            books[index].entries.append(entry)
            existingContents.insert(entry.content)
        }
        save()
    }

    func overwriteEntries(_ entries: [WorldBookEntry], in bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].entries = entries
        save()
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
            entry.keywords = keyArray.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else if let keyString = keyField as? String {
            entry.keywords = keyString.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        entry.isConstant = (raw["constant"] as? Bool) ?? false
        entry.isEnabled = !((raw["disable"] as? Bool) ?? false)

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

        return entry
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.books),
              let decoded = try? JSONDecoder().decode([WorldBook].self, from: data) else {
            return
        }
        books = decoded
    }

    private func save() {
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
