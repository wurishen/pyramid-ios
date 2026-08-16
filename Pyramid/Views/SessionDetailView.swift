import SwiftUI

struct SessionDetailView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var presets: PresetStore
    @ObservedObject var characters: CharacterStore
    let sessionID: UUID

    private var session: ChatSession? {
        store.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        Form {
            Section("角色卡") {
                Picker("绑定角色", selection: characterBinding) {
                    Text("无").tag(Optional<UUID>.none)
                    ForEach(characters.characters) { char in
                        HStack {
                            AvatarView(imageData: char.avatarData, name: char.name, size: 24)
                            Text(char.name)
                        }
                        .tag(Optional(char.id))
                    }
                }
                if let char = characters.character(for: session?.characterId) {
                    Text("角色系统提示词将合并到对话请求中。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("预设") {
                Picker("应用预设", selection: appliedPresetBinding) {
                    Text("无").tag(Optional<UUID>.none)
                    ForEach(presets.presets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                Text("应用后会把预设的模型名、系统提示词和世界书绑定写入当前会话，立即生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("世界书绑定") {
                Picker("绑定世界书", selection: worldBookBinding) {
                    Text("不绑定（使用全局）").tag(Optional<UUID>.none)
                    ForEach(worldBook.books) { book in
                        Text(book.title).tag(Optional(book.id))
                    }
                }
                Text("绑定的会话只使用该书做关键词匹配注入；未绑定时回退到全局世界书。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("系统提示词") {
                TextEditor(text: systemPromptBinding)
                    .frame(minHeight: 100)
                Text("留空则使用全局系统提示词。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("会话信息") {
                LabeledContent("创建时间", value: session?.createdAt.formatted(date: .abbreviated, time: .shortened) ?? "—")
                LabeledContent("消息数", value: "\(session?.messages.count ?? 0)")
            }
        }
        .navigationTitle(session?.title ?? "会话详情")
    }

    private var characterBinding: Binding<UUID?> {
        Binding(
            get: { store.sessions.first { $0.id == sessionID }?.characterId },
            set: { store.setCharacter($0, for: sessionID) }
        )
    }

    private var worldBookBinding: Binding<UUID?> {
        Binding(
            get: { store.sessions.first { $0.id == sessionID }?.worldBookId },
            set: { store.setWorldBook($0, for: sessionID) }
        )
    }

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { store.sessions.first { $0.id == sessionID }?.systemPrompt ?? "" },
            set: { store.setSystemPrompt($0, for: sessionID) }
        )
    }

    private var appliedPresetBinding: Binding<UUID?> {
        Binding(
            get: { store.sessions.first { $0.id == sessionID }?.appliedPresetId },
            set: { newValue in
                store.setAppliedPreset(newValue, for: sessionID)
                if let presetID = newValue,
                   let preset = presets.presets.first(where: { $0.id == presetID }) {
                    apply(preset)
                }
            }
        )
    }

    private func apply(_ preset: Preset) {
        store.setSystemPrompt(preset.systemPrompt, for: sessionID)
        store.setWorldBook(preset.worldBookId, for: sessionID)
        if let model = preset.modelName, !model.isEmpty {
            settings.modelName = model
        }
    }
}

#Preview {
    NavigationStack {
        SessionDetailView(
            store: ChatStore(),
            worldBook: WorldBookStore(),
            settings: AppSettings(),
            presets: PresetStore(),
            characters: CharacterStore(),
            sessionID: UUID()
        )
    }
}
