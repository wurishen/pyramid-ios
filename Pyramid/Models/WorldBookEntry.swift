import Foundation

struct WorldBookEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var content: String
    var keywords: [String]
    var isEnabled: Bool
    var isConstant: Bool
    var priority: Int

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        keywords: [String] = [],
        isEnabled: Bool = true,
        isConstant: Bool = false,
        priority: Int = 0
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.isConstant = isConstant
        self.priority = priority
    }
}
