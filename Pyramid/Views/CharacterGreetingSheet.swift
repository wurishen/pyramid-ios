import SwiftUI

/// 新建会话时，让用户选「使用哪个开场白」的小弹窗。
/// 选完调用 onPick(Character, String)；选「不填开场白」则 onPick(Character, nil)。
struct CharacterGreetingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let character: Character
    /// 用户选定开场白后回调：第二个参数 nil 表示「不填开场白」。
    var onPick: (Character, String?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("「\(character.name.isEmpty ? "未命名" : character.name)」有多个开场白，新建会话时选择一条作为首条助手消息，或选择「不填开场白」建立空白会话。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("开场白") {
                    ForEach(Array(character.availableGreetings.enumerated()), id: \.offset) { index, text in
                        Button {
                            onPick(character, text)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(label(for: index))
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Text(text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    Button {
                        onPick(character, nil)
                        dismiss()
                    } label: {
                        Label("不填开场白（空白会话）", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            .navigationTitle("选择开场白")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func label(for index: Int) -> String {
        index == 0 ? "默认开场白" : "备用开场白 \(index)"
    }
}