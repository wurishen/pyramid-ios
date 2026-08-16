import Foundation

enum WorldBookMatchMode: String, Codable, CaseIterable {
    case contains
    case exact
}

struct WorldBookEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var content: String
    var keywords: [String]
    var isEnabled: Bool
    var isConstant: Bool
    var priority: Int
    var matchMode: WorldBookMatchMode

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        keywords: [String] = [],
        isEnabled: Bool = true,
        isConstant: Bool = false,
        priority: Int = 0,
        matchMode: WorldBookMatchMode = .contains
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.isConstant = isConstant
        self.priority = priority
        self.matchMode = matchMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        content = try c.decode(String.self, forKey: .content)
        keywords = try c.decode([String].self, forKey: .keywords)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        isConstant = try c.decode(Bool.self, forKey: .isConstant)
        priority = try c.decode(Int.self, forKey: .priority)
        matchMode = (try? c.decode(WorldBookMatchMode.self, forKey: .matchMode)) ?? .contains
    }
}
