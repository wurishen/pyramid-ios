import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

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
                Section("对话") {
                    Toggle("流式输出（默认开启）", isOn: $settings.useStreaming)
                }
                Section("说明") {
                    Text("Base URL 可带或不带 /v1，应用会自动拼接 chat/completions。所有设置只保存在本机（UserDefaults）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}

#Preview {
    SettingsView(settings: AppSettings())
}
