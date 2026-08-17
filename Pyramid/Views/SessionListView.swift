import SwiftUI

struct SessionListView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var presets: PresetStore
    @ObservedObject var characters: CharacterStore
    @Environment(\.dismiss) private var dismiss
    @State private var detailSession: ChatSession?
    @State private var renameTarget: ChatSession?
    @State private var renameText = ""
    @State private var deleteTarget: ChatSession?
    @State private var showNewSessionWithCharacter = false

    private var orderedSessions: [ChatSession] { store.orderedSessions() }
    private var pinned: [ChatSession] { orderedSessions.filter(\.isPinned) }
    private var others: [ChatSession] { orderedSessions.filter { !$0.isPinned } }

    var body: some View {
        NavigationStack {
            sessionList
                .navigationTitle("会话")
                .toolbar { sessionListToolbar }
                .sheet(item: $detailSession) { session in detailSheet(session) }
                .alert("重命名会话", isPresented: renameDialogBinding) {
                    TextField("标题", text: $renameText)
                    Button("保存") { commitRename() }
                    Button("取消", role: .cancel) { renameTarget = nil }
                } message: {
                    Text("留空则恢复为「新会话」。")
                }
                .confirmationDialog(
                    "删除会话？",
                    isPresented: deleteDialogBinding,
                    titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) { commitDelete() }
                    Button("取消", role: .cancel) { deleteTarget = nil }
                } message: {
                    deleteDialogMessage
                }
                .sheet(isPresented: $showNewSessionWithCharacter) {
                    NewSessionWithCharacterSheet(
                        characters: characters.characters,
                        store: store,
                        onPicked: { character in
                            store.createSession(character: character)
                            dismiss()
                        }
                    )
                }
        }
    }

    private var sessionList: some View {
        List {
            if !pinned.isEmpty {
                pinnedSection
            }
            othersSection
        }
    }

    private var pinnedSection: some View {
        Section("置顶") {
            ForEach(pinned) { session in
                sessionRow(session)
                    .listRowBackground(rowBackground(for: session))
            }
            .onDelete { indexSet in delete(at: indexSet, from: pinned) }
        }
    }

    private var othersSection: some View {
        let title = pinned.isEmpty ? "全部会话" : "其它"
        return Section {
            ForEach(others) { session in
                sessionRow(session)
                    .listRowBackground(rowBackground(for: session))
            }
            .onDelete { indexSet in delete(at: indexSet, from: others) }
        } header: {
            Text(title)
        } footer: {
            Text("左滑可重命名 / 置顶 / 删除；点行进入会话，点「详情」编辑绑定。")
        }
    }

    private func rowBackground(for session: ChatSession) -> Color? {
        session.id == store.currentSessionID ? Color.accentColor.opacity(0.12) : nil
    }

    @ToolbarContentBuilder
    private var sessionListToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Menu {
                Button {
                    store.createSession()
                    dismiss()
                } label: {
                    Label("新建空白会话", systemImage: "plus.bubble")
                }
                if !characters.characters.isEmpty {
                    Button {
                        showNewSessionWithCharacter = true
                    } label: {
                        Label("新建并绑定角色", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            } label: {
                Label("新建", systemImage: "plus")
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button("完成") { dismiss() }
        }
    }

    private func detailSheet(_ session: ChatSession) -> some View {
        NavigationStack {
            SessionDetailView(
                store: store,
                worldBook: worldBook,
                settings: settings,
                presets: presets,
                characters: characters,
                sessionID: session.id
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { detailSession = nil }
                }
            }
        }
    }

    private func commitRename() {
        if let target = renameTarget {
            store.rename(target.id, to: renameText)
        }
        renameTarget = nil
    }

    private func commitDelete() {
        if let target = deleteTarget { store.delete(target.id) }
        deleteTarget = nil
    }

    @ViewBuilder
    private var deleteDialogMessage: some View {
        if let target = deleteTarget {
            Text("「\(target.title)」及其全部消息将被删除，此操作不可恢复。")
        } else {
            Text("该会话及其全部消息将被删除，此操作不可恢复。")
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: ChatSession) -> some View {
        Button {
            store.select(session.id)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                let char = characters.character(for: session.characterId)
                AvatarView(
                    imageData: char?.avatarData,
                    name: char?.name ?? session.title,
                    size: 40
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displayTitle(session, character: char))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if session.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                        if let char, !char.name.isEmpty {
                            Text(char.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 4) {
                        if let lastMsg = session.messages.last {
                            Text(lastMsg.content.replacingOccurrences(of: "\n", with: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("尚无消息")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(session.lastActivity.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if session.id == store.currentSessionID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                store.togglePinned(session.id)
            } label: {
                Label(session.isPinned ? "取消置顶" : "置顶", systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button {
                renameTarget = session
                renameText = session.title
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(.blue)
            Button(role: .destructive) {
                deleteTarget = session
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                detailSession = session
            } label: {
                Label("详情", systemImage: "gearshape")
            }
            .tint(.indigo)
        }
        .contextMenu {
            Button {
                renameTarget = session
                renameText = session.title
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button {
                store.togglePinned(session.id)
            } label: {
                Label(session.isPinned ? "取消置顶" : "置顶", systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            Button {
                detailSession = session
            } label: {
                Label("详情", systemImage: "gearshape")
            }
            Button(role: .destructive) {
                deleteTarget = session
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var renameDialogBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }
    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private func displayTitle(_ session: ChatSession, character: Character?) -> String {
        let trimmed = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != "新会话" { return trimmed }
        if let name = character?.name, !name.isEmpty { return name }
        return "新会话"
    }

    private func delete(at offsets: IndexSet, from list: [ChatSession]) {
        for index in offsets {
            store.delete(list[index].id)
        }
    }
}

private extension ChatSession {
    /// 用于会话列表预览的时间戳：取最后一条消息时间，否则会话创建时间。
    var lastActivity: Date {
        if let last = messages.last?.createdAt { return last }
        return createdAt
    }
}

/// 选择角色新建会话。点选直接创建并绑定。
struct NewSessionWithCharacterSheet: View {
    let characters: [Character]
    @ObservedObject var store: ChatStore
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

#Preview {
    SessionListView(
        store: ChatStore(),
        worldBook: WorldBookStore(),
        settings: AppSettings(),
        presets: PresetStore(),
        characters: CharacterStore()
    )
}
