import SwiftUI

struct NewSessionWithCharacterSheet: View {
    let characters: [Character]
    var onPicked: (Character) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if characters.isEmpty {
                    Text("还没有角色卡，请先到「设置 → 角色卡」新建或导入。")
                        .foregroundStyle(.secondary)
                }
                ForEach(characters) { character in
                    Button {
                        dismiss()
                        onPicked(character)
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(imageData: character.avatarData, name: character.name, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(character.name.isEmpty ? "未命名" : character.name)
                                if !character.description.isEmpty {
                                    Text(character.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .navigationTitle("选择角色卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
