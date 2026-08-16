import Foundation

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: Role
    var content: String
    var createdAt: Date?

    init(id: UUID = UUID(), role: Role, content: String, createdAt: Date? = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }

    enum Role: String, Codable {
        case user
        case assistant
    }
}
