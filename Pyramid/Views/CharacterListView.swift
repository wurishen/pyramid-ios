import SwiftUI
import UniformTypeIdentifiers

struct CharacterListView: View {
    @ObservedObject var store: CharacterStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var displayRegexes: DisplayRegexStore
    @State private var editingCharacter: Character?
    @State private var showDocumentPicker = false
    @State private var importError: String?
    @State private var importSuccess: String?

    var body: some View {
        List {
            if store.characters.isEmpty {
                Text("还没有角色卡，点右上角 + 新建或导入。")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.characters) { character in
                Button {
                    editingCharacter = character
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(imageData: character.avatarData, name: character.name, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(character.name.isEmpty ? "未命名" : character.name)
                                .foregroundStyle(.primary)
                            if !character.description.isEmpty {
                                Text(character.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .onDelete(perform: deleteCharacters)
        }
        .navigationTitle("角色卡")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showDocumentPicker = true
                    } label: {
                        Label("导入 JSON", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button {
                    editingCharacter = Character()
                } label: {
                    Label("新建", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(
                allowedTypes: [.json, .png, .data, .item],
                allowsMultipleSelection: true,
                onPicked: { urls in handleImport(urls) },
                onCancel: {}
            )
        }
        .alert("导入失败", isPresented: importErrorBinding) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("导入完成", isPresented: importSuccessBinding) {
            Button("好", role: .cancel) { importSuccess = nil }
        } message: {
            Text(importSuccess ?? "")
        }
        .sheet(item: $editingCharacter) { character in
            CharacterEditView(character: character, worldBook: worldBook) { updated in
                store.upsert(updated)
            }
        }
    }

    private func deleteCharacters(at offsets: IndexSet) {
        let ids = offsets.map { store.characters[$0].id }
        for id in ids {
            // Phase 2：先清掉该角色自动构建的 V3 内嵌世界书（若存在且非最后一本）。
            if let ch = store.character(for: id), let bookID = ch.embeddedWorldBookId {
                worldBook.deleteBook(bookID)
            }
            store.delete(id)
            // 同步清掉该角色内嵌 ST Regex Script 自动转出的 DisplayRegex。
            displayRegexes.removeCharacterScopedScripts(characterId: id)
        }
    }

    private func handleImport(_ urls: [URL]) {
        DispatchQueue.main.async { [self] in
            guard !urls.isEmpty else {
                importError = "未选择任何文件"
                return
            }
            var total = 0
            var totalScripts = 0
            for url in urls {
                do {
                    let data = try ImportSupport.readImportedData(from: url)
                    let characters = try ImportSupport.parseCharacters(from: data)
                    for var character in characters {
                        // Phase 2：V3 内嵌 `character_book` → 自动建世界书并绑定。
                        // 二次导入同一角色按 `externalId == uid` 合并，不重复创建。
                        if let id = worldBook.adoptEmbeddedWorldBook(for: character) {
                            character.embeddedWorldBookId = id
                        }
                        // 自动发现 `character.extensionsRegexScripts`（ST 角色卡内嵌的
                        // `data.extensions.regex_scripts`）→ 转成 DisplayRegex → 入库。
                        // **同一会话自动生效**：RenderEngine.Context.allDisplayRegexes 直接
                        // 来自 displayRegexes.regexes，无需重启 / 重发 / 写回 raw。
                        let scripts = scriptsFor(character)
                        store.upsert(character)
                        displayRegexes.replaceCharacterScopedScripts(
                            characterId: character.id,
                            scripts: scripts
                        )
                        totalScripts += scripts.count
                        total += 1
                    }
                } catch {
                    importError = error.localizedDescription
                    return
                }
            }
            if totalScripts > 0 {
                importSuccess = "已导入 \(total) 张角色卡（含 \(totalScripts) 条角色内嵌 Regex）"
            } else {
                importSuccess = "已导入 \(total) 张角色卡"
            }
        }
    }

    /// 把 Character.extensionsRegexScripts 经 SillyTavernScriptImporter 转成 DisplayRegex。
    /// 失败 / 空 → 返回空数组。给每条 DisplayRegex 标 sourceCharacterId = character.id
    /// 以便后续删除角色时同步清理。
    private func scriptsFor(_ character: Character) -> [DisplayRegex] {
        guard !character.extensionsRegexScripts.isEmpty else { return [] }
        let payloads = character.extensionsRegexScripts
        let converted: [DisplayRegex] = payloads.compactMap { script in
            SillyTavernScriptImporter.convert(script).map { display in
                // 保留 DisplayRegex 原 id（避免 UUID 漂移），仅追加 sourceCharacterId。
                DisplayRegex(
                    id: display.id,
                    name: display.name,
                    pattern: display.pattern,
                    replacement: display.replacement,
                    enabled: display.enabled,
                    scope: display.scope,
                    sourceCharacterId: character.id
                )
            }
        }
        return converted
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )
    }

    private var importSuccessBinding: Binding<Bool> {
        Binding(
            get: { importSuccess != nil },
            set: { if !$0 { importSuccess = nil } }
        )
    }
}

struct CharacterEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var worldBook: WorldBookStore
    private let character: Character
    private let onSave: (Character) -> Void

    @State private var name: String
    @State private var descriptionText: String
    @State private var personality: String
    @State private var scenario: String
    @State private var systemPrompt: String
    @State private var worldBookId: UUID?
    @State private var avatarData: Data?
    @State private var showAvatarPicker = false

    // SillyTavern 兼容字段（默认折叠，避免普通用户看到一屏技术字段）。
    @State private var firstMes: String
    @State private var alternateGreetingsText: String
    @State private var mesExample: String
    @State private var creatorNotes: String
    @State private var postHistoryInstructions: String
    @State private var tagsText: String
    @State private var creator: String
    @State private var characterVersion: String
    @State private var showSillyTavernFields = false

    init(character: Character, worldBook: WorldBookStore, onSave: @escaping (Character) -> Void) {
        self.character = character
        self.worldBook = worldBook
        self.onSave = onSave
        _name = State(initialValue: character.name)
        _descriptionText = State(initialValue: character.description)
        _personality = State(initialValue: character.personality)
        _scenario = State(initialValue: character.scenario)
        _systemPrompt = State(initialValue: character.systemPrompt)
        _worldBookId = State(initialValue: character.worldBookId)
        _avatarData = State(initialValue: character.avatarData)
        _firstMes = State(initialValue: character.firstMes)
        // 把数组转成「按行一条」的纯文本，方便用户直接编辑（也兼容酒馆 v1 字符串情况）。
        _alternateGreetingsText = State(initialValue: character.alternateGreetings.joined(separator: "\n"))
        _mesExample = State(initialValue: character.mesExample)
        _creatorNotes = State(initialValue: character.creatorNotes)
        _postHistoryInstructions = State(initialValue: character.postHistoryInstructions)
        _tagsText = State(initialValue: character.tags.joined(separator: ", "))
        _creator = State(initialValue: character.creator)
        _characterVersion = State(initialValue: character.characterVersion)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("头像") {
                    HStack {
                        Spacer()
                        AvatarView(imageData: avatarData, name: name, size: 80)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showAvatarPicker = true }
                }
                Section("基本信息") {
                    TextField("角色名称", text: $name)
                    TextField("描述（角色简介）", text: $descriptionText, axis: .vertical)
                        .lineLimit(2...6)
                    TextField("性格", text: $personality, axis: .vertical)
                        .lineLimit(2...6)
                    TextField("场景", text: $scenario, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section("系统提示词") {
                    TextField("角色系统提示词（可留空）", text: $systemPrompt, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("世界书绑定") {
                    Picker("绑定世界书", selection: $worldBookId) {
                        Text("不绑定").tag(Optional<UUID>.none)
                        ForEach(worldBook.books) { book in
                            Text(book.title).tag(Optional(book.id))
                        }
                    }
                }
                Section {
                    DisclosureGroup("SillyTavern 字段（高级）", isExpanded: $showSillyTavernFields) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("默认开场白（first_mes）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("默认开场白", text: $firstMes, axis: .vertical)
                                .lineLimit(2...8)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("备用开场白（alternate_greetings）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("每行一条。新建对话时如果存在任意开场白，会先让你选一条作为首条助手消息。")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            TextField("备用开场白（每行一条）", text: $alternateGreetingsText, axis: .vertical)
                                .lineLimit(2...8)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("对话示例（mes_example）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $mesExample)
                                .frame(minHeight: 90)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("创作者备注（creator_notes）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("创作者备注", text: $creatorNotes, axis: .vertical)
                                .lineLimit(2...6)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("历史后指令（post_history_instructions）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("历史后指令", text: $postHistoryInstructions, axis: .vertical)
                                .lineLimit(2...6)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("标签（tags）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("标签（用逗号分隔）", text: $tagsText)
                        }
                        TextField("创作者（creator）", text: $creator)
                        TextField("版本号（character_version）", text: $characterVersion)
                    }
                }
            }
            .navigationTitle(character.name.isEmpty ? "新建角色" : "编辑角色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = character
                        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.description = descriptionText
                        updated.personality = personality
                        updated.scenario = scenario
                        updated.systemPrompt = systemPrompt
                        updated.worldBookId = worldBookId
                        updated.avatarData = avatarData
                        updated.firstMes = firstMes
                        // 备用开场白按行切分，丢掉空行
                        updated.alternateGreetings = alternateGreetingsText
                            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        updated.mesExample = mesExample
                        updated.creatorNotes = creatorNotes
                        updated.postHistoryInstructions = postHistoryInstructions
                        updated.tags = tagsText
                            .split(whereSeparator: { $0 == "," || $0 == "，" })
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        updated.creator = creator
                        updated.characterVersion = characterVersion
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showAvatarPicker) {
                AvatarPickerSheet(data: $avatarData)
            }
        }
    }
}

struct AvatarPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var data: Data?
    @State private var sourceType: UIImagePickerController.SourceType = .photoLibrary
    @State private var showCamera = false
    @State private var showLibrary = false

    var body: some View {
        NavigationStack {
            List {
                Button {
                    sourceType = .camera
                    showCamera = true
                } label: {
                    Label("拍照", systemImage: "camera")
                }
                Button {
                    sourceType = .photoLibrary
                    showLibrary = true
                } label: {
                    Label("从相册选择", systemImage: "photo.on.rectangle")
                }
                if data != nil {
                    Button(role: .destructive) {
                        data = nil
                        dismiss()
                    } label: {
                        Label("移除头像", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("选择头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            ImagePicker(sourceType: .camera, data: $data)
        }
        .sheet(isPresented: $showLibrary) {
            ImagePicker(sourceType: .photoLibrary, data: $data)
        }
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    @Binding var data: Data?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage,
               let resized = image.resized(maxDimension: 512),
               let jpeg = resized.jpegData(compressionQuality: 0.8) {
                parent.data = jpeg
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage? {
        let size = self.size
        let ratio = min(maxDimension / size.width, maxDimension / size.height, 1)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

#Preview {
    NavigationStack {
        CharacterListView(store: CharacterStore(), worldBook: WorldBookStore(), displayRegexes: DisplayRegexStore())
    }
}
