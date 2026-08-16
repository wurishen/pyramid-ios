import Foundation

struct WorldBook: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var entries: [WorldBookEntry]

    init(id: UUID = UUID(), title: String, entries: [WorldBookEntry] = []) {
        self.id = id
        self.title = title
        self.entries = entries
    }
}

struct WorldBookExport: Codable {
    var version: Int
    var books: [WorldBook]

    init(version: Int = 1, books: [WorldBook]) {
        self.version = version
        self.books = books
    }
}
