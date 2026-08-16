import Foundation

enum WorldBookMatchMode: String, Codable, CaseIterable {
    case contains
    case exact
}

enum WorldBookInsertionPosition: String, Codable, CaseIterable {
    case beforeSystem
    case afterSystem
    case afterHistory
}

struct WorldBookEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var content: String
    var keywords: [String]
    var secondaryKeywords: [String]
    var scanDepth: Int?
    var probability: Int
    var insertionPosition: WorldBookInsertionPosition
    var isEnabled: Bool
    var isConstant: Bool
    var priority: Int
    var matchMode: WorldBookMatchMode

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        keywords: [String] = [],
        secondaryKeywords: [String] = [],
        scanDepth: Int? = nil,
        probability: Int = 100,
        insertionPosition: WorldBookInsertionPosition = .afterSystem,
        isEnabled: Bool = true,
        isConstant: Bool = false,
        priority: Int = 0,
        matchMode: WorldBookMatchMode = .contains
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.keywords = keywords
        self.secondaryKeywords = secondaryKeywords
        self.scanDepth = scanDepth
        self.probability = probability
        self.insertionPosition = insertionPosition
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
        secondaryKeywords = (try? c.decode([String].self, forKey: .secondaryKeywords)) ?? []
        scanDepth = try? c.decodeIfPresent(Int.self, forKey: .scanDepth)
        probability = (try? c.decode(Int.self, forKey: .probability)) ?? 100
        insertionPosition = (try? c.decode(WorldBookInsertionPosition.self, forKey: .insertionPosition)) ?? .afterSystem
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        isConstant = try c.decode(Bool.self, forKey: .isConstant)
        priority = try c.decode(Int.self, forKey: .priority)
        matchMode = (try? c.decode(WorldBookMatchMode.self, forKey: .matchMode)) ?? .contains
    }
}
