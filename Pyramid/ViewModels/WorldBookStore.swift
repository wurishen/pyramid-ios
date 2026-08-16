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
