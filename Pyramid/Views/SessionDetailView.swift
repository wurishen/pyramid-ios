import SwiftUI

struct SessionDetailView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var presets: PresetStore
    @ObservedObject var characters: CharacterStore
    let sessionID: UUID

    private var session: ChatSession? {
        // Item 8 M6：走 ChatStore.session(for:) 的 O(1) 查找，避免每次 binding getter 都线性扫。
        store.session(for: sessionID)
    }

    var body: some View {
        Form {
            Section("角色卡") {
                // 1:N 重构：角色在创建窗时绑定，会话期间锁死、不允许改绑。
                LabeledContent("绑定角色") {
                    HStack(spacing: 8) {
                        AvatarView(
                            imageData: characters.character(for: session?.characterId)?.avatarData,
                            name: characters.character(for: session?.characterId)?.name ?? "无",
                            size: 24
                        )
                        Text(characters.character(for: session?.characterId)?.name ?? "无")
                    }
                }
                if characters.character(for: session?.characterId) != nil {
                    Text("角色在创建会话时绑定，期间不可修改。需要换角色请新建会话。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("用户") {
                TextField("本会话对 AI 显示的用户名（留空 = 用全局）", text: userDisplayNameBinding)
                Text("不修改你的实际昵称，只影响与 AI 的对话显示。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                DisclosureGroup("会话额外启用 (\(extraWorldBookIdsBinding.wrappedValue.count))") {
                    ForEach(worldBook.books) { book in
                        Toggle(book.title, isOn: extraWorldBookBinding(for: book.id))
                    }
                    Text("会话额外启用的世界书与「全局启用 + 角色绑定」并集，共同决定本会话的注入源。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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

    private var worldBookBinding: Binding<UUID?> {
        Binding(
            get: { store.session(for: sessionID)?.worldBookId },
            set: { store.setWorldBook($0, for: sessionID) }
        )
    }

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { store.session(for: sessionID)?.systemPrompt ?? "" },
            set: { store.setSystemPrompt($0, for: sessionID) }
        )
    }

    private var appliedPresetBinding: Binding<UUID?> {
        Binding(
            get: { store.session(for: sessionID)?.appliedPresetId },
            set: { newValue in
                store.setAppliedPreset(newValue, for: sessionID)
                if let presetID = newValue,
                   let preset = presets.presets.first(where: { $0.id == presetID }) {
                    apply(preset)
                }
            }
        )
    }

    private var userDisplayNameBinding: Binding<String> {
        Binding(
            get: { store.session(for: sessionID)?.userDisplayNameOverride ?? "" },
            set: { store.setUserDisplayNameOverride($0, for: sessionID) }
        )
    }

    private var extraWorldBookIdsBinding: Binding<[UUID]> {
        Binding(
            get: { store.session(for: sessionID)?.extraWorldBookIds ?? [] },
            set: { store.setExtraWorldBookIds($0, for: sessionID) }
        )
    }

    private func extraWorldBookBinding(for bookID: UUID) -> Binding<Bool> {
        Binding(
            get: { extraWorldBookIdsBinding.wrappedValue.contains(bookID) },
            set: { isOn in
                var current = extraWorldBookIdsBinding.wrappedValue
                if isOn {
                    if !current.contains(bookID) { current.append(bookID) }
                } else {
                    current.removeAll { $0 == bookID }
                }
                extraWorldBookIdsBinding.wrappedValue = current
            }
        )
    }

    private func apply(_ preset: Preset) {
        // Item 9 H7：把预设里的多个会话级改动（system prompt / 绑定的世界书）
        // 合并到一次 mutate + 一次 save，不再每个 setter 各排一次 250ms 去抖。
        // settings.modelName 是 AppStorage，独立于本类 save，自己合并。
        store.mutateSession(sessionID) { session in
            session.systemPrompt = preset.systemPrompt
            session.worldBookId = preset.worldBookId
        }
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
