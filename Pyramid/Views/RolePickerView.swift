import SwiftUI

struct RolePickerView: View {
    let characters: [Character]
    var onSelect: (Character) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if characters.isEmpty {
                    Text("还没有角色卡，请在「设置 → 角色卡」中新建或导入。")
                        .foregroundStyle(.secondary)
                }
                ForEach(characters) { character in
                    Button {
                        dismiss()
                        onSelect(character)
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(imageData: character.avatarData, name: character.name, size: 32)
                            Text(character.name.isEmpty ? "未命名" : character.name)
                                .foregroundStyle(.primary)
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
