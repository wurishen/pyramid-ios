import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var content: String

    init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    enum Role: String {
        case user
        case assistant
    }
}
