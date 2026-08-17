import SwiftUI
import UniformTypeIdentifiers

struct CharacterListView: View {
    @ObservedObject var store: CharacterStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var chatStore: ChatStore
    /// 点选角色卡后由父层回调：通常用于切到聊天 Tab 并关闭当前 sheet。
    var onStartChat: () -> Void = {}
    @State private var editingCharacter: Character?
    @State private var showDocumentPicker = false
    @State private var importError: String?
    @State private var importSuccess: String?

    var body: some View {
        List {
            if store.characters.isEmpty {
                Text("还没有角色卡，点右上角 + 新建或导入。点角色卡即可开聊。")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.characters) { character in
                Button {
                    startChat(with: character)
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
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contextMenu {
                    Button {
                        startChat(with: character)
                    } label: {
                        Label("开新聊天窗", systemImage: "bubble.left.and.bubble.right")
                    }
                    Button {
                        editingCharacter = character
                    } label: {
                        Label("编辑", systemImage: "pencil")
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
            store.delete(id)
        }
    }

    private func handleImport(_ urls: [URL]) {
        DispatchQueue.main.async { [self] in
            guard !urls.isEmpty else {
                importError = "未选择任何文件"
                return
            }
            var total = 0
            for url in urls {
                do {
                    let data = try ImportSupport.readImportedData(from: url)
                    let characters = try ImportSupport.parseCharacters(from: data)
                    for character in characters {
                        store.upsert(character)
                        total += 1
                    }
                } catch {
                    importError = error.localizedDescription
                    return
                }
            }
            importSuccess = "已导入 \(total) 张角色卡"
        }
    }

    /// 点选角色卡：以该角色建一个新聊天窗并切到聊天 Tab。
    /// 同一角色可建多窗；窗建好后不可在聊天内切换角色。
    private func startChat(with character: Character) {
        chatStore.createSession(character: character)
        onStartChat()
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
        CharacterListView(store: CharacterStore(), worldBook: WorldBookStore())
    }
}
