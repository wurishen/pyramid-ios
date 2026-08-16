import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var worldBook: WorldBookStore
    @ObservedObject var store: ChatStore
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
    SettingsView(settings: AppSettings(), worldBook: WorldBookStore(), store: ChatStore())
}
