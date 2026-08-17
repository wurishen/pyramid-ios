import SwiftUI
import UniformTypeIdentifiers

/// 设置根页：仅呈现分组列表行，每行 = 标题 + chevron；具体表单下推到子页。
/// 视觉与 iOS 系统「设置」一致：不要大标题占版，不要在根页展开。
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var store: ChatStore
    @ObservedObject var presets: PresetStore
    @ObservedObject var characters: CharacterStore
    @ObservedObject var displayRegexes: DisplayRegexStore
    /// 角色卡点选 → 新建窗回调。ContentView 注入。
    var onCharacterTapped: (Character) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        UserSettingsView(settings: settings)
                    } label: {
                        Label("用户", systemImage: "person.crop.circle")
                    }
                    NavigationLink {
                        CharacterListView(
                            store: characters,
                            worldBook: worldBook,
                            onCharacterTapped: onCharacterTapped
                        )
                    } label: {
                        Label("角色卡", systemImage: "person.crop.rectangle.stack")
                    }
                    NavigationLink {
                        APIConfigView(settings: settings)
                    } label: {
                        Label("API 配置", systemImage: "network")
                    }
                }

                Section {
                    NavigationLink {
                        WorldBookSettingsView(
                            worldBook: worldBook,
                            settings: settings,
                            characters: characters
                        )
                    } label: {
                        Label("世界书", systemImage: "book.closed")
                    }
                    NavigationLink {
                        PresetListView(
                            store: presets,
                            worldBook: worldBook,
                            displayRegexes: displayRegexes
                        )
                    } label: {
                        Label("预设", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        DisplaySettingsView(settings: settings, displayRegexes: displayRegexes)
                    } label: {
                        Label("渲染", systemImage: "text.alignleft")
                    }
                }

                Section {
                    NavigationLink {
                        ContextSettingsView(settings: settings)
                    } label: {
                        Label("上下文", systemImage: "arrow.up.arrow.down.circle")
                    }
                    NavigationLink {
                        InterfaceSettingsView(settings: settings)
                    } label: {
                        Label("界面", systemImage: "rectangle.3.group")
                    }
                    NavigationLink {
                        DataManagementView(
                            settings: settings,
                            store: store,
                            characters: characters,
                            worldBook: worldBook,
                            presets: presets
                        )
                    } label: {
                        Label("数据", systemImage: "externaldrive")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于", systemImage: "info.circle")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - 用户

struct UserSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showAvatarPicker = false

    private var avatarBinding: Binding<Data?> {
        Binding(
            get: { settings.userAvatarData.isEmpty ? nil : settings.userAvatarData },
            set: { settings.userAvatarData = $0 ?? Data() }
        )
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Button {
                        showAvatarPicker = true
                    } label: {
                        AvatarView(
                            imageData: avatarBinding.wrappedValue,
                            name: settings.userName.isEmpty ? "我" : settings.userName,
                            size: 64
                        )
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.userName.isEmpty ? "未设置昵称" : settings.userName)
                            .font(.headline)
                        Text("点按头像可更换")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("基本信息") {
                TextField("昵称", text: $settings.userName)
                    .textContentType(.nickname)
                TextField("对 AI 看到的用户名（留空 = 用昵称）", text: $settings.userDisplayName)
                    .textContentType(.nickname)
            }
            Section {
                TextField("用户人设（多行正文，可描述背景、性格、说话风格）", text: $settings.userPersona, axis: .vertical)
                    .lineLimit(3...10)
                Toggle("将用户人设注入对话", isOn: $settings.userPersonaInjected)
            } header: {
                Text("人设")
            } footer: {
                Text("作为默认用户，对新会话生效。会话详情可覆盖本会话的用户名。")
            }
        }
        .navigationTitle("用户")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAvatarPicker) {
            AvatarPickerSheet(data: avatarBinding)
        }
    }
}

// MARK: - API 配置

struct APIConfigView: View {
    @ObservedObject var settings: AppSettings
    @State private var showModelPicker = false
    @State private var fetchedModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelError: String?

