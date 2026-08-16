import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var store: ChatStore
    @ObservedObject var presets: PresetStore
    @State private var showClearSessionsDialog = false
    @State private var showResetWorldBookDialog = false

    var body: some View {
        NavigationStack {
            Form {
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
                        WorldBookView(store: worldBook, settings: settings)
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
                }
                Section("界面") {
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
                Section("说明") {
                    Text("Base URL 可带或不带 /v1，应用会自动拼接 chat/completions。所有设置只保存在本机（UserDefaults）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
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
        }
    }
}

#Preview {
    SettingsView(
        settings: AppSettings(),
        worldBook: WorldBookStore(),
        store: ChatStore(),
        presets: PresetStore()
    )
}
