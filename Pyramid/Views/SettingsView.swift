import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var store: ChatStore
    @ObservedObject var presets: PresetStore
    @ObservedObject var characters: CharacterStore
    @State private var showClearSessionsDialog = false
    @State private var showResetWorldBookDialog = false
    @State private var isLoadingModels = false
    @State private var showModelPicker = false
    @State private var showUserAvatarPicker = false
    @State private var fetchedModels: [String] = []
    @State private var modelError: String?

    @State private var backupURL: URL?
    @State private var backupError: String?
    @State private var backupSuccess: String?
    @State private var showBackupPicker = false
    @State private var pendingBackup: PyramidBackup?
    @State private var showBackupMergeConfirm = false
    @State private var showBackupOverwriteConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("用户") {
                    HStack(spacing: 16) {
                        Button {
                            showUserAvatarPicker = true
                        } label: {
                            AvatarView(
                                imageData: userAvatarBinding.wrappedValue,
                                name: settings.userName.isEmpty ? "我" : settings.userName,
                                size: 72
                            )
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("昵称", text: $settings.userName)
                                .textContentType(.nickname)
                            Text("点按头像可更换，将显示在聊天页你的消息旁。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    TextField("对 AI 看到的用户名（留空 = 用昵称）", text: $settings.userDisplayName)
                        .textContentType(.nickname)
                    TextField("用户人设（多行正文，可描述背景、性格、说话风格）", text: $settings.userPersona, axis: .vertical)
                        .lineLimit(3...10)
                    Toggle("将用户人设注入对话", isOn: $settings.userPersonaInjected)
                    Text("作为默认用户，对新会话生效。会话详情可覆盖本会话的用户名。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .sheet(isPresented: $showUserAvatarPicker) {
                    AvatarPickerSheet(data: userAvatarBinding)
                }
                Section("角色卡") {
                    NavigationLink("管理角色卡") {
                        CharacterListView(store: characters, worldBook: worldBook)
                    }
                }
                Section("API 配置") {
                    TextField("API Base URL", text: $settings.baseURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("API Key", text: $settings.apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
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
                Section("世界书") {
                    Toggle("启用世界书", isOn: $settings.worldBookEnabled)
                    Toggle("显示注入提示（调试）", isOn: $settings.showInjectionIndicator)
                    NavigationLink("管理世界书条目") {
                        WorldBookView(store: worldBook, settings: settings, characters: characters)
                    }
                }
                Section("预设") {
                    NavigationLink("预设管理") {
                        PresetListView(store: presets, worldBook: worldBook)
                    }
                }
                Section("上下文") {
                    Toggle("显示上下文长度提示", isOn: $settings.showContextHint)
                    Stepper(
                        "警告阈值：\(settings.contextLimit.formatted()) 字符",
                        value: $settings.contextLimit,
                        in: 2000...50000,
                        step: 1000
                    )
                    Text("按字符数粗略估算会话长度与即将注入的世界书内容，超过阈值时提示。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("裁剪策略", selection: contextTrimModeBinding) {
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
                    Text("「不裁剪」发送全量历史；「按消息 / 字符」仅发送最近 N 条 / C 字符。当前用户消息始终保留。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("界面") {
                    Toggle("显示头像", isOn: $settings.showAvatars)
                    Toggle("紧凑模式", isOn: $settings.compactMode)
                    Toggle("显示消息时间戳", isOn: $settings.showTimestamps)
                }
                Section("数据管理") {
                    Button("清空全部会话", role: .destructive) {
                        showClearSessionsDialog = true
                    }
                    Button("重置世界书", role: .destructive) {
                        showResetWorldBookDialog = true
                    }
                }
                Section("备份") {
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
                    Text("导出包含会话、角色、世界书、预设；导入需选择合并或覆盖。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("说明") {
                    Text("Base URL 可带或不带 /v1，应用会自动拼接 chat/completions。所有设置只保存在本机（UserDefaults）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showModelPicker) {
                modelPickerSheet
            }
            .alert("获取模型失败", isPresented: modelErrorBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(modelError ?? "")
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
            .sheet(isPresented: $showBackupPicker) {
                DocumentPicker(
                    allowedTypes: [UTType.json, .data, .item],
                    allowsMultipleSelection: false,
                    onPicked: { urls in handleBackupPicked(urls: urls) },
                    onCancel: {}
                )
            }
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
    }

    private var modelPickerSheet: some View {
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

    private var userAvatarBinding: Binding<Data?> {
        Binding(
            get: { settings.userAvatarData.isEmpty ? nil : settings.userAvatarData },
            set: { settings.userAvatarData = $0 ?? Data() }
        )
    }

    private var contextTrimModeBinding: Binding<ContextTrimMode> {
        Binding(
            get: { settings.contextTrimMode },
            set: { settings.contextTrimMode = $0 }
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

    // MARK: - 备份

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
}

#Preview {
    SettingsView(
        settings: AppSettings(),
        worldBook: WorldBookStore(),
        store: ChatStore(),
        presets: PresetStore(),
        characters: CharacterStore()
    )
}