    var body: some View {
        Form {
            Section("Endpoint") {
                TextField("API Base URL", text: $settings.baseURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("API Key", text: $settings.apiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section("模型") {
                TextField("模型名", text: $settings.modelName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    Task { await loadModels() }
                } label: {
                    if isLoadingModels {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在获取模型列表…")
                        }
                    } else {
                        Label("拉取可用模型", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(
                    isLoadingModels
                        || settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            Section("系统提示词") {
                TextField("系统提示词（可留空）", text: $settings.systemPrompt, axis: .vertical)
                    .lineLimit(3...8)
            }
            Section("对话") {
                Toggle("流式输出（默认开启）", isOn: $settings.useStreaming)
            }
        }
        .navigationTitle("API 配置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showModelPicker, content: modelPickerSheet)
        .alert("获取模型失败", isPresented: modelErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(modelError ?? "")
        }
    }

    private func modelPickerSheet() -> some View {
        NavigationStack {
            List(fetchedModels, id: \.self) { model in
                Button {
                    settings.modelName = model
                    showModelPicker = false
                } label: {
                    HStack {
                        Text(model)
                        Spacer()
                        if model == settings.modelName {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("取消") { showModelPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var modelErrorBinding: Binding<Bool> {
        Binding(
            get: { modelError != nil },
            set: { if !$0 { modelError = nil } }
        )
    }

    private func loadModels() async {
        isLoadingModels = true
        modelError = nil
        defer { isLoadingModels = false }
        do {
            let models = try await OpenAIClient.fetchModels(
                baseURL: settings.baseURL,
                apiKey: settings.apiKey
            )
            guard !models.isEmpty else {
                modelError = "服务器返回了空的模型列表"
                return
            }
            let current = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            var list = models
            if !current.isEmpty && !list.contains(current) {
                list.insert(current, at: 0)
            }
            fetchedModels = list
            showModelPicker = true
        } catch {
            modelError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - 世界书

struct WorldBookSettingsView: View {
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var characters: CharacterStore

    var body: some View {
        Form {
            Section {
                Toggle("启用世界书", isOn: $settings.worldBookEnabled)
                Toggle("显示注入提示（调试）", isOn: $settings.showInjectionIndicator)
            }
            Section {
                NavigationLink("管理世界书条目") {
                    WorldBookView(store: worldBook, settings: settings, characters: characters)
                }
            }
        }
        .navigationTitle("世界书")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 渲染

struct DisplaySettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var displayRegexes: DisplayRegexStore

    var body: some View {
        Form {
            Section {
                Toggle("启用 Markdown 渲染", isOn: $settings.enableMarkdown)
            } footer: {
                Text("作用于助手与用户气泡；不修改消息原文。无 WebView，未识别的 HTML 标签会被降级为纯文本。")
            }
            Section {
                Toggle("剥离隐藏标签", isOn: $settings.hideTagStripEnabled)
                TextField("隐藏标签列表（逗号或换行分隔）", text: $settings.hideTagsRaw, axis: .vertical)
                    .lineLimit(2...6)
            } header: {
                Text("隐藏标签")
            } footer: {
                Text("默认包含 think、thinking。剥离形如 <tag>...</tag> 的整段，失败则保留原文。")
            }
            Section {
                NavigationLink("显示用正则") {
                    DisplayRegexListView(store: displayRegexes)
                }
            } footer: {
                Text("仅作用于助手消息的「渲染前」管道。")
            }
            Section {
                Text("上述所有规则仅作用于气泡显示；复制 / 编辑 / 重新生成 / 发送 API 始终使用原始消息。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("渲染")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 上下文

struct ContextSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("显示上下文长度提示", isOn: $settings.showContextHint)
                Stepper(
                    "警告阈值：\(settings.contextLimit.formatted()) 字符",
                    value: $settings.contextLimit,
                    in: 2000...50000,
                    step: 1000
                )
            } footer: {
                Text("按字符数粗略估算会话长度与即将注入的世界书内容，超过阈值时提示。")
            }
            Section {
                Picker("裁剪策略", selection: $settings.contextTrimMode) {
                    ForEach(ContextTrimMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if settings.contextTrimMode == .byMessages {
                    Stepper(
                        "保留最近 \(settings.contextTrimMessages) 条消息",
                        value: $settings.contextTrimMessages,
                        in: 2...500,
                        step: 5
                    )
                } else if settings.contextTrimMode == .byCharacters {
                    Stepper(
                        "保留最近 \(settings.contextTrimCharacters.formatted()) 字符",
                        value: $settings.contextTrimCharacters,
                        in: 500...80000,
                        step: 500
                    )
                }
            } header: {
                Text("裁剪")
            } footer: {
                Text("「不裁剪」发送全量历史；「按消息 / 字符」仅发送最近 N 条 / C 字符。当前用户消息始终保留。")
            }
        }
        .navigationTitle("上下文")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 界面

struct InterfaceSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("显示头像", isOn: $settings.showAvatars)
                Toggle("显示消息时间戳", isOn: $settings.showTimestamps)
                Toggle("紧凑模式", isOn: $settings.compactMode)
            }
        }
        .navigationTitle("界面")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 数据

struct DataManagementView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ChatStore
    @ObservedObject var characters: CharacterStore
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var presets: PresetStore

    @State private var showClearSessionsDialog = false
    @State private var showResetWorldBookDialog = false
    @State private var backupURL: URL?
    @State private var backupError: String?
    @State private var backupSuccess: String?
    @State private var showBackupPicker = false
    @State private var pendingBackup: PyramidBackup?
    @State private var showBackupMergeConfirm = false
    @State private var showBackupOverwriteConfirm = false

    var body: some View {
        Form {
            Section("会话与数据") {
                Button("清空全部会话", role: .destructive) {
                    showClearSessionsDialog = true
                }
                Button("重置世界书", role: .destructive) {
                    showResetWorldBookDialog = true
                }
            }
            Section {
                Button {
                    exportBackup()
                } label: {
                    Label("导出备份", systemImage: "square.and.arrow.up")
                }
                Button {
                    showBackupPicker = true
                } label: {
                    Label("导入备份", systemImage: "square.and.arrow.down")
                }
                if let url = backupURL {
                    ShareLink(item: url, preview: SharePreview("Pyramid 备份", image: Image(systemName: "doc"))) {
                        Label("分享最新备份", systemImage: "paperplane")
                    }
                }
            } header: {
                Text("备份")
            } footer: {
                Text("导出包含会话、角色、世界书、预设；导入需选择合并或覆盖。")
            }
        }
        .navigationTitle("数据")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBackupPicker, content: backupPickers)
        .alert("备份失败", isPresented: backupErrorBinding) {
            Button("好", role: .cancel) { backupError = nil }
        } message: {
            Text(backupError ?? "")
        }
        .alert("导入完成", isPresented: backupSuccessBinding) {
            Button("好", role: .cancel) { backupSuccess = nil }
        } message: {
            Text(backupSuccess ?? "")
        }
        .confirmationDialog(
            "清空全部会话？",
            isPresented: $showClearSessionsDialog,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                store.clearAllSessions()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除所有会话及其全部消息，此操作不可恢复。清空后将自动新建一个空会话。")
        }
        .confirmationDialog(
            "重置世界书？",
            isPresented: $showResetWorldBookDialog,
            titleVisibility: .visible
        ) {
            Button("重置", role: .destructive) {
                worldBook.resetBooks()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除所有世界书及其全部条目，并重建一本空的「全局世界书」，此操作不可恢复。")
        }
        .confirmationDialog(
            "如何导入备份？",
            isPresented: $showBackupMergeConfirm,
            titleVisibility: .visible
        ) {
            if let backup = pendingBackup {
                Button("合并到现有数据") {
                    BackupService.merge(
                        backup: backup,
                        store: store,
                        characters: characters,
                        worldBook: worldBook,
                        presets: presets,
                        settings: settings
                    )
                    backupSuccess = "已合并 \(backup.sessions.count) 个会话 / \(backup.characters.count) 个角色 / \(backup.worldBooks.count) 本世界书 / \(backup.presets.count) 个预设"
                    pendingBackup = nil
                }
                Button("覆盖现有数据", role: .destructive) {
                    showBackupMergeConfirm = false
                    showBackupOverwriteConfirm = true
                }
                Button("取消", role: .cancel) {
                    pendingBackup = nil
                }
            }
        } message: {
            Text("合并会按 id 去重，保留本机已有数据；覆盖会先清空所有本地数据再替换，不可恢复。")
        }
        .alert("确认覆盖全部数据？",
               isPresented: $showBackupOverwriteConfirm) {
            Button("覆盖", role: .destructive) {
                if let backup = pendingBackup {
                    BackupService.overwrite(
                        backup: backup,
                        store: store,
                        characters: characters,
                        worldBook: worldBook,
                        presets: presets,
                        settings: settings
                    )
                    backupSuccess = "已覆盖：\(backup.sessions.count) 个会话 / \(backup.characters.count) 个角色 / \(backup.worldBooks.count) 本世界书 / \(backup.presets.count) 个预设"
                }
                pendingBackup = nil
            }
            Button("取消", role: .cancel) {
                pendingBackup = nil
            }
        } message: {
            Text("覆盖会删除你所有本机会话、角色、世界书与预设，并替换为备份内容。此操作不可恢复。")
        }
    }

    private func backupPickers() -> some View {
        DocumentPicker(
            allowedTypes: [UTType.json, .data, .item],
            allowsMultipleSelection: false,
            onPicked: { urls in handleBackupPicked(urls: urls) },
            onCancel: {}
        )
    }

    private var backupErrorBinding: Binding<Bool> {
        Binding(
            get: { backupError != nil },
            set: { if !$0 { backupError = nil } }
        )
    }

    private var backupSuccessBinding: Binding<Bool> {
        Binding(
            get: { backupSuccess != nil },
            set: { if !$0 { backupSuccess = nil } }
        )
    }

    private func exportBackup() {
        do {
            let url = try BackupService.makeBackup(
                store: store,
                characters: characters,
                worldBook: worldBook,
                presets: presets,
                settings: settings
            )
            backupURL = url
            backupSuccess = "已导出：\(url.lastPathComponent)"
        } catch {
            backupError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func handleBackupPicked(urls: [URL]) {
        guard let url = urls.first else {
            backupError = "未选择任何文件"
            return
        }
        do {
            let backup = try BackupService.parseBackup(from: url)
            pendingBackup = backup
            showBackupMergeConfirm = true
        } catch {
            backupError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - 关于

struct AboutView: View {
    var body: some View {
        Form {
            Section {
                Text("Pyramid")
                    .font(.title3.bold())
                Text("本地优先的 AI 聊天客户端，支持任意 OpenAI 兼容后端。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Base URL 可带或不带 /v1，应用会自动拼接 chat/completions。所有设置只保存在本机（UserDefaults）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView(
        settings: AppSettings(),
        worldBook: WorldBookStore(),
        store: ChatStore(),
        presets: PresetStore(),
        characters: CharacterStore(),
        displayRegexes: DisplayRegexStore()
    )
}
